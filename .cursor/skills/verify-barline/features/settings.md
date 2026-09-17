# Settings and degraded mode

Settings lets a user open Barline's preferences window, move between sidebar panes, replay the welcome walkthrough, and keep using the app when Accessibility is off. Arrangement of other apps' items is unavailable until Accessibility is granted; nothing here may prompt for that grant unless the user clicks **Enable Accessibility** or **Grant Permission**.

## Sub-features

- `settings-open` opens the Settings window titled `Barline` from each user entry point.
- `settings-sidebar` switches General, Menu Bar Layout, Menu Bar Appearance, Layouts & Focus, Hotkeys, Advanced, and About.
- `settings-degraded` shows the degraded-mode banner when Barline lacks Accessibility and still allows General, Advanced, About, and layout metadata.
- `settings-welcome` reopens the first-run walkthrough from General without making permissions mandatory.
- `settings-layout-unavailable` shows the layout pane's degraded copy instead of a blank editor when Accessibility is missing.

## How to get to it (user POV)

- Right-click the Barline icon in the menu bar and choose `Barline Settings…`.
- Right-click an empty menu-bar area (when **Enable secondary context menu** is on) and choose `Barline Settings…`.
- Open search, then choose the Settings control in the search panel's bottom bar.
- Choose **Show Welcome Again** on the General pane, then **Open Layout Editor** on the walkthrough's bar-setup step (that path opens Settings on Menu Bar Layout).
- A verification launch via `control-barline launch` also presents Settings through `--barline-reopen-probe`. Use that only as a convenience after proving at least one user entry point above.

## Driving it with control-barline

Preconditions:

- `control-barline doctor` reports `ui: ready` or `ui: degraded` on Apple Silicon macOS 26+.
- This run owns the Barline process recorded in `instance.env`.
- Host Accessibility is granted to the driving process so System Events can click Barline's own windows.
- Barline Accessibility may be off. Do not click **Enable Accessibility** unless the recipe is specifically testing that prompt.

- **Open Settings (reopen-probe convenience).** After `control-barline launch`, a window titled `Barline` is visible. Run `control-barline snapshot --path "$EVIDENCE_DIR/settings-open.ax.txt"`. The snapshot contains the sidebar names `General`, `Menu Bar Layout`, `Menu Bar Appearance`, `Layouts & Focus`, `Hotkeys`, `Advanced`, and `About`.
- **Open Settings (user menu).** Right-click `Barline.ControlItem.Visible` and choose `Barline Settings…`. Run `control-barline click --role menu-item --name "Barline Settings…"`. The same `Barline` window becomes key.
- **Degraded banner.** If Barline Accessibility is off, the banner text starts with `Degraded mode:` and the AX identifier `degraded-mode-banner` exists. If Accessibility is on, that banner is absent.
- **General pane.** Choose `General`. Run `control-barline click --name "General"`. The detail pane includes `Launch at Login` or the launch-at-login toggle, `Hide Dock icon`, `Show Welcome Again`, and `Show Barline icon`.
- **Advanced pane.** Choose `Advanced`. Run `control-barline click --name "Advanced"`. The pane includes `Enable the always-hidden section`, `Permissions`, and `Create Support Bundle`.
- **About pane.** Choose `About`. Run `control-barline click --name "About"`. The heading `Barline` and a `Version` line are visible.
- **Layout unavailable without Accessibility.** Choose `Menu Bar Layout`. Run `control-barline click --name "Menu Bar Layout"`. When Barline Accessibility is off, the copy `Menu bar arrangement is unavailable in degraded mode.` is visible and the graphical editor is not. When Accessibility is on, skip this bullet rather than inventing a pass.
- **Replay welcome.** Return to General and choose `Show Welcome Again`. Run `control-barline click --name "Show Welcome Again"`. A window titled `Welcome to Barline` appears with `Get Started` and `Finish Later`. Choose `Finish Later` so the walkthrough does not request TCC.
- **Proof.** Run `control-barline snapshot --path "$EVIDENCE_DIR/settings-after.ax.txt"` and `control-barline screenshot --path "$EVIDENCE_DIR/settings-after.png"`. The artifacts show the `Barline` settings window and the pane you last opened. They do not need Screen Recording granted to Barline.

## Gotchas

- `--barline-reopen-probe` is a launch flag, not a user gesture. Record which entry point you actually used.
- `Enable Accessibility` on the banner or Advanced pane **will** request TCC. Do not click it to "make doctor greener" unless that is the feature under test.
- Menu Bar Layout on macOS 27 still needs Accessibility to see items, but arrangement is ⌘ Command-drag in the system menu bar, not the graphical editor.
- An automatically hidden system menu bar replaces the graphical editor with `Your menu bar is set to automatically hide`. That is not a failed launch.
- `Hide Dock icon` changes activation-policy behavior. Prefer leaving it off during verification so Settings can stay frontmost.
- Do not treat `./script/ci.sh fast` Core tests as proof that Settings opened.
