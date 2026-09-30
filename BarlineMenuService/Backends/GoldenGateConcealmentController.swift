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
            logger.notice("Temporary reveal began: activeItemCount=\(candidateLedger.visibleItemIDs.count, privacy: .public)")
            return true
        }
    }

    func endTemporaryReveal(_ item: MenuBarItemID) async throws {
        try await transactionGate.withLock { [self] in
            guard let candidateLedger = temporaryRevealLedger.ending(item) else { return }
            try await applyCurrentState(temporaryRevealLedger: candidateLedger)
            temporaryRevealLedger = candidateLedger
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
        _ press: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        try await transactionGate.withLock { [self] in
            guard !Task.isCancelled,
                  GoldenGateTiming.admitsClockPress(
                      now: DispatchTime.now().uptimeNanoseconds,
                      deadline: deadlineUptimeNanoseconds,
                      beforeLift: true
                  ),
                  let controller = controller(createIfNeeded: false),
                  let applied = appliedResolution,
                  !applied.concealedBundleIdentifiers.isEmpty ||
                  applied.allowedSystemItemIdentifiers != GoldenGateConcealmentPolicy.allSystemItemIdentifiers
            else { return false }
            BLNGoldenGateAssessmentInvalidate(controller)
            appliedResolution = nil
            // Give MenuBarAgent a moment to leave assessment mode.
            try? await Task.sleep(nanoseconds: GoldenGateTiming.clockLiftSettleNanoseconds)
            // A request may expire or be cancelled while assessment settles.
            // Once lifted, always restore concealment, including this path.
            let pressed = !Task.isCancelled && GoldenGateTiming.admitsClockPress(
                now: DispatchTime.now().uptimeNanoseconds,
                deadline: deadlineUptimeNanoseconds,
                beforeLift: false
            ) && press()
            // Let Notification Center begin presenting before concealment returns.
            if pressed {
                try? await Task.sleep(for: .milliseconds(150))
            }
            // Restoration is mandatory even when the requesting task was
            // cancelled. Keep the transaction gate held until it completes.
            try await Task.detached { [self] in
                try await reapplyAfterLift()
            }.value
            logger.notice("Clock pressed with concealment lifted: pressed=\(pressed, privacy: .public)")
            return pressed
        }
    }

    /// The lift must never become the authoritative state. Retry with backoff;
    /// if every attempt fails, keep retrying in the background until the
    /// desired state is applied or replaced by a newer configuration.
    private func reapplyAfterLift() async throws {
        for delay in [0, 100, 300, 700] {
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            do {
                try await applyCurrentState()
                return
            } catch {
                logger.error("Concealment re-apply after the clock press failed; retrying")
            }
        }
        scheduleBackgroundReapply()
        throw MenuBarBackendError.mutationRecoveryFailed
    }

    private func scheduleBackgroundReapply() {
        Task.detached { [self] in
            for _ in 0 ..< 30 {
                try? await Task.sleep(for: .seconds(1))
                let done = await (try? transactionGate.withLock { [self] () async throws -> Bool in
                    // A newer configure/reveal already applied state.
                    if appliedResolution != nil {
                        return true
                    }
                    try await applyCurrentState()
                    return true
                }) ?? false
                if done {
                    logger.notice("Concealment restored after a failed clock-press re-apply")
                    return
                }
            }
            logger.error("Concealment could not be restored after the clock press")
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
