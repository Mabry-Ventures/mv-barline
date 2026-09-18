# Search menu bar items

Search lets a user find menu-bar items and saved layouts by name or alias, inspect a match, and activate or show a selected item without uploading inventory.

## Sub-features

- `search-open` opens the search panel from the Barline menu or the search hotkey.
- `search-query` filters the list from the field prompted `Search menu bar items…`.
- `search-empty` shows loading, empty, or failed copy when there is nothing to list.
- `search-alias` edits a local alias in the field `Barline.Search.AliasField`.
- `search-activate` uses **Click Item** / **Show Item** or Return on a selected result.
- `search-escape` dismisses the panel or cancels alias editing.

## How to get to it (user POV)

- Right-click the Barline icon and choose `Search Menu Bar Items`.
- Press the hotkey recorded in Settings › Hotkeys › **Search menu bar items**.
- After search is open, choose **Item Actions** for the selected row, or **Click Item** / **Show Item** in the bottom bar.

## Driving it with control-barline

Preconditions:

- `control-barline doctor` reports `ui: ready` for item results (Barline Accessibility on) or `ui: degraded` for the empty/failed copy only.
- Host Accessibility is granted to the driving process.
- Do not screenshot a result list that names other apps' items into Git. Keep those captures in `.artifacts/verify-barline/`.
- Do not run Apple Intelligence / on-device command interpretation as a required pass; deterministic name match is enough.

- **Open search.** Choose `Search Menu Bar Items`. Run `control-barline click --role menu-item --name "Search Menu Bar Items"`. A panel appears with a text field prompted `Search menu bar items…` and focus in that field.
- **Query.** Type a token that matches a known control or fixture, not a person's document name. Run `control-barline fill --name "Search menu bar items…" --value "Barline"`. The list updates to matching rows or stays on `No menu bar items found` / `Loading menu bar items…` / `Menu bar items could not be loaded`.
- **Failed discovery.** If the failed copy is shown, choose `Try Again`. Run `control-barline click --name "Try Again"`. Either items appear or the failed copy remains; both are valid observations when Accessibility or the helper is unhealthy.
- **Activate or show.** With a selected non-control item, choose `Click Item` if it is on-screen or `Show Item` if it is hidden. Run `control-barline click --name "Show Item"` or `control-barline click --name "Click Item"`. Observe either the item's interface or the AX id `Barline.Search.ActivationNotice`.
- **Alias (optional).** Open **Item Actions** (`Actions for selected menu bar item`) and start alias editing. Run `control-barline fill --identifier "Barline.Search.AliasField" --value "verify-alias"`, then `control-barline click --name "Save"`. Cancel with `Cancel` or Escape if you must not persist aliases on this Mac.
- **Dismiss.** Press Escape. The panel closes. If an alias editor was open, the first Escape cancels the editor only; press Escape again to close search.
- **Proof.** Run `control-barline snapshot --path "$EVIDENCE_DIR/search.ax.txt"`. The snapshot includes the search field prompt or, after dismiss, no search panel. Record whether results came from Accessibility inventory or from the empty/failed fallback.

Linux: `GATED`. Core search tests in `BarlineCore` are not this feature.

## Gotchas

- Search remains available in degraded mode as **metadata** search, but live item activation needs Accessibility and a valid snapshot.
- Spotlight / Core Spotlight unavailability must not be reported as search being broken; the in-process index is enough.
- Natural-language command rows (`Run` / `Confirm` / `Edit Manually`, AX id `search-command-action`) are optional and on-device. Skip them unless that sub-feature is in scope. Never send inventory off-machine.
- Escape is overloaded: alias cancel vs panel close.
- Activating a real third-party extra can steal the pointer. Prefer Barline's own controls or `BarlineFixture` items during qualification.
- Do not paste other apps' item titles into the PR body.
