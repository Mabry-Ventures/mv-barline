# Known limitations and release status

The public latest release is Barline 1.0.66 (build 157), published October 2,
2026 from `29e82b395d184da46e860d2d26d796f835e7153b`. See
[release notes](https://github.com/Mabry-Ventures/mv-barline/releases/tag/v1.0.66)
and [execution history](EXECUTION_PLAN.md). Evidence is bound to this exact
source and signed binary, not blanket approval for later changes or every
supported configuration.

## Compatibility

- The target platform is Apple Silicon running macOS 26 or macOS 27. Intel is
  unsupported.
- macOS 27 discovery, native assignment, reordering, relaunch persistence, and
  interruption recovery were exercised on an Apple Silicon macOS 27.0 host.
  Barline uses the system position table on macOS 27 with exact identity,
  convergence verification, and interruption recovery. macOS 26 remains on the
  established XPC arrangement backend.
- The secondary shelf and graphical layout editor require an always-visible
  menu bar. Auto-hide uses native reveal instead; see
  [supported configurations](SUPPORTED_CONFIGURATIONS.md).
- Cross-application arrangement relies on unsupported system behavior. macOS
  updates and third-party item behavior can affect it. Missing or ambiguous
  identities cannot safely authorize a layout mutation.
- Multiple displays, notch/overflow, physical reconnect, sleep/wake, full-screen
  Spaces, and actual permission changes require their own runtime evidence.
  Synthetic tests alone do not certify those configurations.

- On macOS 26, delayed recovery for a missed icon click accepts a Control
  Center-hosted status window only when its frame matches Barline's control
  button's center and width (1.0.65; covered by Core tests, pending runtime
  evidence on a macOS 26 host).

- On macOS 27, Barline hides items with a system Assessment Mode assertion,
  which stops the clock from opening Notification Center. The clock repair in
  1.0.66 lifts the assertion before pressing the clock, so hidden items can
  briefly appear. Build 157 passed three Clock/Notification Center cycles on
  macOS 27.0.1: the panel opened, stayed open and dismissed; sampled frames
  showed no Barline shelf or visible hidden fixture labels. This is not
  continuous no-flicker evidence or a hard quarter-second native activation
  guarantee. Volume, brightness, capture indicators, Globe+N, multiple displays
  and every restoration failure mode need separate qualification.

- An earlier internal unnotarized 1.0.66 candidate's own control was not reachable under
  a controlled concealment assertion on CPLCODEX01. The same candidate works
  with an empty concealment configuration; notarized 1.0.65 retains its control
  under the same fixture configuration. Source and trust both differ, so
  notarization was a testable hypothesis, not a proven fix. This historical
  experiment does not describe the later signed candidates. See the
  [takeover evidence and next comparison](MACOS27_TAKEOVER.md).

- Individual AX operations have timeouts, but the complete inventory crawl has
  no aggregate deadline. Large or unresponsive inventories still need explicit
  responsiveness qualification. Starting cache reuse at completion avoids
  immediate redundant scans; it does not solve an unbounded first scan.

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

Build 157's release evidence is summarized in [execution history](EXECUTION_PLAN.md).
It passed the full Xcode 27 pipeline and signed installed journeys on one Apple
Silicon Mac running macOS 27.0.1. The 60 measured shelf cycles had zero timeouts;
the worst run's p95 was 104.7 ms. Actual Sparkle upgrade, prepared legacy-data
migration, saved-layout operations, native Focus and Clock checks passed.

macOS 26 was not retested for this release. Controlled native-menu/popover
fixtures do not prove every third-party app's behavior. Fresh-user permission
onboarding, the notched/multi-display matrix and extended sleep/wake use remain
unqualified for this build. A roughly ten-minute resource sample does not prove
multi-day stability or absence of leaks. The earlier credential boundary was
resolved and build 157 is notarized and stapled; notarization is a distribution
trust check, not proof that the app is bug-free.

### Historical 1.0.31 evidence

Barline 1.0.31 (build 108) was published on September 17, 2026. Tag `v1.0.31`
points to source `0e6ddd1823baa07247b5f7efdd7baf2114c95987`. Its exact
Developer ID app and disk image are notarized, stapled, Gatekeeper-accepted,
and checksum-bound to the public release. The full macOS 26 gate passed 582
Core tests, 201 Xcode tests, three XCUITests, helper recovery, UI smoke, and
performance checks. On macOS 27, the exact packaged build passed native
visible/hidden assignment in both directions, independent third-party item
moves, competing-click rejection, relaunch persistence, and helper
interruption/recovery.

Fresh downloads of every public release asset matched the published checksums;
the public disk image again passed stapling and Gatekeeper assessment. Gemini
Flash 3.8 High and GPT-6 Astra High independently returned GO on the bounded
release evidence. A clean install and a signed upgrade from 1.0.15 were not
rerun for 1.0.31 before publication. Physical display transitions,
release-duration soak, VoiceOver, and Full Keyboard Access remain separate open
evidence classes.

The public support site and hosted Stripe checkout do not qualify the app and do
not unlock features.

See [release requirements](RELEASING.md), [the test matrix](TEST_MATRIX.md),
and the [reliability-first acceptance contract](RELIABILITY_FIRST.md).
