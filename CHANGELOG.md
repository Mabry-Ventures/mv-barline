# Changelog

## 1.0.22 (build 96) — September 16, 2026

- macOS 27: request read-write access to the one user-selected menu-bar position file. The signed release gate now rejects a build carrying the insufficient read-only entitlement.

## 1.0.21 (build 95) — September 16, 2026

- macOS 27: add privacy-safe transaction-stage diagnostics so an unrecognized system preference change fails closed with an actionable support code rather than an opaque error.

## 1.0.20 (build 94) — September 16, 2026

- macOS 27: reliably request scoped access to the exact system menu-bar position file before attempting a layout change. This avoids POSIX permission false positives that could prevent the access picker from appearing.

## 1.0.19 (build 93) — September 16, 2026

- Restore macOS 27 hidden third-party items even when macOS does not permit a
  second concealment operation. The direction-specific capability rule now
  applies only to moves into Hidden, so a hidden item never becomes stranded.

## 1.0.18 (build 92) — September 16, 2026

- Make the macOS 27 layout path actionable: eligible third-party items now
  reach the native transaction preflight instead of being silently disabled
  when their position-table identity has not been proven.
- Scope authorization to the single macOS menu-bar preference file rather than
  its containing directory, and retire earlier directory-scoped bookmarks so
  users receive one precise, user-initiated repair prompt.
- Report an unresolved native record as a no-write failure with a support
  diagnostic code. Barline never guesses a position-table key or changes the
  layout in that state.

## 1.0.17 (build 91) — September 15, 2026

- Replace macOS 27's synthetic menu-bar movement path with bounded,
  identity-resolved transactions against the system's authoritative menu-bar
  position table. macOS 26 remains isolated on its established XPC backend.
- Verify every proposed position change against fresh Accessibility inventory;
  fail closed and conditionally roll back when native state does not converge.
- Preserve protected system anchors and unrelated position keys, support first
  hide, reveal, restore, and same-section reorder, and report every item changed
  by collision-free re-spacing.
- Add a durable, fully synchronized transaction journal with launch recovery,
  verified companion-state replay, corrupt-journal quarantine, and external
  writer precedence.
- Separate no-side-effect preflight failures, concurrent native winners, and
  recovery-owned transactions so the coordinator never issues a stale second
  restore.
- Repair revoked or corrupt menu-bar preference bookmarks through an explicit,
  user-initiated authorization flow while keeping passive discovery
  noninteractive.
- Bound retained inventory and saved-layout restoration, preserve exact native
  order through transient Accessibility absence, and add macOS 26/27 routing,
  recovery, re-spacing, and compensation regressions.

## 1.0.16 (build 90) — September 15, 2026

- Serialize macOS 27 presentation synchronization with moves, saved-layout
  activation, Focus changes, history, rollback, and helper recovery. A delayed
  cache refresh can no longer replay a stale complete visibility configuration
  after a newer authoritative layout commits.
- Derive every presentation update from a fresh authoritative snapshot after it
  acquires the shared transaction turn, and discard canceled queued work before
  it can reach the native concealment helper.
- Preserve the latest presentation request across an in-flight shelf-item
  activation, then apply it after the interaction lease ends without disturbing
  the temporary reveal/activate/restore journey.
- Track the helper-acknowledged native configuration independently from the
  logical inventory so a failed change restores the presentation users actually
  had, including retained items no longer present in Accessibility.
- Treat superseded presentation synchronization as normal cancellation and use
  deadline-bounded handshakes in the coordinator concurrency regression tests.
- Retry a serialized macOS 27 presentation refresh through the provider's
  short discovery-cache window instead of dropping the native update.
- Schedule routine presentation reconciliation beyond the provider cache window
  to avoid unnecessary mutation-turn contention while retaining bounded retry.
- Define the macOS 27 discovery-cache and presentation-debounce windows from one
  timing policy, with direct app-layer coverage for burst deduplication and
  cancellation before assignment.
- Drive debounce tests with a controllable suspension point rather than elapsed
  wall time, so scheduler load cannot create false failures.

## 1.0.16 (build 84) — September 15, 2026

- Make macOS 27 native concealment a token-bound two-phase transaction. A
  timeout, cancellation, delayed callback, or missing callback aborts only the
  pending candidate and can no longer replace the last accepted assertion.
