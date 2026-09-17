import BarlineCore
import CoreGraphics
import Foundation
import OSLog

actor TahoeMenuBarBackend: MenuBarBackend {
    private let client: WindowServerClient
    private var capabilityCache = MenuBarCapabilityProbeCache()

    var capabilities: MenuBarCapabilities {
        capabilityCache.resolve(at: DispatchTime.now().uptimeNanoseconds) {
            let canSnapshot = client.behavioralProbe()
            let canSynthesize = canSnapshot && client.eventSynthesisProbe()
            return MenuBarCapabilities(
                canSnapshot: canSnapshot,
                canMove: canSynthesize,
                canReveal: canSynthesize,
                canActivate: canSynthesize,
                canRestore: canSynthesize,
                canCapture: canSnapshot,
                arrangement: MenuBarArrangementCapabilities(
                    canReorderNativeItems: canSynthesize,
                    visibilityAssignmentGranularity: canSynthesize ? .item : .unavailable,
                    canReorderShelfItems: true,
                    canApplySavedNativeOrder: canSynthesize
                )
            )
        }
    }

    init(client: WindowServerClient) {
        self.client = client
    }

    func snapshot() throws -> MenuBarSnapshot {
        guard capabilities.canSnapshot else {
            throw MenuBarBackendError.unavailableCapability("Tahoe snapshot")
        }
        return try client.snapshot()
    }

    func move(_ operation: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
        try await client.move(operation)
    }

    func reveal(_ item: MenuBarItemID) async throws -> MenuBarMutationResult {
        try await client.reveal(item)
    }

    func activate(_ item: MenuBarItemID, button: MenuBarMouseButton) async throws {
        try await client.activate(item, button: button)
    }

    func capture(_ items: [MenuBarItemID]) throws -> [MenuBarCapturedImage] {
        try client.capture(items)
    }

    func captureBackground(
        displayID: UInt32,
        sampleHeight: Double?
    ) throws -> MenuBarBackgroundCapture {
        try client.captureBackground(displayID: displayID, sampleHeight: sampleHeight)
    }

    func environment() -> MenuBarEnvironmentSnapshot {
        client.environment()
    }

    func pointContext(_ point: MenuBarPoint) throws -> MenuBarPointContext {
        try client.pointContext(point)
    }

    func beginRevealObservation(_ item: MenuBarItemID) throws -> MenuBarRevealObservationToken {
        try client.beginRevealObservation(item)
    }

    func revealObservationIsVisible(_ token: MenuBarRevealObservationToken) -> Bool {
        client.revealObservationIsVisible(token)
    }

    func endRevealObservation(_ token: MenuBarRevealObservationToken) {
        client.endRevealObservation(token)
    }

    func restore(_ snapshot: MenuBarSnapshot) async throws -> MenuBarMutationResult {
        try await client.restore(snapshot)
    }

    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(
            backendName: "Tahoe",
            state: capabilities.canSnapshot ? .healthy : .unavailable,
            message: capabilities.canSnapshot ? nil : "Required WindowServer probes failed"
        )
    }

    func restart() {}
}

