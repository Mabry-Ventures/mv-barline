# Barline verification map

This directory is the maintained source for verifying the user-facing behavior of Barline. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Host is an Apple Silicon Mac running macOS 26 or later with Xcode 26.6, **or** stop at the Linux hygiene lane documented in the skill. Do not fake a menu-bar UI proof on Linux.
- Launch only through `control-barline launch` so the unsigned Debug bundle lives under `/private/tmp/barline-verify-*` and a running `/Applications/Barline.app` is paused first.
- Set `VERIFY_BARLINE_RUN_ID` to a unique value so evidence lands in `.artifacts/verify-barline/$VERIFY_BARLINE_RUN_ID/`.
- Run `control-barline doctor` and require `ui: ready` or `ui: degraded` before any Mac recipe. `ui: gated` is a skip.
- Never drive an instance that was not started by this verification run. Never drive a user's live menu bar.
- Do not grant Accessibility or Screen Recording unless the feature file's preconditions name that grant and the user/run asked for it.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say otherwise.
- Prefer AX identifiers and visible control names from this repo over coordinates, tab order, or `runtime-smoke` notifications.
- Treat every command as literal. Keep quoted names and flags unchanged.
- Run Mac UI actions through `control-barline click`, `snapshot`, and `screenshot`.
- Run Darwin-free gates through `control-barline linux-gates`.
- Restore any layout this run captured or applied. Do not remove proof artifacts during cleanup.
- Redact private profile names, other apps' item titles, home paths, and process inventories from anything that might be committed.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof includes an AX snapshot of the Barline-owned window and, when host Screen Recording is granted, a screenshot of that window only.
- Linux proof includes the command, stdout, stderr, and exit code of `linux-gates`.
- Mutation proof includes a read-only second view of the stored or on-screen value.
- Record the feature ID and entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition (`GATED: host is Linux`, `GATED: host Accessibility missing`, `GATED: Barline Accessibility missing`).
- Do not report a skipped entry point as verified through Core tests, fixture XCUI, or a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with control-barline` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Settings and degraded mode](./settings.md) covers opening Settings, the sidebar panes, and using the app without Accessibility.
- [Reveal hidden items](./reveal-hidden-items.md) covers the Barline icon, the Barline Bar shelf, and keyboard reveal.
- [Search menu bar items](./search.md) covers the search panel, aliases, and result activation.
- [Layouts and Focus](./layouts-and-focus.md) covers capturing, applying, importing, and recovering saved layouts.
- [Diagnostics](./diagnostics.md) covers the privacy-bounded support bundle and Advanced permission status.
