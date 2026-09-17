# macOS 27 arrangement research implementation plan

Status: approved planning artifact, not implementation evidence  
Prepared: September 16, 2026  
Research input: GPT-6 Pro research spike, `barline-macos27-research-spike.md`  
Local baseline at planning time: `6478e9c596d3fa62e95149dc5100bbfca8e38cf9`

## 1. Objective

Demonstrate the smallest reliable macOS 27 primitive for arranging menu-bar
items without guessing an Accessibility-to-preference-record association.
Keep the shipping macOS 27 backend fail closed until that primitive has passed
controlled forward and reverse experiments.

This plan separates four capabilities that earlier candidates coupled:

1. Native system-menu-bar order.
2. Native app or group visibility.
3. Barline shelf presentation and local shelf order.
4. Durable saved-layout and Focus identity.

A result for one capability does not authorize claims about another.

## 2. Current evidence boundary

The local candidate can discover macOS 27 items, present and dismiss the shelf,
activate shelf items, read the native position table, and reject unresolved
mutations without changing the layout. It cannot reliably associate a selected
AX item with one native position-table record.

The current candidate is not the research baseline merely because it is signed
or installed. Before work begins, bind every experiment to a fresh manifest
containing the exact source SHA, binary digest, harness digest, operating-system
build, machine, display topology, and permissions.

The current unresolved operation remains disabled during the research. No
experiment may make the production position-table writer more permissive.

## 3. Non-goals

- Do not publish a release, update feed, website change, or Git tag.
- Do not push the research branch without separate authorization.
- Do not test on CPLCLAUDE01.
- Do not restart the Mac, MenuBarAgent, SystemUIServer, or unrelated apps.
- Do not disable SIP, bypass TCC, inject into another process, or request
  private entitlements.
- Do not add AX-title, coordinate, record-count, or creation-order fallbacks.
- Do not treat a preference-table change as proof that the intended item moved.
- Do not copy Pelmet's private cursor behavior or entire input shield.
- Do not modify the macOS 26 Tahoe backend during the research phases.
- Do not begin broad Settings redesign or production packaging before a
  primitive passes its decision gate.

## 4. Workspace and source controls

### 4.1 Research workspace

Create an isolated worktree from the exact accepted local baseline. Suggested
branch name:

```text
research/macos27-native-arrangement
```

The main worktree may contain unrelated website and support changes. Record
them in the baseline manifest and leave them untouched.

### 4.2 Repository layout

Keep research-only executables outside the shipping Xcode project:

```text
Research/
  MacOS27ArrangementLab/
    README.md
    Package.swift or standalone lab project
    Sources/
      FixturePublisher/
      ArrangementObserver/
      SyntheticDragProbe/
    Tests/
```

The lab must not be embedded in `Barline.app`, added to its release archive, or
included in the Sparkle feed. The release gate must be able to prove that no
research executable is present in a shipping bundle.

### 4.3 Evidence storage

Store runtime evidence only under ignored paths:

```text
.artifacts/research/macos27-arrangement/<source-sha>/<run-id>/
```

Each run contains:

- `manifest.json`
- `events.jsonl`
- `result.json`
- `failures.jsonl`
- privacy-reviewed diagnostic summary

Do not store raw unrelated AX labels, preference keys, process inventories,
usernames, home-directory paths, or screenshots in committed files.

## 5. Architecture of the research harness

### 5.1 FixturePublisher

Build a controlled AppKit publisher with ground truth unavailable from arbitrary
third-party apps. It must support:

- One process publishing three independently distinguishable status items.
- A second process publishing one status item.
- Explicit, stable `NSStatusItem.autosaveName` values.
- Independently configurable AX identifiers, labels, and titles.
- Duplicate-label mode.
- Missing-label mode.
- Dynamic-title mode.
- Removal and recreation of one item.
- Reversed creation-order mode.
- An activation counter for every item.
- A signed, versioned readiness receipt containing only fixture-owned data.

