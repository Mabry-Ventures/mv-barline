# Installed signed-candidate journey

`test-installed-journey.sh` is a release gate, not a replacement for Core or fixture tests. It never builds, launches, quits, installs, or foregrounds Barline, and never resets a permission or changes a saved layout. It sends a bounded series of real mouse down/up events, so reserve the pointer for the duration of each run. Run only with explicit interactive-runtime approval.

## Prepare once

1. Build `BarlineFixture` locally. Run `bash script/start-journey-fixture.sh /absolute/BarlineFixture.app /absolute/ignored-artifacts-directory`. It refuses an existing fixture, starts one hidden/background instance with two synthetic items (Native and Popover), and prints the three exact environment assignments for the gate. No credentials or real item metadata enter the receipt. Optional `BARLINE_FIXTURE_JOURNEY_ITEMS=Native,Delayed` selects the delayed-discovery lane; `Native,Unresponsive` selects the bounded fault-injection lane.
2. Use Barline's normal layout editor to place **only the synthetic fixture items** `BF Native`, `BF Popover`, and `BF Delayed` in its hidden section. Preserve all unrelated items. Leave the shelf and fixture menus closed. `BF Unresponsive` is an optional, bounded two-second fixture-only fault injection, not part of the success test.
3. Confirm exactly one installed signed/notarized candidate is running. The harness requires that process's Accessibility access and the test process's Accessibility/Screen Recording access; missing access fails without prompting. Do not grant new access to production automatically.

## Run

Set these variables in the command environment:

```text
BARLINE_CANDIDATE_APP=/Applications/Barline.app
BARLINE_SOURCE_SHA=<full source SHA>
BARLINE_EXPECTED_PID=<exact current app PID>
BARLINE_FIXTURE_PID=<exact fixture PID>
BARLINE_FIXTURE_SESSION=<the fixture session token>
BARLINE_FIXTURE_RECEIPT=<the fixture receipt JSON>
BARLINE_JOURNEY_TARGET=BF Native
BARLINE_JOURNEY_BUTTON=left
```

Then execute `bash script/test-installed-journey.sh` and retain stdout in the candidate's ignored artifacts. The default release evidence directory is `.artifacts/release/<source SHA>`; `BARLINE_RELEASE_DIR` may override it. The harness verifies the signature, Gatekeeper, staple, release metadata SHA, and installed executable hash against that release's ZIP **before** any click.

The four source-bound acceptance receipts are `native-left`, `native-right`,
`popover-left`, and a second `popover-reuse` left-click using the same running
fixture. Popover right-click and Delayed left-click are additional raw runtime
checks; run them without `BARLINE_EVIDENCE_OUTPUT` because they are not part of
the four-lane receipt schema. The delayed fixture makes its AX status item
unavailable for the first three seconds; this exercises late discoverability,
not a claim to deterministically control the helper's internal ownership cache.
The ownership-regression Core/helper tests remain independently required.

A PASS requires all of these, not just successful event posting:

- The target is hidden at baseline and the control window matches an AX child of the exact candidate process. A Control Center-owned window is allowed only with matching source geometry.
- A physical-equivalent click opens the actual shelf.
- Clicking the fixture's semantic shelf control increments the target process's receipt with the correct mouse button.
- The target reports menu/popover opening **and** exposes its actual action through AppKit Accessibility.
- Clicking that target action produces a receipt, then a target closure.
- The original fixture status-item position is restored within 25 seconds.

The JSON result binds the runtime observations to the source SHA, installed executable SHA-256, app version, and host OS. A failure must remain a failed gate. If the host blocks synthetic pointer delivery, use Computer Use or the user's physical clicks for a separately recorded equivalent journey; do not substitute an AXPress, Debug notification, or fixture-only test and call this gate passed.

Hosted fixtures have two names: their source AX button says `BF Native` (or
Popover/Delayed), while the Control Center window uses the fixture's autosave
name, such as `BarlineFixture.Journey.Native`. The harness accepts that exact
synthetic alias only after verifying one source/host center match (within 1pt,
width difference at most 2pt, expected owner). It never uses a fuzzy name or an
unverified coordinate. Pointer movement precedes down/up, the original cursor
is restored on exit, and the shelf must remain closed over the opened interface.
The optional `BARLINE_JOURNEY_SCREENSHOT` is an absolute, previously unused PNG
path under the repository's `.artifacts/runtime/`; only the identified shelf
window is captured. AX fallback diagnostics cannot clear a failed AX lane.

Run the same matrix after cold launch, after the real updater installs the candidate, and after a bounded helper interruption. Separately exercise failed activation recovery, open-menu mutation deferral, keyboard/VoiceOver, permission transitions, and available physical display/system-state lanes. This gate does not certify those lanes, macOS 27, or soak duration.

`BarlineUITests` qualifies native-menu and custom-popover receipt behavior within the fixture. The installed `native-right` journey owns right-click qualification because XCUI can acknowledge a status-item right-click without delivering it to the owning process. Xcode 27 does not deliver XCUITest-synthesized status-item events at all, so those two fixture-click cases are explicitly skipped on macOS 27; the stronger source-bound installed-candidate physical journeys remain mandatory there. These tests are intentionally labeled **fixture qualification**, not production integration proof. Run that qualification with menu-bar managers closed: newly created macOS status items can land behind an existing hidden-item barrier even with a fresh autosave name. The tests reject off-screen geometry and do not alter any user's layout. Because macOS-hosted StatusItem can report `isHittable=false` despite an on-screen frame, qualification uses the exact AX-identified element's center coordinate, then independently requires a target-process receipt before examining its menu. A missing receipt is a failed event-delivery gate, never a fixture or production pass. Synthetic receipt JSON is retained as an xcresult attachment on success and failure. Qualification alone uses a visible regular fixture window to avoid hidden-accessory activation ambiguity; the installed journey's background mode is unchanged. Conversely, keep Barline running and the fixture target hidden for the installed production journey.