- Serialize native configuration changes across suspension and preserve
  reference-counted reveal ownership, so retries and overlapping activation
  cannot race each other or report a temporary collision as missing support.
- Reveal AX-absent hidden items natively before resolving fresh Accessibility
  identity and geometry, then retry reconcealment until the accepted logical
  state is restored. macOS 26 keeps its established physical-move workflow.
- Preserve retained items in their stable global native slots, accept
  cross-section assignment without inventing a physical reorder, and recompute
  bundle-level assignment eligibility over the complete merged inventory.
- Persist retained inventory without runtime process identifiers, geometry, or
  live-screen state.

## 1.0.16 (build 83) — September 15, 2026

- Keep successfully concealed macOS 27 items in a bounded retained inventory,
  so Hidden remains actionable after Accessibility removes those items from its
  live tree and after Barline relaunches.
- Wait for the native assessment assertion's asynchronous acceptance before
  committing a layout. A rejected replacement leaves the prior assertion and
  persisted layout intact instead of reporting issuance as success.
- Treat native assertion acceptance as concealment authority while requiring a
  fresh Accessibility observation when revealing an item.

- Publish the borderless, nonactivating Barline Bar as an explicit
  Accessibility window. Its native item controls are now traversable from the
  owning application's AX window tree on the first presentation after launch.
- Keep the source-bound 250 ms performance receipt authoritative while the
  post-Xcode installed gate independently exercises shelf and helper recovery.
  Test-runner teardown load is recorded without becoming a duplicate timing gate.

- Let macOS 27 users assign supported menu bar items between Barline's visible
  and hidden sections. Barline commits the complete visibility state through
  macOS's native concealment controller and persists it only after Accessibility
  inventory proves the system reached the requested visibility.
- Keep unsupported per-item assignments disabled when macOS exposes multiple
  status items for one application or cannot map an Apple system item safely.
  Physical menu bar ordering remains available through Command-drag.
- Make each supported macOS 27 item a direct click target as well as a drag
  source, so visible and hidden assignment remains reliable across SwiftUI
  drag-session behavior changes.
- Preserve assignments for temporarily absent applications, advance helper
  generations after every accepted change, and reject unsafe saved-layout
  restores without altering the current menu bar.
- Keep macOS 27 saved layouts and Focus Filters aligned with native status-item
  order while allowing supported items to change visibility sections. Profiles
  no longer depend on the older physical-divider ordering rule on this backend.
- Keep an explicitly selected Xcode toolchain pinned across every nested
  validation gate so mixed installations cannot contaminate release evidence.
- Use macOS 27's typed drag-and-drop path for Settings assignments, verify the
  native menu bar reaches the requested visibility before persisting a change,
  and restore the prior configuration after any rejected or timed-out update.

## 1.0.15 (build 76) — September 14, 2026

- Fix a macOS 27 Settings appearance mismatch that could render the menu-bar
  inventory on a light surface with invisible light labels. The inventory now
  uses explicit, contrast-safe light and dark palettes.

## 1.0.15 (build 75) — September 14, 2026

- Complete the input-idle fix with an explicit AppKit dependency at the app
  boundary. Build 74 was rejected by the clean Debug and Release compile gate.

## 1.0.15 (build 74) — September 14, 2026

- Ignore persistent keyboard-device flags such as Numeric Pad and Caps Lock
  when waiting for pointer input to settle. macOS 27 can report Numeric Pad
  continuously with no held key; shelf activation now waits only for actual
  Command, Option, Control, Shift, or Function chords.

## 1.0.15 (build 73) — September 14, 2026

- Make the macOS 27 shelf use fixed-width application icons and semantic SF
  Symbols immediately instead of attempting unsupported per-item captures
  after presentation. Its click targets no longer move between mouse-down and
  mouse-up, and the fallback path no longer requires Screen Recording.
- Require three consecutive, in-window geometry samples in the installed
  native-click gate so the test never clicks a shelf that is still laying out.

## 1.0.15 (build 72) — September 14, 2026

- Render the macOS 27 menu bar inventory entirely with SwiftUI semantic
  foregrounds and backgrounds so dark and tinted Settings appearances cannot
  produce invisible labels on a light AppKit-resolved surface.
- Stop consuming unreliable macOS 27 per-item captures in the read-only layout
  inventory. Application items use their app icon, while system items receive
  a named, deterministic SF Symbol instead of blank or stretched placeholders.

