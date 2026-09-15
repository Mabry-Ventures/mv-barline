//
//  StateCoordinatorTests.swift
//  Barline
//

@testable import BarlineCore
import Foundation
import Testing

@Suite("Transactional state coordinator")
struct StateCoordinatorTests {
    @Test("A base layout cannot commit across an unadmitted empty-display connection")
    func rejectsBaseTopologyChange() async throws {
        let before = makeSnapshot(generation: 1, count: 1)
        let after = MenuBarSnapshot(
            generation: 2, capturedAt: before.capturedAt, items: before.items,
            displayIDs: before.displayIDs.union([MenuBarDisplayID("new-empty-display")]), activeSpaceIsValid: true
        )
        let backend = FakeBackend(snapshots: [before, after])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        await #expect(throws: MenuBarBackendError.operationFailed("profile display topology changed during activation")) {
            try await coordinator.activate(
                profile: BarlineProfile(name: "Base", layout: ProfileLayout(visible: before.items.map(\.id))),
                now: before.capturedAt
            )
        }
        #expect(await coordinator.activeProfileID == nil)
        #expect(await backend.moveOperations.isEmpty)
    }

    @Test("Physical profile destinations are checked before checkpoint or workspace effects")
    func rejectsEmptyPhysicalDestinationBeforeEffects() async throws {
        let before = makeSnapshot(generation: 1, count: 1)
        let backend = FakeBackend(
            snapshots: [before],
            capabilities: MenuBarCapabilities(
                canSnapshot: true, canMove: true, canReveal: true, canActivate: true, canRestore: true
            )
        )
        let workspace = WorkspaceRecorder(initial: ProfileWorkspaceState(profile: BarlineProfile(name: "Original")))
        let coordinator = MenuBarStateCoordinator(backend: backend)
        await #expect(throws: ProfileLayoutReconciler.Failure.unsupportedDestination) {
            try await coordinator.activate(
                profile: BarlineProfile(name: "Target", layout: ProfileLayout(hidden: before.items.map(\.id))),
                workspaceTransaction: MenuBarWorkspaceTransaction(
                    capture: { await workspace.capture() }, apply: { try await workspace.apply($0) }
                ),
                prepareCheckpoint: { _, _ in Issue.record("Impossible plan must not create a checkpoint") }
            )
        }
        #expect(await workspace.values.isEmpty)
        #expect(await backend.moveOperations.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Activation preserves newly discovered anchors and never drags fixed items")
    func activatesAroundFixedAndNewItems() async throws {
        let seed = makeSnapshot(generation: 1, count: 4)
        let ids = seed.items.map(\.id)
        func snapshot(_ generation: UInt64, indices: [Int]) -> MenuBarSnapshot {
            MenuBarSnapshot(
                generation: generation, capturedAt: seed.capturedAt,
                items: indices.enumerated().map { order, index in
                    MenuBarItemDescriptor(
                        id: ids[index], section: .visible, order: order,
                        displayID: seed.items[index].displayID, isMovable: index != 2
                    )
                },
                displayIDs: seed.displayIDs, activeSpaceIsValid: true
            )
        }
        let before = snapshot(1, indices: [3, 1, 2, 0])
        let after = snapshot(2, indices: [0, 1, 2, 3])
        let profile = BarlineProfile(name: "Saved", layout: ProfileLayout(visible: [ids[0], ids[2], ids[3]]))
        let backend = FakeBackend(snapshots: [before, after])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let result = try await coordinator.activate(profile: profile, now: after.capturedAt)
        #expect(result == after)
        #expect(await coordinator.activeProfileID == profile.id)
        #expect(await backend.moveOperations.count == 2)
        #expect(await backend.moveOperations.allSatisfy { $0.itemID != ids[1] && $0.itemID != ids[2] })
        var workspace = ProfileWorkspaceState(profile: profile)
        workspace.presentation = try profile.resolvedPresentation(using: nil).resolvingItemIdentities(in: after)
        #expect(ProfileAuthorityMatcher.matches(
            profile: profile,
            checkpoint: MenuBarWorkspaceCheckpoint(snapshot: after, activeProfileID: profile.id, workspace: workspace)
        ))
    }

    @Test("Rule authority denial occurs before any layout or workspace effect")
    func ruleAdmissionDenialHasNoEffects() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let backend = FakeBackend(snapshots: [before])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        let profile = BarlineProfile(name: "Rule", layout: ProfileLayout(hidden: before.items.map(\.id)))
        await #expect(throws: CancellationError.self) {
            try await coordinator.activate(profile: profile, admission: { throw CancellationError() })
        }
        #expect(await backend.moveOperations.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.mutationGeneration == 0)
    }

    @Test("Rule authority revocation between moves compensates without publishing the layout")
    func ruleAdmissionRevocationRollsBack() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let restored = makeSnapshot(generation: 3, count: 2)
        let backend = FakeBackend(snapshots: [before, restored])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        let profile = BarlineProfile(name: "Rule", layout: ProfileLayout(hidden: before.items.map(\.id)))
        await #expect(throws: CancellationError.self) {
            try await coordinator.activate(profile: profile, admission: {
                if await !backend.moveOperations.isEmpty {
                    throw CancellationError()
                }
            })
        }
        #expect(await backend.moveOperations.count == 1)
        #expect(await backend.restoredSnapshots.count == 1)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == restored)
        #expect(await coordinator.canUndo == false)
    }

    @Test("Rule revocation after workspace apply restores workspace without moving items")
    func ruleAdmissionRestoresWorkspace() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let live = makeSnapshot(generation: 2, count: 2)
        let restored = makeSnapshot(generation: 3, count: 2)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let workspace = WorkspaceRecorder(initial: original)
        let backend = FakeBackend(snapshots: [before, live, restored])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        let profile = BarlineProfile(name: "Rule", layout: ProfileLayout(hidden: before.items.map(\.id)))
        await #expect(throws: CancellationError.self) {
            try await coordinator.activate(
                profile: profile,
                workspaceTransaction: MenuBarWorkspaceTransaction(
                    capture: { await workspace.capture() }, apply: { try await workspace.apply($0) }
                ),
                admission: {
                    if await !workspace.values.isEmpty {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(await backend.moveOperations.isEmpty)
        #expect(await workspace.values.count == 2)
        #expect(await workspace.capture() == original)
        #expect(await coordinator.currentSnapshot == restored)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Admission is rechecked after the asynchronous restoration journal guard")
    func ruleAdmissionRecheckedAfterJournal() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let backend = FakeBackend(snapshots: [before])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let journal = RestorationGuardRecorder(rejects: false)
        _ = try await coordinator.refresh()
        await coordinator.setBeforeAuthoritativeLayoutMutation { try await journal.check() }
        let profile = BarlineProfile(name: "Rule", layout: ProfileLayout(hidden: before.items.map(\.id)))
        await #expect(throws: CancellationError.self) {
            try await coordinator.activate(profile: profile, admission: {
                if await journal.calls > 0 {
                    throw CancellationError()
                }
            })
        }
        #expect(await journal.calls == 1)
        #expect(await backend.moveOperations.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await coordinator.mutationGeneration == 0)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Pending restoration guard blocks manual layout effects without replacing authority")
    func restorationGuardBlocksManualMutation() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let backend = FakeBackend(snapshots: [before])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let guardRecorder = RestorationGuardRecorder(rejects: true)
        _ = try await coordinator.refresh()
        await coordinator.setBeforeAuthoritativeLayoutMutation { try await guardRecorder.check() }

        await #expect(throws: MenuBarBackendError.interrupted) {
            try await coordinator.perform(.move(MenuBarMoveOperation(
                itemID: before.items[0].id, section: .hidden, index: 0
            )))
        }

        #expect(await guardRecorder.calls == 1)
        #expect(await backend.moveOperations.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await coordinator.currentSnapshot == before)
        #expect(await coordinator.lastKnownGoodSnapshot == before)
        #expect(await coordinator.mutationGeneration == 0)
        #expect(await coordinator.layoutAuthorityGeneration == 0)
        #expect(await coordinator.canUndo == false)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Pending restoration guard blocks profile layout and workspace effects")
    func restorationGuardBlocksProfileMutation() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let live = makeSnapshot(generation: 2, count: 2)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let workspace = WorkspaceRecorder(initial: original)
        let profile = BarlineProfile(name: "New", layout: ProfileLayout(hidden: before.items.map(\.id)))
        let backend = FakeBackend(snapshots: [before, live])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let guardRecorder = RestorationGuardRecorder(rejects: true)
        _ = try await coordinator.refresh()
        await coordinator.setBeforeAuthoritativeLayoutMutation { try await guardRecorder.check() }

        await #expect(throws: MenuBarBackendError.interrupted) {
            try await coordinator.activate(
                profile: profile,
                workspaceTransaction: MenuBarWorkspaceTransaction(
                    capture: { await workspace.capture() },
                    apply: { try await workspace.apply($0) }
                )
            )
        }

        #expect(await guardRecorder.calls == 1)
        #expect(await backend.moveOperations.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await workspace.values.isEmpty)
        #expect(await workspace.capture() == original)
        // History preflight may refresh physical evidence, but never changes its layout.
        #expect(await coordinator.currentSnapshot == live)
        #expect(await coordinator.lastKnownGoodSnapshot == live)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.mutationGeneration == 0)
        #expect(await coordinator.layoutAuthorityGeneration == 0)
        #expect(await coordinator.canUndo == false)
    }

    @Test("Pending restoration guard leaves undo and redo checkpoints intact", arguments: [false, true])
    func restorationGuardBlocksHistoryMutation(redo: Bool) async throws {
        let snapshots = (1 ... 6).map { makeSnapshot(generation: UInt64($0), count: 2) }
        let backend = FakeBackend(snapshots: snapshots)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        _ = try await coordinator.perform(.reveal(snapshots[0].items[0].id))
        if redo {
            _ = try await coordinator.undo()
        }
        let priorRestorations = await backend.restoredSnapshots
        let priorMutationGeneration = await coordinator.mutationGeneration
        let priorAuthorityGeneration = await coordinator.layoutAuthorityGeneration
        let guardRecorder = RestorationGuardRecorder(rejects: true)
        await coordinator.setBeforeAuthoritativeLayoutMutation { try await guardRecorder.check() }

        await #expect(throws: MenuBarBackendError.interrupted) {
            if redo {
                try await coordinator.redo()
            } else {
                try await coordinator.undo()
            }
        }

        #expect(await guardRecorder.calls == 1)
        #expect(await backend.restoredSnapshots == priorRestorations)
        #expect(await backend.moveOperations.isEmpty)
        #expect(await coordinator.currentSnapshot == snapshots[redo ? 4 : 2])
        #expect(await coordinator.mutationGeneration == priorMutationGeneration)
        #expect(await coordinator.layoutAuthorityGeneration == priorAuthorityGeneration)
        #expect(await coordinator.canUndo == !redo)
        #expect(await coordinator.canRedo == redo)
    }

    @Test("Transient restoration moves bypass the pending restoration guard")
    func transientRestorationBypassesAuthorityGuard() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let backend = FakeBackend(snapshots: [before, after])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let guardRecorder = RestorationGuardRecorder(rejects: true)
        await coordinator.setBeforeAuthoritativeLayoutMutation { try await guardRecorder.check() }
        let move = MenuBarMoveOperation(itemID: before.items[0].id, section: .visible, index: 0)

        let result = try await coordinator.perform(.transientMove(move))

        #expect(result == after)
        #expect(await backend.moveOperations == [move])
        #expect(await guardRecorder.calls == 0)
        #expect(await coordinator.mutationGeneration == 1)
        #expect(await coordinator.layoutAuthorityGeneration == 0)
        #expect(await coordinator.canUndo == false)
    }

    @Test("A successful restoration guard advances authoritative layout generation")
    func successfulRestorationGuardAdvancesAuthority() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let backend = FakeBackend(snapshots: [before, after])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let guardRecorder = RestorationGuardRecorder(rejects: false)
        await coordinator.setBeforeAuthoritativeLayoutMutation { try await guardRecorder.check() }
        let move = MenuBarMoveOperation(itemID: before.items[0].id, section: .visible, index: 0)

        let result = try await coordinator.perform(.move(move))

        #expect(result == after)
        #expect(await backend.moveOperations == [move])
        #expect(await guardRecorder.calls == 1)
        #expect(await coordinator.layoutAuthorityGeneration == 1)
        #expect(await coordinator.mutationGeneration == 1)
        #expect(await coordinator.canUndo)
    }

    @Test("Cancelled mutations compensate in a live task before a queued refresh can proceed")
    func cancelledMutationCompensationIsSerialized() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let backend = FakeBackend(
            snapshots: (1 ... 3).map { makeSnapshot(generation: UInt64($0), count: 2) },
            mutationDelay: .seconds(10),
            checksCancellationDuringCompensation: true
        )
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        let mutation = Task { try await coordinator.perform(.reveal(before.items[0].id)) }
        await backend.waitUntilMutationStarted()
        let refresh = Task { try await coordinator.refresh() }
        mutation.cancel()
        await #expect(throws: CancellationError.self) { try await mutation.value }
        #expect(try await refresh.value.generation == 3)
        #expect(await backend.restoredSnapshots.count == 1)
        #expect(await backend.restoreIsActive == false)
        #expect(await coordinator.currentSnapshot?.generation == 3)
    }

    @Test("Cancelled profile application restores both cancellation-sensitive workspace and layout")
    func cancelledProfileCompensatesWorkspaceAndLayout() async throws {
        let before = makeSnapshot(generation: 1, count: 1)
        let profile = BarlineProfile(name: "New layout", layout: ProfileLayout(hidden: before.items.map(\.id)))
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let workspace = WorkspaceRecorder(initial: original)
        let backend = FakeBackend(
            snapshots: [before, makeSnapshot(generation: 2, count: 1)],
            checksCancellationDuringCompensation: true,
            cancelOnMove: true
        )
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let activation = Task {
            try await coordinator.activate(
                profile: profile,
                workspaceTransaction: MenuBarWorkspaceTransaction(
                    capture: { await workspace.capture() },
                    apply: { value in
                        try Task.checkCancellation()
                        try await workspace.apply(value)
                    }
                )
            )
        }
        await #expect(throws: CancellationError.self) { try await activation.value }
        #expect(await workspace.capture() == original)
        #expect(await workspace.values.count == 2)
        #expect(await backend.restoredSnapshots == [before])
        #expect(await coordinator.currentSnapshot?.generation == 2)
    }

    @Test("Compensation deadlines cancel and drain work instead of orphaning a rollback")
    func compensationDeadlineDrainsBeforeRelease() async throws {
        let before = makeSnapshot(generation: 1, count: 1)
        let backend = FakeBackend(
            snapshots: [before, makeSnapshot(generation: 2, count: 1)],
            revealFailure: .interrupted,
            checksCancellationDuringCompensation: true,
            restoreDelay: .seconds(10)
        )
        let coordinator = MenuBarStateCoordinator(backend: backend, compensationTimeout: .milliseconds(20))
        _ = try await coordinator.refresh()
        await #expect(throws: (any Error).self) {
            try await coordinator.perform(.reveal(before.items[0].id))
        }
        #expect(await backend.restoreIsActive == false)
        #expect(await coordinator.currentSnapshot == nil)
        #expect(try await coordinator.refresh().generation == 2)
    }

    @Test("An interaction lease excludes profile, history and background refresh while allowing its own moves")
    func interactionLeaseProtectsWholeJourney() async throws {
        let before = makeSnapshot(generation: 1, count: 3)
        let backend = FakeBackend(snapshots: (1 ... 4).map { makeSnapshot(generation: UInt64($0), count: 3) })
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Concurrent Focus", layout: ProfileLayout(visible: before.items.map(\.id)))
        let expiredToken = try await coordinator.withItemInteraction { token in
            let blocked = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                group.addTask {
                    do {
                        _ = try await coordinator.activate(profile: profile)
                        return false
                    } catch MenuBarBackendError.unsafeMenuTracking {
                        return true
                    } catch {
                        return false
                    }
                }
                group.addTask {
                    do {
                        _ = try await coordinator.undo()
                        return false
                    } catch MenuBarBackendError.unsafeMenuTracking {
                        return true
                    } catch {
                        return false
                    }
                }
                group.addTask {
                    do {
                        _ = try await coordinator.refresh()
                        return false
                    } catch MenuBarBackendError.unsafeMenuTracking {
                        return true
                    } catch {
                        return false
                    }
                }
                var values = [Bool]()
                for await value in group {
                    values.append(value)
                }
                return values
            }
            #expect(blocked == [true, true, true])
            #expect(await backend.snapshotCallCount == 0)
            #expect(await backend.moveOperations.isEmpty)
            await #expect(throws: MenuBarBackendError.unsafeMenuTracking) {
                try await coordinator.withItemInteraction { _ in true }
            }
            await #expect(throws: MenuBarBackendError.unsafeMenuTracking) {
                try await coordinator.refresh(interactionID: UUID())
            }
            let refreshed = try await coordinator.refresh(interactionID: token)
            let authority = try await coordinator.refreshAuthority(
                expectedGeneration: refreshed.generation, interactionID: token
            )
            let moved = try await coordinator.perform(
                .transientMove(MenuBarMoveOperation(itemID: before.items[0].id, section: .visible, index: 0)),
                expectedGeneration: authority.generation,
                interactionID: token
            )
            #expect(moved.generation == 3)
            return token
        }
        await #expect(throws: MenuBarBackendError.unsafeMenuTracking) {
            try await coordinator.refresh(interactionID: expiredToken)
        }
        #expect(try await coordinator.refresh().generation == 4)
    }

    @Test("Throwing and cancelled interaction bodies always release their lease")
    func interactionLeaseReleasesOnFailureAndCancellation() async throws {
        let backend = FakeBackend(snapshots: [makeSnapshot(generation: 1, count: 2)])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        await #expect(throws: MenuBarBackendError.interrupted) {
            try await coordinator.withItemInteraction { _ -> Bool in
                throw MenuBarBackendError.interrupted
            }
        }
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await coordinator.withItemInteraction { _ in
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(10))
            }
        }
        for await _ in started.stream {
            break
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        started.continuation.finish()
        #expect(try await coordinator.refresh().generation == 1)
        #expect(try await coordinator.withItemInteraction { _ in 42 } == 42)
    }

    @Test("Refresh retries and keeps the first valid snapshot")
    func retryRefresh() async throws {
        let valid = makeSnapshot(generation: 1, count: 3)
        let backend = FakeBackend(snapshots: [
            makeSnapshot(generation: 1, count: 0),
            valid,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(
                maximumAttempts: 2,
                baseDelay: .zero,
                maximumDelay: .zero
            )
        )

        let result = try await coordinator.refresh(now: valid.capturedAt)

        #expect(result == valid)
        #expect(await coordinator.lastKnownGoodSnapshot == valid)
        #expect(await coordinator.lastRejection == nil)
    }

    @Test("Authority refresh binds the old generation and returns fresh state")
    func refreshesBoundAuthority() async throws {
        let original = makeSnapshot(generation: 1, count: 3)
        let refreshed = makeSnapshot(generation: 2, count: 3)
        let backend = FakeBackend(snapshots: [original, refreshed])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: original.capturedAt)

        await #expect(
            throws: MenuBarAuthorityRefreshError.staleGeneration(
                expected: 0,
                actual: original.generation
            )
        ) {
            try await coordinator.refreshAuthority(
                expectedGeneration: 0,
                now: refreshed.capturedAt
            )
        }
        #expect(await backend.snapshotCallCount == 1)

        let result = try await coordinator.refreshAuthority(
            expectedGeneration: original.generation,
            now: refreshed.capturedAt
        )

        #expect(result == refreshed)
        #expect(await coordinator.currentSnapshot == refreshed)
        #expect(await backend.snapshotCallCount == 2)
    }

    @Test("Stale authority cannot refresh or execute after state advances")
    func rejectsStaleExecutionAuthority() async throws {
        let original = makeSnapshot(generation: 1, count: 3)
        let refreshed = makeSnapshot(generation: 2, count: 3)
        let advanced = makeSnapshot(generation: 3, count: 3)
        let backend = FakeBackend(snapshots: [original, refreshed, advanced])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: original.capturedAt)
        _ = try await coordinator.refreshAuthority(
            expectedGeneration: original.generation,
            now: refreshed.capturedAt
        )
        _ = try await coordinator.refresh(now: advanced.capturedAt)

        await #expect(
            throws: MenuBarAuthorityRefreshError.staleGeneration(
                expected: refreshed.generation,
                actual: advanced.generation
            )
        ) {
            try await coordinator.perform(
                .reveal(original.items[0].id),
                expectedGeneration: refreshed.generation,
                now: advanced.capturedAt
            )
        }
        #expect(await backend.revealedItems.isEmpty)
    }

    @Test("Failed post-mutation validation restores the prior snapshot")
    func rollsBackInvalidMutation() async throws {
        let before = makeSnapshot(generation: 1, count: 4)
        let invalidAfter = makeSnapshot(generation: 2, count: 0)
        let verifiedRollback = makeSnapshot(generation: 3, count: 4)
        let backend = FakeBackend(snapshots: [before, invalidAfter, verifiedRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.perform(
                .reveal(before.items[0].id),
                now: invalidAfter.capturedAt
            )
        }

        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await backend.restoredSnapshots == [before])
    }

    @Test("Reveal rolls back when the target remains hidden")
    func rejectsRevealNoOp() async throws {
        let itemID = MenuBarItemID(
            bundleIdentifier: "com.example.hidden",
            accessibilityIdentifier: "hidden"
        )
        let layout = ProfileLayout(hidden: [itemID])
        let before = makeProfileSnapshot(generation: 1, layout: layout)
        let hiddenAfter = makeProfileSnapshot(generation: 2, layout: layout)
        let verifiedRollback = makeProfileSnapshot(generation: 3, layout: layout)
        let backend = FakeBackend(snapshots: [before, hiddenAfter, verifiedRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.perform(.reveal(itemID), now: hiddenAfter.capturedAt)
        }

        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await backend.restoredSnapshots == [before])
    }

    @Test("Menu tracking blocks mutation before backend side effects")
    func blocksMenuTrackingMutation() async throws {
        let tracking = makeSnapshot(generation: 1, count: 2, menuTracking: true)
        let backend = FakeBackend(snapshots: [tracking])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: tracking.capturedAt)

        await #expect(throws: MenuBarBackendError.unsafeMenuTracking) {
            try await coordinator.perform(.reveal(tracking.items[0].id), now: tracking.capturedAt)
        }

        #expect(await backend.revealedItems.isEmpty)
    }

    @Test("Rollback rejects a logically similar layout on the wrong display")
    func rejectsWrongDisplayRollback() async throws {
        let before = makeSnapshot(generation: 1, count: 3)
        let invalidAfter = makeSnapshot(generation: 2, count: 0)
        let wrongDisplayRollback = makeSnapshot(
            generation: 3,
            count: 3,
            display: MenuBarDisplayID("other-display")
        )
        let backend = FakeBackend(snapshots: [before, invalidAfter, wrongDisplayRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.perform(
                .reveal(before.items[0].id),
                now: invalidAfter.capturedAt
            )
        }

        #expect(await coordinator.currentSnapshot == nil)
        #expect(await coordinator.lastKnownGoodSnapshot == before)
    }

    @Test("Concurrent mutations are serialized across backend suspension")
    func serializesConcurrentMutations() async throws {
        let first = makeSnapshot(generation: 1, count: 2)
        let second = makeSnapshot(generation: 2, count: 2)
        let third = makeSnapshot(generation: 3, count: 2)
        let backend = FakeBackend(
            snapshots: [first, second, third],
            mutationDelay: .milliseconds(25)
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: first.capturedAt)

        async let firstMutation = coordinator.perform(.reveal(first.items[0].id), now: second.capturedAt)
        async let secondMutation = coordinator.perform(.reveal(first.items[1].id), now: third.capturedAt)
        _ = try await (firstMutation, secondMutation)

        #expect(await backend.maximumConcurrentMutations == 1)
    }

    @Test("Public refresh waits for an active mutation before publishing")
    func serializesRefreshWithMutation() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let afterMutation = makeSnapshot(generation: 2, count: 2)
        let afterRefresh = makeSnapshot(generation: 3, count: 2)
        let backend = FakeBackend(
            snapshots: [before, afterMutation, afterRefresh],
            mutationDelay: .milliseconds(25)
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        let mutation = Task {
            try await coordinator.perform(.reveal(before.items[0].id), now: afterMutation.capturedAt)
        }
        await backend.waitUntilMutationStarted()
        let refresh = Task {
            try await coordinator.refresh(now: afterRefresh.capturedAt)
        }

        #expect(try await mutation.value == afterMutation)
        #expect(try await refresh.value == afterRefresh)
        #expect(await coordinator.currentSnapshot == afterRefresh)
        #expect(await coordinator.lastKnownGoodSnapshot == afterRefresh)
    }

    @Test("Stale item references are rejected before backend side effects")
    func rejectsStaleReference() async throws {
        let snapshot = makeSnapshot(generation: 1, count: 2)
        let stale = MenuBarItemID(
            bundleIdentifier: "com.example.missing",
            accessibilityIdentifier: "missing"
        )
        let backend = FakeBackend(snapshots: [snapshot])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: snapshot.capturedAt)

        await #expect(throws: MenuBarBackendError.staleItem(stale)) {
            try await coordinator.perform(.reveal(stale), now: snapshot.capturedAt)
        }
        #expect(await backend.revealedItems.isEmpty)
    }

    @Test("Non-hideable items are rejected before a hidden-section move")
    func rejectsHidingNonHideableItem() async throws {
        let display = MenuBarDisplayID("test-display")
        let itemID = MenuBarItemID(
            bundleIdentifier: "com.apple.screencaptureui",
            accessibilityIdentifier: "Item-0"
        )
        let snapshot = MenuBarSnapshot(
            generation: 1,
            capturedAt: Date(),
            items: [
                MenuBarItemDescriptor(
                    id: itemID,
                    section: .visible,
                    order: 0,
                    displayID: display,
                    isSystemItem: true,
                    title: "Item-0",
                    isOnScreen: true,
                    isMovable: true,
                    canBeHidden: false
                ),
            ],
            displayIDs: [display],
            activeSpaceIsValid: true
        )
        let backend = FakeBackend(snapshots: [snapshot])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: snapshot.capturedAt)

        await #expect(throws: MenuBarBackendError.operationFailed("menu bar item cannot be hidden")) {
            try await coordinator.perform(.move(MenuBarMoveOperation(
                itemID: itemID,
                section: .hidden,
                index: 0,
                destinationDisplayID: display
            )), now: snapshot.capturedAt)
        }
        #expect(await backend.moveOperations.isEmpty)
    }

    @Test("Exhausted invalid refreshes preserve the last-known-good snapshot")
    func preservesLastKnownGoodAfterRetryExhaustion() async throws {
        let good = makeSnapshot(generation: 1, count: 3)
        let invalid = makeSnapshot(generation: 2, count: 0)
        let backend = FakeBackend(snapshots: [good, invalid, invalid])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(
                maximumAttempts: 2,
                baseDelay: .zero,
                maximumDelay: .zero,
                maximumJitterPermille: 0
            )
        )
        _ = try await coordinator.refresh(now: good.capturedAt)

        await #expect(throws: MenuBarBackendError.invalidSnapshot(.emptySnapshot)) {
            try await coordinator.refresh(now: invalid.capturedAt)
        }

        #expect(await coordinator.currentSnapshot == good)
        #expect(await coordinator.lastKnownGoodSnapshot == good)
        #expect(await coordinator.lastRejection == .emptySnapshot)
        #expect(await coordinator.backendHealth.state == .degraded)
        #expect(await backend.snapshotCallCount == 3)
    }

    @Test("Backend mutation errors roll back without replacing the original error")
    func rollsBackBackendMutationError() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let verifiedRollback = makeSnapshot(generation: 2, count: 2)
        let backend = FakeBackend(
            snapshots: [before, verifiedRollback],
            revealFailure: .operationFailed("injected reveal failure")
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.operationFailed("injected reveal failure")) {
            try await coordinator.perform(.reveal(before.items[0].id), now: before.capturedAt)
        }

        #expect(await backend.restoredSnapshots == [before])
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await coordinator.lastKnownGoodSnapshot == verifiedRollback)
    }

    @Test("Recovery restarts, restores last-known-good, and commits a fresh snapshot")
    func recoveryRestoresAndRefreshes() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let recovered = makeSnapshot(generation: 2, count: 2)
        let backend = FakeBackend(snapshots: [before, recovered])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        let result = try await coordinator.recover(now: recovered.capturedAt)

        #expect(result == recovered)
        #expect(await backend.restartCount == 1)
        #expect(await backend.restoredSnapshots == [before])
        #expect(await coordinator.currentSnapshot == recovered)
        #expect(await coordinator.lastKnownGoodSnapshot == recovered)
        #expect(await coordinator.mutationGeneration == 1)
    }

    @Test("Recovery validates against time after a delayed helper restart")
    func recoveryUsesPostRestartValidationTime() async throws {
        let capturedAt = Date().addingTimeInterval(0.05)
        let recovered = makeSnapshot(generation: 1, count: 2, capturedAt: capturedAt)
        let backend = FakeBackend(
            snapshots: [recovered],
            restartDelay: .milliseconds(100)
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            validator: SnapshotValidator(
                policy: SnapshotValidationPolicy(maximumFutureClockSkew: 0)
            ),
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let result = try await coordinator.recover()

        #expect(result == recovered)
        #expect(await backend.restartCount == 1)
    }

    @Test("Queued refresh validates against time after acquiring its turn")
    func queuedRefreshUsesPostWaitValidationTime() async throws {
        let startedAt = Date()
        let before = makeSnapshot(generation: 1, count: 2, capturedAt: startedAt)
        let afterMutation = makeSnapshot(
            generation: 2,
            count: 2,
            capturedAt: startedAt.addingTimeInterval(0.01)
        )
        let queuedRefresh = makeSnapshot(
            generation: 3,
            count: 2,
            capturedAt: startedAt.addingTimeInterval(0.05)
        )
        let backend = FakeBackend(
            snapshots: [before, afterMutation, queuedRefresh],
            mutationDelay: .milliseconds(100)
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            validator: SnapshotValidator(
                policy: SnapshotValidationPolicy(maximumFutureClockSkew: 0)
            ),
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        async let mutation = coordinator.perform(
            .reveal(before.items[0].id),
            now: afterMutation.capturedAt
        )
        await backend.waitUntilMutationStarted()
        async let refresh = coordinator.refresh()

        _ = try await mutation
        let result = try await refresh
        #expect(result == queuedRefresh)
    }

    @Test("Refresh retries preserve replacement-generation recovery signal")
    func refreshRetriesPreserveReplacementGenerationError() async throws {
        let startedAt = Date()
        let before = makeSnapshot(generation: 50, count: 2, capturedAt: startedAt)
        let replacementCapturedAt = startedAt.addingTimeInterval(0.05)
        let backend = FakeBackend(
            snapshots: [
                before,
                makeSnapshot(generation: 1, count: 2, capturedAt: replacementCapturedAt),
                makeSnapshot(generation: 2, count: 2, capturedAt: replacementCapturedAt),
                makeSnapshot(generation: 3, count: 2, capturedAt: replacementCapturedAt),
                makeSnapshot(generation: 4, count: 2, capturedAt: replacementCapturedAt),
            ]
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            validator: SnapshotValidator(
                policy: SnapshotValidationPolicy(maximumFutureClockSkew: 0)
            ),
            retryPolicy: RetryPolicy(
                maximumAttempts: 4,
                baseDelay: .milliseconds(100),
                maximumDelay: .milliseconds(100),
                maximumJitterPermille: 0
            )
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(
            throws: MenuBarBackendError.invalidSnapshot(
                .nonMonotonicGeneration(previous: 50, candidate: 4)
            )
        ) {
            try await coordinator.refresh()
        }
    }

    @Test("Replacement helper generations are rebased monotonically")
    func rebasesReplacementHelperGeneration() async throws {
        let before = makeSnapshot(generation: 50, count: 2)
        let replacementFirst = makeSnapshot(generation: 1, count: 2)
        let replacementSecond = makeSnapshot(generation: 2, count: 2)
        let backend = FakeBackend(snapshots: [before, replacementFirst, replacementSecond])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        let recovered = try await coordinator.recover(now: replacementFirst.capturedAt)
        let refreshed = try await coordinator.refresh(now: replacementSecond.capturedAt)

        #expect(recovered.generation == 51)
        #expect(refreshed.generation == 52)
    }

    @Test("Invalid replacement helper keeps prior authority")
    func invalidReplacementKeepsPriorAuthority() async throws {
        let before = makeSnapshot(generation: 50, count: 2)
        let wrong = makeProfileSnapshot(
            generation: 1,
            layout: ProfileLayout(hidden: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, wrong])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.recover(now: wrong.capturedAt)
        }

        #expect(await coordinator.currentSnapshot == nil)
        #expect(await coordinator.lastKnownGoodSnapshot == before)
    }

    @Test("Profile activation applies ordered moves and commits only after validation")
    func activatesProfileTransactionally() async throws {
        let before = makeSnapshot(generation: 1, count: 3)
        let profile = BarlineProfile(
            id: UUID(100),
            name: "Work",
            layout: ProfileLayout(
                visible: [before.items[2].id],
                hidden: [before.items[0].id],
                alwaysHidden: [before.items[1].id]
            )
        )
        let after = makeProfileSnapshot(generation: 2, layout: profile.layout)
        let backend = FakeBackend(snapshots: [before, after])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        let result = try await coordinator.activate(profile: profile, now: after.capturedAt)

        #expect(result == after)
        #expect(await coordinator.activeProfileID == profile.id)
        #expect(await backend.moveOperations == [
            MenuBarMoveOperation(
                itemID: before.items[0].id, section: .hidden, index: 0,
                destinationDisplayID: before.items[0].displayID
            ),
            MenuBarMoveOperation(
                itemID: before.items[1].id, section: .alwaysHidden, index: 0,
                destinationDisplayID: before.items[1].displayID
            ),
        ])
        #expect(await backend.restoredSnapshots.isEmpty)
    }

    @Test("Activation checkpoint receives the resolved target before side effects")
    func preparesResolvedActivationCheckpointBeforeMutation() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let freshBefore = makeSnapshot(generation: 2, count: 2)
        let profile = BarlineProfile(
            id: UUID(119),
            name: "Prepared",
            layout: ProfileLayout(hidden: before.items.map(\.id))
        )
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let recorder = WorkspaceRecorder(initial: original)
        let backend = FakeBackend(snapshots: [before, freshBefore])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.activate(
                profile: profile,
                now: freshBefore.capturedAt,
                workspaceTransaction: MenuBarWorkspaceTransaction(
                    capture: { await recorder.capture() },
                    apply: { try await recorder.apply($0) }
                ),
                prepareCheckpoint: { checkpoint, presentation in
                    #expect(checkpoint.snapshot == freshBefore)
                    #expect(checkpoint.workspace == original)
                    #expect(presentation == profile.resolvedPresentation(using: nil))
                    #expect(await recorder.values.isEmpty)
                    #expect(await backend.moveOperations.isEmpty)
                    throw MenuBarBackendError.operationFailed("simulated persistence failure")
                }
            )
        }

        #expect(await recorder.values.isEmpty)
        #expect(await backend.moveOperations.isEmpty)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Pending activation promotes an exactly applied target without mutation")
    func promotesCompletedPendingActivation() async throws {
        let originalSnapshot = makeSnapshot(generation: 1, count: 2)
        let layout = ProfileLayout(hidden: originalSnapshot.items.map(\.id))
        let liveTarget = makeProfileSnapshot(generation: 2, layout: layout)
        let profile = BarlineProfile(id: UUID(118), name: "Pending", layout: layout)
        let presentation = profile.resolvedPresentation(using: nil)
        var targetWorkspace = ProfileWorkspaceState(profile: profile)
        targetWorkspace.presentation = presentation
        let originalWorkspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: originalSnapshot,
            activeProfileID: nil,
            workspace: originalWorkspace
        )
        let recorder = WorkspaceRecorder(initial: targetWorkspace)
        let backend = FakeBackend(snapshots: [liveTarget])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let result = try await coordinator.recoverPendingProfileActivation(
            profile: profile,
            persistedPresentation: presentation,
            checkpoint: checkpoint,
            workspaceTransaction: MenuBarWorkspaceTransaction(
                capture: { await recorder.capture() },
                apply: { try await recorder.apply($0) }
            ),
            now: liveTarget.capturedAt
        )

        #expect(result == .promoted(presentation))
        #expect(await coordinator.activeProfileID == profile.id)
        #expect(await recorder.values.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
    }

    @Test("Pending partial activation restores the durable checkpoint")
    func restoresPartialPendingActivation() async throws {
        let originalSnapshot = makeSnapshot(generation: 1, count: 2)
        let targetLayout = ProfileLayout(hidden: originalSnapshot.items.map(\.id))
        let partialLayout = ProfileLayout(
            visible: [originalSnapshot.items[1].id],
            hidden: [originalSnapshot.items[0].id]
        )
        let partialSnapshot = makeProfileSnapshot(generation: 2, layout: partialLayout)
        let restoredSnapshot = makeSnapshot(generation: 3, count: 2)
        let profile = BarlineProfile(id: UUID(117), name: "Pending", layout: targetLayout)
        let presentation = profile.resolvedPresentation(using: nil)
        var partialWorkspace = ProfileWorkspaceState(profile: profile)
        partialWorkspace.presentation = presentation
        let originalWorkspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: originalSnapshot,
            activeProfileID: nil,
            workspace: originalWorkspace
        )
        let recorder = WorkspaceRecorder(initial: partialWorkspace)
        let backend = FakeBackend(snapshots: [partialSnapshot, restoredSnapshot])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let result = try await coordinator.recoverPendingProfileActivation(
            profile: profile,
            persistedPresentation: presentation,
            checkpoint: checkpoint,
            workspaceTransaction: MenuBarWorkspaceTransaction(
                capture: { await recorder.capture() },
                apply: { try await recorder.apply($0) }
            ),
            now: partialSnapshot.capturedAt
        )

        #expect(result == .restored(restoredSnapshot))
        #expect(await coordinator.activeProfileID == nil)
        #expect(await recorder.values == [originalWorkspace])
        #expect(await backend.restoredSnapshots == [originalSnapshot])
    }

    @Test("Partial Focus recovery needs retained presentation evidence", arguments: [false, true])
    func partialFocusRecoveryRequiresPresentationEvidence(retainsPresentation: Bool) async throws {
        let originalSnapshot = makeSnapshot(generation: 1, count: 2)
        let targetLayout = ProfileLayout(hidden: originalSnapshot.items.map(\.id))
        let partialSnapshot = makeProfileSnapshot(
            generation: 2,
            layout: ProfileLayout(
                visible: [originalSnapshot.items[1].id],
                hidden: [originalSnapshot.items[0].id]
            )
        )
        let restoredSnapshot = makeSnapshot(generation: 3, count: 2)
        let profile = BarlineProfile(id: UUID(119), name: "Pending", layout: targetLayout)
        let presentation = profile.resolvedPresentation(using: nil)
        var liveWorkspace = ProfileWorkspaceState(profile: profile)
        // ProfileManager currently clears this on its activation-error path.
        // Do not substitute the journal's desired presentation for live evidence.
        liveWorkspace.presentation = retainsPresentation ? presentation : nil
        let originalWorkspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let recorder = WorkspaceRecorder(initial: liveWorkspace)
        let backend = FakeBackend(snapshots: [partialSnapshot, restoredSnapshot])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let result = try await coordinator.recoverPendingProfileActivation(
            profile: profile,
            persistedPresentation: presentation,
            checkpoint: MenuBarWorkspaceCheckpoint(
                snapshot: originalSnapshot,
                activeProfileID: nil,
                workspace: originalWorkspace
            ),
            workspaceTransaction: MenuBarWorkspaceTransaction(
                capture: { await recorder.capture() },
                apply: { try await recorder.apply($0) }
            ),
            now: partialSnapshot.capturedAt
        )

        if retainsPresentation {
            #expect(result == .restored(restoredSnapshot))
            #expect(await recorder.values == [originalWorkspace])
            #expect(await backend.restoredSnapshots == [originalSnapshot])
        } else {
            #expect(result == .inconclusive)
            #expect(await recorder.values.isEmpty)
            #expect(await backend.restoredSnapshots.isEmpty)
        }
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Explicit recovery after restart restores or compensates failure", arguments: [false, true])
    func explicitCheckpointRecoveryAfterRestart(restoreFails: Bool) async throws {
        let original = makeSnapshot(generation: 1, count: 2)
        let partial = makeProfileSnapshot(
            generation: 2,
            layout: ProfileLayout(
                visible: [original.items[1].id],
                hidden: [original.items[0].id]
            )
        )
        let restored = makeSnapshot(generation: 3, count: 2)
        let workspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        var liveWorkspace = workspace
        liveWorkspace.shelfBehavior.isEnabled.toggle()
        liveWorkspace.presentation = nil
        let recorder = WorkspaceRecorder(initial: liveWorkspace)
        let backend = FakeBackend(
            snapshots: [partial, restoreFails ? partial : restored],
            restoreFailures: restoreFails ? 1 : 0
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: original,
            activeProfileID: nil,
            workspace: workspace
        )
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )

        if restoreFails {
            await #expect(throws: MenuBarBackendError.interrupted) {
                try await coordinator.restoreWorkspaceCheckpoint(
                    checkpoint, workspaceTransaction: transaction, now: partial.capturedAt
                )
            }
            #expect(await recorder.values == [workspace, liveWorkspace])
            #expect(await backend.restoredSnapshots == [original, partial])
            #expect(await coordinator.currentSnapshot == partial)
        } else {
            let result = try await coordinator.restoreWorkspaceCheckpoint(
                checkpoint, workspaceTransaction: transaction, now: partial.capturedAt
            )
            #expect(result == restored)
            #expect(await recorder.values == [workspace])
            #expect(await backend.restoredSnapshots == [original])
        }

        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Explicit stale-checkpoint recovery fails before workspace or layout side effects")
    func staleCheckpointPreflightHasNoSideEffects() async throws {
        let original = makeSnapshot(generation: 1, count: 3)
        let live = makeSnapshot(generation: 2, count: 2)
        let workspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let recorder = WorkspaceRecorder(initial: workspace)
        let backend = FakeBackend(snapshots: [live])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: original, activeProfileID: nil, workspace: workspace
        )
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() }, apply: { try await recorder.apply($0) }
        )
        await #expect(throws: WorkspaceRecoveryPlanner.Failure.incompleteInventory) {
            try await coordinator.restoreWorkspaceCheckpoint(
                checkpoint, workspaceTransaction: transaction, now: live.capturedAt
            )
        }
        #expect(await recorder.values.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
    }

    @Test("Confirmed available-item recovery retains original checkpoint and claims no profile")
    func availableCheckpointRecovery() async throws {
        let original = makeSnapshot(generation: 1, count: 3)
        let live = makeSnapshot(generation: 2, count: 2)
        let fresh = makeSnapshot(generation: 3, count: 2)
        let after = makeSnapshot(generation: 4, count: 2)
        let workspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let recorder = WorkspaceRecorder(initial: workspace)
        let backend = FakeBackend(
            snapshots: [live, fresh, after],
            environment: MenuBarEnvironmentSnapshot(
                activeDisplayID: 1, activeStableDisplayID: MenuBarDisplayID("test-display"),
                activeSpaceToken: 1, activeSpaceIsFullscreen: false
            )
        )
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: original, activeProfileID: UUID(), workspace: workspace
        )
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() }, apply: { try await recorder.apply($0) }
        )
        let prepared = try await coordinator.prepareAvailableWorkspaceRecovery(
            checkpoint, workspaceTransaction: transaction, now: live.capturedAt
        )
        #expect(prepared.preview.missingItemIDs.count == 1)
        #expect(await recorder.values.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
        let result = try await coordinator.restoreAvailableWorkspaceRecovery(
            prepared, workspaceTransaction: transaction, now: after.capturedAt
        )
        #expect(result.snapshot == after)
        #expect(result.activeDisplayID == MenuBarDisplayID("test-display"))
        #expect(result.activeProfileID == nil)
        #expect(await coordinator.activeProfileID == nil)
        #expect(prepared.checkpoint == checkpoint)
        #expect(await recorder.values == [workspace])
        #expect(await backend.restoredSnapshots.count == 1)
    }

    @Test("A changed inventory invalidates partial-recovery confirmation without side effects")
    func availableRecoveryRejectsChangedPreview() async throws {
        let original = makeSnapshot(generation: 1, count: 4)
        let live = makeSnapshot(generation: 2, count: 2)
        let changed = makeSnapshot(generation: 3, count: 3)
        let workspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let recorder = WorkspaceRecorder(initial: workspace)
        let backend = FakeBackend(snapshots: [live, changed])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() }, apply: { try await recorder.apply($0) }
        )
        let prepared = try await coordinator.prepareAvailableWorkspaceRecovery(
            MenuBarWorkspaceCheckpoint(snapshot: original, activeProfileID: nil, workspace: workspace),
            workspaceTransaction: transaction, now: live.capturedAt
        )
        await #expect(throws: (any Error).self) {
            try await coordinator.restoreAvailableWorkspaceRecovery(
                prepared, workspaceTransaction: transaction, now: changed.capturedAt
            )
        }
        #expect(await recorder.values.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
    }

    @Test("Failed available-item verification compensates workspace and layout")
    func availableRecoveryCompensatesFailedTarget() async throws {
        let original = makeSnapshot(generation: 1, count: 3)
        let layout = ProfileLayout(visible: [original.items[0].id], hidden: [original.items[1].id])
        let live = makeProfileSnapshot(generation: 2, layout: layout)
        let fresh = makeProfileSnapshot(generation: 3, layout: layout)
        let wrong = makeProfileSnapshot(generation: 4, layout: layout)
        let rollback = makeProfileSnapshot(generation: 5, layout: layout)
        let workspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        var liveWorkspace = workspace
        liveWorkspace.shelfBehavior.isEnabled.toggle()
        let recorder = WorkspaceRecorder(initial: liveWorkspace)
        let backend = FakeBackend(snapshots: [live, fresh, wrong, rollback])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let checkpoint = MenuBarWorkspaceCheckpoint(snapshot: original, activeProfileID: nil, workspace: workspace)
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() }, apply: { try await recorder.apply($0) }
        )
        let prepared = try await coordinator.prepareAvailableWorkspaceRecovery(
            checkpoint, workspaceTransaction: transaction, now: live.capturedAt
        )
        await #expect(throws: WorkspaceRecoveryPlanner.Failure.exactTargetUnavailable) {
            try await coordinator.restoreAvailableWorkspaceRecovery(
                prepared, workspaceTransaction: transaction, now: rollback.capturedAt
            )
        }
        #expect(await recorder.values == [workspace, liveWorkspace])
        #expect(await backend.restoredSnapshots.count == 2)
        #expect(await coordinator.currentSnapshot == rollback)
        #expect(prepared.checkpoint == checkpoint)
    }

    @Test("Settings change-and-revert invalidates partial recovery confirmation")
    func availableRecoveryRejectsNewWorkspaceRevision() async throws {
        let original = makeSnapshot(generation: 1, count: 3)
        let live = makeSnapshot(generation: 2, count: 2)
        let fresh = makeSnapshot(generation: 3, count: 2)
        let workspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let recorder = RevisionedWorkspaceRecorder(initial: workspace)
        let backend = FakeBackend(snapshots: [live, fresh])
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() }, apply: { await recorder.apply($0) },
            currentRevision: { await recorder.currentRevision() },
            applyIfCurrent: { await recorder.apply($0, ifCurrentRevision: $1) },
            rollbackSuperseded: { await recorder.rollbackSuperseded(from: $0, to: $1) }
        )
        let prepared = try await coordinator.prepareAvailableWorkspaceRecovery(
            MenuBarWorkspaceCheckpoint(snapshot: original, activeProfileID: nil, workspace: workspace),
            workspaceTransaction: transaction, now: live.capturedAt
        )
        var changed = workspace
        changed.shelfBehavior.isEnabled.toggle()
        await recorder.apply(changed)
        await recorder.apply(workspace)
        await #expect(throws: MenuBarWorkspaceTransactionError.superseded) {
            try await coordinator.restoreAvailableWorkspaceRecovery(
                prepared, workspaceTransaction: transaction, now: fresh.capturedAt
            )
        }
        #expect(await recorder.currentRevision() == 2)
        #expect(await backend.restoredSnapshots.isEmpty)
    }

    @Test("Pending no-op activation accepts the original state without mutation")
    func acceptsUnchangedPendingActivation() async throws {
        let originalSnapshot = makeSnapshot(generation: 1, count: 2)
        let liveOriginal = makeSnapshot(generation: 2, count: 2)
        let profile = BarlineProfile(
            id: UUID(116),
            name: "Pending",
            layout: ProfileLayout(hidden: originalSnapshot.items.map(\.id))
        )
        let originalWorkspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: originalSnapshot,
            activeProfileID: nil,
            workspace: originalWorkspace
        )
        let recorder = WorkspaceRecorder(initial: originalWorkspace)
        let backend = FakeBackend(snapshots: [liveOriginal])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let result = try await coordinator.recoverPendingProfileActivation(
            profile: profile,
            persistedPresentation: profile.resolvedPresentation(using: nil),
            checkpoint: checkpoint,
            workspaceTransaction: MenuBarWorkspaceTransaction(
                capture: { await recorder.capture() },
                apply: { try await recorder.apply($0) }
            ),
            now: liveOriginal.capturedAt
        )

        #expect(result == .unchanged(liveOriginal))
        #expect(await recorder.values.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
    }

    @Test("Pending activation preserves unrelated live state")
    func preservesUnrelatedPendingActivationState() async throws {
        let originalSnapshot = makeSnapshot(generation: 1, count: 2)
        let unrelatedLayout = ProfileLayout(alwaysHidden: originalSnapshot.items.map(\.id))
        let unrelatedSnapshot = makeProfileSnapshot(generation: 2, layout: unrelatedLayout)
        let profile = BarlineProfile(
            id: UUID(115),
            name: "Pending",
            layout: ProfileLayout(hidden: originalSnapshot.items.map(\.id))
        )
        let originalWorkspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let unrelatedWorkspace = ProfileWorkspaceState(
            profile: BarlineProfile(name: "Unrelated", layout: unrelatedLayout)
        )
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: originalSnapshot,
            activeProfileID: nil,
            workspace: originalWorkspace
        )
        let recorder = WorkspaceRecorder(initial: unrelatedWorkspace)
        let backend = FakeBackend(snapshots: [unrelatedSnapshot])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let result = try await coordinator.recoverPendingProfileActivation(
            profile: profile,
            persistedPresentation: profile.resolvedPresentation(using: nil),
            checkpoint: checkpoint,
            workspaceTransaction: MenuBarWorkspaceTransaction(
                capture: { await recorder.capture() },
                apply: { try await recorder.apply($0) }
            ),
            now: unrelatedSnapshot.capturedAt
        )

        #expect(result == .inconclusive)
        #expect(await recorder.values.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
    }

    @Test("Authority envelope survives every relaunch persistence boundary")
    func persistsAuthorityEnvelopeAcrossRelaunchBoundaries() throws {
        let suiteName = "com.mabryventures.Barline.tests.authority.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "profileAuthority"
        let snapshot = makeSnapshot(generation: 1, count: 2)
        let profile = BarlineProfile(
            id: UUID(114),
            name: "Pending",
            layout: ProfileLayout(hidden: snapshot.items.map(\.id))
        )
        let presentation = profile.resolvedPresentation(using: nil)
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: snapshot,
            activeProfileID: nil,
            workspace: ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        )
        let token = UUID(113)
        let pending = ProfileAuthorityEnvelope(
            pendingFocusProfile: profile,
            token: token,
            presentation: presentation,
            checkpoint: checkpoint,
            priorAuthority: nil
        )

        try ProfileAuthorityEnvelopeStore(defaults: defaults, key: key).save(pending)
        #expect(defaults.object(forKey: "focus.workspaceBeforeFocus") == nil)
        #expect(ProfileAuthorityEnvelopeStore(defaults: defaults, key: key).load() == pending)
        #expect(ProfileAuthorityEnvelopeStore(defaults: defaults, key: key).load() == pending)

        let active = ProfileAuthorityEnvelope(active: ProfileActiveAuthority(
            profileID: profile.id,
            token: token,
            presentation: presentation
        ))
        try ProfileAuthorityEnvelopeStore(defaults: defaults, key: key).save(active)
        let relaunched = ProfileAuthorityEnvelopeStore(defaults: defaults, key: key)
        #expect(relaunched.load() == active)
        #expect(relaunched.load()?.activeAuthority?.token == token)
    }

    @Test("Workspace settings commit and restore inside layout history")
    func restoresWorkspaceWithHistory() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let freshBefore = makeSnapshot(generation: 2, count: 2)
        let after = makeSnapshot(generation: 3, count: 2)
        let liveAfter = makeSnapshot(generation: 4, count: 2)
        let restoredBefore = makeSnapshot(generation: 5, count: 2)
        let profile = BarlineProfile(
            id: UUID(120),
            name: "Workspace",
            layout: ProfileLayout(visible: before.items.map(\.id)),
            appearance: ProfileAppearance(itemSpacing: 6),
            shelfBehavior: ProfileShelfBehavior(isEnabled: true)
        )
        let original = ProfileWorkspaceState(
            appearance: ProfileAppearance(itemSpacing: -3),
            shelfBehavior: ProfileShelfBehavior(isEnabled: false),
            revealTriggers: ProfileRevealTriggers(),
            autoRehide: ProfileAutoRehide(),
            applicationMenuOverlapBehavior: .leaveVisible
        )
        let recorder = WorkspaceRecorder(initial: original)
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )
        let backend = FakeBackend(snapshots: [before, freshBefore, after, liveAfter, restoredBefore])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        _ = try await coordinator.activate(
            profile: profile,
            now: after.capturedAt,
            workspaceTransaction: transaction
        )
        _ = try await coordinator.undo(
            now: restoredBefore.capturedAt,
            workspaceTransaction: transaction
        )

        #expect(await recorder.values == [ProfileWorkspaceState(profile: profile), original])
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("History restore preserves concurrent workspace edits and rolls back layout")
    func historyRestorePreservesConcurrentWorkspaceEdit() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let activationStart = makeSnapshot(generation: 2, count: 2)
        let activated = makeSnapshot(generation: 3, count: 2)
        let liveActivated = makeSnapshot(generation: 4, count: 2)
        let restoredTarget = makeSnapshot(generation: 5, count: 2)
        let verifiedRollback = makeSnapshot(generation: 6, count: 2)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let profile = BarlineProfile(
            id: UUID(122),
            name: "History target",
            layout: ProfileLayout(visible: before.items.map(\.id)),
            appearance: ProfileAppearance(itemSpacing: 4),
            shelfBehavior: ProfileShelfBehavior(isEnabled: false)
        )
        let activationRecorder = WorkspaceRecorder(initial: original)
        let activationTransaction = MenuBarWorkspaceTransaction(
            capture: { await activationRecorder.capture() },
            apply: { try await activationRecorder.apply($0) }
        )
        let backend = FakeBackend(snapshots: [
            before, activationStart, activated, liveActivated, restoredTarget, verifiedRollback,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(
            profile: profile,
            now: activated.capturedAt,
            workspaceTransaction: activationTransaction
        )

        let revisionedRecorder = RevisionedWorkspaceRecorder(
            initial: ProfileWorkspaceState(profile: profile)
        )
        let historyTransaction = MenuBarWorkspaceTransaction(
            capture: { await revisionedRecorder.capture() },
            apply: { await revisionedRecorder.apply($0) },
            currentRevision: { await revisionedRecorder.currentRevision() },
            applyIfCurrent: { workspace, revision in
                await revisionedRecorder.apply(workspace, ifCurrentRevision: revision)
            },
            rollbackSuperseded: { target, previous in
                await revisionedRecorder.rollbackSuperseded(from: target, to: previous)
            }
        )

        await #expect(throws: MenuBarWorkspaceTransactionError.superseded) {
            try await coordinator.undo(
                now: restoredTarget.capturedAt,
                workspaceTransaction: historyTransaction
            )
        }

        var expected = ProfileWorkspaceState(profile: profile)
        expected.shelfBehavior.isEnabled = true
        #expect(await revisionedRecorder.capture() == expected)
        #expect(await backend.restoredSnapshots == [activationStart, liveActivated])
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("History restore aborts before side effects when workspace capture drifts")
    func historyRestoreRejectsWorkspaceDriftBeforeApply() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let profile = BarlineProfile(
            id: UUID(123),
            name: "Active",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, after])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: after.capturedAt)
        let recorder = EarlyRevisionWorkspaceRecorder(
            initial: ProfileWorkspaceState(profile: profile)
        )
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { await recorder.apply($0) },
            currentRevision: { await recorder.currentRevision() },
            applyIfCurrent: { workspace, revision in
                await recorder.apply(workspace, ifCurrentRevision: revision)
            },
            rollbackSuperseded: { _, _ in nil }
        )

        await #expect(throws: MenuBarWorkspaceTransactionError.superseded) {
            try await coordinator.undo(
                now: after.capturedAt,
                workspaceTransaction: transaction
            )
        }

        #expect(await recorder.applyCount == 0)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await coordinator.currentSnapshot == after)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("History rollback clears authority when workspace changes during layout rollback")
    func historyRollbackRejectsWorkspaceDriftAfterWorkspaceRollback() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let activationStart = makeSnapshot(generation: 2, count: 2)
        let activated = makeSnapshot(generation: 3, count: 2)
        let liveActivated = makeSnapshot(generation: 4, count: 2)
        let wrongRestoredTarget = makeProfileSnapshot(
            generation: 5,
            layout: ProfileLayout(hidden: before.items.map(\.id))
        )
        let verifiedRollback = makeSnapshot(generation: 6, count: 2)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let profile = BarlineProfile(
            id: UUID(129),
            name: "Rollback authority",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let activationRecorder = WorkspaceRecorder(initial: original)
        let activationTransaction = MenuBarWorkspaceTransaction(
            capture: { await activationRecorder.capture() },
            apply: { try await activationRecorder.apply($0) }
        )
        let backend = FakeBackend(snapshots: [
            before,
            activationStart,
            activated,
            liveActivated,
            wrongRestoredTarget,
            verifiedRollback,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(
            profile: profile,
            now: activated.capturedAt,
            workspaceTransaction: activationTransaction
        )

        let recorder = CountingRevisionWorkspaceRecorder(
            initial: ProfileWorkspaceState(profile: profile),
            injectEditAtRevisionRead: 4
        )
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { await recorder.apply($0) },
            currentRevision: { await recorder.currentRevision() },
            applyIfCurrent: { workspace, revision in
                await recorder.apply(workspace, ifCurrentRevision: revision)
            },
            rollbackSuperseded: { _, _ in nil }
        )

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.undo(
                now: wrongRestoredTarget.capturedAt,
                workspaceTransaction: transaction
            )
        }

        var expected = ProfileWorkspaceState(profile: profile)
        expected.shelfBehavior.isEnabled = true
        #expect(await recorder.capture() == expected)
        #expect(await recorder.applyCount == 2)
        #expect(await backend.restoredSnapshots == [activationStart, liveActivated])
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Layout-only history clears profile authority when workspace changes during restore")
    func layoutOnlyHistoryRejectsWorkspaceDriftDuringRestore() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let activated = makeSnapshot(generation: 2, count: 2)
        let movedLayout = ProfileLayout(
            visible: [before.items[1].id],
            hidden: [before.items[0].id]
        )
        let moved = makeProfileSnapshot(generation: 3, layout: movedLayout)
        let liveMoved = makeProfileSnapshot(generation: 4, layout: movedLayout)
        let restoredTarget = makeSnapshot(generation: 5, count: 2)
        let verifiedRollback = makeProfileSnapshot(generation: 6, layout: movedLayout)
        let profile = BarlineProfile(
            id: UUID(130),
            name: "Layout authority",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [
            before, activated, moved, liveMoved, restoredTarget, verifiedRollback,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: activated.capturedAt)
        _ = try await coordinator.perform(
            .move(MenuBarMoveOperation(itemID: before.items[0].id, section: .hidden, index: 0)),
            now: moved.capturedAt
        )
        let recorder = CountingRevisionWorkspaceRecorder(
            initial: ProfileWorkspaceState(profile: profile),
            injectEditAtRevisionRead: 4
        )
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { await recorder.apply($0) },
            currentRevision: { await recorder.currentRevision() },
            applyIfCurrent: { workspace, revision in
                await recorder.apply(workspace, ifCurrentRevision: revision)
            },
            rollbackSuperseded: { _, _ in nil }
        )

        await #expect(throws: MenuBarWorkspaceTransactionError.superseded) {
            try await coordinator.undo(
                now: restoredTarget.capturedAt,
                workspaceTransaction: transaction
            )
        }

        #expect(await recorder.applyCount == 0)
        #expect(await backend.restoredSnapshots == [activated, liveMoved])
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Profile activation verifies the selected display before committing authority")
    func rejectsProfileResultOnWrongDisplay() async throws {
        let firstDisplay = MenuBarDisplayID("first-display")
        let secondDisplay = MenuBarDisplayID("second-display")
        let firstItem = MenuBarItemID(
            bundleIdentifier: "com.example.first",
            accessibilityIdentifier: "first"
        )
        let secondItem = MenuBarItemID(
            bundleIdentifier: "com.example.second",
            accessibilityIdentifier: "second"
        )
        func snapshot(_ generation: UInt64, swapped: Bool) -> MenuBarSnapshot {
            MenuBarSnapshot(
                generation: generation,
                capturedAt: Date(),
                items: [
                    MenuBarItemDescriptor(
                        id: firstItem,
                        section: .visible,
                        order: 0,
                        displayID: swapped ? secondDisplay : firstDisplay,
                        isOnScreen: true
                    ),
                    MenuBarItemDescriptor(
                        id: secondItem,
                        section: .visible,
                        order: 1,
                        displayID: swapped ? firstDisplay : secondDisplay,
                        isOnScreen: true
                    ),
                ],
                displayIDs: [firstDisplay, secondDisplay],
                activeSpaceIsValid: true
            )
        }
        let before = snapshot(1, swapped: false)
        let wrongDisplayResult = snapshot(2, swapped: true)
        let verifiedRollback = snapshot(3, swapped: false)
        let profile = BarlineProfile(
            id: UUID(124),
            name: "First display",
            layout: ProfileLayout(visible: [firstItem, secondItem]),
            displayOverrides: [
                DisplayProfileOverride(
                    displayID: firstDisplay,
                    layout: ProfileLayout(hidden: [firstItem])
                ),
            ]
        )
        let backend = FakeBackend(snapshots: [before, wrongDisplayResult, verifiedRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.activate(
                profile: profile,
                on: firstDisplay,
                now: wrongDisplayResult.capturedAt
            )
        }

        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await backend.restoredSnapshots == [before])
    }

    @Test("A partially applied workspace failure restores and verifies both workspace and layout")
    func rollsBackPartialWorkspaceFailure() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let freshBefore = makeSnapshot(generation: 2, count: 2)
        let verifiedRollback = makeSnapshot(generation: 3, count: 2)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let targetProfile = BarlineProfile(
            id: UUID(125),
            name: "Target",
            layout: ProfileLayout(visible: before.items.map(\.id)),
            appearance: ProfileAppearance(itemSpacing: 4)
        )
        let recorder = WorkspaceRecorder(initial: original, partialFailApplyNumbers: [1])
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )
        let backend = FakeBackend(snapshots: [before, freshBefore, verifiedRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.activate(
                profile: targetProfile,
                now: freshBefore.capturedAt,
                workspaceTransaction: transaction
            )
        }

        #expect(await recorder.capture() == original)
        #expect(await recorder.values == [ProfileWorkspaceState(profile: targetProfile), original])
        #expect(await backend.restoredSnapshots == [freshBefore])
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Concurrent workspace edits supersede activation without being overwritten")
    func preservesConcurrentWorkspaceEditDuringActivation() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let freshBefore = makeSnapshot(generation: 2, count: 2)
        let after = makeSnapshot(generation: 3, count: 2)
        let verifiedRollback = makeSnapshot(generation: 4, count: 2)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let profile = BarlineProfile(
            id: UUID(126),
            name: "Target",
            layout: ProfileLayout(visible: before.items.map(\.id)),
            appearance: ProfileAppearance(itemSpacing: 4)
        )
        var expectedWorkspace = original
        expectedWorkspace.shelfBehavior.isEnabled.toggle()
        let recorder = RevisionedWorkspaceRecorder(initial: original)
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { await recorder.apply($0) },
            currentRevision: { await recorder.currentRevision() },
            applyIfCurrent: { workspace, revision in
                await recorder.apply(workspace, ifCurrentRevision: revision)
            },
            rollbackSuperseded: { target, original in
                await recorder.rollbackSuperseded(from: target, to: original)
            }
        )
        let backend = FakeBackend(
            snapshots: [before, freshBefore, after, verifiedRollback]
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarWorkspaceTransactionError.self) {
            try await coordinator.activate(
                profile: profile,
                now: after.capturedAt,
                workspaceTransaction: transaction
            )
        }

        #expect(await recorder.capture() == expectedWorkspace)
        #expect(await backend.restoredSnapshots == [freshBefore])
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Workspace transaction aborts revoke prior authority")
    func workspaceTransactionAbortsRevokeAuthority() async throws {
        for transactionError in [
            MenuBarWorkspaceTransactionError.superseded,
            .sideEffectRecoveryFailed,
        ] {
            let before = makeSnapshot(generation: 1, count: 2)
            let activated = makeSnapshot(generation: 2, count: 2)
            let live = makeSnapshot(generation: 3, count: 2)
            let prior = BarlineProfile(
                id: UUID(127),
                name: "Prior",
                layout: ProfileLayout(visible: before.items.map(\.id))
            )
            let replacement = BarlineProfile(
                id: UUID(128),
                name: "Replacement",
                layout: ProfileLayout(visible: before.items.map(\.id))
            )
            let original = ProfileWorkspaceState(profile: prior)
            let transaction = MenuBarWorkspaceTransaction(
                capture: { original },
                apply: { _ in },
                currentRevision: { 0 },
                applyIfCurrent: { _, _ in throw transactionError },
                rollbackSuperseded: { _, _ in nil }
            )
            let backend = FakeBackend(snapshots: [before, activated, live])
            let coordinator = MenuBarStateCoordinator(
                backend: backend,
                retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
            )
            _ = try await coordinator.refresh(now: before.capturedAt)
            _ = try await coordinator.activate(profile: prior, now: activated.capturedAt)
            #expect(await coordinator.activeProfileID == prior.id)

            await #expect(throws: MenuBarWorkspaceTransactionError.self) {
                try await coordinator.activate(
                    profile: replacement,
                    now: live.capturedAt,
                    workspaceTransaction: transaction
                )
            }

            #expect(await coordinator.activeProfileID == nil)
            #expect(await coordinator.currentSnapshot == live)
            #expect(await backend.restoredSnapshots.isEmpty)
        }
    }

    @Test("Unverified activation rollback clears current authority")
    func clearsAuthorityWhenActivationRollbackFails() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let freshBefore = makeSnapshot(generation: 2, count: 2)
        let profile = BarlineProfile(
            id: UUID(121),
            name: "Rollback",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let recorder = WorkspaceRecorder(initial: original, failApplyNumbers: [2])
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )
        let backend = FakeBackend(
            snapshots: [before, freshBefore],
            failMoveAt: 1,
            restoreFailures: 1
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.activate(
                profile: profile,
                now: before.capturedAt,
                workspaceTransaction: transaction
            )
        }

        #expect(await coordinator.currentSnapshot == nil)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.lastKnownGoodSnapshot == freshBefore)
    }

    @Test("Stored workspace checkpoints validate before side effects")
    func rejectsInvalidStoredWorkspaceCheckpoint() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let invalidWorkspace = ProfileWorkspaceState(
            appearance: ProfileAppearance(itemSpacing: .nan),
            shelfBehavior: ProfileShelfBehavior(),
            revealTriggers: ProfileRevealTriggers(),
            autoRehide: ProfileAutoRehide(),
            applicationMenuOverlapBehavior: .hideWhenNeeded
        )
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: before,
            activeProfileID: nil,
            workspace: invalidWorkspace
        )
        let recorder = WorkspaceRecorder(
            initial: ProfileWorkspaceState(profile: BarlineProfile(name: "Current"))
        )
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )
        let backend = FakeBackend(snapshots: [])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        await #expect(throws: ProfileValidationError.invalidAppearance) {
            try await coordinator.restoreWorkspaceCheckpoint(
                checkpoint,
                workspaceTransaction: transaction
            )
        }
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await recorder.values.isEmpty)
    }

    @Test("Conditional workspace restore preserves a superseding profile")
    func conditionalRestorePreservesSupersedingProfile() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let presentationLayout = ProfileLayout(hidden: before.items.map(\.id))
        let newerLayout = ProfileLayout(alwaysHidden: before.items.map(\.id))
        let freshBefore = makeSnapshot(generation: 2, count: 2)
        let afterPresentation = makeProfileSnapshot(generation: 3, layout: presentationLayout)
        let freshPresentation = makeProfileSnapshot(generation: 4, layout: presentationLayout)
        let afterNewer = makeProfileSnapshot(generation: 5, layout: newerLayout)
        let liveNewer = makeProfileSnapshot(generation: 6, layout: newerLayout)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let presentation = BarlineProfile(
            id: UUID(131),
            name: "Presentation",
            layout: presentationLayout
        )
        let newer = BarlineProfile(id: UUID(132), name: "Newer", layout: newerLayout)
        let recorder = WorkspaceRecorder(initial: original)
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )
        let backend = FakeBackend(
            snapshots: [
                before, freshBefore, afterPresentation, freshPresentation, afterNewer, liveNewer,
            ]
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(
            profile: presentation,
            now: afterPresentation.capturedAt,
            workspaceTransaction: transaction
        )
        _ = try await coordinator.activate(
            profile: newer,
            now: afterNewer.capturedAt,
            workspaceTransaction: transaction
        )
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: before,
            activeProfileID: nil,
            workspace: original
        )

        let result = try await coordinator.restoreWorkspaceCheckpoint(
            checkpoint,
            ifCurrentMatches: presentation,
            authorityIsCurrent: true,
            workspaceTransaction: transaction,
            now: liveNewer.capturedAt
        )

        #expect(result == .superseded)
        #expect(await coordinator.activeProfileID == newer.id)
        #expect(await coordinator.currentSnapshot == liveNewer)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await recorder.values == [
            ProfileWorkspaceState(profile: presentation),
            ProfileWorkspaceState(profile: newer),
        ])
    }

    @Test("Conditional workspace restore rejects stale activation ownership")
    func conditionalRestoreRejectsStaleActivationOwnership() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let presentationLayout = ProfileLayout(hidden: before.items.map(\.id))
        let livePresentation = makeProfileSnapshot(generation: 2, layout: presentationLayout)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let presentation = BarlineProfile(
            id: UUID(133),
            name: "Presentation",
            layout: presentationLayout
        )
        let recorder = WorkspaceRecorder(initial: ProfileWorkspaceState(profile: presentation))
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )
        let backend = FakeBackend(snapshots: [livePresentation])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: before,
            activeProfileID: nil,
            workspace: original
        )

        let result = try await coordinator.restoreWorkspaceCheckpoint(
            checkpoint,
            ifCurrentMatches: presentation,
            authorityIsCurrent: false,
            workspaceTransaction: transaction,
            now: livePresentation.capturedAt
        )

        #expect(result == .superseded)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await recorder.values.isEmpty)
        #expect(await coordinator.currentSnapshot == livePresentation)
    }

    @Test("Durable ownership restores after coordinator relaunch")
    func conditionalRestoreRehydratesDurableOwnership() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let presentationLayout = ProfileLayout(hidden: before.items.map(\.id))
        let livePresentation = makeProfileSnapshot(generation: 2, layout: presentationLayout)
        let restored = makeSnapshot(generation: 3, count: 2)
        let original = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let presentation = BarlineProfile(
            id: UUID(134),
            name: "Presentation",
            layout: presentationLayout
        )
        let recorder = WorkspaceRecorder(initial: ProfileWorkspaceState(profile: presentation))
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )
        let backend = FakeBackend(snapshots: [livePresentation, restored])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: before,
            activeProfileID: nil,
            workspace: original
        )

        let result = try await coordinator.restoreWorkspaceCheckpoint(
            checkpoint,
            ifCurrentMatches: presentation,
            authorityIsCurrent: true,
            workspaceTransaction: transaction,
            now: restored.capturedAt
        )

        #expect(result == .restored(restored))
        #expect(await backend.restoredSnapshots == [before])
        #expect(await recorder.values == [original])
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Relaunch authority rehydrates only for an exact live workspace")
    func rehydratesExactLiveAuthority() async throws {
        let base = makeSnapshot(generation: 1, count: 2)
        let profile = BarlineProfile(
            id: UUID(135),
            name: "Durable",
            layout: ProfileLayout(visible: base.items.map(\.id))
        )
        let live = makeProfileSnapshot(generation: 2, layout: profile.layout)
        let recorder = WorkspaceRecorder(initial: ProfileWorkspaceState(profile: profile))
        let transaction = MenuBarWorkspaceTransaction(
            capture: { await recorder.capture() },
            apply: { try await recorder.apply($0) }
        )
        let coordinator = MenuBarStateCoordinator(
            backend: FakeBackend(snapshots: [live]),
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let retained = try await coordinator.rehydrateActiveProfileAuthority(
            profile: profile,
            persistedPresentation: profile.resolvedPresentation(for: nil),
            workspaceTransaction: transaction,
            now: live.capturedAt
        )

        #expect(retained != nil)
        #expect(await coordinator.activeProfileID == profile.id)

        let drifted = WorkspaceRecorder(initial: ProfileWorkspaceState(profile: BarlineProfile(name: "Other")))
        let driftedTransaction = MenuBarWorkspaceTransaction(
            capture: { await drifted.capture() },
            apply: { try await drifted.apply($0) }
        )
        let mismatchCoordinator = MenuBarStateCoordinator(
            backend: FakeBackend(snapshots: [live]),
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        let mismatched = try await mismatchCoordinator.rehydrateActiveProfileAuthority(
            profile: profile,
            persistedPresentation: profile.resolvedPresentation(for: nil),
            workspaceTransaction: driftedTransaction,
            now: live.capturedAt
        )
        #expect(mismatched == nil)
        #expect(await mismatchCoordinator.activeProfileID == nil)
    }

    @Test("Redo captures a live externally changed inverse layout")
    func redoUsesLiveExternalInverse() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let external = makeProfileSnapshot(
            generation: 3,
            layout: ProfileLayout(hidden: before.items.map(\.id))
        )
        let restoredBefore = makeSnapshot(generation: 4, count: 2)
        let liveBefore = makeSnapshot(generation: 5, count: 2)
        let restoredExternal = makeProfileSnapshot(
            generation: 6,
            layout: ProfileLayout(hidden: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [
            before, after, external, restoredBefore, liveBefore, restoredExternal,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.perform(.reveal(before.items[0].id), now: after.capturedAt)

        _ = try await coordinator.undo(now: restoredBefore.capturedAt)
        let redone = try await coordinator.redo(now: restoredExternal.capturedAt)

        #expect(await backend.restoredSnapshots == [before, external])
        #expect(redone == restoredExternal)
    }

    @Test("Profile activation resolves the active display override through the helper boundary")
    func activatesActiveDisplayOverride() async throws {
        let before = makeSnapshot(generation: 1, count: 3)
        let activeDisplay = MenuBarDisplayID("test-display")
        let overrideLayout = ProfileLayout(
            visible: [before.items[1].id],
            hidden: [before.items[2].id],
            alwaysHidden: [before.items[0].id]
        )
        let profile = BarlineProfile(
            id: UUID(101),
            name: "Presentation",
            layout: ProfileLayout(visible: before.items.map(\.id)),
            displayOverrides: [
                DisplayProfileOverride(displayID: activeDisplay, layout: overrideLayout),
            ]
        )
        let after = makeProfileSnapshot(generation: 2, layout: overrideLayout)
        let backend = FakeBackend(
            snapshots: [before, after],
            environment: MenuBarEnvironmentSnapshot(
                activeDisplayID: 7,
                activeStableDisplayID: activeDisplay,
                activeSpaceToken: 42,
                activeSpaceIsFullscreen: false
            )
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        _ = try await coordinator.activate(profile: profile, now: after.capturedAt)

        #expect(await backend.moveOperations.map(\.itemID) == overrideLayout.allItemIDs)
        #expect(await backend.moveOperations.allSatisfy {
            $0.destinationDisplayID == activeDisplay
        })
        #expect(await coordinator.activeProfileID == profile.id)
    }

    @Test("Reconnected display overrides target the unique live display")
    func activatesReconnectedDisplayOverride() async throws {
        let storedDisplay = MenuBarDisplayID("stored-display")
        let liveDisplay = MenuBarDisplayID("test-display")
        let fingerprint = MenuBarDisplayHardwareFingerprint(
            "v1:" + String(repeating: "c", count: 64)
        )
        let rawBefore = makeSnapshot(generation: 1, count: 3, display: liveDisplay)
        let before = MenuBarSnapshot(
            generation: rawBefore.generation,
            capturedAt: rawBefore.capturedAt,
            items: rawBefore.items,
            displayIDs: rawBefore.displayIDs,
            displayIdentities: [
                MenuBarDisplayIdentity(
                    runtimeID: liveDisplay,
                    hardwareFingerprint: fingerprint
                ),
            ],
            activeSpaceIsValid: true
        )
        let overrideLayout = ProfileLayout(
            visible: [before.items[1].id],
            hidden: [before.items[2].id],
            alwaysHidden: [before.items[0].id]
        )
        let group = ProfileGroup(
            id: UUID(132),
            name: "Reconnect",
            itemIDs: [before.items[1].id]
        )
        let profile = BarlineProfile(
            id: UUID(133),
            name: "Reconnected",
            layout: ProfileLayout(visible: before.items.map(\.id)),
            displayOverrides: [
                DisplayProfileOverride(
                    displayID: storedDisplay,
                    displayFingerprint: fingerprint,
                    layout: overrideLayout,
                    groups: [group]
                ),
            ]
        )
        let freshBefore = MenuBarSnapshot(
            generation: 2,
            capturedAt: before.capturedAt,
            items: before.items,
            displayIDs: before.displayIDs,
            displayIdentities: before.displayIdentities,
            activeSpaceIsValid: true
        )
        let rawAfter = makeProfileSnapshot(generation: 3, layout: overrideLayout)
        let after = MenuBarSnapshot(
            generation: rawAfter.generation,
            capturedAt: rawAfter.capturedAt,
            items: rawAfter.items,
            displayIDs: rawAfter.displayIDs,
            displayIdentities: before.displayIdentities,
            activeSpaceIsValid: true
        )
        let originalWorkspace = ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        let recorder = WorkspaceRecorder(initial: originalWorkspace)
        let backend = FakeBackend(
            snapshots: [before, freshBefore, after],
            environment: MenuBarEnvironmentSnapshot(
                activeDisplayID: 7,
                activeStableDisplayID: liveDisplay,
                activeSpaceToken: 42,
                activeSpaceIsFullscreen: false
            )
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        _ = try await coordinator.activate(
            profile: profile,
            now: after.capturedAt,
            workspaceTransaction: MenuBarWorkspaceTransaction(
                capture: { await recorder.capture() },
                apply: { try await recorder.apply($0) }
            )
        )

        #expect(await backend.moveOperations.allSatisfy {
            $0.destinationDisplayID == liveDisplay
        })
        let appliedWorkspace = try #require(await recorder.values.first)
        #expect(appliedWorkspace.presentation == ResolvedProfilePresentation(
            source: .displayOverride(storedDisplay),
            destinationDisplayID: liveDisplay,
            layout: overrideLayout,
            groups: [group],
            spacers: []
        ))
    }

    @Test("Display identity changes during activation roll back authority")
    func rejectsDisplayIdentityChangeDuringActivation() async throws {
        let liveDisplay = MenuBarDisplayID("test-display")
        let originalFingerprint = MenuBarDisplayHardwareFingerprint(
            "v1:" + String(repeating: "d", count: 64)
        )
        let replacementFingerprint = MenuBarDisplayHardwareFingerprint(
            "v1:" + String(repeating: "e", count: 64)
        )
        let rawBefore = makeSnapshot(generation: 1, count: 3, display: liveDisplay)
        let before = MenuBarSnapshot(
            generation: rawBefore.generation,
            capturedAt: rawBefore.capturedAt,
            items: rawBefore.items,
            displayIDs: rawBefore.displayIDs,
            displayIdentities: [
                MenuBarDisplayIdentity(
                    runtimeID: liveDisplay,
                    hardwareFingerprint: originalFingerprint
                ),
            ],
            activeSpaceIsValid: true
        )
        let layout = ProfileLayout(
            visible: [before.items[1].id],
            hidden: [before.items[2].id],
            alwaysHidden: [before.items[0].id]
        )
        let rawAfter = makeProfileSnapshot(generation: 2, layout: layout)
        let after = MenuBarSnapshot(
            generation: rawAfter.generation,
            capturedAt: rawAfter.capturedAt,
            items: rawAfter.items,
            displayIDs: rawAfter.displayIDs,
            displayIdentities: [
                MenuBarDisplayIdentity(
                    runtimeID: liveDisplay,
                    hardwareFingerprint: replacementFingerprint
                ),
            ],
            activeSpaceIsValid: true
        )
        let rollback = MenuBarSnapshot(
            generation: 3,
            capturedAt: before.capturedAt,
            items: before.items,
            displayIDs: before.displayIDs,
            displayIdentities: [
                MenuBarDisplayIdentity(
                    runtimeID: liveDisplay,
                    hardwareFingerprint: replacementFingerprint
                ),
            ],
            activeSpaceIsValid: true
        )
        let profile = BarlineProfile(
            id: UUID(134),
            name: "Identity change",
            displayOverrides: [
                DisplayProfileOverride(
                    displayID: liveDisplay,
                    displayFingerprint: originalFingerprint,
                    layout: layout
                ),
            ]
        )
        let backend = FakeBackend(snapshots: [before, after, rollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.activate(
                profile: profile,
                on: liveDisplay,
                now: after.capturedAt
            )
        }

        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == nil)
        #expect(await backend.restoredSnapshots == [before])
    }

    @Test("Display identity ambiguity during activation rolls back authority")
    func rejectsDisplayIdentityAmbiguityDuringActivation() async throws {
        let liveDisplay = MenuBarDisplayID("test-display")
        let duplicateDisplay = MenuBarDisplayID("duplicate-display")
        let fingerprint = MenuBarDisplayHardwareFingerprint(
            "v1:" + String(repeating: "f", count: 64)
        )
        let rawBefore = makeSnapshot(generation: 1, count: 2, display: liveDisplay)
        let identity = MenuBarDisplayIdentity(
            runtimeID: liveDisplay,
            hardwareFingerprint: fingerprint
        )
        let before = MenuBarSnapshot(
            generation: rawBefore.generation,
            capturedAt: rawBefore.capturedAt,
            items: rawBefore.items,
            displayIDs: rawBefore.displayIDs,
            displayIdentities: [identity],
            activeSpaceIsValid: true
        )
        let layout = ProfileLayout(visible: before.items.reversed().map(\.id))
        let rawAfter = makeProfileSnapshot(generation: 2, layout: layout)
        let after = MenuBarSnapshot(
            generation: rawAfter.generation,
            capturedAt: rawAfter.capturedAt,
            items: rawAfter.items,
            displayIDs: [liveDisplay, duplicateDisplay],
            displayIdentities: [
                identity,
                MenuBarDisplayIdentity(
                    runtimeID: duplicateDisplay,
                    hardwareFingerprint: fingerprint
                ),
            ],
            activeSpaceIsValid: true
        )
        let rollback = MenuBarSnapshot(
            generation: 3,
            capturedAt: before.capturedAt,
            items: before.items,
            displayIDs: before.displayIDs,
            displayIdentities: before.displayIdentities,
            activeSpaceIsValid: true
        )
        let profile = BarlineProfile(
            id: UUID(135),
            name: "Identity ambiguity",
            displayOverrides: [
                DisplayProfileOverride(
                    displayID: liveDisplay,
                    displayFingerprint: fingerprint,
                    layout: layout
                ),
            ]
        )
        let backend = FakeBackend(snapshots: [before, after, rollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.self) {
            try await coordinator.activate(
                profile: profile,
                on: liveDisplay,
                now: after.capturedAt
            )
        }

        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == rollback)
    }

    @Test("Base presentation checkpoints remain unscoped when overrides exist")
    func basePresentationCheckpointIsUnscoped() async throws {
        let display = MenuBarDisplayID("test-display")
        let snapshot = makeSnapshot(generation: 1, count: 1, display: display)
        let profile = BarlineProfile(
            name: "Base scope",
            layout: ProfileLayout(visible: snapshot.items.map(\.id)),
            displayOverrides: [
                DisplayProfileOverride(
                    displayID: display,
                    layout: ProfileLayout(hidden: snapshot.items.map(\.id))
                ),
            ]
        )
        let workspace = ProfileWorkspaceState(profile: profile)
        let backend = FakeBackend(
            snapshots: [snapshot],
            environment: MenuBarEnvironmentSnapshot(
                activeDisplayID: 7,
                activeStableDisplayID: display,
                activeSpaceToken: 42,
                activeSpaceIsFullscreen: false
            )
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        let checkpoint = try await coordinator.captureWorkspaceCheckpoint(
            workspaceTransaction: MenuBarWorkspaceTransaction(
                capture: { workspace },
                apply: { _ in }
            ),
            now: snapshot.capturedAt
        )

        #expect(checkpoint.activeDisplayID == nil)
        #expect(checkpoint.workspace.presentation?.source == .base)
    }

    @Test("Base profile activation preserves source displays")
    func baseProfileActivationPreservesSourceDisplays() async throws {
        let firstDisplay = MenuBarDisplayID("first-display")
        let secondDisplay = MenuBarDisplayID("second-display")
        let firstItem = MenuBarItemDescriptor(
            id: MenuBarItemID(
                bundleIdentifier: "com.example.first",
                accessibilityIdentifier: "first"
            ),
            section: .visible,
            order: 0,
            displayID: firstDisplay,
            isOnScreen: true
        )
        let secondItem = MenuBarItemDescriptor(
            id: MenuBarItemID(
                bundleIdentifier: "com.example.second",
                accessibilityIdentifier: "second"
            ),
            section: .visible,
            order: 1,
            displayID: secondDisplay,
            isOnScreen: true
        )
        let before = MenuBarSnapshot(
            generation: 1,
            capturedAt: Date(),
            items: [firstItem, secondItem],
            displayIDs: [firstDisplay, secondDisplay],
            activeSpaceIsValid: true
        )
        let after = MenuBarSnapshot(
            generation: 2,
            capturedAt: before.capturedAt,
            items: [firstItem, secondItem],
            displayIDs: before.displayIDs,
            activeSpaceIsValid: true
        )
        let profile = BarlineProfile(
            id: UUID(102),
            name: "All Displays",
            layout: ProfileLayout(visible: [firstItem.id, secondItem.id])
        )
        let backend = FakeBackend(
            snapshots: [before, after],
            environment: MenuBarEnvironmentSnapshot(
                activeDisplayID: 7,
                activeStableDisplayID: firstDisplay,
                activeSpaceToken: 42,
                activeSpaceIsFullscreen: false
            )
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        _ = try await coordinator.activate(profile: profile, now: after.capturedAt)

        // Both displays already match; activation must not issue redundant drags.
        #expect(await backend.moveOperations.isEmpty)
        #expect(await coordinator.activeProfileID == profile.id)
    }

    @Test("A partially applied profile is rolled back and never becomes authoritative")
    func rollsBackPartialProfileActivation() async throws {
        let before = makeSnapshot(generation: 1, count: 3)
        let profile = BarlineProfile(
            id: UUID(101),
            name: "Broken",
            layout: ProfileLayout(visible: before.items.reversed().map(\.id))
        )
        let verifiedRollback = makeSnapshot(generation: 2, count: 3)
        let backend = FakeBackend(snapshots: [before, verifiedRollback], failMoveAt: 2)
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.operationFailed("injected move failure")) {
            try await coordinator.activate(profile: profile, now: before.capturedAt)
        }

        #expect(await backend.moveOperations.count == 2)
        #expect(await backend.restoredSnapshots == [before])
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == verifiedRollback)
    }

    @Test("Profiles with stale items fail before applying any move")
    func rejectsStaleProfileReference() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let stale = MenuBarItemID(
            bundleIdentifier: "com.example.absent",
            accessibilityIdentifier: "absent"
        )
        let profile = BarlineProfile(name: "Stale", layout: ProfileLayout(hidden: [stale]))
        let backend = FakeBackend(snapshots: [before])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.staleItem(stale)) {
            try await coordinator.activate(profile: profile, now: before.capturedAt)
        }

        #expect(await backend.moveOperations.isEmpty)
        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Thrown snapshot errors retry and recover backend health")
    func retriesThrownSnapshotError() async throws {
        let valid = makeSnapshot(generation: 1, count: 2)
        let backend = FakeBackend(snapshots: [valid], snapshotFailures: 1)
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(
                maximumAttempts: 2,
                baseDelay: .zero,
                maximumDelay: .zero,
                maximumJitterPermille: 0
            )
        )

        let result = try await coordinator.refresh(now: valid.capturedAt)

        #expect(result == valid)
        #expect(await backend.snapshotCallCount == 2)
        #expect(await coordinator.backendHealth.state == .healthy)
    }

    @Test("Move and status-item activation use validated stable IDs")
    func appliesMoveAndActivateBranches() async throws {
        let first = makeSnapshot(generation: 1, count: 2)
        let second = makeProfileSnapshot(
            generation: 2,
            layout: ProfileLayout(
                visible: [first.items[1].id],
                hidden: [first.items[0].id]
            )
        )
        let third = makeSnapshot(generation: 3, count: 2)
        let backend = FakeBackend(snapshots: [first, second, third])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        let move = MenuBarMoveOperation(itemID: first.items[0].id, section: .hidden, index: 0)

        // No explicit refresh: the mutation must establish a validated starting snapshot itself.
        _ = try await coordinator.perform(.move(move), now: first.capturedAt)
        try await coordinator.activateItem(
            first.items[1].id,
            button: .right,
            expectedGeneration: second.generation,
            now: third.capturedAt
        )

        #expect(await backend.moveOperations == [move])
        #expect(await backend.activations == [.init(itemID: first.items[1].id, button: .right)])
        #expect(await backend.snapshotCallCount == 2)
        #expect(await coordinator.currentSnapshot == second)

        _ = try await coordinator.refresh(now: third.capturedAt)
        #expect(await coordinator.currentSnapshot == third)
    }

    @Test("Move postcondition rejects the wrong section-relative ordinal")
    func rejectsWrongMoveOrdinal() async throws {
        let before = makeSnapshot(generation: 1, count: 3)
        let wrong = makeProfileSnapshot(
            generation: 2,
            layout: ProfileLayout(
                visible: [before.items[2].id],
                hidden: [before.items[1].id, before.items[0].id]
            )
        )
        let verifiedRollback = makeSnapshot(generation: 3, count: 3)
        let operation = MenuBarMoveOperation(
            itemID: before.items[0].id,
            section: .hidden,
            index: 0
        )
        let backend = FakeBackend(snapshots: [before, wrong, verifiedRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )

        await #expect(throws: MenuBarBackendError.operationFailed(
            "menu bar move did not reach requested section"
        )) {
            try await coordinator.perform(.move(operation), now: wrong.capturedAt)
        }
        #expect(await backend.restoredSnapshots == [before])
        #expect(await coordinator.currentSnapshot == verifiedRollback)
    }

    @Test("Layout mutations create bounded undo and redo checkpoints")
    func undoesAndRedoesLayoutMutation() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let liveAfter = makeSnapshot(generation: 3, count: 2)
        let restoredBefore = makeSnapshot(generation: 4, count: 2)
        let liveBefore = makeSnapshot(generation: 5, count: 2)
        let restoredAfter = makeSnapshot(generation: 6, count: 2)
        let backend = FakeBackend(snapshots: [
            before, after, liveAfter, restoredBefore, liveBefore, restoredAfter,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.perform(.reveal(before.items[0].id), now: after.capturedAt)

        #expect(await coordinator.canUndo)
        _ = try await coordinator.undo(now: restoredBefore.capturedAt)
        #expect(await coordinator.canRedo)
        _ = try await coordinator.redo(now: restoredAfter.capturedAt)

        #expect(await backend.restoredSnapshots == [before, liveAfter])
        #expect(await coordinator.currentSnapshot == restoredAfter)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Click delivery does not validate a post-activation snapshot or create undo history")
    func clickDoesNotCreateUndoHistory() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        // If activation incorrectly requests another snapshot, this unchanged
        // generation would be rejected as stale after the target handled the click.
        let staleAfterClick = makeSnapshot(generation: 1, count: 2)
        let backend = FakeBackend(snapshots: [before, staleAfterClick])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        try await coordinator.activateItem(
            before.items[0].id,
            button: .left,
            expectedGeneration: before.generation,
            now: staleAfterClick.capturedAt
        )

        #expect(await backend.snapshotCallCount == 1)
        #expect(await backend.activations == [.init(itemID: before.items[0].id, button: .left)])
        #expect(await coordinator.currentSnapshot == before)
        #expect(await coordinator.canUndo == false)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Click activation preserves an existing redo checkpoint")
    func clickPreservesRedoHistory() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let afterReveal = makeSnapshot(generation: 2, count: 2)
        let liveAfterReveal = makeSnapshot(generation: 3, count: 2)
        let restoredBefore = makeSnapshot(generation: 4, count: 2)
        let liveAfterClick = makeSnapshot(generation: 5, count: 2)
        let restoredAfter = makeSnapshot(generation: 6, count: 2)
        let backend = FakeBackend(snapshots: [
            before,
            afterReveal,
            liveAfterReveal,
            restoredBefore,
            liveAfterClick,
            restoredAfter,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.perform(.reveal(before.items[0].id), now: afterReveal.capturedAt)
        _ = try await coordinator.undo(now: restoredBefore.capturedAt)

        try await coordinator.activateItem(
            before.items[1].id,
            button: .right,
            expectedGeneration: restoredBefore.generation,
            now: liveAfterClick.capturedAt
        )

        #expect(await coordinator.canRedo)
        _ = try await coordinator.redo(now: restoredAfter.capturedAt)
        #expect(await coordinator.currentSnapshot == restoredAfter)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Structurally valid wrong history layout rolls back")
    func rollsBackWrongHistoryLayout() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let liveAfter = makeSnapshot(generation: 3, count: 2)
        let wrongLayout = ProfileLayout(hidden: before.items.map(\.id))
        let wrongButValid = makeProfileSnapshot(generation: 4, layout: wrongLayout)
        let verifiedAfter = makeSnapshot(generation: 5, count: 2)
        let backend = FakeBackend(snapshots: [
            before, after, liveAfter, wrongButValid, verifiedAfter,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.perform(.reveal(before.items[0].id), now: after.capturedAt)

        await #expect(
            throws: MenuBarBackendError.operationFailed(
                "history restore did not reach requested layout"
            )
        ) {
            try await coordinator.undo(now: wrongButValid.capturedAt)
        }

        #expect(await backend.restoredSnapshots == [before, liveAfter])
        #expect(await coordinator.currentSnapshot == verifiedAfter)
        #expect(await coordinator.lastKnownGoodSnapshot == verifiedAfter)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Profile identity follows layout history through undo and redo")
    func restoresProfileIdentityWithHistory() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let afterFirst = makeSnapshot(generation: 2, count: 2)
        let afterSecond = makeSnapshot(generation: 3, count: 2)
        let liveSecond = makeSnapshot(generation: 4, count: 2)
        let restoredFirst = makeSnapshot(generation: 5, count: 2)
        let liveFirst = makeSnapshot(generation: 6, count: 2)
        let restoredSecond = makeSnapshot(generation: 7, count: 2)
        let firstProfile = BarlineProfile(
            id: UUID(104),
            name: "First",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let secondProfile = BarlineProfile(
            id: UUID(105),
            name: "Second",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [
            before,
            afterFirst,
            afterSecond,
            liveSecond,
            restoredFirst,
            liveFirst,
            restoredSecond,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: firstProfile, now: afterFirst.capturedAt)
        _ = try await coordinator.activate(profile: secondProfile, now: afterSecond.capturedAt)

        _ = try await coordinator.undo(now: restoredFirst.capturedAt)
        #expect(await coordinator.activeProfileID == firstProfile.id)

        _ = try await coordinator.redo(now: restoredSecond.capturedAt)
        #expect(await coordinator.activeProfileID == secondProfile.id)
        #expect(await backend.restoredSnapshots == [afterFirst, liveSecond])
    }

    @Test("Failed history restore rolls back snapshot and profile identity")
    func rollsBackFailedHistoryRestore() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let liveAfter = makeSnapshot(generation: 3, count: 2)
        let verifiedAfter = makeSnapshot(generation: 4, count: 2)
        let profile = BarlineProfile(
            id: UUID(106),
            name: "Current",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(
            snapshots: [before, after, liveAfter, verifiedAfter],
            restoreFailures: 1
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: after.capturedAt)

        await #expect(throws: MenuBarBackendError.interrupted) {
            try await coordinator.undo(now: after.capturedAt)
        }

        #expect(await backend.restoredSnapshots == [before, liveAfter])
        #expect(await coordinator.currentSnapshot == verifiedAfter)
        #expect(await coordinator.lastKnownGoodSnapshot == verifiedAfter)
        #expect(await coordinator.activeProfileID == profile.id)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Invalid post-history snapshot rolls back snapshot and profile identity")
    func rollsBackInvalidHistorySnapshot() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let liveAfter = makeSnapshot(generation: 3, count: 2)
        let invalid = makeSnapshot(generation: 4, count: 0)
        let verifiedAfter = makeSnapshot(generation: 5, count: 2)
        let profile = BarlineProfile(
            id: UUID(107),
            name: "Current",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, after, liveAfter, invalid, verifiedAfter])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: after.capturedAt)

        await #expect(throws: MenuBarBackendError.invalidSnapshot(.emptySnapshot)) {
            try await coordinator.undo(now: invalid.capturedAt)
        }

        #expect(await backend.restoredSnapshots == [before, liveAfter])
        #expect(await coordinator.currentSnapshot == verifiedAfter)
        #expect(await coordinator.lastKnownGoodSnapshot == verifiedAfter)
        #expect(await coordinator.activeProfileID == profile.id)
        #expect(await coordinator.lastRejection == .emptySnapshot)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Profile authority can be conservatively cleared without mutating the layout")
    func clearsProfileAuthority() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let profile = BarlineProfile(
            id: UUID(109),
            name: "Current",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, after])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: after.capturedAt)

        await coordinator.clearActiveProfileAuthority()

        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == after)
        #expect(await backend.restoredSnapshots.isEmpty)
    }

    @Test("Manual layout mutations revoke active profile authority")
    func layoutMutationClearsProfileAuthority() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let activated = makeSnapshot(generation: 2, count: 2)
        let revealed = makeSnapshot(generation: 3, count: 2)
        let profile = BarlineProfile(
            id: UUID(110),
            name: "Current",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, activated, revealed])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: activated.capturedAt)

        _ = try await coordinator.perform(.reveal(before.items[0].id), now: revealed.capturedAt)

        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.canUndo)
    }

    @Test("Transient moves preserve profile authority and layout history")
    func transientMovePreservesProfileAuthorityAndHistory() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let profile = BarlineProfile(
            id: UUID(131),
            name: "Current",
            layout: ProfileLayout(
                visible: [before.items[1].id],
                hidden: [before.items[0].id]
            )
        )
        let activated = makeProfileSnapshot(generation: 2, layout: profile.layout)
        let transientLayout = ProfileLayout(
            visible: [before.items[1].id, before.items[0].id]
        )
        let temporarilyShown = makeProfileSnapshot(generation: 3, layout: transientLayout)
        let liveTemporarilyShown = makeProfileSnapshot(generation: 4, layout: transientLayout)
        let restoredBefore = makeSnapshot(generation: 5, count: 2)
        let backend = FakeBackend(snapshots: [
            before,
            activated,
            temporarilyShown,
            liveTemporarilyShown,
            restoredBefore,
        ])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: activated.capturedAt)

        _ = try await coordinator.perform(
            .transientMove(
                MenuBarMoveOperation(
                    itemID: before.items[0].id,
                    section: .visible,
                    index: 1
                )
            ),
            now: temporarilyShown.capturedAt
        )

        #expect(await coordinator.activeProfileID == profile.id)
        _ = try await coordinator.undo(now: restoredBefore.capturedAt)
        #expect(await coordinator.currentSnapshot == restoredBefore)
        #expect(await coordinator.canUndo == false)
        #expect(await coordinator.canRedo)
    }

    @Test("External layout refresh revokes active profile authority")
    func externalRefreshClearsProfileAuthority() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let profile = BarlineProfile(
            id: UUID(130),
            name: "Current",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let activated = makeProfileSnapshot(generation: 2, layout: profile.layout)
        let changed = makeProfileSnapshot(
            generation: 3,
            layout: ProfileLayout(hidden: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, activated, changed])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: activated.capturedAt)

        _ = try await coordinator.refresh(now: changed.capturedAt)

        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == changed)
    }

    @Test("Unchanged external refresh retains active profile authority")
    func unchangedRefreshRetainsProfileAuthority() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let profile = BarlineProfile(
            id: UUID(131),
            name: "Current",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let activated = makeProfileSnapshot(generation: 2, layout: profile.layout)
        let unchanged = makeProfileSnapshot(generation: 3, layout: profile.layout)
        let backend = FakeBackend(snapshots: [before, activated, unchanged])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: activated.capturedAt)

        _ = try await coordinator.refresh(now: unchanged.capturedAt)

        #expect(await coordinator.activeProfileID == profile.id)
        #expect(await coordinator.currentSnapshot == unchanged)
    }

    @Test("Failed history rollback clears unverified current authority")
    func clearsAuthorityWhenHistoryRollbackFails() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let liveAfter = makeSnapshot(generation: 3, count: 2)
        let invalid = makeSnapshot(generation: 4, count: 0)
        let profile = BarlineProfile(
            id: UUID(108),
            name: "Current",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(
            snapshots: [before, after, liveAfter, invalid],
            restoreFailureCallNumbers: [2]
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: after.capturedAt)

        do {
            _ = try await coordinator.undo(now: invalid.capturedAt)
            Issue.record("Expected history rollback failure")
        } catch let MenuBarBackendError.operationFailed(message) {
            #expect(message.contains("history restore failed"))
            #expect(message.contains("rollback failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await backend.restoredSnapshots == [before, liveAfter])
        #expect(await coordinator.currentSnapshot == nil)
        #expect(await coordinator.lastKnownGoodSnapshot == liveAfter)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Semantically unverifiable history rollback clears current authority")
    func clearsAuthorityWhenHistoryRollbackLayoutDoesNotMatch() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let liveAfter = makeSnapshot(generation: 3, count: 2)
        let invalid = makeSnapshot(generation: 4, count: 0)
        let wrongRollback = makeProfileSnapshot(
            generation: 5,
            layout: ProfileLayout(hidden: before.items.map(\.id))
        )
        let profile = BarlineProfile(
            id: UUID(109),
            name: "Current",
            layout: ProfileLayout(visible: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, after, liveAfter, invalid, wrongRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)
        _ = try await coordinator.activate(profile: profile, now: after.capturedAt)

        do {
            _ = try await coordinator.undo(now: invalid.capturedAt)
            Issue.record("Expected history rollback verification failure")
        } catch let MenuBarBackendError.operationFailed(message) {
            #expect(message.contains("history restore failed"))
            #expect(message.contains("rollback failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await backend.restoredSnapshots == [before, liveAfter])
        #expect(await coordinator.currentSnapshot == nil)
        #expect(await coordinator.lastKnownGoodSnapshot == liveAfter)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.canUndo)
        #expect(await coordinator.canRedo == false)
    }

    @Test("Explicit last-known-good restore participates in post-validation")
    func restoresLastKnownGoodMutation() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let after = makeSnapshot(generation: 2, count: 2)
        let backend = FakeBackend(snapshots: [before, after])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        let result = try await coordinator.perform(
            .restoreLastKnownGood,
            now: after.capturedAt
        )

        #expect(result == after)
        #expect(await backend.restoredSnapshots == [before])
        #expect(await coordinator.lastKnownGoodSnapshot == after)
    }

    @Test("Last-known-good restore rejects a structurally valid wrong layout")
    func rejectsWrongLastKnownGoodLayout() async throws {
        let itemIDs = [
            MenuBarItemID(bundleIdentifier: "com.example.first", accessibilityIdentifier: "first"),
            MenuBarItemID(bundleIdentifier: "com.example.second", accessibilityIdentifier: "second"),
        ]
        let before = makeProfileSnapshot(
            generation: 1,
            layout: ProfileLayout(visible: itemIDs)
        )
        let wrong = makeProfileSnapshot(
            generation: 2,
            layout: ProfileLayout(visible: Array(itemIDs.reversed()))
        )
        let verifiedRollback = makeProfileSnapshot(
            generation: 3,
            layout: ProfileLayout(visible: itemIDs)
        )
        let backend = FakeBackend(snapshots: [before, wrong, verifiedRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        do {
            _ = try await coordinator.perform(.restoreLastKnownGood, now: wrong.capturedAt)
            Issue.record("Expected last-known-good layout verification failure")
        } catch let MenuBarBackendError.operationFailed(message) {
            #expect(message.contains("did not reach requested layout"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await backend.restoredSnapshots == [before, before])
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await coordinator.lastKnownGoodSnapshot == verifiedRollback)
    }

    @Test("Invalid profile post-snapshot rolls back and records the rejection")
    func rollsBackInvalidProfileSnapshot() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let invalid = makeSnapshot(generation: 2, count: 0)
        let verifiedRollback = makeSnapshot(generation: 3, count: 2)
        let profile = BarlineProfile(
            id: UUID(102),
            name: "Invalid result",
            layout: ProfileLayout(visible: before.items.reversed().map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, invalid, verifiedRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.invalidSnapshot(.emptySnapshot)) {
            try await coordinator.activate(profile: profile, now: invalid.capturedAt)
        }

        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.lastRejection == .emptySnapshot)
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await backend.restoredSnapshots == [before])
    }

    @Test("Rollback does not call restore when the backend lacks that capability")
    func rollbackWithoutRestoreCapability() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let capabilities = MenuBarCapabilities(
            canSnapshot: true,
            canMove: true,
            canReveal: true,
            canActivate: true,
            canRestore: false
        )
        let backend = FakeBackend(
            snapshots: [before],
            capabilities: capabilities,
            revealFailure: .interrupted
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(throws: MenuBarBackendError.interrupted) {
            try await coordinator.perform(.reveal(before.items[0].id), now: before.capturedAt)
        }

        #expect(await backend.restoredSnapshots.isEmpty)
        #expect(await coordinator.currentSnapshot == nil)
    }

    @Test("A structurally valid no-op snapshot cannot commit a profile")
    func rejectsProfileSemanticNoOp() async throws {
        let before = makeSnapshot(generation: 1, count: 2)
        let noOp = makeSnapshot(generation: 2, count: 2)
        let verifiedRollback = makeSnapshot(generation: 3, count: 2)
        let profile = BarlineProfile(
            id: UUID(103),
            name: "Must move",
            layout: ProfileLayout(hidden: before.items.map(\.id))
        )
        let backend = FakeBackend(snapshots: [before, noOp, verifiedRollback])
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
        _ = try await coordinator.refresh(now: before.capturedAt)

        await #expect(
            throws: MenuBarBackendError.operationFailed(
                "profile activation did not reach requested layout"
            )
        ) {
            try await coordinator.activate(profile: profile, now: noOp.capturedAt)
        }

        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == verifiedRollback)
        #expect(await backend.restoredSnapshots == [before])
    }
}

