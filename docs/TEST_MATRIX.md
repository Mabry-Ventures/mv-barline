# Test matrix

This is a status ledger, not release evidence. Exact candidate results belong
under ignored `.artifacts/ci/<sha>/` directories.

| Area | Current automated evidence | Status |
| --- | --- | --- |
| Pure domain | Swift Testing for snapshots, state coordination, profile presentation, display reconnect resolution, persistence/import, search, Spotlight records, and command/service validation | 582 tests in 60 suites pass for the exact 1.0.31 source candidate |
| Recovery policy | Standalone Swift script | Implemented |
| Notch overflow resolver | Standalone Swift script | Implemented |
| Debug/Release/analyze | Local Xcode steps plus the Xcode test plan | Build, analysis, and the test plan pass on both supported hosts |
| Architecture firewall | Static boundary script | Implemented and passing |
| Fixture regression | Script runs snapshot/state/profile/command cases and launches a configurable three-status-item app | 168 regressions pass on the exact-head full gate |
| Fixture app | Environment-configurable status items plus deterministic accessibility surface | Implemented as `BarlineFixture` |
| XPC interruption | Local kill/relaunch probe | Exact-head full gate passes the replacement-helper probe and eight helper-interruption/reopen cycles |
| UI smoke | Exact-build status-item, shelf Accessibility, and installed physical-equivalent journey probes | Three XCUITests and the macOS 26 UI smoke pass; the exact packaged build passes native visible/hidden assignment, competing-click rejection, relaunch persistence, and interruption recovery on macOS 27 |
| Accessibility | Source assertions and fixture runtime AX label audit | Exact-head semantic fixture audit passes; manual VoiceOver and Full Keyboard Access remain required |
| Support-bundle privacy | Encoder content probes plus static logging/credential checks | Passes on the exact-head full gate |
| Performance smoke | Shelf responsiveness and app-owned production reopen probes | Exact-head 20-cycle shelf and 20-cycle reopen presentation budgets pass in the unlocked interactive session |
| Soak | Repeated Core cycles plus XPC interruption and responsiveness | Prior integration evidence exists; the release-duration soak is explicitly deferred |
| Release/install/update | Clean archive, signing, notarization, stapling, Gatekeeper, Sparkle, SBOM, public download, and signed-upgrade gates | Build 108 passed exact-source packaging and fresh public-asset hash verification; `v1.0.31` is public. A clean install and signed upgrade from 1.0.15 were not rerun for this release |

The fail-closed full gate runs these scripts and reports unavailable permissions
or missing product behavior instead of silently treating them as passed.

## Required real-macOS scenarios

The published 1.0.31 (build 108) has exact macOS 26 source/test evidence,
macOS 27 native arrangement and recovery evidence, packaged-artifact evidence,
and fresh public-download verification. Separate runtime evidence remains for a
1.0.31 clean install, a signed upgrade from 1.0.15, Ice import,
login launch, sleep/wake, repeated sleep/wake, active-space changes, full-screen,
Stage Manager, menu bar auto-hide, display connect/disconnect, scaling changes,
notched/non-notched displays, single/multiple displays, mixed scaling,
permission deny/grant/revoke, active-profile app relaunch, App Intent,
model availability, Spotlight reindex, XPC interruption, incomplete snapshots,
menu tracking, activation rollback, or last-known-good restore.

Headless Core coverage proves deterministic display alias resolution,
ambiguity rejection, live-ID mutation targeting, profile schema v7 migration,
transactional resolved presentation, and group/spacer projection. It does not
replace the required physical display connect/disconnect runtime pass.

The build-108 receipt set passed on macOS 26.6.2 and a separate macOS 27.0 host.
Future macOS point releases still require their own exact-candidate runtime
evidence; compilation alone does not extend this result.