## 1.0.15 (build 71) — September 14, 2026

- Fail the dropped-control-click recovery closed unless AppKit exposes a
  finite, status-item-sized accessibility frame and the event is inside the
  menu bar. Target menus and popovers on macOS 27 can no longer be mistaken
  for the three-dot control even when its hosted scene uses a broad container.

## 1.0.15 (build 70) — September 14, 2026

- Restrict the scene-backed status-item recovery fallback to the exact Barline
  button bounds. On macOS 27, a hosted status-item window can span far beyond
  the button; clicks inside Barline's shelf are now explicitly excluded so a
  successful hidden-item activation cannot reopen the shelf 100 ms later.

## 1.0.15 (build 69) — September 14, 2026

- Route natural-language search activation through the same dedicated
  status-item command path as shelf and item-search activation. No activation
  entry point can fall back to the transactional layout-mutation API.

## 1.0.15 (build 68) — September 14, 2026

- Treat status-item activation as an acknowledged command instead of a
  transactional layout mutation. After a target accepts its click, Barline no
  longer performs a post-delivery inventory validation or rollback that can
  misclassify the successful activation and reopen the shelf on macOS 27.

## 1.0.15 (build 67) — September 14, 2026

- Treat every click owned by Barline's shelf as a shelf interaction, even in
  the narrow area where the macOS 27 menu bar and shelf geometries overlap.
  Activating a custom popover can no longer schedule a delayed empty-space
  toggle that reopens the shelf over the target interface.

- Present macOS 27 menu bar inventory as readable, named items using native
  Settings colors instead of placing tiny fallback artwork in an imitation
  menu bar. Empty sections now state clearly that they contain no items.

- Keep macOS 27 menu bar item fallbacks at native icon size instead of
  stretching generic artwork across each item's measured width. Prefer the
  source application's icon when available while preserving the real layout
  geometry and accessible item label.
- Keep standalone release probes compatible with both the Xcode 26 and Xcode
  27 SwiftPM product layouts.
- Handle cancellation inside delayed UI tasks explicitly so the production app
  builds cleanly with the Swift 6.3 diagnostics in Xcode 27.

## 1.0.14 (build 62) — September 14, 2026

- Keep the macOS 27 native-concealment bridge compile-time linked through the
  helper target's Objective-C bridging header. Release dead-code stripping can
  no longer remove the bridge entry points and make shelf activation fail
  before its click is delivered.

## 1.0.14 (build 61) — September 14, 2026

- Route both macOS 26 status-item buttons through the same source-targeted
  WindowServer delivery path. Keep its session observation tap passive so
  disabling the acknowledgement cannot swallow the click before AppKit sees it.

- Keep the proven macOS 27 Accessibility click route independent and unchanged;
  Golden Gate activation continues to use the exact physical-equivalent event
  sequence qualified on macOS 27.

## 1.0.14 (build 56) — September 14, 2026

- Deliver macOS 27 status-item activation at the freshly resolved public
  Accessibility bounds instead of falling back to the retired per-item
  WindowServer inventory. Left- and right-clicks use the same guarded,
  physical-equivalent route and still require independent interface evidence.

- Deliver secondary clicks through a guarded physical-equivalent route on
  macOS 26 as well, preventing hosted status items from remaining in menu
  tracking without receiving their right-click action.

- Keep the hidden-item shelf interactive on macOS 27 by explicitly accepting
  pointer events in its nonactivating panel. Physical, keyboard, and
  Accessibility activation now share the same native button path.

- Observe temporarily revealed macOS 27 items through their public
  Accessibility owner rather than the legacy per-status-item WindowServer
  inventory. Order-only identity changes are rebound only when the semantic
  match is unique; ambiguous targets continue to fail closed.

- Activate macOS 27 shelf items through their exact Accessibility identity,
  avoiding stale WindowServer coordinates after native concealment changes.
  An indeterminate Accessibility acknowledgement is never retried, preventing
  duplicate actions while Barline independently verifies the opened interface.

- Use macOS 27's native menu-bar assessment restriction to conceal supported
  hidden items while keeping Barline's shelf responsive. Shelf presentation no
  longer creates a duplicate native copy, and activating a shelf item widens
  the native allowlist only for the lifetime of that interaction.

- Apply macOS 27 concealment at the application boundary. Apps whose menu-bar
  items have mixed visible and hidden assignments remain visible, and unknown
  Apple system items fail visible rather than hiding the wrong control.

