@_spi(BarlinePlatformPresence) @testable import BarlineCore
import Foundation
import Testing

@Suite("Qualified native reveal activation")
struct MenuBarObservedActivationTests {
    @Test("The old reveal-before-refresh sequence cannot mint transient layout authority")
    func transientRefreshRemainsRejected() async throws {
        let backend = ObservedActivationBackend()
        let coordinator = Self.coordinator(backend)
        _ = try await coordinator.refresh()
        let token = await backend.beginRevealObservation(MenuBarAuthorityObservationTests.item)
        await #expect(throws: MenuBarBackendError.unavailableCapability("associated macOS 27 Focus presence")) {
            _ = try await coordinator.refresh()
        }
        #expect(await backend.activations.isEmpty)
        await backend.endRevealObservation(token)
    }

    @Test("Hidden native activation validates before reveal and delivers exactly once", arguments: [MenuBarMouseButton.left, .right])
    func hiddenActivation(_ button: MenuBarMouseButton) async throws {
        let backend = ObservedActivationBackend()
        let coordinator = Self.coordinator(backend)
        let initial = try await coordinator.refresh()
        let token = try await coordinator.withItemInteraction { interaction in
            try await coordinator.activateItemWithRevealObservation(
                MenuBarAuthorityObservationTests.item, button: button,
                expectedGeneration: initial.generation, interactionID: interaction
            )
        }
        #expect(await backend.activations == [button])
        #expect(await backend.calls == ["scan", "scan", "environment", "reveal", "environment", "activate"])
        #expect(await backend.ends == 0)
        #expect(await coordinator.canUndo == false)
        #expect(await coordinator.canRedo == false)
        let accepted = await coordinator.lastKnownGoodSnapshot
        #expect(accepted?.items.first?.section == .hidden)
        // While the returned token owns a temporary reveal, ordinary mutation
        // admission remains strict and no transient scan can replace authority.
        await #expect(throws: MenuBarBackendError.unavailableCapability("associated macOS 27 Focus presence")) {
            _ = try await coordinator.perform(.move(.init(
                itemID: MenuBarAuthorityObservationTests.item, section: .visible, index: 0
            )))
        }
        #expect(await backend.moves == 0)
        #expect(await coordinator.lastKnownGoodSnapshot == accepted)
        await backend.endRevealObservation(token)
        #expect(await backend.ends == 1)
        _ = try await coordinator.refresh()
    }

    @Test("Reveal failures never deliver input and clean up the admitted token", arguments: ObservedActivationBackend.Fault.allCases)
    private func rejectsChangedReveal(_ fault: ObservedActivationBackend.Fault) async throws {
        let backend = ObservedActivationBackend(fault: fault)
        let coordinator = Self.coordinator(backend)
        let initial = try await coordinator.refresh()
        let task = Task {
            try await coordinator.withItemInteraction { interaction in
                try await coordinator.activateItemWithRevealObservation(
                    MenuBarAuthorityObservationTests.item, button: .left,
                    expectedGeneration: initial.generation, interactionID: interaction
                )
            }
        }
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(await backend.activations.isEmpty)
        #expect(await backend.ends == 1)
        #expect(await backend.moves == 0)
        #expect(await coordinator.canUndo == false)
        #expect(await coordinator.lastKnownGoodSnapshot?.items.first?.section == .hidden)
    }

    @Test("Expired generation fails before a reveal is admitted")
    func staleGenerationDoesNotReveal() async throws {
        let backend = ObservedActivationBackend()
        let coordinator = Self.coordinator(backend)
        _ = try await coordinator.refresh()
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.withItemInteraction { interaction in
                try await coordinator.activateItemWithRevealObservation(
                    MenuBarAuthorityObservationTests.item, button: .left,
                    expectedGeneration: 0, interactionID: interaction
                )
            }
        }
        #expect(await backend.calls == ["scan"])
        #expect(await backend.ends == 0)
    }

    private static func coordinator(_ backend: ObservedActivationBackend) -> MenuBarStateCoordinator {
        MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelay: .zero, maximumDelay: .zero)
        )
    }
}

