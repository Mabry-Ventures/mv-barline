# Changelog

## 1.0.59 (build 136) — diagnostic candidate, not for distribution

- Record privacy-safe counts at the macOS 27 logical-layout and native
  concealment boundaries to isolate an intermittent post-activation restore
  failure. This candidate remains internal until the cause is fixed and both
  installed operating-system gates pass.

## 1.0.58 (build 135) — candidate

1.0.57 was staged but not published. Independent review found that its
fail-closed macOS 27 ownership check could leave a two-second duplicate-action
window suppressing a distinct native click.

- End duplicate-action ownership at the next physical mouse-down, including
  when Accessibility cannot resolve the new click; still suppress a late
  mouse-up from the recovered click itself.
- Resolve Barline's status control through a bounded Accessibility parent
  chain and cap the hit test's messaging timeout. Keep the exact-button-frame
  gate before invoking the hit test.
- Cover ambiguous AX ownership, consecutive native clicks, a held-click
  release, and cancellation of a pending fallback in coordinator tests.

## 1.0.57 (build 134) — candidate

1.0.56 was staged but not published. Its installed macOS 27 fixture journey
opened and completed the target menu once, then Barline's delayed status-item
fallback mistook an overlapping menu click for a missed click on its own icon
and reopened the shelf.

- Require the macOS 27 fallback to verify that Barline's accessible status
  control is the topmost element at the click point. Ambiguous hits fail closed;
  AppKit's normal status-item action remains available.
- Keep the macOS 26 fallback unchanged and add a regression case for an
  overlapping menu at the control's screen coordinates.

## 1.0.56 (build 133) — candidate

1.0.55 was qualified in source tests but not published. An installed macOS 26
journey exposed a disagreement between the helper's visible move result and
the coordinator's first postcondition, followed by unnecessary compensation
and failed activation. Whether the inventory lagged or the item remained
non-clickable requires installed-candidate telemetry to distinguish.

- Retry the transient reveal/restore postcondition against bounded fresh
  inventories before starting rollback; permanent layout edits keep their
  existing strict verification.
- Require installed journeys to prove a genuinely concealed fixture, an empty
  recovery journal, and a stable restoration after the compensation window.
  macOS 27 uses native Accessibility hit testing because its source status-item
  frame remains on screen even when the item is hidden.
- Keep diagnostic logging limited to section, on-screen state, and display
  match, with no item names or application inventory.

## 1.0.55 (build 132) — candidate

1.0.54 was a private diagnostic build, not published. Its installed macOS 26
journeys confirmed successful section restoration while the prior journey gate
still rejected offscreen slot compaction as a failure.

- Qualify temporary hidden-item restoration by verifying the same unique
  fixture window returns behind Barline's hidden divider, rather than requiring
  the old offscreen pixel coordinate. The gate still requires the exact
  signed candidate, real pointer events, one fixture action, and a closed
  interface before accepting restoration.
- Carry forward privacy-safe helper move diagnostics for any recurrence.

## 1.0.54 (build 131) — diagnostic candidate

1.0.53 was staged but not published. Its installed macOS 26 popover journey
still failed restoration after successful activation; the helper reported a
generic operation failure before the new coordinator postcondition could help.

- Distinguish a helper move that never reaches the requested section from a
  coordinator postcondition failure in privacy-safe diagnostics.
- Record bounded, name-free move observations (anchor category, side, section,
  display match, and relative geometry) to locate the native drag failure.
  No movement behavior changes in this diagnostic build.

## 1.0.53 (build 130) — candidate

1.0.52 was staged but not published; its changes are included here.

- Complete temporary restoration when the original item is verified off-screen
  in its requested hidden section and display, even if macOS reinserts it at
  a different hidden neighbor. An installed 1.0.52 popover journey had reached
  the hidden section but its exact-slot check rejected the result and rolled
  the item back into the visible menu bar.
- Keep exact-slot verification for permanent layout edits and visible-section
  restoration. Reject hidden restoration if an unrelated item changes section
  or display.

## 1.0.52 (build 129) — candidate

1.0.51 was staged but not published; its changes are included here.

- Accept a verified on-screen temporary reveal on macOS 26 even when macOS
  places the item beside a different native neighbor. Permanent layout edits
  and restoration retain their exact-position verification.
- Continue a bounded physical drag when an item moves but has not reached its
  requested section or display. A partial movement no longer falsely ends
  temporary restoration with the item still visible.
- Exercise twenty post-recovery shelf opens so the installed latency p95 gate
  has a meaningful sample after XPC helper interruption. Keep separate
  candidate-bound baseline and post-interruption receipts, including each
  run's slowest click.

## 1.0.51 (build 128) — candidate

This candidate was staged but not published; 1.0.52 supersedes it.

