# Test matrix

This is a status ledger, not release evidence. Exact candidate results belong
under ignored `.artifacts/ci/<sha>/` directories.

| Area | Current automated evidence | Status |
| --- | --- | --- |
| Pure domain | Swift Testing for snapshots, state coordination, profile presentation, display reconnect resolution, persistence/import, search, Spotlight records, and command/service validation | 380 tests pass for the 1.0.13 source candidate |
| Recovery policy | Standalone Swift script | Implemented |
| Notch overflow resolver | Standalone Swift script | Implemented |
| Debug/Release/analyze | Local Xcode steps in `script/ci.sh full` | Exact-head full gate passes on macOS 26.6.2 arm64 |
| Architecture firewall | Static boundary script | Implemented and passing |
| Fixture regression | Script runs snapshot/state/profile/command cases and launches a configurable three-status-item app | 168 regressions pass on the exact-head full gate |
| Fixture app | Environment-configurable status items plus deterministic accessibility surface | Implemented as `BarlineFixture` |
| XPC interruption | Local kill/relaunch probe | Exact-head full gate passes the replacement-helper probe and eight helper-interruption/reopen cycles |
| UI smoke | Exact-build visible-status-item and cold-launch shelf Accessibility probe plus compiled XCUITest target | Four fixture XCUITest scenarios and production smoke pass in the unlocked interactive session without activating Barline |
| Accessibility | Source assertions and fixture runtime AX label audit | Exact-head semantic fixture audit passes; manual VoiceOver and Full Keyboard Access remain required |
| Support-bundle privacy | Encoder content probes plus static logging/credential checks | Passes on the exact-head full gate |
| Performance smoke | Shelf responsiveness and app-owned production reopen probes | Exact-head 20-cycle shelf and 20-cycle reopen presentation budgets pass in the unlocked interactive session |
| Soak | Repeated Core cycles plus XPC interruption and responsiveness | Prior integration evidence exists; the release-duration soak is explicitly deferred |
| Release/install/update | Clean archive, signing, notarization, stapling, Gatekeeper, Sparkle, and SBOM gates | Build 38 passed exact-source packaging, signing, notarization, stapling, Gatekeeper, Sparkle, SBOM, public hash verification, and an installed launch check, and was published as `v1.0.13`; clean installation on a Mac that has never run Barline and installed click journeys were not run |

The fail-closed full gate runs these scripts and reports unavailable permissions
or missing product behavior instead of silently treating them as passed.

## Required real-macOS scenarios

The published 1.0.13 (build 38) has an installed upgrade and launch check from
the exact public disk image. The published 1.0.12 (build 37) has bounded signed
Sparkle upgrade evidence from build 36. The
clean-install, helper-interruption, Focus and target-activation evidence belongs
to 1.0.11 (build 36) and does not qualify build 37. Separate runtime evidence remains for Ice import,
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

macOS 27 runtime compatibility cannot be claimed without a macOS 27 host. The
current host documented in the baseline audit has Xcode 26.6 only.