Every fixture item must expose an internal immutable test token. The token is
ground truth inside the fixture and is never assumed to be a system position
key.

### 5.2 ArrangementObserver

Create a read-only observer that records:

- Fixture ground-truth item tokens.
- Current AX elements, roles, actions, frames, and relationships.
- AX hit-test result at the selected source and target points.
- Relative order of fixture items and selected neighboring system items.
- Active display identity, bounds, scale, and notch/overflow condition.
- Visible, hidden, and shelf assignment as separate fields.
- Table state through per-run keyed aliases when table observation is enabled.

The observer must distinguish:

- A changed coordinate.
- A changed relative order.
- A changed visible/hidden classification.
- A changed local shelf order.
- A changed table record.

None of those observations alone is a successful move.

### 5.3 SyntheticDragProbe

Implement the native event experiment as an explicit state machine:

```text
idle
  -> preflighting
  -> sourceValidated
  -> mouseDownPosted
  -> dragging
  -> mouseUpPosted
  -> observing
  -> verified | rejected | indeterminate
```

The probe accepts fixture-owned source and destination identities. It does not
accept a preference-table key.

Initial implementation requirements:

- Resolve a fresh visible AX source and destination.
- Validate the actual screen hit with
  `AXUIElementCopyElementAtPosition` and a bounded ancestor/descendant check.
- Reject shared-host PID matches without element relationship evidence.
- Reject offscreen, obscured, notch-covered, overflow-only, zero-sized, stale,
  or ambiguous elements.
- Require stable display topology and always-visible menu-bar configuration.
- Require no held mouse button and a quiet input window.
- Defer if the pointer never becomes quiet. Do not proceed merely because a
  timeout expired.
- Revalidate immediately before mouse-down.
- Use a HID event source and the global HID event stream.
- Put Command on mouse-down, every dragged event, and mouse-up.
- Emit bounded interpolated drag events rather than one coordinate jump.
- Run event production off the main actor.
- Keep the cursor visible in the first implementation.
- Do not use window-number fields, `postToPid`, or macOS 26 window routing.
- Record whether mouse-down and mouse-up were successfully constructed and
  posted.
- Guarantee bounded mouse-up cleanup after every post-down exit.
- Propagate cancellation rather than hiding it behind unrestricted `try?`.
- Avoid automatic reverse movement after user interference.

The first implementation must not swallow global physical input. If testing
shows that safe isolation is necessary, that becomes a separately reviewed
experiment with a bounded event tap, explicit escape path, and proof that the
tap is removed on every exit.

### 5.4 Result model

Define pure result types in the research target before event implementation:

```text
preflightRejected(reason)
moveVerified(evidence)
moveNotObserved(evidence)
interferenceDetected(evidence)
cleanupIndeterminate(evidence)
restorationVerified(evidence)
restorationFailed(evidence)
```

Success evidence requires:

- The selected source occupies the intended relative insertion point.
- Every unrelated fixture item preserves its relative order.
- Visibility matches the requested state.
- The selected item still activates exactly once.
- No synthetic input remains held.
- The source and destination are re-resolved after the operation.

## 6. Execution phases and gates

No later phase starts until the preceding gate has a written result.

### Phase 0: freeze the baseline and disable contamination

Tasks:

1. Create the isolated worktree.
2. Record local and remote branch state without resetting either.
3. Build the evidence manifest writer.
4. Record CPLCODEX01 macOS build, hardware, displays, scaling, notch state,
   menu-bar auto-hide, active Space, Xcode version, signing identity class,
   Accessibility permission, and Screen Recording permission.
5. Record competing menu-bar managers and stop only their layout controllers
   when specifically authorized.
6. Add a research assertion that aborts if Barline attempts a native
   position-table write during Phases 1 through 3.
7. Verify that the shipping candidate still fails closed on unresolved identity.

Gate P0:

- Manifest complete.
- No production files modified.
- Position-table write sentinel tested.
- CPLCODEX01 is the only macOS 27 host in scope.

### Phase 1: fixture ground truth

Tasks:

