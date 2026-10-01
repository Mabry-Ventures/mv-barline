//
//  MenuBarAuthorityObservationTests.swift
//  Barline
//

@testable import BarlineCore
import Foundation
import Testing

@Suite("Atomic runtime observation envelopes")
struct MenuBarAuthorityObservationTests {
    static let display = MenuBarDisplayID("observation-fixture")
    static let item = MenuBarItemID(bundleIdentifier: "com.example.fixture", accessibilityIdentifier: "item")

    static func snapshot(generation: UInt64 = 1, section: MenuBarSection = .visible, time: Date = Date()) -> MenuBarSnapshot {
        MenuBarSnapshot(
            generation: generation, capturedAt: time,
            items: [MenuBarItemDescriptor(id: item, section: section, order: 0, displayID: display)],
            displayIDs: [display], activeSpaceIsValid: true
        )
    }

    static func receipt(session: UUID = UUID(), phase: NativeConcealmentReceipt.Phase = .deasserted) -> NativeConcealmentReceipt {
        NativeConcealmentReceipt(
            helperSessionID: session, assertionRevision: 1, configurationRevision: 1,
            configurationDigest: String(repeating: "a", count: 64), effectiveStateDigest: String(repeating: "b", count: 64), phase: phase
        )
    }

    static func environment(_ receipt: NativeConcealmentReceipt?, space: Int = 1, tracking: Bool = false,
                            display: MenuBarDisplayID = display) -> MenuBarEnvironmentSnapshot
    {
        MenuBarEnvironmentSnapshot(
            activeDisplayID: 1, activeStableDisplayID: display, activeSpaceToken: space,
            activeSpaceIsFullscreen: false, menuTrackingIsActive: tracking, nativeConcealmentReceipt: receipt
        )
    }

    static func scan(_ snapshot: MenuBarSnapshot, id: UUID = UUID(), start: UInt64 = 1, end: UInt64 = 2,
                     initial: MenuBarEnvironmentSnapshot? = nil, final: MenuBarEnvironmentSnapshot? = nil) -> MenuBarObservationScan
    {
        let scene = environment(receipt())
        return MenuBarObservationScan(
            scanID: id, startedAtUptimeNanoseconds: start, completedAtUptimeNanoseconds: end,
            observedSnapshot: snapshot, initialEnvironment: initial ?? scene, finalEnvironment: final ?? initial ?? scene
        )
    }

    @Test("Generation rebasing preserves the actual scan, inventory and observation time")
    func rebasePreservesScan() {
        let raw = Self.snapshot()
        let context = Self.scan(raw)
        let envelope = MenuBarAuthorityObservation(snapshot: raw, scan: context)
        let rebased = envelope.rebasingGeneration(to: 100)
        #expect(rebased.snapshot.generation == 100)
        #expect(rebased.snapshot.items == raw.items)
        #expect(rebased.snapshot.capturedAt == raw.capturedAt)
        #expect(rebased.scan == context)
        #expect(rebased.scan?.observedSnapshot.generation == 1)
    }

    @Test("Changed native receipt, scene or tracking state never inherits context")
    func rejectsUnstableScope() {
        let raw = Self.snapshot()
        let receipt = Self.receipt()
        let initial = Self.environment(receipt)
        let finals = [
            Self.environment(Self.receipt()),
            Self.environment(receipt, space: 2),
            Self.environment(receipt, tracking: true),
            Self.environment(receipt, display: MenuBarDisplayID("elsewhere")),
            Self.environment(nil),
        ]
        for final in finals {
            #expect(MenuBarAuthorityObservation(snapshot: raw, scan: Self.scan(raw, initial: initial, final: final)).scan == nil)
        }
        for phase in [NativeConcealmentReceipt.Phase.transient, .unknown] {
            let scene = Self.environment(Self.receipt(phase: phase))
            #expect(MenuBarAuthorityObservation(snapshot: raw, scan: Self.scan(raw, initial: scene)).scan == nil)
        }
        #expect(MenuBarAuthorityObservation(snapshot: raw, scan: Self.scan(raw, start: 0)).scan == nil)
        #expect(MenuBarAuthorityObservation(snapshot: raw, scan: Self.scan(raw, start: 3, end: 2)).scan == nil)
    }

