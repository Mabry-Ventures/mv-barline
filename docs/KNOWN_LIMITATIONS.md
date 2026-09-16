# Known limitations and release status

This page distinguishes the published Barline 1.0.15 boundary from the
unpublished 1.0.17 candidate. Release evidence is bound to its exact source and
signed binary; it is not blanket approval for later changes.

## Compatibility

- The target platform is Apple Silicon running macOS 26 or macOS 27. Intel is
  unsupported.
- macOS 27 discovery and layout presentation were exercised on an Apple
  Silicon macOS 27.0 host. Barline 1.0.15's graphical layout was read-only on
  that system. The unpublished 1.0.17 candidate adds transactional assignment
  and reordering through the system position table, with exact identity,
  convergence verification, and interruption recovery. Runtime qualification
  of that exact candidate remains open.
- The secondary shelf and graphical layout editor require an always-visible
  menu bar. Auto-hide uses native reveal instead; see
  [supported configurations](SUPPORTED_CONFIGURATIONS.md).
- Cross-application arrangement relies on unsupported system behavior. macOS
  updates and third-party item behavior can affect it. Missing or ambiguous
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

Barline 1.0.15 (build 76) was published on September 15, 2026. Its exact
Developer ID executable and disk image are notarized, stapled, Gatekeeper-
accepted, and hash-bound to tag `v1.0.15`. Native left/right and popover journeys,
20-cycle shelf performance, and forced helper recovery passed on macOS 26.6.2
and macOS 27 RC 26A428 with zero timeouts. The signed update from public 1.0.14,
clean DMG installs, and fresh public-asset downloads passed on both supported systems.

One immediate macOS 26 fixture restoration attempt and one extra fresh
synthetic post-upgrade restoration attempt did not restore position within the
test deadline. Both were retained; the source-bound acceptance receipts later
passed. The app preserves an interrupted temporary reveal in a local recovery
journal instead of silently discarding the original position. Physical display
transitions, release-duration soak, VoiceOver, and Full Keyboard Access remain
separate open evidence classes.

A rare rapid-close miss was recorded in releases through 1.0.13. Build 76's
candidate-bound performance receipts completed without a shelf-open timeout on
either supported operating system, but that bounded result is not a claim that
third-party status items or future macOS updates can never fail.

The public support site and hosted Stripe checkout do not qualify the app and do
not unlock features.

Barline 1.0.17 is not published. Its source gates and independent code reviews
authorize only controlled installed qualification; they are not a release
verdict.

See [release requirements](RELEASING.md), [the test matrix](TEST_MATRIX.md),
and the [reliability-first acceptance contract](RELIABILITY_FIRST.md).
