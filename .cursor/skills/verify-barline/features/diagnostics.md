# Diagnostics

Diagnostics lets a user review permission state and create a privacy-bounded support bundle from Advanced Settings, preview it, and save it only after choosing a destination. The bundle must not contain paths, item names, screenshots, process lists, or logs.

## Sub-features

- `diagnostics-permissions` shows Accessibility and Screen Recording as **Permission Granted** or **Grant Permission** without auto-prompting.
- `diagnostics-preview` creates an in-memory support-bundle preview from **Create Support Bundle**.
- `diagnostics-review` shows the **Review Support Bundle** alert summarizing allowed contents.
- `diagnostics-save` writes JSON only after **Choose Save Location** and an explicit save-panel confirmation.
- `diagnostics-cancel` leaves no file when the user cancels the review alert or the save panel.
- `diagnostics-status` exposes progress on AX id `support-bundle-status`.

## How to get to it (user POV)

- Open Settings → **Advanced**.
- From Menu Bar Layout's failed state, choose **Open Diagnostics** (navigates to Advanced).
- From Menu Bar Layout's missing Screen Recording state on macOS 26, choose **Go to Advanced Settings**.

## Driving it with control-barline

Preconditions:

- `control-barline doctor` reports `ui: ready` or `ui: degraded`. This feature does **not** require Barline Accessibility or Screen Recording.
- Host Accessibility is granted so Advanced Settings can be clicked.
- Choose a destination under `/private/tmp/barline-verify-*` or `$EVIDENCE_DIR`, never the user's Desktop, if you save a bundle.
- Do not click **Grant Permission** unless the run is expressly testing the permission request.

- **Open Advanced.** Choose `Advanced`. Run `control-barline click --name "Advanced"`. The Permissions section lists `Accessibility` and `Screen Recording`. The Diagnostics section includes `Privacy-bounded diagnostics` and `Create Support Bundle`.
- **Permission state.** Record which rows say `Permission Granted` versus `Grant Permission`. That is the observation; do not change it.
- **Create preview.** Choose `Create Support Bundle`. Run `control-barline click --name "Create Support Bundle"`. Status `support-bundle-status` becomes `Preparing preview…` then `Preview ready. Choose whether to save it.` An alert titled `Review Support Bundle` appears. The message includes `This JSON contains only` and does not include item titles.
- **Cancel (default for shared Macs).** Choose `Cancel`. Run `control-barline click --name "Cancel"`. No new JSON file is written. Status may remain the preview-ready copy.
- **Save (disposable destination only).** Choose `Choose Save Location`, pick `$EVIDENCE_DIR/support-bundle.json`, and confirm. Status becomes `Support bundle saved. Review it before sharing.` Open the file and assert it is JSON **without** home paths, menu-item titles, profile names, PIDs, or screenshot bytes. The fail-closed check `./script/test-support-bundle-privacy.sh` is a source gate, not a substitute for this save.
- **Proof.** Run `control-barline snapshot --path "$EVIDENCE_DIR/diagnostics.ax.txt"`. The snapshot shows Advanced Settings, `Create Support Bundle`, and `support-bundle-status`. If a bundle was saved, keep it next to the snapshot in the evidence directory.

Linux: `GATED` for the UI flow. You may still run `./script/test-support-bundle-privacy.sh` as a source check; that does not prove the Advanced Settings buttons work.

## Gotchas

- Creating a bundle must be an explicit click. Do not generate one from a script and call the Settings feature passed.
- The preview alert is the review step. Saving without that alert is a failed proof.
- `Grant Permission` opens system TCC UI. Leave it alone in a routine verification run.
- Support-bundle privacy tests that inject canary secrets are not runtime evidence for a release candidate.
- Failed preview copy is `The support bundle preview could not be created.` Record it; do not retry in a loop.