@Suite("Retry and backoff policy")
struct RetryPolicyTests {
    @Test("Backoff doubles, caps, and bounds jitter")
    func boundedExponentialBackoff() {
        let policy = RetryPolicy(
            maximumAttempts: 0,
            baseDelay: .milliseconds(100),
            maximumDelay: .milliseconds(450),
            maximumJitterPermille: 200
        )

        #expect(policy.maximumAttempts == 1)
        #expect(policy.delay(forAttempt: -1) == .milliseconds(100))
        #expect(policy.delay(forAttempt: 1) == .milliseconds(200))
        #expect(policy.delay(forAttempt: 1, jitterPermille: 200) == .milliseconds(240))
        #expect(policy.delay(forAttempt: 1, jitterPermille: 900) == .milliseconds(240))
        #expect(policy.delay(forAttempt: 3, jitterPermille: 200) == .milliseconds(450))
    }
}

private actor RestorationGuardRecorder {
    private let rejects: Bool
    private(set) var calls = 0

    init(rejects: Bool) {
        self.rejects = rejects
    }

    func check() throws {
        calls += 1
        if rejects {
            throw MenuBarBackendError.interrupted
        }
    }
}

private actor WorkspaceRecorder {
    private var current: ProfileWorkspaceState
    private(set) var values = [ProfileWorkspaceState]()
    private let failApplyNumbers: Set<Int>
    private let partialFailApplyNumbers: Set<Int>
    private var applyCount = 0

    init(
        initial: ProfileWorkspaceState,
        failApplyNumbers: Set<Int> = [],
        partialFailApplyNumbers: Set<Int> = []
    ) {
        current = initial
        self.failApplyNumbers = failApplyNumbers
        self.partialFailApplyNumbers = partialFailApplyNumbers
    }

    func capture() -> ProfileWorkspaceState {
        current
    }

    func apply(_ value: ProfileWorkspaceState) throws {
        applyCount += 1
        if failApplyNumbers.contains(applyCount) {
            throw MenuBarBackendError.operationFailed("injected workspace failure")
        }
        current = value
        values.append(value)
        if partialFailApplyNumbers.contains(applyCount) {
            throw MenuBarBackendError.operationFailed("injected partial workspace failure")
        }
    }
}

