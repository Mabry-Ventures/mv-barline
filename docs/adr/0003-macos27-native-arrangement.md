# ADR 0003: macOS 27 native arrangement authority

- Status: Accepted for implementation
- Date: 2026-09-16
- Evidence: `docs/MACOS_27_P3_RESULT.md`,
  `docs/MACOS_27_P4_VISIBILITY_RESULT.md`, and
  `docs/MACOS_27_P5_IDENTITY_RESULT.md`

## Context

Barline's imported macOS 27 path mixed three different mechanisms behind the
word "move":

1. native status-item order;
2. native visibility assignment;
3. Barline shelf order.

It also treated `com.apple.MenuBar` position records as if they were a stable,
current item identity. P3 proved that a bounded native Command-drag can reorder
live fixture items. P4 proved that visibility can be applied independently,
but third-party publishers with multiple items must be assigned as a complete
application group. P5 contradicted the durable position-record identity model:
verified native moves did not produce a stable, transaction-owned set of
records across AX, lifecycle, creation-order, and autosave variations.

The current shipping route also bypasses the real macOS 27 concealment
controller. `XPCMenuBarBackend.configureConcealment` calls the main-process
`GoldenGateAXSnapshotProvider` method, which intentionally does nothing, while
the transactional controller already exists in `BarlineMenuService`.

## Decision

### 1. Separate capabilities by state owner

Extend the compatibility contract with explicit arrangement capabilities:

```swift
public enum MenuBarVisibilityAssignmentGranularity: String, Codable, Sendable {
    case unavailable
    case item
    case applicationGroupAndKnownSystemItem
}

public struct MenuBarArrangementCapabilities: Codable, Equatable, Sendable {
    public let canReorderNativeItems: Bool
    public let visibilityAssignmentGranularity: MenuBarVisibilityAssignmentGranularity
    public let canReorderShelfItems: Bool
    public let canApplySavedNativeOrder: Bool
}
```

`MenuBarCapabilities` carries this value as an optional field for wire
compatibility. Missing fields decode to the conservative legacy projection.
The old `canMove` field remains only until all callers migrate; new product
decisions must not use it.

The macOS 27 backend reports:

- `canReorderNativeItems = true` only when the P3 gesture prerequisites pass;
- `visibilityAssignmentGranularity = .applicationGroupAndKnownSystemItem`
  only when the assessment controller is available;
- `canReorderShelfItems = true`;
- `canApplySavedNativeOrder = false`.

The macOS 26 backend keeps its current native move and restore semantics.

### 2. Remove the position table from macOS 27 mutation authority

On macOS 27, production code must not write, conditionally roll back, recover,
or use position-table records to authorize a move. The existing table reader
may remain temporarily for migration diagnostics only, behind a read-only
boundary, until its dead mutation code is deleted.

No AX title, AX identifier, coordinate, record count, creation order, current
autosave name, or historical table suffix may substitute for native identity.

### 3. Use one bounded native gesture transaction

Direct native reordering on macOS 27 uses this ownership split:

- `BarlineCore` owns pure eligibility, transaction state, result contracts,
  and capability policy.
- The main process resolves fresh AX elements, display topology, source and
  destination geometry, hit tests both endpoints, and observes the result.
- `BarlineMenuService` emits only the bounded raw HID Command-drag for a typed
  request containing validated geometry, button, modifier, display, deadline,
  and an opaque transaction token. It never receives a preference key or AX
  object.
- `MenuBarStateCoordinator` serializes the operation, rejects stale
  generations, and publishes a refreshed snapshot only after the requested
  adjacency and unrelated-order postconditions pass.

Cancellation, topology change, input interference, helper replacement,
timeout, failed hit testing, or ambiguous postconditions fail closed. Cleanup
must release the mouse button and Command modifier before returning. A failed
or indeterminate gesture never updates logical visibility, shelf order, saved
layout authority, or active-profile authority.

### 4. Route visibility through the XPC service

`XPCMenuBarBackend.configureConcealment` always calls
`BarlineMenuService.Connection.configureConcealment`. The no-op
`GoldenGateAXSnapshotProvider.configureConcealment` route is removed.

