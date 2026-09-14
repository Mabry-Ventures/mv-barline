# Known limitations and release status

This page describes the boundaries of Barline 1.0.14. Release evidence is bound
to its exact source and signed binary; it is not blanket approval for later
changes.

## Compatibility

- The target platform is Apple Silicon running macOS 26 or macOS 27. Intel is
  unsupported.
- macOS 27 discovery and layout presentation were exercised on an Apple
  Silicon macOS 27.0 host. Barline's macOS 27 backend is deliberately
  read-only; arrangement uses native Command-drag and fails closed when public
  Accessibility cannot provide unambiguous inventory or divider geometry.
- The secondary shelf and graphical layout editor require an always-visible
  menu bar. Auto-hide uses native reveal instead; see
  [supported configurations](SUPPORTED_CONFIGURATIONS.md).
- Cross-application arrangement relies on unsupported WindowServer behavior.
  macOS updates and third-party item behavior can affect it. Missing or ambiguous
  identities cannot safely authorize a layout mutation.
- Multiple displays, notch/overflow, physical reconnect, sleep/wake, full-screen
  Spaces, and actual permission changes require their own runtime evidence.
  Synthetic tests alone do not certify those configurations.

## Features in qualification

Saved layouts, import/export, transactional activation, recovery, native Focus
Filter integration, groups, and search favorites/aliases are included.

Display-layout authoring, explainable context rules, and per-item shortcuts are
included. Barline integrates through native Focus Filters and does not provide
an independent catalog of macOS Focus modes.

Automatic rules are optional and start paused after relaunch. Resume is explicit;
manual layout changes pause them again. Rules never restart other applications
to change system item spacing; such layouts must first be applied manually.

Deterministic search remains available without Apple Intelligence. Optional
on-device interpretation and Spotlight behavior have separate availability and
validation requirements; see [search architecture](SEARCH_AND_APPLE_INTELLIGENCE.md).

## Current reliability and distribution boundary

Barline 1.0.13 (build 38) was published on September 13, 2026. Before
publication it passed 380 Core tests, the fixture, recovery, privacy,
accessibility, menu-bar, performance, Debug/Release, analysis, and repository
hygiene lanes on macOS 26.6.2. Its Developer ID app and disk image were
notarized, stapled, and accepted by Gatekeeper. The exact public disk image was
hash-verified, installed over 1.0.12 on the maintainer Mac, and launch-checked.
The XCUITest lane could not acquire macOS UI Automation authorization; separate
Accessibility UI and performance lanes passed.

Clean installation on a Mac that has never run Barline has not been run. It is
the only way to exercise the disk image install, the move-to-Applications offer,
and the walkthrough's real permission grants. Installed click journeys against
the signed app, physical configuration, accessibility, and release-duration soak
also remain distinct open evidence classes. Historical failed attempts remain in
local evidence and are not overwritten by later passes.

A click that closes the shelf within about 300 ms of opening it can be ignored
when Barline's WindowServer confirmation for that presentation times out. The
shelf stays open and the next click closes it. Automated rapid open/close
testing observed this in about 1 of 300 cycles; ordinary click timing is
expected to reach that window far less often. Its cause is still under
investigation, and it is accepted as a known limitation through 1.0.13.

The public support site and hosted Stripe checkout do not qualify the app and do
not unlock features.

See [release requirements](RELEASING.md), [the test matrix](TEST_MATRIX.md),
and the [reliability-first acceptance contract](RELIABILITY_FIRST.md).