private actor RevisionedWorkspaceRecorder {
    private var current: ProfileWorkspaceState
    private var revision: UInt64 = 0
    private var targetWasApplied = false
    private var editWasInjected = false

    init(initial: ProfileWorkspaceState) {
        current = initial
    }

    func capture() -> ProfileWorkspaceState {
        current
    }

    func currentRevision() -> UInt64 {
        if targetWasApplied, !editWasInjected {
            current.shelfBehavior.isEnabled.toggle()
            revision &+= 1
            editWasInjected = true
        }
        return revision
    }

    func rollbackSuperseded(
        from target: ProfileWorkspaceState,
        to original: ProfileWorkspaceState
    ) -> UInt64? {
        let expectedRevision = revision
        let merged = current.rollingBackUnchangedFields(applied: target, to: original)
        return apply(merged, ifCurrentRevision: expectedRevision)
    }

    func apply(_ value: ProfileWorkspaceState) {
        current = value
        revision &+= 1
    }

    func apply(
        _ value: ProfileWorkspaceState,
        ifCurrentRevision expectedRevision: UInt64
    ) -> UInt64? {
        guard revision == expectedRevision else { return nil }
        current = value
        revision &+= 1
        targetWasApplied = true
        return revision
    }
}

private actor EarlyRevisionWorkspaceRecorder {
    private var current: ProfileWorkspaceState
    private var revision: UInt64 = 0
    private var didCapture = false
    private var editWasInjected = false
    private(set) var applyCount = 0

    init(initial: ProfileWorkspaceState) {
        current = initial
    }

    func capture() -> ProfileWorkspaceState {
        didCapture = true
        return current
    }

    func currentRevision() -> UInt64 {
        if didCapture, !editWasInjected {
            current.shelfBehavior.isEnabled.toggle()
            revision &+= 1
            editWasInjected = true
        }
        return revision
    }

    func apply(_ value: ProfileWorkspaceState) {
        current = value
        revision &+= 1
        applyCount += 1
    }

    func apply(
        _ value: ProfileWorkspaceState,
        ifCurrentRevision expectedRevision: UInt64
    ) -> UInt64? {
        guard revision == expectedRevision else { return nil }
        apply(value)
        return revision
    }
}

