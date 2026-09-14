# Changelog

## 1.0.14 (build 45) — September 14, 2026

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

## Unreleased

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
