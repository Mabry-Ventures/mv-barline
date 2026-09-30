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
    // Access is serialized by transactionGate, including worker admission.
    private var recoveryLease = GoldenGateRecoveryLease()
    private var recoveryTask: Task<Void, Never>?

    init() {
        opaqueController = BLNGoldenGateAssessmentCreate()
    }

    deinit {
        recoveryTask?.cancel()
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
                cancelBackgroundRecovery()
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
            cancelBackgroundRecovery()
            logger.notice("Temporary reveal began: activeItemCount=\(candidateLedger.visibleItemIDs.count, privacy: .public)")
            return true
        }
    }

    func endTemporaryReveal(_ item: MenuBarItemID) async throws {
        try await transactionGate.withLock { [self] in
            guard let candidateLedger = temporaryRevealLedger.ending(item) else { return }
            try await applyCurrentState(temporaryRevealLedger: candidateLedger)
            temporaryRevealLedger = candidateLedger
            cancelBackgroundRecovery()
            logger.notice("Temporary reveal ended: activeItemCount=\(candidateLedger.visibleItemIDs.count, privacy: .public)")
        }
    }

    /// macOS 27 Assessment Mode, which provides native concealment, stops the
    /// clock from opening Notification Center even when the clock is allowed.
    /// Lift the committed assertion just long enough to press the clock, then
    /// re-apply the same state; Notification Center stays open once presented.
    /// Returns false without lifting anything when no assertion is held or the
    /// click is too old, so a native or superseded click is left alone.
    func pressSystemClockLiftingConcealment(
        deadlineUptimeNanoseconds: UInt64,
        isCurrent: @escaping @Sendable () -> Bool,
        _ press: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        try await transactionGate.withLock { [self] in
            guard !Task.isCancelled,
                  GoldenGateTiming.admitsClockPress(
                      now: DispatchTime.now().uptimeNanoseconds,
                      deadline: deadlineUptimeNanoseconds,
                      beforeLift: true
                  ),
                  controller(createIfNeeded: false) != nil,
                  let applied = appliedResolution,
                  !applied.concealedBundleIdentifiers.isEmpty ||
                  applied.allowedSystemItemIdentifiers != GoldenGateConcealmentPolicy.allSystemItemIdentifiers
            else { return false }
            let pressed = try await GoldenGateClockTransaction.run(
                deadline: deadlineUptimeNanoseconds,
                now: { DispatchTime.now().uptimeNanoseconds },
                isCurrent: isCurrent,
                lift: { [self] in
                    if let controller = controller(createIfNeeded: false) {
                        BLNGoldenGateAssessmentInvalidate(controller)
                    }
                    appliedResolution = nil
                },
                press: press,
                restore: { [self] in try await reapplyAfterLift() }
            )
            logger.notice("Clock pressed with concealment lifted: pressed=\(pressed, privacy: .public)")
            return pressed
        }
    }

    /// Bound cooperative activation work. The synchronous native Begin/Commit
    /// calls cannot be interrupted here; session cancellation remains the
    /// outer watchdog if the operating system stops responding.
    /// On failure, transfer remaining work to a lifecycle-owned worker instead
    /// of holding the foreground queue through four three-second attempts.
    private func reapplyAfterLift() async throws {
        do {
            try await applyCurrentState(timeout: GoldenGateTiming.clockRestoreBudget)
            cancelBackgroundRecovery()
        } catch {
            logger.error("Concealment re-apply after the clock press failed; scheduling recovery")
            scheduleBackgroundReapply()
            throw MenuBarBackendError.mutationRecoveryFailed
        }
    }

    private func scheduleBackgroundReapply() {
        cancelBackgroundRecovery()
        let lease = recoveryLease.begin()
        recoveryTask = Task.detached { [weak self] in
            for _ in 0 ..< 30 {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    let done = try await transactionGate.withLock { [self] in
                        guard recoveryLease.contains(lease), !Task.isCancelled else { return true }
                        try await applyCurrentState()
                        recoveryLease.invalidate()
                        recoveryTask = nil
                        return true
                    }
                    if done {
                        return
                    }
                } catch {
                    if Task.isCancelled {
                        return
                    }
                }
            }
            self?.logger.error("Concealment could not be restored after the clock press")
        }
    }

    private func cancelBackgroundRecovery() {
        recoveryLease.invalidate()
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    func invalidate() async {
        // Restart cleanup must complete even when its caller is cancelled.
        // Enqueue it behind any accepted state change without inheriting the
        // caller's cancellation state.
        await Task.detached { [self] in
            try? await transactionGate.withLock { [self] in
                cancelBackgroundRecovery()
                if let controller = controller(createIfNeeded: false) {
                    BLNGoldenGateAssessmentInvalidate(controller)
                }
                temporaryRevealLedger = TemporaryRevealLedger()
                appliedResolution = nil
                desiredConfiguration = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [])
            }
        }.value
    }

    private func applyCurrentState(
        temporaryRevealLedger: TemporaryRevealLedger? = nil,
        timeout: Duration = .seconds(3)
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
        let desiredVisibleCount = desiredConfiguration.visibleItemIDs.count
        let desiredHiddenCount = desiredConfiguration.concealedItemIDs.count
        logger.notice(
            "Concealment state: desiredVisible=\(desiredVisibleCount, privacy: .public) desiredHidden=\(desiredHiddenCount, privacy: .public) temporaryVisible=\(temporarilyVisible.count, privacy: .public) concealedBundles=\(resolved.concealedBundleIdentifiers.count, privacy: .public)"
        )
        // Assessment-mode assertions are stateful. Replacing a healthy
        // assertion with an identical one on every shelf click can be rejected
        // by macOS 27 and turns an otherwise-ready shelf into a silent no-op.
        // Keep the committed assertion when the effective allowlists have not
        // changed; real visibility changes still flow through the transactional
        // activate-then-commit path below.
        if appliedResolution == resolved {
            return
        }
        let bundles = resolved.concealedBundleIdentifiers.sorted() as CFArray
        let systemItems = resolved.allowedSystemItemIdentifiers.sorted().map(NSNumber.init) as CFArray
        // Synchronous bridge setup must consume the activation budget too.
        let deadline = ContinuousClock.now.advanced(by: timeout)
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