- Accept a verified on-screen temporary reveal on macOS 26 even when macOS
  places the item beside a different native neighbor. Permanent layout edits
  and restoration retain their exact-position verification.
- Exercise twenty post-recovery shelf opens so the installed latency p95 gate
  has a meaningful sample after XPC helper interruption. Keep separate
  candidate-bound baseline and post-interruption receipts, including each
  run's slowest click.

## 1.0.50 (build 127) — candidate

This candidate was staged but not published; 1.0.51 supersedes it.

- Show a loading-only Barline Bar immediately on macOS 27 while native item
  concealment is reconciled. Item icons remain withheld until that check
  succeeds, preventing duplicate native and shelf copies without making the
  first click appear unresponsive.
- Show a clear preparation failure instead of leaving the loading state open,
  and give an empty hidden section a readable placeholder rather than a tiny
  blank panel.
- Correct the installed macOS 27 performance probe to identify the unique
  app-owned shelf surface when WindowServer omits its title. Repeated
  Accessibility queries no longer inflate click timing.

## 1.0.49 (build 126) — candidate

This candidate was staged but not published; 1.0.50 supersedes it.

- Bound macOS 27 Accessibility requests on individual menu bar elements as
  well as their owning apps. A slow item can no longer inherit the longer
  system default messaging timeout during inventory.
- Skip retained-inventory encoding and preference writes when a refreshed
  snapshot contains no changed descriptor. Layout recovery and changed-item
  persistence continue through the existing transaction path.
- Add privacy-safe timing intervals for app and helper inventory and for
  shelf presentation and concealment readiness. These make the next macOS 27
  installed-build measurements attributable to the slow phase.

## 1.0.48 (build 125) — September 21, 2026

1.0.47 was built and qualified but never published; its change is included
here.

- Make layout changes and the Barline Bar fast on a busy Mac. Each macOS 27
  menu bar inventory asked every running process for status items; on a Mac
  with 154 processes, of which 14 own items, that took about two seconds and
  a layout change ran it eight to ten times. Barline now asks only the known
  owners, plus newly launched apps, with a full scan every 15 seconds. Moving
  an item drops from 12–25 seconds to under 3, and the Barline Bar opens in
  about half a second instead of 4.5–9.
- Resolve a specific item in the helper using the same identity as the app, so
  items whose titles show live readings can be activated from the Barline Bar
  and search.
- Describe the running macOS version in the first-run walkthrough and the
  layout editor. On macOS 27, Screen Recording is not needed to arrange
  items, ⌘ Command-drag only changes an item's position, and an item macOS
  cannot conceal is described as staying visible.
- Retry menu bar discovery when the screen unlocks or the user returns to the
  session. Barline launched while the screen was locked — for example, after
  an overnight update — saw no menu bar, and the Menu Bar Layout page stayed
  on "Menu bar items could not be loaded" until Try Again was pressed.

## 1.0.46 (build 123) — September 20, 2026

- Keep one identity for a menu bar item whose title shows a live reading.
  Applications that display processor load, temperature, transfer rate, or
  battery percentage rewrite their title every few seconds, which changed the
  item's identity with it and left every saved assignment for that
  application unresolvable.
- Ignore an assignment for an item the menu bar no longer contains instead of
  rejecting every other assignment alongside it. One absent item previously
  made the whole layout unchangeable.

## 1.0.45 (build 122) — September 20, 2026

- Give the Accessibility inventory requests their own five-second budget. A
  Mac with many menu bar items needs longer than a second to build one
  inventory, so the previous budget reported the helper as incapable of
  moving, revealing, or restoring anything.
- Stop tearing down the helper session when a read runs out of time. A read
  leaves no partial native state, and replacing the session cancelled
  concealment work that was about to succeed.

## 1.0.44 (build 121) — September 19, 2026

- Open the layout editor from the first-run walkthrough through the same
  window path as every other caller, so the button no longer does nothing.
- Force the macOS 27 search panel to composite for an inactive accessory app,
  matching the shelf's ordering fix.
- Retry a menu bar layout assignment once when a background refresh supersedes
  the authority generation before any write, and identify the failing stage in
  the assignment alert with a privacy-safe reference code.

## 1.0.43 (build 120) — September 18, 2026

- Anchor the shelf with Barline's live AppKit status-item frame so macOS 27
  display-coordinate differences cannot push it to the opposite screen edge.

## 1.0.42 (build 119) — September 18, 2026

- Anchor Dynamic shelf placement beneath Barline's clicked menu-bar control
  instead of forcing the shelf to the center of the display.

## 1.0.41 (build 118) — September 17, 2026

- Keep the shelf visible when a macOS 27 Mac is operated through Screen
  Sharing instead of allowing WindowServer to classify it as unshareable.