private actor ObservedActivationBackend: MenuBarBackend {
    enum Fault: CaseIterable, Sendable {
        case space, fullscreen, menuTracking, session, configuration, unknown, cancellation, delivery
    }

    let capabilities = MenuBarCapabilities.fallback
    private let session = UUID()
    private let fault: Fault?
    private var generation: UInt64 = 0
    private var revealed = false
    private(set) var calls: [String] = []
    private(set) var activations: [MenuBarMouseButton] = []
    private(set) var ends = 0
    private(set) var moves = 0

    init(fault: Fault? = nil) {
        self.fault = fault
    }

    private func receipt() -> NativeConcealmentReceipt {
        NativeConcealmentReceipt(
            helperSessionID: revealed && fault == .session ? UUID() : session,
            assertionRevision: revealed ? 2 : 1,
            configurationRevision: revealed && fault == .configuration ? 2 : 1,
            configurationDigest: String(repeating: "a", count: 64),
            effectiveStateDigest: String(repeating: revealed ? "c" : "b", count: 64),
            phase: revealed ? (fault == .unknown ? .unknown : .transient) : .asserted
        )
    }

    func environment() -> MenuBarEnvironmentSnapshot {
        calls.append("environment")
        return MenuBarEnvironmentSnapshot(
            activeDisplayID: 1,
            activeStableDisplayID: MenuBarAuthorityObservationTests.display,
            activeSpaceToken: revealed && fault == .space ? 2 : 1,
            activeSpaceIsFullscreen: revealed && fault == .fullscreen,
            menuTrackingIsActive: revealed && fault == .menuTracking,
            nativeConcealmentReceipt: receipt()
        )
    }

    func snapshot() throws -> MenuBarSnapshot {
        try authorityObservation(freshness: .freshRequired).snapshot
    }

    func authorityObservation(freshness _: MenuBarObservationFreshness) throws -> MenuBarAuthorityObservation {
        calls.append("scan")
        guard !revealed else {
            throw MenuBarBackendError.unavailableCapability("associated macOS 27 Focus presence")
        }
        generation += 1
        let snapshot = MenuBarAuthorityObservationTests.snapshot(generation: generation, section: .hidden)
        let scene = MenuBarAuthorityObservationTests.environment(receipt())
        let scanID = UUID()
        return MenuBarAuthorityObservation(snapshot: snapshot, scan: MenuBarObservationScan(
            scanID: scanID, startedAtUptimeNanoseconds: 1, completedAtUptimeNanoseconds: 30,
            observedSnapshot: snapshot, initialEnvironment: scene, finalEnvironment: scene,
            platformPresenceObservation: MenuBarAuthorityObservationTests.nativePresence(scanID: scanID, focus: .absent)
        ))
    }

    func beginRevealObservation(_: MenuBarItemID) async -> MenuBarRevealObservationToken {
        calls.append("reveal")
        revealed = true
        if fault == .cancellation {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return MenuBarRevealObservationToken()
    }

    func endRevealObservation(_: MenuBarRevealObservationToken) async {
        calls.append("end")
        ends += 1
        revealed = false
    }

    func activate(_: MenuBarItemID, button: MenuBarMouseButton) throws {
        calls.append("activate")
        if fault == .delivery {
            throw MenuBarBackendError.interrupted
        }
        activations.append(button)
    }

    func move(_: MenuBarMoveOperation) throws -> MenuBarMutationResult {
        moves += 1
        throw MenuBarBackendError.mutationNotStarted
    }

    func reveal(_: MenuBarItemID) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func restore(_: MenuBarSnapshot) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func restart() {}
    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "ObservedActivation", state: .healthy)
    }
}