@available(macOS 27.0, *)
actor GoldenGateMenuBarBackend: MenuBarBackend {
    private let client: WindowServerClient
    private let concealmentController = GoldenGateConcealmentController()
    private var revealObservations = TemporaryRevealObservationRegistry()
    private var restorationTasks = [MenuBarRevealObservationToken: Task<Void, Never>]()
    private var restartTask: Task<Void, Never>?
    private var capabilityCache = MenuBarCapabilityProbeCache()
    private let logger = Logger(category: "GoldenGateMenuBarBackend")

    var capabilities: MenuBarCapabilities {
        capabilityCache.resolve(at: DispatchTime.now().uptimeNanoseconds) {
            let canSnapshot = client.goldenGateBehavioralProbe()
            let canSynthesizeInput = client.eventSynthesisProbe()
            let canConceal = concealmentController.isAvailable
            let canActivate = canSnapshot && canConceal && canSynthesizeInput
            return MenuBarCapabilities(
                canSnapshot: canSnapshot,
                canMove: canSnapshot && canConceal && canSynthesizeInput,
                // Golden Gate supports the app's guarded click flow by widening
                // the native allowlist around activation. It still cannot honor
                // the public mutation-style `reveal` contract.
                canReveal: false,
                canActivate: canActivate,
                canRestore: false,
                canCapture: false,
                arrangement: MenuBarArrangementCapabilities(
                    // Native status-item dragging is deliberately outside the
                    // macOS 27 release boundary. Visibility uses the native
                    // assessment API; physical ordering remains user-owned.
                    canReorderNativeItems: false,
                    visibilityAssignmentGranularity: canConceal
                        ? .applicationGroupAndKnownSystemItem
                        : .unavailable,
                    canReorderShelfItems: true,
                    canApplySavedNativeOrder: false
                )
            )
        }
    }

    init(client: WindowServerClient) {
        self.client = client
    }

    func snapshot() throws -> MenuBarSnapshot {
        guard capabilities.canSnapshot else {
            throw MenuBarBackendError.unavailableCapability("Golden Gate snapshot")
        }
        return try client.goldenGateSnapshot()
    }

    func move(_: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("Golden Gate move")
    }

    func reveal(_: MenuBarItemID) async throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("Golden Gate reveal")
    }

    func activate(_ item: MenuBarItemID, button: MenuBarMouseButton) async throws {
        try await Task.sleep(for: .milliseconds(100))
        try await client.activateGoldenGate(item, button: button)
    }

    func capture(_: [MenuBarItemID]) throws -> [MenuBarCapturedImage] {
        throw MenuBarBackendError.unavailableCapability("Golden Gate item capture")
    }

    func captureBackground(
        displayID: UInt32,
        sampleHeight: Double?
    ) throws -> MenuBarBackgroundCapture {
        try client.captureBackground(displayID: displayID, sampleHeight: sampleHeight)
    }

    func environment() -> MenuBarEnvironmentSnapshot {
        client.environment()
    }

    func pointContext(_ point: MenuBarPoint) throws -> MenuBarPointContext {
        try client.pointContext(point)
    }

    func beginRevealObservation(
        _ item: MenuBarItemID
    ) async throws -> MenuBarRevealObservationToken {
        guard revealObservations.canAdmitOperations else { throw MenuBarBackendError.interrupted }
        let lifecycleEpoch = revealObservations.lifecycleEpoch
        var didRevealNatively = false
        do {
            // Native concealment can remove a hidden item from the AX tree.
            // Reveal by stable identity first, then bind observation and click
            // delivery only after fresh owner/geometry resolution succeeds.
            didRevealNatively = try await concealmentController.beginTemporaryReveal(item)
            let resolved = try await resolveAfterNativeReveal(item)
            let token = client.beginRevealObservation(sourcePID: resolved.ownerPID)
            if didRevealNatively {
                guard revealObservations.register(token, item: item, at: lifecycleEpoch) else {
                    client.endRevealObservation(token)
                    throw MenuBarBackendError.interrupted
                }
            }
            return token
        } catch {
            if didRevealNatively, lifecycleEpoch == revealObservations.lifecycleEpoch {
                let recoveryToken = MenuBarRevealObservationToken()
                _ = revealObservations.register(recoveryToken, item: item, at: lifecycleEpoch)
                if await !restoreObservation(recoveryToken) {
                    scheduleRestoration(for: recoveryToken)
                }
            }
            throw error
        }
    }

    func revealObservationIsVisible(_ token: MenuBarRevealObservationToken) -> Bool {
        client.revealObservationIsVisible(token)
    }

    func endRevealObservation(_ token: MenuBarRevealObservationToken) async {
        client.endRevealObservation(token)
        if await !restoreObservation(token) {
            scheduleRestoration(for: token)
        }
    }

    func configureConcealment(_ configuration: MenuBarConcealmentConfiguration) async throws {
        guard revealObservations.canAdmitOperations else { throw MenuBarBackendError.interrupted }
        try await concealmentController.configure(configuration)
    }

    func nativeDrag(
        _: MenuBarNativeDragTransaction
    ) async throws -> MenuBarNativeDragReceipt {
        throw MenuBarBackendError.unavailableCapability("Golden Gate native menu bar reorder")
    }

    func restore(_: MenuBarSnapshot) async throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("Golden Gate restore")
    }

    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(
            backendName: "GoldenGate",
            state: capabilities.canSnapshot ? .healthy : .unavailable,
            message: capabilities.canSnapshot ? nil : "Required WindowServer probes failed"
        )
    }

    func restart() async {
        if let restartTask {
            await restartTask.value
            return
        }
        guard revealObservations.beginRestart() else { return }
        restorationTasks.values.forEach { $0.cancel() }
        restorationTasks.removeAll()
        let task = Task { await concealmentController.invalidate() }
        restartTask = task
        await task.value
        restartTask = nil
        revealObservations.finishRestart()
    }

    private func resolveAfterNativeReveal(
        _ item: MenuBarItemID
    ) async throws -> GoldenGateAXInventory.ResolvedItem {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            try Task.checkCancellation()
            if let resolved = try? GoldenGateAXInventory.resolve(item) {
                return resolved
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw MenuBarBackendError.timedOut
    }

    private func restoreObservation(_ token: MenuBarRevealObservationToken) async -> Bool {
        guard let reservation = revealObservations.reserve(token) else { return true }
        do {
            try await concealmentController.endTemporaryReveal(reservation.item)
            restorationTasks[token]?.cancel()
            restorationTasks[token] = nil
            return true
        } catch {
            _ = revealObservations.restoreFailed(reservation)
            logger.error("Golden Gate temporary reveal restoration deferred")
            return false
        }
    }

    private func scheduleRestoration(for token: MenuBarRevealObservationToken) {
        guard restorationTasks[token] == nil else { return }
        restorationTasks[token] = Task { [weak self] in
            var delay = Duration.milliseconds(250)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if await restoreObservation(token) {
                    return
                }
                delay = min(delay * 2, .seconds(5))
            }
        }
    }
}

