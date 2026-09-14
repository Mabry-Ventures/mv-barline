# Barline architecture

Barline currently consists of the SwiftUI/AppKit application, a pure Swift
`BarlineCore` package, and the embedded `BarlineMenuService` XPC helper.

## Runtime responsibilities

- `Barline` owns presentation, input observation, settings, permissions,
  update UI, and the projection of validated domain state.
- `BarlineCore` owns stable item identity, typed snapshots, validation,
  backend contracts, transactional coordination, profiles, and deterministic
  search. It imports Foundation only.
- `BarlineMenuService` owns compatibility probes and WindowServer access. It
  selects Tahoe, Golden Gate, or safe fallback behavior through live probes.
- `Shared` contains the Codable XPC envelope and public utilities needed by
  both processes. Ephemeral window descriptions and direct compatibility
  wrappers live only in the helper.

The app communicates with the helper through Codable request and response
values. Synchronous transport calls run on the connection queue, never on the
caller's actor. Cancellation invalidates a connection generation so late
responses cannot become authoritative.

## State flow

1. The helper resolves required symbols dynamically and runs a behavioral
   enumeration probe.
2. The app requests a typed `MenuBarSnapshot` through `XPCMenuBarBackend`.
3. `MenuBarStateCoordinator` validates display geometry, active-space state,
   timestamp, generation, item identities, required controls, and continuity.
4. Only a valid candidate becomes current and last-known-good state.
5. Mutations take an explicit FIFO coordinator turn, validate before and
   after the operation, and accept rollback only after a fresh snapshot proves
   the exact logical layout was restored. Unverifiable rollback clears current
   and profile authority while retaining last-known-good recovery data.
6. Profile activation and history treat menu-bar layout, user-facing workspace
   settings, and resolved group/spacer presentation as one transaction. History
   stores all three, move planning uses section-relative global order plus an
   explicit live destination display, and a restored profile ID remains
   authoritative only while the definition selected for that display matches.
   Reconnected overrides use a helper-derived opaque hardware alias only when
   exactly one stored override and one live display match.
7. Recovery invalidates the helper connection, re-probes, rebases helper
   generations monotonically, restores when the backend supports it, and
   refreshes authoritative state. A failed recovery never republishes cached
   state from the superseded helper.
8. Shelf presentation is provisional until two consecutive observations agree
   that AppKit has a visible, active-Space panel with usable target-display
   geometry and a direct, read-only helper probe reports the semantic shelf
   role onscreen for the app process on that display. The helper retains the
   ephemeral WindowServer identity; only role-level booleans cross XPC. This
   probe bypasses the mutation actor and a probe timeout does not invalidate the
   shared session. Failed commits retry once and then roll back the logical
   section; later AppKit order-out also reconciles the logical presentation
   state.
9. On macOS 27, the app sends the helper a complete visible/concealed identity
   partition. A pure policy converts that state into native system-item and
   application allowlists. Mixed assignments for one application and unknown
   Apple items fail visible. Shelf activation temporarily widens the allowlist
   for the selected application's interface and restores it after the observed
   interface closes.

Recurring 1–10 second refresh and image-capture timers have been removed.
Refreshes are driven by application, workspace, wake, active-space, display,
theme, permission, and mutation events. One-shot debounce and auto-rehide
timers remain bounded interaction mechanics, not idle polling.

## Compatibility boundary

Stable IDs, semantic geometry, bounded PNG payloads, environment state, and
typed mutation results are the complete cross-process contract. The helper
re-enumerates and revalidates a stable ID immediately before acting. Duplicate
base identities receive deterministic occurrence aliases within a snapshot;
raw window numbers never cross XPC. See `PRIVATE_API_BOUNDARY.md`.