    @Test("A scan cannot be attached to changed layout, captured time or safety fields")
    func rejectsDifferentSnapshotAssociation() {
        let raw = Self.snapshot()
        let context = Self.scan(raw)
        let different = [
            Self.snapshot(section: .hidden, time: raw.capturedAt),
            Self.snapshot(time: raw.capturedAt.addingTimeInterval(1)),
            MenuBarSnapshot(generation: 1, capturedAt: raw.capturedAt, items: [], displayIDs: raw.displayIDs, activeSpaceIsValid: true),
            MenuBarSnapshot(generation: 1, capturedAt: raw.capturedAt, items: raw.items, displayIDs: raw.displayIDs,
                            activeSpaceIsValid: true, menuTrackingIsActive: true),
            MenuBarSnapshot(generation: 1, capturedAt: raw.capturedAt, items: raw.items, displayIDs: raw.displayIDs,
                            activeSpaceIsValid: false),
        ]
        for snapshot in different {
            #expect(MenuBarAuthorityObservation(snapshot: snapshot, scan: context).scan == nil)
        }
    }

    @Test("Runtime envelope and context are non-Codable; snapshot schema does not gain trust")
    func persistenceCannotReconstructContext() throws {
        let raw = Self.snapshot()
        let context = Self.scan(raw)
        let envelope = MenuBarAuthorityObservation(snapshot: raw, scan: context)
        #expect(!((envelope as Any) is any Encodable))
        #expect(!((context as Any) is any Encodable))
        let encoded = try JSONEncoder().encode(raw)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("scanID"))
        let decoded = try JSONDecoder().decode(MenuBarSnapshot.self, from: encoded)
        #expect(MenuBarAuthorityObservation(snapshot: decoded).scan == nil)
        #expect(decoded == raw)
    }

    @Test("Protocol default dynamically dispatches ordinary/fresh operations and supplies no context")
    func legacyDefaultDispatch() async throws {
        let legacy = LegacyObservationBackend()
        let backend: any MenuBarBackend = legacy
        #expect(try await backend.authorityObservation(freshness: .cachedAllowed).scan == nil)
        #expect(try await backend.authorityObservation(freshness: .freshRequired).scan == nil)
        #expect(await legacy.ordinaryCalls == 1)
        #expect(await legacy.freshCalls == 1)
    }

    @Test("Refresh admits an atomic override, while bare move publication clears context")
    func overrideAndConservativeMovePublication() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        let observed = await coordinator.currentAuthorityObservation
        #expect(observed?.scan != nil)
        #expect(await observed?.snapshot == (coordinator.currentSnapshot))
        #expect(await backend.observationCalls == 1)
        _ = try await coordinator.perform(.move(MenuBarMoveOperation(itemID: Self.item, section: .hidden, index: 0)))
        #expect(await coordinator.currentSnapshot?.items.first?.section == .hidden)
        #expect(await coordinator.currentAuthorityObservation == nil)
        #expect(await backend.freshCalls > 0)
    }

    @Test("Restart revokes old context; checked generation normalization preserves the new scan")
    func restartRebaseAndCacheIdentity() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        let before = await coordinator.currentAuthorityObservation
        _ = try await coordinator.recover()
        let recovered = await coordinator.currentAuthorityObservation
        #expect(recovered?.scan != nil)
        #expect(recovered?.scan?.scanID != before?.scan?.scanID)
        #expect(recovered?.scan?.initialEnvironment.nativeConcealmentReceipt?.helperSessionID !=
            before?.scan?.initialEnvironment.nativeConcealmentReceipt?.helperSessionID)
        #expect(recovered?.snapshot.generation == 2)
        #expect(recovered?.scan?.observedSnapshot.generation == 1)
        _ = try await coordinator.refresh()
        let cached = await coordinator.currentAuthorityObservation
        #expect(cached?.snapshot.generation == 3)
        #expect(cached?.scan == recovered?.scan)
    }

    @Test("An empty response with context still fails strict snapshot validation")
    func contextDoesNotExemptMissingInventory() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend, retryPolicy: RetryPolicy(maximumAttempts: 1))
        let baseline = try await coordinator.refresh()
        await backend.dropInventory()
        await #expect(throws: MenuBarBackendError.invalidSnapshot(.emptySnapshot)) {
            try await coordinator.refresh()
        }
        #expect(await coordinator.currentSnapshot == baseline)
        #expect(await coordinator.currentAuthorityObservation?.snapshot == baseline)
    }

    @Test("A failed restart observation leaves no old runtime context")
    func failedRestartRevokesContext() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        #expect(await coordinator.currentAuthorityObservation?.scan != nil)
        await backend.failObservations()
        await #expect(throws: MenuBarBackendError.operationFailed("fixture observation failed")) {
            try await coordinator.recover()
        }
        #expect(await coordinator.currentAuthorityObservation == nil)
        #expect(await coordinator.currentSnapshot == nil)
    }

    @Test("Generation overflow cannot publish a newly supplied runtime context")
    func generationOverflowDoesNotPublish() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        _ = try await coordinator.recover()
        let before = await coordinator.currentAuthorityObservation
        await backend.forceGeneration(UInt64.max)
        await #expect(throws: MenuBarBackendError.operationFailed("helper generation normalization overflow")) {
            try await coordinator.refresh()
        }
        #expect(await coordinator.currentAuthorityObservation == before)
        #expect(await coordinator.currentSnapshot == before?.snapshot)
    }
}