## 1.0.40 (build 117) — September 17, 2026

- Force the nonactivating shelf panel to composite on macOS 27 when Barline is
  an inactive accessory app, avoiding a false successful open with no visible
  shelf.

## 1.0.39 (build 116) — September 17, 2026

- Preserve an unchanged, successfully committed macOS 27 concealment assertion
  when opening the shelf instead of replacing it with a duplicate transaction
  that the OS can reject.

## 1.0.38 (build 115) — September 17, 2026

- Load macOS 27's dyld-cache-only MenuBarClientCore framework lazily, matching
  the runtime contract used by working Golden Gate menu-bar implementations.
- Record a bounded local diagnostic when the framework or required assessment
  classes cannot be resolved, replacing the previous silent shelf no-op.
- Keep the native-concealment readiness wait confined to macOS 27 so macOS 26
  cold-launch shelf clicks remain immediate.

## 1.0.37 (build 114) — September 17, 2026

- Recover macOS 27 native concealment when the menu service's first private-
  runtime probe occurs too early during launch, so clicking Barline opens the
  shelf without briefly duplicating its hidden items in the system menu bar.

## 1.0.36 (build 113) — September 17, 2026

- Center Dynamic shelf placement consistently instead of retaining a
  technically valid but visually off-center menu-bar anchor.
- Reconcile macOS 27 native concealment before the first shelf frame so saved
  hidden items cannot appear in both the system menu bar and Barline's shelf
  during cold-launch setup.

## 1.0.35 (build 112) — September 17, 2026

- Center the shelf within its display when Dynamic placement would otherwise
  clamp it flush against the left or right edge, while preserving explicit
  Barline-icon placement for users who select it.

## 1.0.34 (build 111) — September 17, 2026

- Keep a macOS 27 item with ambiguous divider-overlap geometry visible,
  immovable, and non-hideable instead of rejecting the entire otherwise valid
  menu-bar inventory.

## 1.0.33 (build 110) — September 17, 2026

- Distinguish active-display resolution, missing Barline divider controls, and
  section-geometry rejection after a successful macOS 27 Accessibility
  inventory, using only bounded counts and fixed diagnostic codes.

## 1.0.32 (build 109) — September 17, 2026

- Preserve privacy-safe macOS 27 Accessibility result categories and bounded
  inventory counts in support bundles so a clean-machine discovery failure can
  be distinguished from missing permissions, empty menu bars, and invalid
  geometry without recording app names, item names, process IDs, or paths.
- Report the terminal inventory stage instead of collapsing every
  `AXExtrasMenuBar` failure into the same empty snapshot.

## 1.0.31 (build 108) — September 17, 2026

- Keep the shared macOS 27 assignment session alive for the full app process,
  so switching settings panes or recreating the Settings window cannot bypass
  an in-flight native transaction.
- Add a regression proving replacement view owners observe the same locked
  session and cannot enter the backend until the original operation settles.

## 1.0.31 (build 107) — September 17, 2026

- Share one assignment session across every macOS 27 layout section so a
  suspended move disables both its source and destination until the native
  transaction has fully settled.
- Reject opposite-section clicks and drops while another assignment is in
  flight, preventing competing user actions from surfacing stale-layout
  failures.
- Add a deterministic suspension-point regression proving an overlapping
  assignment never enters the backend and that the session releases after the
  first operation completes.

## 1.0.31 (build 106) — September 17, 2026

- Give multi-item macOS 27 publishers a stable application-level identity so
  Accessibility alias or inventory-order churn cannot invalidate an in-flight
  visibility action.
- Label grouped controls with the application's localized name instead of an
  arbitrary status-item title, including matching VoiceOver guidance.
- Resolve the current representative immediately before each grouped move and
  reject malformed empty application identifiers.
- Keep application discovery off the main actor by rendering only names already
  present in the current menu-bar inventory.
- Serialize layout assignment controls while a move is in flight and treat a
  drop back onto the current section as an intentional no-op.

## 1.0.30 (build 104) — September 17, 2026

- Make macOS 27 layout changes transactional: verify complete section, display,
  inventory, and shelf-order postconditions, require settled profile
  observations, and compensate failed or cancelled logical moves.
- Preserve macOS-owned visible menu-bar order while reliably persisting and
  restoring Barline-owned Hidden and Always Hidden shelf order.
- Remove the macOS 27 native HID drag implementation. Visible menu-bar ordering
  stays user-owned through Command-drag; Barline handles supported visibility
  assignments and shelf ordering without synthesizing native drags.
- Treat bundle identifiers case-insensitively and exclude Barline's own controls
  from application-group concealment decisions.
- Represent multi-item third-party publishers as one explicit application
  group and keep that group reversible from either visibility section.

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
