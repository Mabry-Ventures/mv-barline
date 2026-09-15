# Privacy

Barline is a local macOS utility. It has no account, cloud service, analytics
SDK, advertising SDK, telemetry upload, or remote AI service. Barline does not
sell data or upload a menu bar inventory.

## Data Barline handles

Barline reads menu bar window metadata, application identifiers, item titles,
geometry, and process identifiers to identify and arrange status items. When
Screen Recording permission is granted, it captures menu bar item imagery for
local previews and appearance rendering. Those images are kept in process
memory; the current app does not provide an image-upload path.

Preferences, hotkeys, appearance choices, and an optional custom menu bar icon
are stored locally with macOS `UserDefaults`. Profiles and pending App Intent
commands use the Barline App Group container with atomic files, validation, and
a previous-valid backup. Profile archives are accessed only after an explicit
user import or export action.

On macOS 27, Barline also stores a bounded, sanitized menu bar inventory in
`UserDefaults`: stable item identifiers, titles and display names, section and
order, opaque display identity, and semantic capability flags. Process IDs,
window geometry, and screenshots are not retained in this inventory. This lets
a collapsed native divider preserve the user's arrangement after relaunch. The
data never leaves the Mac, is not included in support bundles, and new or
ambiguous items default to visible.

Search favorites and custom aliases are stored with stable item identifiers in
the bounded `SearchItemPreferences.json` file in Barline's local Application
Support directory. They are not sent to a server. You can remove a favorite or
clear an alias in the search interface; after quitting Barline, removing that
specific preferences file resets all search favorites and aliases. Exported
diagnostics must not include these private labels.

Optional automatic layout rules are off by default. When enabled, Barline reads
the current frontmost app identifier and power/battery state locally. It does
not retain an app-usage history. Selected app identifiers, target layout IDs,
rule priorities, conditions, and enabled/paused choices are stored in the bounded
`ContextualRules.json` file in local Application Support. Remove individual rules
in Layouts & Focus; removing this file after quitting resets automation to off.
Rules start paused whenever Barline reopens and require an explicit Resume;
failed storage or an interrupted session cannot silently resume rearrangement.

Per-item keyboard assignments pair stable item identifiers with key codes and
modifier flags in the bounded `ItemShortcutPreferences.json` file in the same
directory. They do not record typed text or keystroke history. Remove assignments
in Hotkeys, or remove that file after quitting to reset all item shortcuts.
Both files are written atomically with owner-only permissions. Neither is
uploaded or included in diagnostic bundles.

Interrupted temporary item reveals use a bounded local recovery journal in
Barline's Application Support directory. It stores stable item identifiers,
original display/section, neighboring identifiers and timestamps, not images.
Completed restorations remove their active records. Choosing Keep Current Item
Positions archives the old journal locally; those backup files remain until
you remove Barline's TemporaryReveals directory after quitting. Recovery files
are not included in support bundles or uploaded.

For display-specific profiles, Barline derives an opaque SHA-256 alias from
public display hardware values so a uniquely identifiable monitor can be
recognized after reconnecting. Raw hardware values are not stored. Profile
exports include the opaque alias so reconnect behavior survives import; sharing
an archive therefore shares a stable pseudonymous monitor identifier.

Barline writes operational messages to Apple's unified logging system. Current
item-operation logs use internal tags rather than menu item titles. Support
bundle export is explicit, bounded, sanitized, and reviewed before saving.

## Permissions

- Accessibility is required for cross-application discovery and mutation;
  settings, profile metadata, search, and diagnostics remain available in
  degraded mode.
- Screen & System Audio Recording is optional and supports item-image previews
  and menu bar appearance features.

Barline explains and requests a permission only after the user invokes a
feature that needs it. Denial and revocation retain the degraded experience;
grants are rechecked when the app becomes active.

## Network access

Debug builds disable automatic updates. Release builds trust only Barline's
committed Sparkle public key and GitHub-hosted signed appcast. Apart from update
checks, explicit links, and dependency resolution during development, Barline
has no intentional network feature.

## Sharing and deletion

Barline does not automatically share local data. Preferences can be removed by
deleting Barline's macOS preferences after quitting the app. Profiles can be
exported, selectively imported, deleted, or reset; last-known-good recovery is
available from Profiles settings.

This document describes the development tree, not a published binary release.
New feature code remains subject to installed-candidate qualification before
public distribution.
