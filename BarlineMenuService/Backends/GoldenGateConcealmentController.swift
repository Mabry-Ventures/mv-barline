import BarlineCore
import Foundation
import OSLog

@available(macOS 27.0, *)
final class GoldenGateConcealmentController: @unchecked Sendable {
    private let logger = Logger(category: "GoldenGateConcealmentController")
    private let transactionGate = AsyncExclusiveOperationGate()
    private let controllerLock = NSLock()
    private var opaqueController: UnsafeMutableRawPointer?
    private var desiredConfiguration = MenuBarConcealmentConfiguration(
        visibleItemIDs: [], concealedItemIDs: []
    )
    private var temporaryRevealLedger = TemporaryRevealLedger()
    private var appliedResolution: GoldenGateResolvedConcealment?

    init() {
        opaqueController = BLNGoldenGateAssessmentCreate()
    }

    deinit {
        controllerLock.lock()
        let controller = opaqueController
        opaqueController = nil
        controllerLock.unlock()
        if let controller {
            BLNGoldenGateAssessmentInvalidate(controller)
            BLNGoldenGateAssessmentDestroy(controller)
        }
    }

    var isAvailable: Bool {
        controller() != nil
    }

    func configure(_ configuration: MenuBarConcealmentConfiguration) async throws {
        try await transactionGate.withLock { [self] in
            let previousConfiguration = desiredConfiguration
            desiredConfiguration = configuration
            do {
                try await applyCurrentState()
            } catch {
                desiredConfiguration = previousConfiguration
                throw error
            }
        }
    }

    @discardableResult
    func beginTemporaryReveal(_ item: MenuBarItemID) async throws -> Bool {
        try await transactionGate.withLock { [self] in
            guard desiredConfiguration.concealedItemIDs.contains(item) else { return false }
            let candidateLedger = temporaryRevealLedger.beginning(item)
            try await applyCurrentState(temporaryRevealLedger: candidateLedger)
            temporaryRevealLedger = candidateLedger
            return true
        }
    }

    func endTemporaryReveal(_ item: MenuBarItemID) async throws {
        try await transactionGate.withLock { [self] in
            guard let candidateLedger = temporaryRevealLedger.ending(item) else { return }
            try await applyCurrentState(temporaryRevealLedger: candidateLedger)
            temporaryRevealLedger = candidateLedger
        }
    }

    func invalidate() async {
        // Restart cleanup must complete even when its caller is cancelled.
        // Enqueue it behind any accepted state change without inheriting the
        // caller's cancellation state.
        await Task.detached { [self] in
            try? await transactionGate.withLock { [self] in
                if let controller = controller(createIfNeeded: false) {
                    BLNGoldenGateAssessmentInvalidate(controller)
                }
                temporaryRevealLedger = TemporaryRevealLedger()
                appliedResolution = nil
            }
        }.value
    }

    private func applyCurrentState(
        temporaryRevealLedger: TemporaryRevealLedger? = nil
    ) async throws {
        guard let opaqueController = controller() else {
            throw MenuBarBackendError.unavailableCapability("Golden Gate native concealment")
        }
        let temporarilyVisible = (temporaryRevealLedger ?? self.temporaryRevealLedger).visibleItemIDs
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: desiredConfiguration.visibleItemIDs + temporarilyVisible,
            concealedItemIDs: desiredConfiguration.concealedItemIDs.filter {
                !temporarilyVisible.contains($0)
            }
        )
        let resolved = GoldenGateConcealmentPolicy.resolve(
            configuration,
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        let bundles = resolved.concealedBundleIdentifiers.sorted() as CFArray
        let systemItems = resolved.allowedSystemItemIdentifiers.sorted().map(NSNumber.init) as CFArray
        let transaction = BLNGoldenGateAssessmentBegin(opaqueController, bundles, systemItems)
        guard transaction != 0 else {
            throw MenuBarBackendError.unavailableCapability("Golden Gate native concealment")
        }
        var committed = false
        defer {
            if !committed {
                _ = BLNGoldenGateAssessmentAbort(opaqueController, transaction)
            }
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                switch BLNGoldenGateAssessmentActivationState(opaqueController, transaction) {
                case 1:
                    try Task.checkCancellation()
                    guard BLNGoldenGateAssessmentCommit(opaqueController, transaction) else {
                        throw MenuBarBackendError.interrupted
                    }
                    committed = true
                    appliedResolution = resolved
                    return
                case -1:
                    throw MenuBarBackendError.operationFailed(
                        "Golden Gate native concealment rejected"
                    )
                case -2:
                    throw MenuBarBackendError.interrupted
                default:
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            throw MenuBarBackendError.timedOut
        } catch {
            logger.error("Golden Gate assertion transaction aborted before commit")
            throw error
        }
    }

    /// Returns the retained bridge controller, retrying creation after a
    /// transient launch-time runtime miss. Access is synchronous because the
    /// backend capability probe is synchronous and may run outside the actor.
    private func controller(createIfNeeded: Bool = true) -> UnsafeMutableRawPointer? {
        controllerLock.lock()
        defer { controllerLock.unlock() }
        if opaqueController == nil, createIfNeeded {
            opaqueController = BLNGoldenGateAssessmentCreate()
        }
        return opaqueController
    }
}
