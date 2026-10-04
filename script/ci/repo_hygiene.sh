#!/usr/bin/env bash

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# shellcheck source=script/lib/common.sh
source "$ROOT/script/lib/common.sh"

require() {
    command -v "$1" >/dev/null 2>&1 || { printf 'error: missing %s\n' "$1" >&2; exit 1; }
}

require actionlint
require ruby
require shellcheck
require node
node --input-type=module -e 'if (Number(process.versions.node.split(".")[0]) < 22) throw new Error("Website gates require Node.js 22 or newer");'

# shellcheck source=script/lib/identity.sh
source "$ROOT/script/lib/identity.sh"
barline_validate_bundle_identifier "com.example.ConfiguredBarline"
for invalid_bundle_identifier in "" "\$(UNRESOLVED)" "invalid/path" "invalid..identifier" "single"; do
    if barline_validate_bundle_identifier "$invalid_bundle_identifier"; then
        printf 'error: invalid bundle identifier passed validation: %s\n' "$invalid_bundle_identifier" >&2
        exit 1
    fi
done
legacy_bundle_identifier="com.mabryventures.""Barline"
if git grep -n -F "$legacy_bundle_identifier" -- \
    'script/*.sh' 'script/**/*.sh' ':(exclude)script/ci/repo_hygiene.sh'
then
    printf 'error: scripts must derive the Barline bundle identifier from build settings\n' >&2
    exit 1
fi

git diff --check

shell_files=()
while IFS= read -r -d '' file; do shell_files+=("$file"); done < <(git ls-files -z '*.sh' '.githooks/*')
for file in "${shell_files[@]}"; do
    bash -n "$file"
done
shellcheck --external-sources "${shell_files[@]}"
actionlint -shellcheck shellcheck

ruby -rjson -rpsych -rrexml/document -e '
  generated = ->(p) { p.start_with?(".git/", ".artifacts/", ".build/") || p.include?("/.build/") }
  Dir.glob("**/*.json", File::FNM_DOTMATCH).reject { |p| generated.call(p) }.each { |p| JSON.parse(File.read(p)) }
  Dir.glob(".github/**/*.{yml,yaml}").each { |p| Psych.safe_load(File.read(p), aliases: true) }
  Dir.glob("**/*.{plist,xcsettings,xcworkspacedata}").reject { |p| generated.call(p) }.each do |p|
    text = File.read(p)
    REXML::Document.new(text) if text.lstrip.start_with?("<?xml", "<plist", "<Workspace")
  end
'

ruby -e '
  Dir.glob(".github/workflows/*.{yml,yaml}").each do |path|
    File.readlines(path).each_with_index do |line, index|
      next unless (match = line.match(/uses:\s*([^#\s]+)@([^#\s]+)/))
      abort "#{path}:#{index + 1}: action is not pinned to a full SHA" unless match[2].match?(/\A[0-9a-f]{40}\z/)
    end
  end
'

if grep -RInE 'runs-on:[[:space:]]*(macos|\[?[^#]*self-hosted)|pull_request_target' .github/workflows; then
    printf 'error: macOS, self-hosted, and pull_request_target workflows are forbidden\n' >&2
    exit 1
fi

[[ "$(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) | wc -l | tr -d ' ')" == 1 ]] || {
    printf 'error: exactly one GitHub Actions workflow is allowed\n' >&2
    exit 1
}
ruby -rpsych -e '
  workflow = Psych.safe_load(File.read(".github/workflows/repo-hygiene.yml"), aliases: false)
  jobs = workflow.fetch("jobs")
  abort "error: exactly one portable hygiene job is allowed" unless jobs.keys == ["hygiene"]
  job = jobs.fetch("hygiene")
  abort "error: only included Ubuntu runners are allowed" unless ["ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04"].include?(job["runs-on"])
  abort "error: reusable workflows are forbidden" if job.key?("uses")
  abort "error: hygiene timeout must remain bounded at five minutes" unless job["timeout-minutes"] == 5
'
grep -q '^permissions:$' .github/workflows/repo-hygiene.yml
grep -q '^  contents: read$' .github/workflows/repo-hygiene.yml
if grep -RInE '^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*$' .github/workflows; then
    printf 'error: workflow token write permissions are forbidden\n' >&2
    exit 1
fi

required=(LICENSE NOTICE.md THIRD_PARTY_NOTICES.md SECURITY.md docs/PROVENANCE.md docs/UPSTREAM.md AGENTS.md Barline.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
for file in "${required[@]}"; do
    [[ -s "$file" ]] || { printf 'error: required repository file missing or empty: %s\n' "$file" >&2; exit 1; }
done

if git ls-files | grep -Ei '(\.p12$|\.mobileprovision$|\.provisionprofile$|sparkle.*private|notari[sz]ation.*(password|credential)|(^|/)(id_rsa|id_ed25519)$)'; then
    printf 'error: possible signing/notarization/private-key material is tracked\n' >&2
    exit 1
fi
if git grep -n -E -- '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'; then
    printf 'error: private-key material is tracked\n' >&2
    exit 1
fi

./script/test-release-evidence-privacy.sh
ruby ./script/test-app-intents-topology.rb

# Dependency-free static website checks belong in the existing Linux lane.
# They validate staging/build safeguards, not deployed release availability.
node --test site/tests/*.test.mjs

executables=(
    script/bootstrap.sh
    script/build_and_run.sh
    script/ci.sh
    script/ci/repo_hygiene.sh
    script/ci/architecture_firewall.sh
    script/generate-release-build-metadata.rb
    script/test-accessibility.sh
    script/test-fixtures.sh
    script/test-menu-bar-recovery.sh
    script/test-notch-overflow.sh
    script/test-performance-smoke.sh
    script/test-release-evidence-privacy.sh
    script/test-support-bundle-privacy.sh
    script/test-ui-smoke.sh
    script/test-xpc-interruption.sh
    .githooks/pre-commit
    .githooks/pre-push
)
for file in "${executables[@]}"; do
    [[ -x "$file" ]] || { printf 'error: required script is not executable: %s\n' "$file" >&2; exit 1; }
done

for pattern in '.artifacts/' '.build/' 'DerivedData/' 'build/' '*.xcresult'; do
    grep -Fqx "$pattern" .gitignore || { printf 'error: generated path is not ignored: %s\n' "$pattern" >&2; exit 1; }
done

ruby -e '
  Dir.glob("**/*.md").reject { |p| p.start_with?(".git/", ".artifacts/", ".build/") }.each do |path|
    text = File.read(path)
    abort "#{path}: merge-conflict marker present" if text.match?(/^(<<<<<<<|=======|>>>>>>>) /)
    abort "#{path}: Markdown file has no heading" unless text.match?(/^# /)
  end
'

printf 'Repository hygiene passed (Linux-safe; no Swift compilation or macOS validation performed).\n'
