# macOS 26 and 27 installed qualification result

Status: implementation qualification complete; independent review pending  
Prepared: September 17, 2026  
Implementation source: `3d83b71fe646d3a2f0c8387752cb78d24e4f9b3a`  
Candidate version: 1.0.28 (build 102)

## Decision

Barline's implemented macOS 27 boundary is qualified for app-group visibility,
local shelf presentation, activation, persistence, and recovery. Native menu-bar
reordering remains deliberately unsupported on macOS 27. The Settings UI directs
users to Command-drag in the system menu bar and does not claim that Barline can
perform native reordering.

The macOS 26 backend remains unchanged and passed direct installed movement and
shelf checks. This report is implementation evidence, not authorization to
publish a release, update feed, website change, or Git tag.

## Frozen artifact

- Notarized ZIP: `.artifacts/release/3d83b71fe646d3a2f0c8387752cb78d24e4f9b3a/dist/Barline-1.0.28.zip`
- ZIP SHA-256: `bc3f58c87c99e6f76c2f532d3aa3066ecd8c480e7afca2d6200e2e4ef031b197`
- App executable SHA-256: `1a400922f94856b7351bc190629828a7e217be1f1338823347e54ae8bc971a91`
- Signature: Developer ID Application, Mabry Ventures LLC
- Gatekeeper: accepted
- Stapler: ticket validated

The same executable digest was installed at isolated candidate paths on both
qualification hosts. Neither production `/Applications/Barline.app` was
replaced.

## Host matrix

| Host | OS | Candidate path | Result |
| --- | --- | --- | --- |
| Local qualification Mac | macOS 26.6.2 (25G83) | `~/Applications/BarlineCandidate-3d83b71-macos26.app` | Passed implemented macOS 26 boundary |
| CPLCODEX01 | macOS 27.0 (26A428) | `~/Applications/BarlineCandidate-3d83b71.app` | Passed implemented macOS 27 boundary |

CPLCLAUDE01 was not used. No Mac, MenuBarAgent, SystemUIServer, or unrelated
application was restarted.

## macOS 27 results

The exact installed candidate passed:

- cold-start Stats app-group reveal with no error alert;
- Stats app-group hide with no error alert;
- five repeated hide/reveal pairs;
- hide, candidate-only quit, background relaunch, and hidden-state persistence;
- independent 1Password hide and reveal while the Stats group stayed hidden;
- Control Center preservation after an intentionally restored test state;
- candidate/helper liveness after repeated mutations;
- production-app executable integrity before and after qualification;
- zero matching failure records for `Golden Gate layout assignment failed`,
  `mutation_recovery_failed`, `Visibility logical postcondition mismatch`, or
  `Visibility verification attempt` after the final cycles.

The postcondition accepts AX enumeration churn only within an unchanged logical
section. It still rejects an unrelated item's section or display reassignment,
loss of the affected app group's semantic identity, or failure to converge to
the requested section and display.

The installed physical-click performance harness could not identify a unique
Barline control window on macOS 27 and therefore rejected the sample before
posting input. This is a harness limitation, not a passing receipt. Shelf
presentation and dismissal were instead observed directly on the exact
candidate during the installed UI qualification. The rejected harness attempt
is retained under ignored `.artifacts` evidence.

## macOS 26 results

The exact installed candidate passed:

- visible-to-hidden drag of a Stats item in Barline's layout editor;
- hidden-to-visible restoration;
- relaunch persistence of the restored visible state;
- 20 physical status-item shelf cycles with zero timeouts;
- cold latency 103.0 ms, p95 74.2 ms, and maximum 103.0 ms against the
  250 ms interaction budget;
- pointer restoration and a valid installed-candidate evidence receipt;
- Gatekeeper, code-signing, notarization-ticket, archive-digest, and executable-
  digest validation.

## Automated regression evidence

The exact implementation source passed:

- 571 Swift core tests in 59 suites;
- the focused coordinator suite, 130 tests in two suites;
- `./script/ci.sh fast`;
- Debug and Release builds;
- strict lint and static analysis;
- repository and website hygiene;
- accessibility audit;
- local status-item UI smoke, 20 shelf Accessibility cycles;
- local performance smoke, 20 cycles, zero timeouts, p95 48.4 ms;
- reopen burst, helper interruption, and recovery;
- native architecture, topology, persistence, evidence-validator, privacy, and
  support-bundle gates.

The broad `./script/ci.sh full` invocation completed all remaining gates but
reported two infrastructure failures:

1. `test-plan-core`: Apple's `xctest` runner passed the integration test, then
   stalled in XCTest IDE-session setup while waiting for workers to materialize
   before `BarlineTests` began. A standalone retry reproduced the same pre-test
   stall. No assertion or product process failed.
2. `test-xcode-ui`: `xcodebuild` stalled before creating an XCTest worker. No UI
   test began and no product assertion failed.

Both stalled Apple runners were terminated after preserving their logs and
result bundles. These two lanes are not represented as passes. Equivalent
product behavior is covered by the passing Swift core, accessibility, UI-smoke,
performance, and installed-candidate evidence above.

## Root cause resolved

The final defect was not an inability to write app-group visibility. The native
visibility write succeeded and the requested group converged, but macOS 27
re-enumerated unaffected AX items in a different within-section order. Barline
treated that incidental enumeration order as native order and rolled back a
successful mutation.

The fix changes only the macOS 27 logical backend's verification contract:

- app-group visibility is authoritative;
- native system order is not inferred from AX enumeration;
- within-section enumeration churn is tolerated;
- unrelated section or display changes still fail closed;
- the macOS 26 movement backend and protocol remain unchanged.

Regression tests cover delayed convergence, cold-start capability fallback,
collapsed app groups, duplicate aliases, inventory relocation, enumeration
churn, unrelated visibility changes, and unrelated display reassignment.

## Remaining release gates

Before public distribution:

1. Obtain independent Gemini Flash 3.8 High and GPT-6 Astra High production-
   readiness reviews against the exact source and this evidence.
2. Resolve any material findings and rerun affected gates.
3. Cut a release version/build and changelog entry from the approved source.
4. Package, sign, notarize, and repeat exact-candidate critical-path checks on
   macOS 26 and macOS 27.
5. Publish only after an explicit release decision.