private actor CountingRevisionWorkspaceRecorder {
    private var current: ProfileWorkspaceState
    private var revision: UInt64 = 0
    private var revisionReadCount = 0
    private let injectEditAtRevisionRead: Int
    private(set) var applyCount = 0

    init(initial: ProfileWorkspaceState, injectEditAtRevisionRead: Int) {
        current = initial
        self.injectEditAtRevisionRead = injectEditAtRevisionRead
    }

    func capture() -> ProfileWorkspaceState {
        current
    }

    func currentRevision() -> UInt64 {
        revisionReadCount += 1
        if revisionReadCount == injectEditAtRevisionRead {
            current.shelfBehavior.isEnabled.toggle()
            revision &+= 1
        }
        return revision
    }

    func apply(_ value: ProfileWorkspaceState) {
        current = value
        revision &+= 1
        applyCount += 1
    }

    func apply(
        _ value: ProfileWorkspaceState,
        ifCurrentRevision expectedRevision: UInt64
    ) -> UInt64? {
        guard revision == expectedRevision else { return nil }
        apply(value)
        return revision
    }
}

private actor FakeBackend: MenuBarBackend {
    struct Activation: Equatable, Sendable {
        let itemID: MenuBarItemID
        let button: MenuBarMouseButton
    }

    let capabilities: MenuBarCapabilities

    private var snapshots: [MenuBarSnapshot]
    private(set) var restoredSnapshots = [MenuBarSnapshot]()
    private(set) var revealedItems = [MenuBarItemID]()
    private(set) var moveOperations = [MenuBarMoveOperation]()
    private(set) var activations = [Activation]()
    private(set) var maximumConcurrentMutations = 0
    private(set) var snapshotCallCount = 0
    private(set) var restartCount = 0
    private var concurrentMutations = 0
    private var mutationStarted = false
    private var mutationStartWaiters = [CheckedContinuation<Void, Never>]()
    private let mutationDelay: Duration
    private let restartDelay: Duration
    private let revealFailure: MenuBarBackendError?
    private let failMoveAt: Int?
    private let environmentSnapshot: MenuBarEnvironmentSnapshot?
    private var snapshotFailuresRemaining: Int
    private var restoreFailuresRemaining: Int
    private let restoreFailureCallNumbers: Set<Int>
    private var restoreCallCount = 0
    private let checksCancellationDuringCompensation: Bool
    private let cancelOnMove: Bool
    private let restoreDelay: Duration
    private(set) var restoreIsActive = false

    init(
        snapshots: [MenuBarSnapshot],
        capabilities: MenuBarCapabilities = MenuBarCapabilities(
            canSnapshot: true,
            canMove: true,
            canReveal: true,
            canActivate: true,
            canRestore: true,
            // This logical backend does not synthesize a drag to a physical item.
            moveDestinationSupport: .emptySectionAllowed
        ),
        mutationDelay: Duration = .zero,
        restartDelay: Duration = .zero,
        revealFailure: MenuBarBackendError? = nil,
        failMoveAt: Int? = nil,
        environment: MenuBarEnvironmentSnapshot? = nil,
        snapshotFailures: Int = 0,
        restoreFailures: Int = 0,
        restoreFailureCallNumbers: Set<Int> = [],
        checksCancellationDuringCompensation: Bool = false,
        cancelOnMove: Bool = false,
        restoreDelay: Duration = .zero
    ) {
        self.snapshots = snapshots
        self.capabilities = capabilities
        self.mutationDelay = mutationDelay
        self.restartDelay = restartDelay
        self.revealFailure = revealFailure
        self.failMoveAt = failMoveAt
        environmentSnapshot = environment
        snapshotFailuresRemaining = max(0, snapshotFailures)
        restoreFailuresRemaining = max(0, restoreFailures)
        self.restoreFailureCallNumbers = restoreFailureCallNumbers
        self.checksCancellationDuringCompensation = checksCancellationDuringCompensation
        self.cancelOnMove = cancelOnMove
        self.restoreDelay = restoreDelay
    }

    func snapshot() throws -> MenuBarSnapshot {
        if checksCancellationDuringCompensation {
            try Task.checkCancellation()
        }
        snapshotCallCount += 1
        if snapshotFailuresRemaining > 0 {
            snapshotFailuresRemaining -= 1
            throw MenuBarBackendError.interrupted
        }
        guard !snapshots.isEmpty else {
            throw MenuBarBackendError.operationFailed("no fake snapshot")
        }
        return snapshots.removeFirst()
    }

    func move(_ operation: MenuBarMoveOperation) throws -> MenuBarMutationResult {
        if cancelOnMove {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        moveOperations.append(operation)
        if moveOperations.count == failMoveAt {
            throw MenuBarBackendError.operationFailed("injected move failure")
        }
        return MenuBarMutationResult(generation: 0, changedItemIDs: [operation.itemID])
    }

    func reveal(_ item: MenuBarItemID) async throws -> MenuBarMutationResult {
        concurrentMutations += 1
        maximumConcurrentMutations = max(maximumConcurrentMutations, concurrentMutations)
        mutationStarted = true
        let waiters = mutationStartWaiters
        mutationStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        defer { concurrentMutations -= 1 }
        try await Task.sleep(for: mutationDelay)
        if let revealFailure {
            throw revealFailure
        }
        revealedItems.append(item)
        return MenuBarMutationResult(generation: 0, changedItemIDs: [item])
    }

    func waitUntilMutationStarted() async {
        guard !mutationStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            mutationStartWaiters.append(continuation)
        }
    }

    func activate(_ item: MenuBarItemID, button: MenuBarMouseButton) {
        activations.append(Activation(itemID: item, button: button))
    }

    func environment() throws -> MenuBarEnvironmentSnapshot {
        guard let environmentSnapshot else {
            throw MenuBarBackendError.unavailableCapability("environment")
        }
        return environmentSnapshot
    }

    func restore(_ snapshot: MenuBarSnapshot) async throws -> MenuBarMutationResult {
        if checksCancellationDuringCompensation {
            try Task.checkCancellation()
        }
        restoreIsActive = true
        defer { restoreIsActive = false }
        restoreCallCount += 1
        restoredSnapshots.append(snapshot)
        if restoreDelay > .zero {
            try await Task.sleep(for: restoreDelay)
        }
        if restoreFailureCallNumbers.contains(restoreCallCount) || restoreFailuresRemaining > 0 {
            restoreFailuresRemaining -= 1
            throw MenuBarBackendError.interrupted
        }
        return MenuBarMutationResult(
            generation: snapshot.generation,
            changedItemIDs: snapshot.items.map(\.id)
        )
    }

    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "Fake", state: .healthy)
    }

    func restart() async {
        restartCount += 1
        try? await Task.sleep(for: restartDelay)
    }
}

