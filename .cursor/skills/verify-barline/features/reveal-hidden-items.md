# Reveal hidden items

Reveal hidden items lets a user show the tucked-away menu-bar section from the Barline icon, the Barline Bar shelf, or a recorded hotkey, then hide it again without rearranging other items.

## Sub-features

- `reveal-click` left-clicks the visible Barline control and shows hidden items.
- `reveal-shelf` presents the shelf window titled `Barline Bar` when the Barline Bar setting is on and the system menu bar is not set to auto-hide.
- `reveal-menu` uses `Show Hidden Section` / `Hide Hidden Section` from the Barline icon's menu.
- `reveal-hotkey` toggles the hidden section from the hotkey recorded as `Toggle the hidden section`.
- `reveal-close` hides the section or closes the shelf so the control returns to its resting state.

## How to get to it (user POV)

- Left-click the Barline icon in the menu bar (`Barline.ControlItem.Visible`).
- Right-click (or Control-click) the Barline icon and choose `Show Hidden Section` or `Hide Hidden Section`.
- Press the hotkey configured in Settings › Hotkeys › **Toggle the hidden section**.
- Option-click the visible control to toggle the always-hidden section when that section is enabled in Advanced.

## Driving it with control-barline

Preconditions:

- `control-barline doctor` reports `ui: ready` (Barline Accessibility granted). `ui: degraded` is `GATED` for this feature — Settings still works, but Barline cannot inspect other apps' items or publish a trustworthy shelf.
- Host Accessibility is granted to the driving process.
- The system menu bar is set to always show. Auto-hide forces a native reveal fallback; do not call that the shelf.
- **Show Barline icon** is on (General). **Enable the Barline Bar** is on unless you are explicitly proving native section reveal.
- Do not post `runtime-smoke.toggle-shelf`. That is a CI probe, not this feature.

- **Identify the control.** Run `control-barline snapshot --path "$EVIDENCE_DIR/reveal-before.ax.txt"`. Process `Barline` exposes extras-menu-bar child `Barline.ControlItem.Visible` or a window named `Barline.ControlItem.Visible` with nonzero width and height.
- **Left-click reveal.** Click the control. Run `control-barline click --role status-item --name "Barline.ControlItem.Visible"`. Hidden items become visible **or** a window titled `Barline Bar` appears with role `AXWindow`.
- **Shelf identity.** If the Barline Bar is enabled, run `control-barline snapshot --path "$EVIDENCE_DIR/reveal-shelf.ax.txt"`. Exactly one AX window is named `Barline Bar`. The app does not become frontmost solely because the shelf opened.
- **Activate nothing extra.** Do not click a foreign menu-bar item unless the recipe is `search-activate` or an installed journey. This feature's pass is reveal and close, not clicking Weather or Control Center.
- **Close.** Left-click the control again, or click outside the shelf, or choose `Hide Hidden Section`. Run `control-barline click --role status-item --name "Barline.ControlItem.Visible"`. The `Barline Bar` window is gone and the hidden section is not left expanded.
- **Menu entry.** Control-click the icon and choose `Show Hidden Section`. Run `control-barline click --role menu-item --name "Show Hidden Section"`. The same revealed state appears.
- **Proof.** Run `control-barline snapshot --path "$EVIDENCE_DIR/reveal-after.ax.txt"` after close. The snapshot shows no `Barline Bar` window. If you capture a screenshot, crop to the Barline-owned shelf or omit other apps' item titles.

Linux / missing Accessibility: run `control-barline doctor` and record `GATED` with the printed reason. That is the correct outcome on this Cursor VM.

## Gotchas

- `./script/test-ui-smoke.sh` toggles the shelf through a Debug notification. A pass there is a local CI gate, not this feature.
- XCUI fixture tests (`BarlineUITests`) click `BF Native` / `BF Popover` and must never be reported as Barline activation proof.
- The installed `native-left` journey in `script/INSTALLED_JOURNEY.md` is the production-grade physical path. It requires a notarized candidate, a reserved pointer, and fixture items placed in the hidden section. Do not run it against a user's layout.
- Auto-hidden menu bars, notched overflow, and multiple displays are separate lanes (`docs/SUPPORTED_CONFIGURATIONS.md`). A single-display always-visible bar is the baseline.
- Option-click is always-hidden, not hidden. Mixing them invalidates the recipe.
- Do not leave the hidden section expanded; rehide is part of the proof.