1. Implement both fixture publishers.
2. Implement all label, lifecycle, and creation-order modes.
3. Implement activation counters and signed readiness receipts.
4. Implement the read-only observer.
5. Demonstrate that the observer distinguishes every fixture item even when AX
   labels are duplicated or absent.
6. Demonstrate that recreation invalidates the old live AX element.

Gate P1:

- Fixture identities and activation counters are deterministic.
- Observer reports correct relative order in every fixture mode.
- No table writes occur.
- Raw unrelated AX data is absent from artifacts.

### Phase 2: manual native positive control

This phase requires two deliberate human gestures because generic Computer Use
cannot hold Command across a drag.

Tasks:

1. Present one fully visible three-item fixture.
2. Capture the stable precondition.
3. Ask for one Command-drag of the named fixture item past its named neighbor.
4. Verify relative order, activation, and unrelated-order preservation.
5. Ask for one reverse Command-drag.
6. Verify complete restoration.

Gate P2:

- Forward and reverse native moves both pass.
- If either gesture fails, classify whether the item is protected,
  non-draggable, obscured, or otherwise ineligible.
- A failed manual positive control stops synthetic-drag work for that fixture.

### Phase 3: independent synthetic native drag

Tasks:

1. Implement the minimal SyntheticDragProbe.
2. Start with the single-item publisher and short-distance reorder.
3. Test the three-item publisher in normal-label mode.
4. Test forward and reverse movement.
5. Add duplicate-label, absent-label, dynamic-title, recreation, and reversed
   creation-order cases.
6. Run an initial pilot of 20 forward/reverse cycles for each admitted fixture
   class, retaining every failure.
7. Test deliberate pointer or topology interference and require a rejected or
   indeterminate result rather than false success.

Gate P3:

- Intended relative placement is verified, not inferred from coordinates.
- Unrelated order is preserved in every passing run.
- Activation works exactly once after every passing move.
- Cleanup is proven after success, rejection, cancellation, and interference.
- Zero position-table writes and zero process restarts occur.
- Any fixture class that cannot meet the gate is explicitly unsupported.

Decision after P3:

- If P3 passes, authorize design of a production native-gesture backend.
- If manual P2 passes but P3 fails, retain native Command-drag guidance and
  investigate only the recorded delivery difference.
- If P2 fails, preserve read-only arrangement behavior for that class.

### Phase 4: independent visibility and shelf order

Run this phase separately from physical ordering.

Tasks:

1. Trace the current Settings assignment from UI through
   `XPCMenuBarBackend`, `GoldenGateAXSnapshotProvider`, and the concealment
   controller.
2. Prove whether a single-item fixture can be hidden and shown through native
   concealment without a position-table mutation.
3. Hide and show the multi-item publisher only as an explicit group.
4. Reject or explain a mixed same-app assignment. Never hide siblings silently.
5. Reorder fixture representations in Barline's local shelf model while proving
   native system order remains unchanged.
6. Exercise reveal, activation, dismissal, relaunch, and repetition.
7. Verify clock, Control Center, Notification Center, and normal system menus.

Gate P4:

- Visibility results identify their granularity: item, app, or group.
- Shelf ordering is demonstrably local.
- Native system order is unchanged by a shelf-order operation.
- Relaunch restores only state proven safe for that granularity.
- Focus, shortcuts, and automation cannot bypass the same restriction.

### Phase 5: bounded persistence-identity research

This phase begins only after P3 and P4 produce discriminating evidence.

Tasks:

1. Vary fixture autosave name, AX identifier, title, lifecycle, and creation
   order one variable at a time.
2. Observe native table changes read-only.
3. Inspect only documented runtime interfaces and concrete available classes.
4. Determine whether any structural mapping survives multiple same-process
   items, duplicate labels, recreation, relaunch, and native renumbering.
5. Treat manual forward/reverse correlation as session-scoped unless durability
   is independently proven.

Gate P5:

- Classify the identity hypothesis as supported, contradicted, or unresolved.
- No table writer is re-enabled merely because one correlation is unique.
- A durable mapping requires repeatable proof across every required lifecycle.