- Refresh the native allowlist when applications launch, quit, or change their
  status items so a stale process inventory cannot strand a newly launched app.

- Remember the last verified macOS 27 section assignment locally after a native
  Command-drag. Relaunches can restore hiding without flashing the divider;
  new, changed, mixed, or ambiguous items remain visible until verified.

- Accept macOS 27's measured Accessibility attachment seams at a status-item
  divider while keeping overlaps beyond the divider width fail-safe.

- Preserve each meaningful status-item label in the macOS 27 shelf so multiple
  controls from one application remain distinguishable, including to assistive
  technologies; unnamed items continue to use the application name.

- Restore menu bar discovery on macOS 27, where WindowServer now exposes one
  composite menu bar surface instead of one window per status item. Barline
  uses a bounded, read-only Accessibility inventory and preserves native
  Command-drag as the arrangement path on macOS 27.

- Run the macOS 27 Accessibility inventory in Barline's signed application
  process, matching macOS's process-bound permission model instead of asking
  the embedded helper to read an authorization it cannot inherit.

- Keep the macOS 27 hidden-section divider addressable through public
  Accessibility while it remains visually collapsed, restoring reliable
  hidden-item classification.

- Classify macOS 27 section geometry across live, parked, and expanded divider
  states without allowing ambiguous or missing controls to replace the last
  known-good layout.

- Keep the graphical layout inventory usable when Screen Recording is absent
  by showing deterministic fallback item icons. Pixel previews remain optional.

- Coalesce repeated AppKit lifecycle and status-item window notifications while
  menu bar discovery is already running. One bounded trailing refresh preserves
  the latest inventory without allowing an operating-system event storm to
  restart discovery indefinitely.

- Add privacy-bounded discovery counters and closed failure codes to support
  bundles so empty inventories, incomplete snapshots, missing controls, and
  lifecycle churn can be distinguished without collecting item names, process
  lists, screen content, or paths.

## 1.0.13 (build 38) — September 13, 2026

- Prevent Menu Bar Layout, search, and the shelf from remaining on an infinite
  loading indicator when macOS temporarily cannot provide a complete menu bar
  snapshot.

- Retry transient discovery failures within a strict bound and retry again when
  Barline's menu bar controls become available, without polling in the
  background or replacing the last known-good item list.

- Distinguish a verified empty menu bar from a discovery failure. Failed
  discovery now ends with a clear error, a Try Again action, and access to
  diagnostics instead of an indefinite spinner.

## 1.0.12 (build 37) — September 12, 2026

- Download Barline as a disk image. Open it and drag Barline onto the
  Applications shortcut. The zip remains the update package, so updating from an
  earlier version works as before.

- When Barline is opened from outside an Applications folder, it offers to move
  itself there before asking for any permission. macOS ties Accessibility and
  Screen Recording permission to where an app runs, so permission granted from
  Downloads could otherwise be lost after moving the app.

- New installs open a short walkthrough. It explains Accessibility and Screen
  Recording, asks for each only when you click, shows how the visible, hidden,
  and always-hidden sections work, and opens the layout editor. Every step can be
  skipped, and Settings › General can show it again. People updating from an
  earlier version are not shown it.

- Update the CompactSlider control library to 2.1.0 and remove the unused Ifrit
  library. The acknowledgements in About now match the libraries Barline ships.

- Known limitation: a click that closes the shelf within about 300 ms of opening
  it can be ignored. The shelf stays open and the next click closes it.

## 1.0.11 (build 36) — September 11, 2026

- Ship Sparkle's update framework and helpers as arm64-only. Barline supports
  Apple Silicon only, so release packaging removes non-arm64 code from prebuilt
  dependencies before signing and rejects any executable code in the app that
  is not arm64.

- Known limitation: a click that closes the shelf within about 300 ms of opening
  it can be ignored. The shelf stays open and the next click closes it.

- Move the canonical repository to `Mabry-Ventures/mv-barline`. The Sparkle
  update feed, About links, issue templates, release tooling, SBOM namespace,
  and website links now use that name. No public release has been published
  under the previous name, so no installed client points at the old feed.