private func makeSnapshot(
    generation: UInt64,
    count: Int,
    menuTracking: Bool = false,
    display: MenuBarDisplayID = MenuBarDisplayID("test-display"),
    capturedAt: Date = Date()
) -> MenuBarSnapshot {
    MenuBarSnapshot(
        generation: generation,
        capturedAt: capturedAt,
        items: (0 ..< count).map { index in
            MenuBarItemDescriptor(
                id: MenuBarItemID(
                    bundleIdentifier: "com.example.item\(index)",
                    accessibilityIdentifier: "item-\(index)"
                ),
                section: .visible,
                order: index,
                displayID: display,
                isOnScreen: true
            )
        },
        displayIDs: [display],
        activeSpaceIsValid: true,
        menuTrackingIsActive: menuTracking
    )
}

private func makeProfileSnapshot(
    generation: UInt64,
    layout: ProfileLayout
) -> MenuBarSnapshot {
    let display = MenuBarDisplayID("test-display")
    let items = [
        (MenuBarSection.visible, layout.visible),
        (.hidden, layout.hidden),
        (.alwaysHidden, layout.alwaysHidden),
    ].flatMap { section, itemIDs in
        itemIDs.enumerated().map { index, itemID in
            MenuBarItemDescriptor(
                id: itemID,
                section: section,
                order: index,
                displayID: display,
                isOnScreen: section == .visible
            )
        }
    }
    return MenuBarSnapshot(
        generation: generation,
        capturedAt: Date(),
        items: items,
        displayIDs: [display],
        activeSpaceIsValid: true
    )
}

private extension UUID {
    init(_ suffix: UInt8) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }
}