### Phase 6: production integration design

This phase produces an architecture decision record before product code.

If native synthetic drag passes P3, the preferred integration boundary is:

- `BarlineCore`: pure move-state, eligibility, evidence, and result contracts.
- Main Barline process: trusted AX resolution, hit testing, fresh geometry,
  topology validation, and postcondition observation.
- `BarlineMenuService`: narrowly scoped raw HID event production behind a new
  typed XPC request. It receives validated geometry and a transaction token,
  not a preference key or AX object.
- `MenuBarStateCoordinator`: FIFO admission, generation ownership,
  cancellation, compensation decision, and authoritative refresh.

Suggested production types:

```text
GoldenGateNativeMoveEligibility
GoldenGateNativeMoveRequest
GoldenGateNativeMoveStage
GoldenGateNativeMoveEvidence
GoldenGateNativeMoveResult
```

The new mover must not reuse `WindowServerClient.synthesizeMove` because that
method depends on per-window identifiers and process-targeted delivery from the
macOS 26 model.

If visibility passes P4 independently, add explicit capability fields rather
than overloading `canMove`:

```text
canReorderNativeItems
visibilityAssignmentGranularity
canReorderShelfItems
canApplySavedNativeOrder
```

Profiles and Focus must consume those capabilities. A saved layout may contain
local shelf order even when native order is unavailable, but the UI and archive
must distinguish them.

If neither P3 nor a durable P5 identity passes, remove macOS 27 graphical move
affordances and ship the inventory as read-only with native Command-drag
guidance. Do not retain a control that predictably produces an error dialog.

Gate P6:

- ADR reviewed.
- Capability semantics cover Settings, keyboard, Accessibility actions,
  profiles, Focus, shortcuts, rules, restore, and automation.
- Position-table code is either removed from mutation authority or retained
  only behind a separately proven capability.
- macOS 26 behavior and protocol compatibility remain unchanged.

### Phase 7: implementation and automated verification

Only after P6 approval:

1. Add pure state-machine and eligibility tests first.
2. Add typed XPC protocol changes with decoding/version rejection tests.
3. Implement helper event production.
4. Implement main-process AX preflight and postcondition verification.
5. Wire the coordinator.
6. Wire Settings after backend behavior passes.
7. Wire profiles, Focus, shortcuts, and rules last.

Required automated cases:

- Duplicate labels.
- Multiple items from one publisher.
- Recreated AX element.
- Dynamic title.
- Changed creation order.
- Source disappears before mouse-down.
- Destination disappears before mouse-down.
- Display topology changes during preflight.
- Cancellation before and after mouse-down.
- User input before and during a drag.
- Mouse-event allocation failure.
- Helper interruption at every move stage.
- Activation after move.
- Forward and reverse verification.
- No success state from coordinate change alone.
- No table write in native-gesture mode.
- macOS 26 backend selection and movement unchanged.

Gate P7:

- `./script/ci.sh fast` passes on exact source.
- Debug, Release, static analysis, strict lint, and Core tests pass.
- Research harness remains excluded from shipping products.
- A changed source SHA invalidates previous runtime receipts.

### Phase 8: installed qualification

Freeze one signed, notarized private candidate. Test it on:

- The macOS 26 qualification host.
- CPLCODEX01 running macOS 27.

Initial macOS 27 installed matrix:

| Scenario | Required result |
| --- | --- |
| Single fixture item | Forward and reverse order verified |
| Three items, unique labels | Correct insertion and preserved sibling order |
| Duplicate labels | Exact selected item moves or operation rejects |
| Missing labels | Exact selected item moves or operation rejects |
| Dynamic title | Identity remains correct or operation rejects |
| Recreated item | Stale operation rejects; fresh operation may proceed |
| Same-app multiple items | Supported granularity is enforced |
| Notch/overflow | Obscured targets reject; visible targets verify |
| Auto-hide | Native fallback applies; no synthetic hidden-bar drag |
| Multiple displays | Active target display and topology are verified |
| Spaces/full screen | Unsupported configurations reject cleanly |
| Sleep/wake | Fresh resolution required before movement |
| Relaunch | No stale session association is reused |
| User interference | Rejected or indeterminate, never false success |
| Helper interruption | Input cleanup and authoritative refresh succeed |
| Activation after move | Exactly one target action occurs |

