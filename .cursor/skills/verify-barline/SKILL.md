---
name: verify-barline
description: Drive and prove Barline, a macOS menu-bar organizer. Use to launch a local unsigned build, doctor host/TCC/instance health, exercise settings/shelf/search/layouts/diagnostics the way a user does, and capture evidence. Full launch/drive/proof needs Apple Silicon macOS 26+ with host Accessibility (Barline Accessibility for arrangement; Screen Recording optional). Linux can run repository hygiene and other Darwin-free gates only — never fake a menu-bar UI proof.
---

# Verify Barline

Barline is a GPLv3, Apple Silicon-only macOS menu-bar utility. A user touches the **menu-bar control**, the **Barline Bar (shelf)**, **Settings**, **search**, **saved layouts / Focus**, and **diagnostics**. There is no web UI and no public CLI for those surfaces.

This skill is for the next agent that has never seen the app. Read `features/README.md` before driving. Run `scripts/control-barline` for every launch, doctor, evidence, and cleanup step.

## Host gates (read this first)

| Lane | Host | What it proves |
| --- | --- | --- |
| Linux hygiene | This Cursor VM / GitHub `ubuntu-latest` | Repository hygiene, architecture firewall, website tests, Darwin-free Ruby/shell gates |
| Local unsigned UI | Apple Silicon macOS 26+ with Xcode 26.6 | Settings, welcome, degraded-mode fallback, unsigned Debug launch |
| Menu-bar arrangement | Same Mac **and** Accessibility granted to **Barline** | Shelf, layout editor, capture/apply layout, item activation |
| Layout images / appearance capture | Same Mac **and** optional Screen Recording granted to **Barline** | Item previews in the layout editor (not required on macOS 27's Command-drag path) |
| Installed candidate | Notarized `/Applications/Barline.app` plus reserved pointer | Four physical target-interface journeys in `script/INSTALLED_JOURNEY.md` |

**Do not** report a Linux hygiene pass as a menu-bar proof. **Do not** use `runtime-smoke` Distributed Notifications, XCUI fixture receipts, or Core unit tests as a user-path proof. **Do not** launch `./script/build_and_run.sh` against a user's notarized install (same bundle ID `com.mabryventures.Barline`; the script `pkill`s every `Barline` / `BarlineMenuService` process by name).

Required TCC / authorization, when driving on a Mac:

- **Host Accessibility** (the terminal, Codex, or Computer Use process that sends AX / System Events clicks). Missing this fails without a user-facing prompt if you only preflight.
- **Barline Accessibility** — only when the recipe inspects or moves **other apps'** menu bar items. Settings, saved-layout metadata, search metadata, diagnostics, and recovery UI stay reachable without it (degraded mode).
- **Barline Screen Recording** — optional; never prompt unless the mapped feature needs item images.
- **Host Screen Recording** — only for `screencapture` of Barline windows.
- **Developer Tools** automation — XCUITest / `./script/test-xcode-ui.sh` only.

Never show an Accessibility or Screen Recording dialog the user (or this run) did not ask for. Never make a permission a condition of using Settings.

## Launch

Verification launch is an **unsigned arm64 Debug** app from a disposable derived-data root, not `/Applications/Barline.app`.

```bash
export VERIFY_BARLINE_RUN_ID="${VERIFY_BARLINE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
./.cursor/skills/verify-barline/scripts/control-barline launch
```

What that wraps (Mac only):

1. Refuses Linux / Intel / non-Darwin hosts with exit `2` and `GATED`.
2. Refuses if a previous verification instance file is still live.
3. Pauses a running **installed** `/Applications/Barline.app` via `script/lib/installed-app.sh` (exact executable path, not process name).
4. Sets `BARLINE_RUN_ROOT=/private/tmp/barline-verify-$(id -u)-$VERIFY_BARLINE_RUN_ID`.
5. Runs `./script/build_and_run.sh --verify`, which builds, ad-hoc signs, and launches with `--barline-reopen-probe`. Ready when stdout contains `verified: Barline is running from` and `pgrep -x Barline` sees a process whose executable path is under `$BARLINE_RUN_ROOT`.
6. Writes `$EVIDENCE_DIR/instance.env` (run root, bundle path, our PIDs only).

Canonical direct build if you must invoke Xcode yourself:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Barline.xcodeproj -scheme Barline \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

**Teardown:** `./.cursor/skills/verify-barline/scripts/control-barline cleanup` (see Cleanup). Do not leave the paused installed app stopped.

**Isolation:** two Barline instances cannot share the system menu bar or `UserDefaults`. Do not double-drive. Do not point this skill at a live user session. The installed-candidate journey in `script/INSTALLED_JOURNEY.md` is a separate, explicit path that **never** builds, launches, or quits Barline.

## Doctor

Read-only. Run first whenever anything looks off.

```bash
./.cursor/skills/verify-barline/scripts/control-barline doctor
```

A Mac instance is worth driving only when doctor prints `ui: ready` (or `ui: degraded` for Settings-only recipes). Treat `ui: gated` as a skip, not a pass.

Doctor answers:

- Host: `Darwin/arm64` and `sw_vers` ≥ 26, or `Linux` with `ui: gated`.
- Toolchain: `xcodebuild` under `/Applications/Xcode.app/Contents/Developer` (Mac UI only).
- Instance: `instance.env` exists, recorded executable path is the running Barline, bundle id is `com.mabryventures.Barline`, `codesign --verify --deep --strict` holds, architecture is `arm64`.
- Host AX: System Events can see process `Barline` (needed to click). Failure → `ui: gated` with `host_accessibility=missing`.
- Barline AX / Screen Recording: inferred from Settings copy (`Degraded mode:` banner vs layout editor), never by dumping TCC databases or process lists.
- Installed copy: whether `/Applications/Barline.app` was paused for this run.

On Linux, a healthy doctor looks like `ui: gated` plus `hygiene: ready` or `hygiene: missing-tools`. That is success for the Linux lane, not for UI.

## Drive

Harness: `control-barline` on top of repo scripts and, on a Mac, System Events (Accessibility). Prefer **names and AX identifiers from this repo** over coordinates.

```bash
./.cursor/skills/verify-barline/scripts/control-barline snapshot --path "$EVIDENCE_DIR/before.ax.txt"
./.cursor/skills/verify-barline/scripts/control-barline click --name "Advanced"
./.cursor/skills/verify-barline/scripts/control-barline screenshot --path "$EVIDENCE_DIR/advanced.png"
```

Stable handles (do not invent others):

| Surface | Handle |
| --- | --- |
| Settings window | title `Barline`, id `SettingsWindow` |
| Welcome window | title `Welcome to Barline`, id `WelcomeWindow` |
| Degraded banner | AX id `degraded-mode-banner` |
| Sidebar | `General`, `Menu Bar Layout`, `Menu Bar Appearance`, `Layouts & Focus`, `Hotkeys`, `Advanced`, `About` |
| Visible control | AX id `Barline.ControlItem.Visible` (status item; also window name `Barline.ControlItem.Visible`) |
| Shelf | window title / description / AX id `Barline Bar`, role `AXWindow` |
| Search field | prompt `Search menu bar items…` |
| Search alias | AX id `Barline.Search.AliasField` |
| Layout loading/empty/fail | `Barline.Layout.Loading`, `Barline.Layout.Empty`, `Barline.Layout.LoadFailed` |
| Support bundle status | AX id `support-bundle-status` |
| Profile status | AX id `profile-status` |
| Control menu | `Barline Settings…`, `Search Menu Bar Items`, `Show Hidden Section` / `Hide Hidden Section`, `Quit Barline` |

User entry points to Settings (prove at least one per settings recipe):

- Right-click the Barline icon → **Barline Settings…**
- Secondary menu (empty menu-bar area, if enabled) → **Barline Settings…**
- Search panel Settings button
- `./script/build_and_run.sh --verify` presents Settings via `--barline-reopen-probe` (launch convenience, **not** a user entry point)

Shelf / hidden-item reveal (user path only):

- Left-click `Barline.ControlItem.Visible`
- Menu: **Show Hidden Section**
- Hotkey recorded under Settings › Hotkeys › **Toggle the hidden section**

Do **not** post `com.mabryventures.Barline.runtime-smoke.toggle-shelf` and call the shelf verified. That notification is a CI probe (`--barline-runtime-smoke`). `./script/test-ui-smoke.sh` is a local gate, not a user-path proof.

Installed physical journeys stay behind `bash script/test-installed-journey.sh` and `script/INSTALLED_JOURNEY.md`. Those require a reserved pointer and a signed candidate; they are not the default unsigned recipe.

Linux drive (the only drive this VM can complete):

```bash
./.cursor/skills/verify-barline/scripts/control-barline linux-gates
```

That wraps `./script/ci/repo_hygiene.sh`, `./script/ci/architecture_firewall.sh`, `./script/test-platform-lane.sh`, `./script/test-app-intents-topology.rb`, `./script/test-installed-evidence.sh`, `./script/test-evidence-writer.sh`, `./script/test-installed-app-pause.sh`, `./script/test-release-notes.sh`, `./script/test-release-evidence-privacy.sh`, and `node --test site/tests/*.test.mjs`. It does not compile Swift and does not launch Barline.

## Evidence

Put every artifact under the run directory the helper prints:

```text
.artifacts/verify-barline/$VERIFY_BARLINE_RUN_ID/
```

That tree is gitignored (`.artifacts/`). Cleanup must not delete it.

Proof standards:

- Exercise the **user path** in the feature file, not internal setters, Debug notifications, or fixture-only XCUI.
- Capture the **action and the resulting state** (AX snapshot or screenshot of Barline-owned UI before and after).
- Mutation proof needs a second read (reopen the pane, reopen search, re-query the support-bundle status).
- Do not log secrets, user content, other apps' menu-bar titles, usernames, home paths, raw `ps` dumps, signing identities, or **private profile names**. Redact layout names in committed notes. Screenshots belong in `.artifacts/`, never in Git.
- Mocks only at production boundaries that already isolate the helper (synthetic installed-evidence fixtures are validator tests, not runtime evidence).
- A skipped Mac entry point is `GATED` with the unmet precondition. Do not mark it verified via Core tests.

Minimum files for a Mac UI proof:

- `doctor.txt` — doctor output
- `commands.log` — exact helper invocations
- `before.ax.txt` / `after.ax.txt` — System Events snapshots of the Barline window
- `after.png` — screenshot of that window only (host Screen Recording)
- `result.txt` — feature id, entry point, host OS/build, what was observed

Minimum files for a Linux hygiene proof:

- `doctor.txt`
- `linux-gates.log` — full stdout/stderr of `linux-gates`
- `result.txt` — `ui: gated`; list of gates that passed

## Cleanup

```bash
./.cursor/skills/verify-barline/scripts/control-barline cleanup
```

Cleanup:

- SIGTERM then SIGKILL **only** PIDs recorded in `instance.env` whose executable path is still under `$BARLINE_RUN_ROOT`.
- Removes `/private/tmp/barline-verify-*` run roots this helper created.
- Restores a paused `/Applications/Barline.app` via `barline_restore_installed_app`.
- **Keeps** `.artifacts/verify-barline/$VERIFY_BARLINE_RUN_ID/`.

Never `pkill -x Barline` from this skill. `build_and_run.sh` still does that internally during launch; that is why launch pauses the installed copy first.

## Helpers

All helpers are executable. From the repo root:

```bash
./.cursor/skills/verify-barline/scripts/control-barline help
./.cursor/skills/verify-barline/scripts/control-barline host
./.cursor/skills/verify-barline/scripts/control-barline doctor
./.cursor/skills/verify-barline/scripts/control-barline launch          # Mac; exit 2 on Linux
./.cursor/skills/verify-barline/scripts/control-barline linux-gates     # Linux-safe documented scripts
./.cursor/skills/verify-barline/scripts/control-barline click --name NAME
./.cursor/skills/verify-barline/scripts/control-barline snapshot --path FILE
./.cursor/skills/verify-barline/scripts/control-barline screenshot --path FILE
./.cursor/skills/verify-barline/scripts/control-barline cleanup
```

`linux-gates` and `doctor` are the only commands this Linux VM can complete. `launch`, `click`, `snapshot`, and `screenshot` must exit `2` with `GATED` here.

## Maintenance

When Settings labels, AX ids, or `./script/ci.sh` modes change, update this skill and `features/` with `/maintain-verification-skill`.
