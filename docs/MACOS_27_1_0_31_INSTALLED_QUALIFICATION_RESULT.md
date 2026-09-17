# macOS 27 installed qualification result — Barline 1.0.31 build 105

Status: **historical candidate passed the exercised single-display journeys; superseded by source changes**  
Prepared: September 17, 2026 (CT)  
Implementation source: `ec08e2c51813fbe1d85959edd0df2ae7786b4c21`  
Candidate version: 1.0.31 (build 105)  
Host: CPLCODEX01, macOS 27.0 (26A428)

## Decision

Build 105 is not the release candidate because the post-review hardening change
that removes synchronous filesystem/application lookup from SwiftUI rendering
changes the source. Its installed results remain useful as historical evidence
for the macOS 27 grouped-visibility backend, but they do not qualify build 106
or any later artifact.

The exact notarized build 105 candidate passed the exercised single-display
macOS 27 journeys. Production `/Applications/Barline.app` was not replaced.

## Frozen artifact

- Notarized ZIP: `.artifacts/release/ec08e2c51813fbe1d85959edd0df2ae7786b4c21/dist/Barline-1.0.31.zip`
- ZIP SHA-256: `65796c6f50aac3c64ee70cb9e9b2bf2c33597f6394dc373c3c393fda5a755770`
- Isolated installed path: `/private/tmp/barline-1.0.31-105.UngaLU/Barline.app`
- Signature: Developer ID Application: Mabry Ventures LLC (A886EMZZW6)
- Gatekeeper: accepted (Notarized Developer ID)
- Stapler: ticket validated

## Observed macOS 27 results

The following were exercised against the exact isolated build 105 candidate:

1. The layout inventory loaded and classified 1Password, Control Center, and
   Clock as visible, with the Stats application group hidden.
2. Stats moved hidden → visible → hidden without an error alert.
3. 1Password moved visible → hidden → visible independently of Stats.
4. A cold candidate-only relaunch preserved the restored visibility state.
5. Revealing Stats exposed a real Stats CPU status item and its native menu
   opened successfully.
6. Temporarily revealed items re-hid after the configured delay.
7. Terminating the candidate's XPC helper caused a new helper process to spawn;
   a subsequent Stats visibility mutation succeeded.
8. The production application path and installed production bundle were left
   untouched.

## Evidence limits

- Only a single display was attached to CPLCODEX01. Multi-display, notched
  display, disconnect/reconnect, and display-topology migration were not tested.
- The exercised native interaction used macOS 27 direct reveal mode, not a
  separate Barline shelf presentation journey.
- Five consecutive Stats hide/reveal pairs were not recorded as a single
  receipt-backed run.
- Sleep/wake and launch/termination while concealed were not exercised.
- Two Xcode-driven lanes previously ended before test assertions with worker
  launch exit 73. Direct XCTest evidence covered the underlying test bundle,
  but the Xcode UI-runner infrastructure issue remained unresolved for build
  105.
- The verification algorithm deliberately rejects its first matching
  observation until a second matching observation establishes settled state.
  Therefore a zero-match requirement for `Visibility verification attempt` is
  invalid and is not used as a qualification criterion.

## Superseding candidate requirements

Build 106 or later must be rebuilt, signed, notarized, installed, and validated
as a new exact artifact. No build 105 digest or runtime result may be presented
as proof for the superseding build. At minimum, repeat the grouped assignment,
persistence, native-menu, temporary-rehide, and helper-recovery journeys on
macOS 27, and rerun the macOS 26 regression matrix before release review.

This document records implementation evidence. It is not authorization to
publish, tag, update the appcast, or deploy a download.
