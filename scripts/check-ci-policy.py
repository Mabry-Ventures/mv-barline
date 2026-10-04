#!/usr/bin/env python3
"""Fail closed on unapproved GitHub runner routes; run locally before pushing.
Requires PyYAML 6.0.3. This repository check cannot prevent allocation by another
workflow: enterprise standard Linux runners remain enabled by owner decision.
"""
from pathlib import Path
import sys
import yaml

ALLOWED = {"ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04"}
class UniqueLoader(yaml.SafeLoader):
    pass

def mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f"duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result
UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)

def inspect(root):
    errors = []
    paths = sorted((root / ".github/workflows").glob("*.y*ml"))
    for path in paths:
        try:
            if path.is_symlink():
                raise ValueError("workflow symlinks are not allowed")
            workflow = yaml.load(path.read_text(), Loader=UniqueLoader)
            for name, job in workflow.get("jobs", {}).items():
                where = f"{path.name}:{name}"
                if "uses" in job:
                    ref = job["uses"]
                    if not isinstance(ref, str) or not ref.startswith("./.github/workflows/") or ".." in ref[2:] or "${{" in ref or Path(ref).suffix not in {".yml", ".yaml"}:
                        errors.append(f"{where}: external or dynamic reusable workflow needs explicit owner review")
                    elif not (root / ref[2:]).is_file():
                        errors.append(f"{where}: local reusable workflow does not exist")
                    continue
                runner = job.get("runs-on")
                if not isinstance(runner, str) or runner not in ALLOWED:
                    errors.append(f"{where}: only literal approved Ubuntu labels are allowed (got {runner!r})")
                timeout = job.get("timeout-minutes")
                if type(timeout) is not int or not 1 <= timeout <= 180:
                    errors.append(f"{where}: set an explicit integer timeout between 1 and 180 minutes")
        except (ValueError, TypeError, AttributeError, yaml.YAMLError) as exc:
            errors.append(f"{path.name}: cannot validate workflow: {exc}")
    return errors

if __name__ == "__main__":
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    errors = inspect(root)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        sys.exit(1)
    print("CI policy: literal Ubuntu runners, bounded jobs, local reusable workflows only")