actor FallbackMenuBarBackend: MenuBarBackend {
    let capabilities = MenuBarCapabilities.fallback

    func snapshot() throws -> MenuBarSnapshot {
        throw MenuBarBackendError.unavailableCapability("menu bar snapshot")
    }

    func move(_: MenuBarMoveOperation) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("move")
    }

    func reveal(_: MenuBarItemID) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("reveal")
    }

    func activate(_: MenuBarItemID, button _: MenuBarMouseButton) throws {
        throw MenuBarBackendError.unavailableCapability("activate")
    }

    func capture(_: [MenuBarItemID]) throws -> [MenuBarCapturedImage] {
        throw MenuBarBackendError.unavailableCapability("capture")
    }

    func captureBackground(
        displayID _: UInt32,
        sampleHeight _: Double?
    ) throws -> MenuBarBackgroundCapture {
        throw MenuBarBackendError.unavailableCapability("background capture")
    }

    func restore(_: MenuBarSnapshot) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("restore")
    }

    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(
            backendName: "Fallback",
            state: .unavailable,
            message: "Private compatibility probes are unavailable; safe native features remain accessible"
        )
    }

    func restart() {}
}

enum MenuBarBackendFactory {
    static func make() -> any MenuBarBackend {
        let client = WindowServerClient()

        // Selection is gated by live behavior first. The OS check only
        // determines which implementation gets first opportunity to probe.
        if #available(macOS 27.0, *) {
            // Keep the versioned backend even before permission is granted so
            // a later authorized request can recover without falling back to
            // the retired per-window inventory.
            return GoldenGateMenuBarBackend(client: client)
        }

        // A failed startup observation may mean the session is locked, not an
        // unsupported API. Retain a probe-gated backend so later requests can
        // recover; no capability becomes available until its live probe passes.
        return TahoeMenuBarBackend(client: client)
    }
}
