# Linux host proof for verify-barline

This is the generator-run record for the Linux Cursor VM. Runtime artifacts remain under gitignored `.artifacts/verify-barline/linux-proof-20260917/` after cleanup. This file is the committed, privacy-safe summary. It is **not** a menu-bar UI proof.

## Host

- OS: Linux x86_64
- `control-barline host` → `host_class=linux`, `ui=gated`, `linux_lane=hygiene`
- Date: 2026-09-17

## Doctor

`VERIFY_BARLINE_RUN_ID=linux-proof-20260917` `control-barline doctor` on source `86a66d20b00da3d742ff52d1f0a6eb7fce746aef` (clean worktree):

```
ui=gated
hygiene=ready
linux_gates=ready
reason=Linux Cursor VM cannot launch or drive the macOS menu-bar app
full_launch_drive_proof=requires Apple Silicon macOS 26+ with host Accessibility; Barline Accessibility for arrangement; Screen Recording optional
```

## Gated Mac commands (expected)

| Command | Exit |
| --- | --- |
| `control-barline launch` | 2 `GATED` |
| `control-barline click --name Advanced` | 2 `GATED` |
| `control-barline snapshot --path …` | 2 `GATED` |

No Barline process was started. No screenshot of a menu bar was taken.

## Proven: `control-barline linux-gates`

Exit 0, `linux-gates failures=0`. Wrapped documented scripts only:

| Gate | Result |
| --- | --- |
| `./script/ci/repo_hygiene.sh` | PASS (Linux-safe; no Swift compilation) |
| `./script/ci/architecture_firewall.sh` | PASS |
| `bash ./script/test-platform-lane.sh` | PASS (18 cases; no runtime certified) |
| `ruby ./script/test-app-intents-topology.rb` | PASS (23 cases) |
| `bash ./script/test-installed-evidence.sh` | PASS (91 synthetic validator cases) |
| `bash ./script/test-evidence-writer.sh` | PASS (44 synthetic writer cases) |
| `bash ./script/test-installed-app-pause.sh` | PASS (10 cases; no processes stopped) |
| `bash ./script/test-release-notes.sh` | PASS (6 cases) |
| `bash ./script/test-release-evidence-privacy.sh` | PASS |
| `node --test site/tests/*.test.mjs` | PASS (15 tests) |

`script/lib/common.sh` was rewritten from `A && B || die` to an `if` so ShellCheck SC2015 no longer fails `repo_hygiene.sh` on this host or on GitHub's Ubuntu hygiene job.

## Cleanup

`control-barline cleanup` reported evidence retained at `.artifacts/verify-barline/linux-proof-20260917`. `doctor.txt`, `linux-gates.log`, `commands.log`, and `logs/` were still present after teardown. No instance PIDs existed to kill.

## Still gated (need Apple Silicon macOS 26+)

- Launch of unsigned Debug Barline (`./script/build_and_run.sh --verify`)
- Settings / welcome / degraded-mode UI (`features/settings.md`)
- Reveal hidden items / Barline Bar (`features/reveal-hidden-items.md`)
- Search (`features/search.md`)
- Layouts and Focus (`features/layouts-and-focus.md`)
- Diagnostics support-bundle UI (`features/diagnostics.md`)
- Host Accessibility, Barline Accessibility, Screen Recording, Developer Tools, installed-candidate journeys

Re-run those recipes on a Mac with `control-barline launch` and `control-barline doctor` reporting `ui: ready` or `ui: degraded`. Do not treat this Linux record as those features passing.