private actor LegacyObservationBackend: MenuBarBackend {
    let capabilities = MenuBarCapabilities.fallback
    private(set) var ordinaryCalls = 0
    private(set) var freshCalls = 0
    func snapshot() -> MenuBarSnapshot {
        ordinaryCalls += 1; return MenuBarAuthorityObservationTests.snapshot()
    }

    func snapshotForVerification() -> MenuBarSnapshot {
        freshCalls += 1; return MenuBarAuthorityObservationTests.snapshot()
    }

    func move(_: MenuBarMoveOperation) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func reveal(_: MenuBarItemID) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func activate(_: MenuBarItemID, button _: MenuBarMouseButton) {}
    func restore(_: MenuBarSnapshot) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "Legacy", state: .healthy)
    }

    func restart() {}
}

private actor AtomicObservationBackend: MenuBarBackend {
    let capabilities = MenuBarCapabilities(canSnapshot: true, canMove: true, canReveal: false, canActivate: true, canRestore: true,
                                           moveDestinationSupport: .emptySectionAllowed)
    private var generation: UInt64 = 0
    private var section = MenuBarSection.visible
    private var sessionID = UUID()
    private var cached: MenuBarAuthorityObservation?
    private var inventoryDropped = false
    private var observationFailure = false
    private var forcedGeneration: UInt64?
    private(set) var observationCalls = 0
    private(set) var freshCalls = 0
    func snapshot() throws -> MenuBarSnapshot {
        throw MenuBarBackendError.operationFailed("legacy path unexpectedly called")
    }

    func snapshotForVerification() throws -> MenuBarSnapshot {
        throw MenuBarBackendError.operationFailed("legacy fresh path unexpectedly called")
    }

    func authorityObservation(freshness: MenuBarObservationFreshness) throws -> MenuBarAuthorityObservation {
        guard !observationFailure else { throw MenuBarBackendError.operationFailed("fixture observation failed") }
        observationCalls += 1
        if let forcedGeneration {
            generation = forcedGeneration
        } else {
            generation += 1
        }
        if freshness == .freshRequired {
            freshCalls += 1
        }
        if freshness == .cachedAllowed, let cached, !inventoryDropped {
            return cached.rebasingGeneration(to: generation)
        }
        var raw = MenuBarAuthorityObservationTests.snapshot(generation: generation, section: section)
        if inventoryDropped {
            raw = MenuBarSnapshot(generation: generation, capturedAt: raw.capturedAt, items: [], displayIDs: raw.displayIDs, activeSpaceIsValid: true)
        }
        let scene = MenuBarAuthorityObservationTests.environment(MenuBarAuthorityObservationTests.receipt(session: sessionID))
        let context = MenuBarAuthorityObservationTests.scan(raw, initial: scene)
        let observed = MenuBarAuthorityObservation(snapshot: raw, scan: context)
        cached = observed
        return observed
    }

    func dropInventory() {
        inventoryDropped = true
    }

    func failObservations() {
        observationFailure = true
    }

    func forceGeneration(_ value: UInt64) {
        forcedGeneration = value; cached = nil
    }

    func move(_ operation: MenuBarMoveOperation) -> MenuBarMutationResult {
        section = operation.section; cached = nil
        return MenuBarMutationResult(generation: generation, changedItemIDs: [operation.itemID])
    }

    func restore(_ snapshot: MenuBarSnapshot) -> MenuBarMutationResult {
        section = snapshot.items.first?.section ?? .visible; cached = nil
        return MenuBarMutationResult(generation: generation, changedItemIDs: [])
    }

    func reveal(_: MenuBarItemID) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func activate(_: MenuBarItemID, button _: MenuBarMouseButton) {}
    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "Atomic", state: .healthy)
    }

    func restart() {
        generation = 0; sessionID = UUID(); cached = nil
    }
}