- Keep the nonactivating shelf panel registered with AppKit while hidden and
  use the standard nonactivating order path when showing it. This makes a true
  clean-install cold launch publish the shelf through the application's
  Accessibility window list without activating Barline or claiming focus.
  Barline augments AppKit's live Accessibility window list only while the shelf
  is visible, preserving native Settings-window discovery. AppKit owns the
  native shelf role; repeated presentations must expose exactly one shelf root.

Build 34 passed its full source, signing, notarization, update, installed
interaction, recovery, and performance gates. Its independent clean-package
cold launch exposed a visible and hit-testable shelf that remained absent from
the application Accessibility window list, so build 34 was not published.

- Publish the cold-launch shelf through the macOS Accessibility window tree
  without activating Barline, making it frontmost, or claiming keyboard focus.
  The existing nonactivating presentation now exposes explicit window semantics
  and a window-created notification after its visible commit.

- Recheck temporarily unavailable helper capabilities on later requests, with
  bounded probing and no background retry loop, instead of retaining a failed
  startup probe permanently. Signed installed qualification covers forced helper
  interruption followed by a successful shelf interaction.

- Distinguish interrupted Focus transaction failures from final verification
  failures using fixed privacy-safe diagnostic codes.

- Keep clock, Control Center and other non-hideable status items out of
  empty-space click and hover handling. Preserve genuine empty-space clicks
  around Barline's noninteractive layout separators.
- Reject delayed empty-space click results after a newer click.
- Offer an explicit, confirmation-gated restore for an interrupted Focus
  checkpoint; retain the checkpoint when restoration cannot be verified.

- Plan saved layouts around fixed system items and newly discovered items,
  preserving display ownership and avoiding redundant drag operations.
- Verify complete layout results before committing profile authority; reject
  unsupported physical destinations before changing workspace settings.
- Keep Barline's section dividers fixed during saved-layout application and
  reject unadmitted display changes or impossible divider ordering.
- Retain observed workspace presentation during pending Focus recovery instead
  of clearing the evidence needed for safe restoration.

- Correct the macOS Focus Filter extension's launch and embedding topology;
  add regression gates for registration and extracted intent metadata.
- Cancel superseded status-item window/screen observations and clear detached
  geometry instead of allowing stale owners to overwrite current state.

- Restore baseline target-process routing for matched shelf clicks before
  acknowledging session delivery, without replaying a mouse-down.
- Correct display-variant authoring guidance in Layouts & Focus.
- Allow deleting the final saved layout; persist an empty local catalog without
  weakening validation for imported/exported archives.

- Capture and edit verified display-specific layout variants without replacing
  the base layout or silently discarding a failed-save draft.
- Add optional, event-driven frontmost-app and power/battery layout rules using
  the existing transaction and rollback path. Configured Focus layouts and
  manual changes take priority; rules start paused after relaunch.
- Add per-item global shortcuts, once-per-release dispatch, conflict reporting,
  and private atomic storage. Failed changes preserve prior assignments.
- Harden shortcut suspension, teardown, and registration recovery.
- Improve visitor documentation, privacy guidance, issue intake and verified
  private security reporting. Preserve Ice attribution and GPL notices.
- Make the shelf timing probe reject failed closes immediately and reacquire
  its target before each click, so later samples cannot hide a failed cycle.

Published September 11, 2026 as `v1.0.11`, Barline's first public release,
after the local macOS 26 gate, Developer ID signing, Apple notarization,
stapling, Gatekeeper assessment, and a signed update from build 34. Installed
click journeys against the signed app were not run before publication. macOS 27
runtime qualification and the extended soak remain deliberately deferred and are
not claimed by this release.

## 1.0.10 (build 19) — candidate

- Collapse and expand valid shelf groups without rearranging physical menu bar
  items; preserve access when group membership is ambiguous.
- Add local search favorites and aliases with bounded, private, atomic storage.
- Guide saved layouts through native macOS Focus Filter setup and clarify
  existing display-variant behavior.
- Keep optional support confined to About and disabled until the canonical
  site is live. No subscription, tracking, paid unlock, or payment reminders.

This candidate is not yet qualified or published. Contextual auto-application
and per-item global shortcuts remain future work, not release features.

## 1.0.9 (build 18)

- Prevent delayed drag callbacks from posting after cancellation or timeout.
- Complete hosted item drags before evaluating their final placement, even
  when macOS does not report an intermediate geometry transition.

- Bind delayed rehide work to its originating presentation, so an old click,
  hover, or timer cannot dismiss a newer shelf.