Then run the macOS 26 regression matrix for discovery, left/right activation,
popover reuse, shelf performance, movement, restore, saved layouts, Focus, and
helper recovery.

Gate P8:

- Exact candidate receipts pass on both operating systems.
- All failed attempts remain in the evidence packet.
- No production readiness claim is made from the 20-cycle research pilot.
- Accessibility, physical displays, update, and recovery retain independent
  evidence classes.

## 7. Stop conditions

Stop the current experiment and preserve evidence when any of these occurs:

- The selected item cannot be uniquely hit-tested.
- A fixture ground-truth identity cannot be followed through the operation.
- The display topology changes.
- The menu bar becomes hidden or the target moves into overflow.
- User input begins during the operation.
- Mouse-down may have posted but mouse-up cannot be confirmed.
- An unrelated fixture item changes relative order unexpectedly.
- The target no longer activates once after movement.
- A position-table write occurs during a no-write experiment.
- A process restart appears necessary to obtain the expected result.
- The result requires a private entitlement or invented selector.

A stop condition produces `rejected` or `indeterminate`, never `passed`.

## 8. Evidence report required before integration

The research handoff must report:

- Exact source, binaries, OS build, machine, displays, toolchain, signing, and
  permission state.
- Result for H1 native event ordering, H2 independent visibility, and H3 native
  identity: supported, contradicted, or unresolved.
- Whether each success required a per-item window ID, position key, preference
  write, or system-process restart.
- Fixture identity, AX relationship proof, hit-test proof, intended order,
  observed order, preservation of unrelated order, activation, cleanup, and
  reverse restoration.
- Every failed and interfered run.
- Exact supported granularity for same-app items.
- Proposed capability boundaries and smallest integration diff.
- Explicit statement that the report is research evidence, not a release
  certificate.

## 9. Estimated work sequence

The plan is milestone-based rather than calendar-based:

1. P0-P1: harness foundation and fixture truth.
2. P2: two-gesture human positive control.
3. P3: synthetic-drag primitive and fixture pilot.
4. P4: visibility and shelf-order separation.
5. P5: optional identity research.
6. P6: architecture decision.
7. P7: production implementation, if authorized by evidence.
8. P8: exact-candidate installed qualification.

If P3 fails, the plan intentionally becomes shorter: retain native Command-drag
guidance, finish P4 capability separation, remove misleading macOS 27 movement
affordances, and qualify the reduced product boundary.

## 10. Primary implementation references

- [Pelmet's pinned ItemMover.swift](https://github.com/fif7y/pelmet/blob/e8978b8c27eb05b9b7e26a9b6aea1835ac22ddfc/Packages/PelmetEngine/Sources/PelmetEngine/ItemMover.swift)
  is implementation evidence for a HID Command-drag, not proof that Barline can
  reuse it safely.
- [Pelmet's pinned PlacementController.swift](https://github.com/fif7y/pelmet/blob/e8978b8c27eb05b9b7e26a9b6aea1835ac22ddfc/Pelmet/App/PlacementController.swift)
  shows that its full product also uses preference reconstruction, so its mover
  must be evaluated independently.
- [Apple's AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h)
  is the source for screen-position element validation.
- [Apple's NSStatusItem autosaveName](https://developer.apple.com/documentation/appkit/nsstatusitem/autosavename-swift.property)
  is a fixture variable to investigate, not an assumed Barline identity.
- Barline's existing macOS 26 synthetic move remains a regression boundary, not
  the implementation template for macOS 27.

Pinned external sources are retained in the originating research spike. Any
source incorporated into production must receive license and attribution review
before code is copied.
