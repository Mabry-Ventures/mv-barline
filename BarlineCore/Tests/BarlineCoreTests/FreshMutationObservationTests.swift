@testable import BarlineCore
import Foundation
import Testing

@Suite("Fresh mutation observations")
struct FreshMutationObservationTests {
    @Test("A cached successful-looking move cannot publish unchanged native state")
    func rejectsCachedMoveSuccess() async throws {
        let backend = CachedMutationBackend(stallsMoves: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        await #expect(throws: MenuBarBackendError.operationFailed("menu bar move did not reach requested section")) {
            try await coordinator.perform(.move(MenuBarMoveOperation(
                itemID: backend.itemID, section: .hidden, index: 0
            )))
        }
        #expect(await backend.freshObservationCount == 2)
        #expect(await backend.restoreCount == 1)
        #expect(await coordinator.currentSnapshot?.items.first?.section == .visible)
        #expect(await coordinator.canUndo == false)
    }

    @Test("Undo cannot verify a stalled restore against its cached proposed target")
    func rejectsCachedHistoryRestore() async throws {
        let backend = CachedMutationBackend(stallsRestores: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.perform(.move(MenuBarMoveOperation(
            itemID: backend.itemID, section: .hidden, index: 0
        )))
        #expect(await coordinator.canUndo)
        await #expect(throws: MenuBarBackendError.operationFailed("history restore did not reach requested layout")) {
            try await coordinator.undo()
        }
        #expect(await coordinator.currentSnapshot?.items.first?.section == .hidden)
        #expect(await coordinator.canUndo)
        #expect(await backend.restoreCount == 2)
        #expect(await backend.freshObservationCount == 3)
    }

    @Test("Restart recovery cannot publish a cached restore proposal")
    func rejectsCachedRestartRestore() async throws {
        let backend = CachedMutationBackend(stallsRestores: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        await backend.changeNativeSection(to: .hidden)
        await #expect(throws: MenuBarBackendError.operationFailed("history restore did not reach requested layout")) {
            try await coordinator.recover()
        }
        #expect(await coordinator.currentSnapshot == nil)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await backend.freshObservationCount == 1)
        #expect(await backend.restoreCount == 1)
    }
}

/// Ordinary reads deliberately expose an optimistic cached proposal. Only the
/// verification operation samples native state, modeling a caching adapter.
private actor CachedMutationBackend: MenuBarBackend {
    nonisolated let itemID = MenuBarItemID(bundleIdentifier: "com.example.fixture", accessibilityIdentifier: "item")
    let capabilities = MenuBarCapabilities(
        canSnapshot: true, canMove: true, canReveal: false, canActivate: true, canRestore: true,
        moveDestinationSupport: .emptySectionAllowed
    )
    private let displayID = MenuBarDisplayID("fixture-display")
    private let stallsMoves: Bool
    private let stallsRestores: Bool
    private var nativeSection = MenuBarSection.visible
    private var cachedSection = MenuBarSection.visible
    private var generation: UInt64 = 0
    private(set) var freshObservationCount = 0
    private(set) var restoreCount = 0

    init(stallsMoves: Bool = false, stallsRestores: Bool = false) {
        self.stallsMoves = stallsMoves
        self.stallsRestores = stallsRestores
    }

    func snapshot() -> MenuBarSnapshot {
        observation(section: cachedSection)
    }

    func snapshotForVerification() -> MenuBarSnapshot {
        freshObservationCount += 1
        return observation(section: nativeSection)
    }

    private func observation(section: MenuBarSection) -> MenuBarSnapshot {
        generation += 1
        return MenuBarSnapshot(
            generation: generation, capturedAt: Date(),
            items: [MenuBarItemDescriptor(id: itemID, section: section, order: 0, displayID: displayID)],
            displayIDs: [displayID], activeSpaceIsValid: true
        )
    }

    func changeNativeSection(to section: MenuBarSection) {
        nativeSection = section
    }

    func move(_ operation: MenuBarMoveOperation) -> MenuBarMutationResult {
        cachedSection = operation.section
        if !stallsMoves {
            nativeSection = operation.section
        }
        return MenuBarMutationResult(generation: generation, changedItemIDs: [itemID])
    }

    func restore(_ snapshot: MenuBarSnapshot) throws -> MenuBarMutationResult {
        restoreCount += 1
        guard let section = snapshot.items.first?.section else {
            throw MenuBarBackendError.mutationNotStarted
        }
        cachedSection = section
        if !stallsRestores {
            nativeSection = section
        }
        return MenuBarMutationResult(generation: generation, changedItemIDs: [itemID])
    }

    func reveal(_: MenuBarItemID) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("reveal")
    }

    func activate(_: MenuBarItemID, button _: MenuBarMouseButton) {}
    func restart() {}
    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "CachedFixture", state: .healthy)
    }
}