- Give the primary control window exclusive ownership of its clicks and use
  captured event coordinates for empty-space click arbitration.
- Exclude windowless hosted control clicks from smart rehide, independently
  of asynchronously cached menu-bar geometry.

- Restore temporarily revealed items to their original section/display even if
  neighboring icons disappear or move.
- Resolve hidden items' logical display ownership independently of their
  off-screen coordinates before activation or restoration.
- Preserve interrupted restoration across restarts and expose Retry Item
  Restoration in Layouts & Focus. Pause after three unsuccessful attempts.
- Keep pending restoration intact when a competing layout operation cannot
  proceed safely.
- Require exact-candidate target-action, performance and helper-recovery receipts
  before installed qualification passes.
- Match macOS-hosted status-item geometry consistently in performance probes,
  with regression tests for the observed two-point source/host width difference.

Changes below describe historical development candidates and are not release
certification.

### 1.0.8 local candidate corrections

- Route shelf-item clicks through the macOS session event stream with ordered
  source-queue barriers; do not mistake direct-process receipt for activation.
- Keep temporarily revealed native items out of the shelf until restoration,
  without changing saved layout positions.
- Prevent picker presentation during reveal/restore and avoid automatically
  reopening it over an unconfirmed or delayed target interface.
- Verify physical display geometry before treating a hosted item as visible;
  a stale macOS on-screen flag can otherwise skip reveal and click off-display.

### Added

- Barline product identity, original temporary icon sources, centralized build
  configuration, provenance, GPL notices, and local build commands.
- `BarlineCore` foundations for stable item identity, snapshot validation,
  last-known-good state coordination, profile schema version 7, profile JSON
  migration/validation with exact appearance checkpoints, atomic profile-file
  storage and recovery, deterministic
  search, Spotlight record bounds, and typed command validation.
- Core Spotlight indexing and a bounded typed Foundation Models interpreter
  connected behind deterministic validation and confirmation.
- Compatibility contracts and a strict XPC compatibility firewall.
- Saved profile editing/import/export, transactional activation, Focus and App
  Intent delivery, Presentation templates, opaque display reconnect aliases,
  operational shelf groups/spacers, and last-known-good recovery.
- A General setting that keeps Barline out of the Dock even while its Settings
  window is open.
- Contextual permissions and degraded settings/search/diagnostics behavior.
- Privacy-safe reviewed support-bundle export and a deterministic fixture app.
- Release-only Sparkle trust configuration and credentialed packaging tooling.
- Linux-only repository-hygiene workflow and fail-closed local CI command
  surface.

### Changed

- Minimum deployment target is macOS 26.0 and shipping builds are intended for
  Apple Silicon only.
- Product-facing Ice names and identifiers were replaced with Barline; Ice
  remains in provenance, attribution, historical migration keys, and historical
  documentation where necessary.
- Apple's Focus settings now select any saved Barline Profile directly instead
  of enabling a Barline-specific Presentation mode. Profile and Focus changes
  serialize layout, workspace settings, and resolved group/spacer presentation
  as one verified transaction, retain a crash-stable pre-Focus journal, and
  clear authority when rollback or a restored profile definition cannot be
  proven current.
- Menu-bar restoration now uses global cross-display planning, section-relative
  postconditions, explicit stable destination-display targeting,
  already-correct no-op handling, and monotonic helper generation rebasing.
- The hidden-item shelf now keeps a valid AppKit presentation ordered while an
  unrelated compatibility-helper request delays WindowServer observation.
  Helper confirmation remains stronger evidence and recovery input, but helper
  availability can no longer erase a delivered status-item click.
- Background launch no longer opens permission or Settings windows from a
  transient permission read; permission UI remains contextual.
- Release evidence now preserves a strict build-metadata whitelist instead of
  raw Xcode settings containing machine paths or signing configuration.

### Release boundaries

- Real Focus/Shortcuts, VoiceOver, display/sleep-wake, signed installation, and
  update-from-previous execution require candidate-bound system testing.
- Developer ID signing, Barline App Group provisioning, notarization, stapling,
  Gatekeeper, Sparkle signing, and Developer Tools automation have passed on a
  clean candidate and must be repeated after source changes.
- Foreground production runtime validation requires a dedicated interactive
  session where Barline focus changes are acceptable. Xcode 27 and a macOS 27
  runtime host remain unavailable, so no macOS 27 runtime claim is made.
