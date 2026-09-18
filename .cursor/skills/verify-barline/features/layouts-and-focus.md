# Layouts and Focus

Layouts and Focus lets a user capture the current menu-bar arrangement, apply a saved layout, assign it through macOS Focus Settings, import or export an archive, and recover from an interrupted Focus change without leaving a half-applied profile authoritative.

## Sub-features

- `layouts-list` shows saved layouts or the empty state `No Saved Layouts` on **Layouts & Focus**.
- `layouts-capture` captures the current arrangement under a layout name when Accessibility is granted.
- `layouts-apply` applies a named layout with the **Apply** button (`Apply <name> profile`).
- `layouts-edit` opens **Edit** for display variants, groups, and rules without saving until the editor commits.
- `layouts-import-export` imports an Ice discovery or a layout archive after preview, and exports all layouts.
- `layouts-recovery` uses Undo / Redo / Restore Last-Known-Good and the Focus recovery buttons when a checkpoint exists.
- `layouts-degraded` keeps the pane reachable when Accessibility is off, with Capture and Apply disabled.

## How to get to it (user POV)

- Open Settings and choose the sidebar row `Layouts & Focus`.
- Choose **Open Focus Settings** (`open-native-focus-settings`) to assign a layout in System Settings.
- Choose **Capture Current Layout**, **Apply**, **Edit**, **Import from Ice…**, **Import Layout Archive…**, or **Export All Layouts…** on that pane.
- Use **Undo Layout Change**, **Redo Layout Change**, or **Restore Last-Known-Good Layout** in the Recovery section.

## Driving it with control-barline

Preconditions:

- `control-barline doctor` reports `ui: ready` for capture/apply, or `ui: degraded` for the disabled-controls observation only.
- Host Accessibility is granted. Barline Accessibility is required for capture, apply, Ice import, and restore; it is not required to open the pane and read the empty state.
- Do not overwrite a user's existing layouts. Use a disposable name such as `VerifyCapture` and delete it before cleanup, or skip capture on a machine that already has personal layouts.
- Never log or commit the user's real layout names.

- **Open the pane.** Choose `Layouts & Focus`. Run `control-barline click --name "Layouts & Focus"`. The detail pane shows either `No Saved Layouts` or a list of layout rows with **Apply**, **Edit**, and delete controls.
- **Degraded capture.** When Accessibility is off, `Capture Current Layout` and **Apply** are disabled and the copy `Profile management remains available, but capturing or applying menu bar layouts requires Accessibility.` is visible. Record that observation and stop; do not fail the recipe for a disabled button.
- **Capture (Accessibility on, disposable Mac only).** Type `VerifyCapture` into `Layout name`. Run `control-barline fill --name "Layout name" --value "VerifyCapture"`, then `control-barline click --name "Capture Current Layout"`. A row named `VerifyCapture` appears, or `profile-status` explains a validation failure without applying a partial layout.
- **Apply.** Choose `Apply VerifyCapture profile`. Run `control-barline click --name "Apply VerifyCapture profile"`. Status copy or an `Active` label appears on that row. If apply cannot be verified, last-known-good remains; that is a pass for fail-closed behavior, not a license to retry until it looks green.
- **Recovery controls exist.** The Recovery section includes `Undo Layout Change`, `Redo Layout Change`, and `Restore Last-Known-Good Layout`. Click them only if this run created the history you would undo.
- **Focus recovery (only if buttons exist).** If `restore-interrupted-focus-layout` is present, do not confirm the dialog unless the run's job is recovery. Choosing **Cancel** is the safe default.
- **Proof.** Run `control-barline snapshot --path "$EVIDENCE_DIR/layouts.ax.txt"`. The snapshot shows the Layouts & Focus pane, empty-state or disposable row, and disabled vs enabled Capture/Apply matching the Accessibility state. Delete `VerifyCapture` with `Delete VerifyCapture profile` if you created it.

Linux: `GATED`.

## Gotchas

- Listing Focus filters in System Settings is not proof that a filter loads or that Focus activated a layout.
- Rules start paused on relaunch; Resume is explicit. Do not treat a paused rule as a failed apply.
- Imports preview before save. `Replace Existing and Import` is destructive — never use it on a user's archive during verification.
- Display variants capture only the verified active display. Ambiguous or empty displays must be rejected, not overwritten.
- `docs/FEATURE_QUALIFICATION.md` installed receipts are candidate-bound. A later SHA cannot reuse them.
- Partial activation must never be left as authoritative state. If a capture or apply is interrupted, use Restore Last-Known-Good rather than improvising.