One pure `GoldenGateConcealmentPolicy` resolves every request before XPC:

- a third-party publisher with one item may appear item-granular because the
  application group has cardinality one;
- every item from a multi-item third-party publisher must receive the same
  assignment;
- known system identifiers may be assigned individually;
- mixed, unknown, ambiguous, Barline-owned, or untrusted assignments fail
  visible;
- allowed application identifiers preserve the installed bundle identifier's
  original spelling; comparisons remain case-insensitive.

The helper begins, verifies, commits, aborts, and invalidates the assessment
transaction. The main process does not publish the new logical assignment
until the helper acknowledges commit and a fresh snapshot is compatible with
the requested group policy.

### 5. Keep shelf order local

Shelf order is Barline-owned presentation state and never implies native menu
bar order. Reordering shelf items changes only the local shelf sequence. It
must not issue a native drag or touch the position table.

Clicking or temporarily revealing a shelf item may widen visibility only for
the bounded activation transaction. Restoration must be owned by the helper
transaction and survive cancellation, dismissal, and helper restart.

### 6. Use one policy for every activation source

`MenuBarArrangementPolicy` in `BarlineCore` computes an
`ArrangementExecutionPlan` from the current snapshot, requested profile, and
arrangement capabilities. The following entry points must call the same
coordinator method and may not perform arrangement work directly:

- Settings drag and direct profile application;
- keyboard shortcuts;
- App Intents;
- macOS Focus Filter commands;
- contextual rules;
- Presentation mode and recovery;
- launch/relaunch reconciliation.

On macOS 27, a saved layout applies supported visibility assignments, local
shelf order, appearance, triggers, and workspace settings. It does not restore
saved native order. Completion text and diagnostics must state that native
order remains managed by macOS; they must not report a full native-order
restore. Unsupported or ambiguous visibility requests fail visible and do not
become active profile authority.

### 7. Preserve macOS 26 behavior

The Tahoe backend, its native restore semantics, and its accepted tests remain
unchanged except for adapting to the explicit capability contract. Platform
selection occurs once at the backend and policy boundaries, not as scattered
view-level availability checks.

## Required implementation sequence

1. Add the capability types, conservative decoding, and pure policy tests.
2. Add the typed native gesture XPC request and helper implementation.
3. Replace the macOS 27 position-table move/restore path with the gesture
   transaction and AX postcondition.
4. Route concealment through XPC and enforce application-group admission.
5. Separate local shelf order from native order in Settings and profiles.
6. Route every activation source through the shared execution plan.
7. Delete or quarantine macOS 27 table mutation and recovery code.
8. Update UI copy, diagnostics, support bundles, architecture documentation,
   and release notes.

## Verification gates

No candidate may be called production ready until all of these pass at the
same source SHA:

- unit tests for capability decoding, policy admission, group visibility,
  unsupported saved native order, FIFO ownership, cancellation, and recovery;
- topology tests proving every activation source reaches the shared policy;
- research-bundle exclusion and no-position-write sentinels;
- macOS 26 regression suite with unchanged move, restore, profile, Focus,
  shortcut, rule, shelf, reveal, and activation behavior;
- macOS 27 fixture repetition for native reorder, interference rejection,
  visibility grouping, shelf-only ordering, temporary reveal, relaunch, helper
  replacement, and profile/Focus/shortcut/rule parity;
- signed candidate installation, accessibility permissions, notarization,
  staple, Gatekeeper, cold launch, update staging, and support-bundle checks;
- independent Gemini Flash 3.8 High and GPT-6 Astra High production-readiness
  reviews after all fixes and candidate-bound tests.

## Consequences

Barline no longer promises a capability that macOS 27 evidence cannot support:
automatic restoration of arbitrary saved native order. It retains safe direct
native reordering, native visibility at the proven granularity, and independent
local shelf ordering.

This removes the stale-record feedback loop that caused visual moves, failed
logical assignments, later snapback, and repeated incompatible fixes. It also
requires a compatibility-contract migration, a new XPC message, shared policy
work, explicit partial-capability UI, and complete regression qualification on
both supported operating systems before release.
