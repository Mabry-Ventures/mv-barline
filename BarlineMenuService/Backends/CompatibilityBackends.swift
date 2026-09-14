import BarlineCore
import Foundation

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
                canCapture: canSnapshot
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
    private var revealedItemsByObservation = [MenuBarRevealObservationToken: MenuBarItemID]()
    private var capabilityCache = MenuBarCapabilityProbeCache()

    var capabilities: MenuBarCapabilities {
        capabilityCache.resolve(at: DispatchTime.now().uptimeNanoseconds) {
            let canSnapshot = client.goldenGateBehavioralProbe()
            let canActivate = canSnapshot && concealmentController.isAvailable && client.eventSynthesisProbe()
            return MenuBarCapabilities(
                canSnapshot: canSnapshot,
                canMove: false,
                // Golden Gate supports the app's guarded click flow by widening
                // the native allowlist around activation. It still cannot honor
                // the public mutation-style `reveal` contract.
                canReveal: false,
                canActivate: canActivate,
                canRestore: false,
                canCapture: false
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

    func beginRevealObservation(_ item: MenuBarItemID) throws -> MenuBarRevealObservationToken {
        let resolved = try GoldenGateAXInventory.resolve(item)
        let token = client.beginRevealObservation(sourcePID: resolved.ownerPID)
        do {
            try concealmentController.beginTemporaryReveal(resolved.id)
            revealedItemsByObservation[token] = resolved.id
            return token
        } catch {
            client.endRevealObservation(token)
            throw error
        }
    }

    func revealObservationIsVisible(_ token: MenuBarRevealObservationToken) -> Bool {
        client.revealObservationIsVisible(token)
    }

    func endRevealObservation(_ token: MenuBarRevealObservationToken) {
        client.endRevealObservation(token)
        if let item = revealedItemsByObservation.removeValue(forKey: token) {
            concealmentController.endTemporaryReveal(item)
        }
    }

    func configureConcealment(_ configuration: MenuBarConcealmentConfiguration) throws {
        try concealmentController.configure(configuration)
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

    func restart() {
        concealmentController.invalidate()
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
