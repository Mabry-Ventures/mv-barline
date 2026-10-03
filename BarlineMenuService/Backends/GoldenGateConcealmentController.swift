import AppKit
import BarlineCore
import CryptoKit
import Foundation
import OSLog

@available(macOS 27.0, *)
final class GoldenGateConcealmentController: @unchecked Sendable {
    private let logger = Logger(category: "GoldenGateConcealmentController")
    private let transactionGate = AsyncExclusiveOperationGate()
    private let controllerLock = NSLock()
    /// The same sealed configuration authenticates the XPC peer. Never use the
    /// helper's own bundle ID or accept the protected app identity from a caller.
    private let barlineBundleIdentifier = BarlineMenuService.requiredIdentity(
        forInfoKey: "BarlineAppSigningIdentifier"
    )
    private var opaqueController: UnsafeMutableRawPointer?
    private var desiredConfiguration = MenuBarConcealmentConfiguration(
        visibleItemIDs: [], concealedItemIDs: []
    )
    private var temporaryRevealLedger = TemporaryRevealLedger()
    private var appliedResolution: GoldenGateResolvedConcealment?
    private var appliedNativeState: GoldenGateNativeConcealmentState?
    /// Ephemeral lifecycle witnesses only, never item/display/Focus authority.
    /// A bundle may relaunch between workspace samples without changing the
    /// native allowlist, but its new status items still need a deassertion edge.
    private struct PublisherInstance: Hashable, Sendable {
        let bundleIdentifier: String
        let processIdentifier: Int32
        let launchDate: Date?
    }

    private struct PreparedState: Sendable {
        let configuration: MenuBarConcealmentConfiguration
        let native: GoldenGateNativeConcealmentState
        let running: Set<PublisherInstance>
        let observedPublishers: Set<PublisherInstance>
        let visiblePublishers: Set<PublisherInstance>
        let configurationDigest: String
        let effectiveDigest: String
        let hasTemporaryReveal: Bool
        let revealOwnershipChanged: Bool
    }

    private var acceptedConfiguration: MenuBarConcealmentConfiguration?
    private var settledPublishers = Set<PublisherInstance>()
    private var hasDeassertionBoundary = true
    private var publisherRefreshPending = false
    private var receiptLedger = NativeConcealmentReceiptLedger()
    /// A new helper session has no acknowledged native state. Discovery needs
    /// a real deasserted acknowledgement before it can derive the first saved
    /// configuration. This one-shot is never inferred from an unknown receipt:
    /// failed transitions must not silently reset accepted user intent.
    private var initialEnvironmentStatePending = true
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

    @discardableResult
    func configure(_ configuration: MenuBarConcealmentConfiguration) async throws -> NativeConcealmentReceipt {
        try await transactionGate.withLock { [self] in
            initialEnvironmentStatePending = false
            let previousConfiguration = desiredConfiguration
            desiredConfiguration = configuration
            do {
                try await applyCurrentState()
                finishSuccessfulReconciliation()
                return receiptLedger.receipt
            } catch {
                desiredConfiguration = previousConfiguration
                throw error
            }
        }
    }

    func receipt() async throws -> NativeConcealmentReceipt {
        try await transactionGate.withLock { [self] in
            checkedReceipt()
        }
    }

    func environment(_ observeScene: @escaping @Sendable () -> MenuBarEnvironmentSnapshot) async throws -> MenuBarEnvironmentSnapshot {
        try await transactionGate.withLock { [self] in
            if initialEnvironmentStatePending {
                initialEnvironmentStatePending = false
                // The empty configuration takes the bridge's native clear
                // transaction. Begin, Commit and committed-state verification
                // must succeed; allocation alone is not proof of deassertion.
                try await applyCurrentState()
            }
            return observeScene().replacingConcealmentReceipt(checkedReceipt())
        }
    }

    private func checkedReceipt() -> NativeConcealmentReceipt {
        if receiptLedger.receipt.hasKnownEffectiveState {
            guard let appliedNativeState,
                  let controller = controller(createIfNeeded: false),
                  BLNGoldenGateAssessmentCommittedState(controller) == expectedAssertionState(appliedNativeState)
            else {
                receiptLedger.markUnknown()
                appliedResolution = nil
                appliedNativeState = nil
                return receiptLedger.receipt
            }
        }
        return receiptLedger.receipt
    }

    @discardableResult
    func beginTemporaryReveal(_ item: MenuBarItemID) async throws -> Bool {
        try await transactionGate.withLock { [self] in
            guard desiredConfiguration.concealedItemIDs.contains(item) else { return false }
            let candidateLedger = temporaryRevealLedger.beginning(item)
            try await applyCurrentState(temporaryRevealLedger: candidateLedger)
            temporaryRevealLedger = candidateLedger
            finishSuccessfulReconciliation()
            logger.notice("Temporary reveal began: activeItemCount=\(candidateLedger.visibleItemIDs.count, privacy: .public)")
            return true
        }
    }

    func endTemporaryReveal(_ item: MenuBarItemID) async throws {
        try await transactionGate.withLock { [self] in
            guard let candidateLedger = temporaryRevealLedger.ending(item) else { return }
            try await applyCurrentState(temporaryRevealLedger: candidateLedger)
            temporaryRevealLedger = candidateLedger
            finishSuccessfulReconciliation()
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
                    receiptLedger.beginNativeTransition()
                    if let controller = controller(createIfNeeded: false) {
                        BLNGoldenGateAssessmentInvalidate(controller)
                    }
                    appliedResolution = nil
                    appliedNativeState = nil
                    hasDeassertionBoundary = true
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
            receiptLedger.markUnknown()
            appliedResolution = nil
            appliedNativeState = nil
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
                        // A reveal begun since admission may defer this reset.
                        // Do not acknowledge or forget the unsettled publisher.
                        guard !publisherRefreshPending else { return false }
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
            self?.logger.error("Concealment reconciliation exhausted its bounded recovery attempts")
        }
    }

    private func cancelBackgroundRecovery() {
        recoveryLease.invalidate()
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func finishSuccessfulReconciliation() {
        cancelBackgroundRecovery()
        if publisherRefreshPending, temporaryRevealLedger.visibleItemIDs.isEmpty {
            scheduleBackgroundReapply()
        }
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
                appliedNativeState = nil
                acceptedConfiguration = nil
                settledPublishers.removeAll()
                hasDeassertionBoundary = true
                publisherRefreshPending = false
                desiredConfiguration = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [])
                receiptLedger.invalidateSession()
                initialEnvironmentStatePending = true
            }
        }.value
    }

    private func applyCurrentState(
        temporaryRevealLedger: TemporaryRevealLedger? = nil,
        timeout: Duration = .seconds(3),
        permitsPublisherRefresh: Bool = true
    ) async throws {
        initialEnvironmentStatePending = false
        guard let opaqueController = controller() else {
            throw MenuBarBackendError.unavailableCapability("Golden Gate native concealment")
        }
        let candidateRevealLedger = temporaryRevealLedger ?? self.temporaryRevealLedger
        let temporarilyVisible = candidateRevealLedger.visibleItemIDs
        let revealOwnershipChanged = candidateRevealLedger != self.temporaryRevealLedger
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: desiredConfiguration.visibleItemIDs + temporarilyVisible,
            concealedItemIDs: desiredConfiguration.concealedItemIDs.filter {
                !temporarilyVisible.contains($0)
            }
        )
        let resolved = GoldenGateConcealmentPolicy.resolve(
            configuration,
            barlineBundleIdentifier: barlineBundleIdentifier
        )
        let running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { application -> PublisherInstance? in
                guard !application.isTerminated, application.processIdentifier > 0,
                      let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty
                else { return nil }
                return PublisherInstance(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: application.processIdentifier,
                    launchDate: application.launchDate
                )
            })
        }
        try Task.checkCancellation()
        let nativeState = GoldenGateNativeConcealmentState(
            resolution: resolved, runningBundleIdentifiers: running.map(\.bundleIdentifier),
            barlineBundleIdentifier: barlineBundleIdentifier
        )
        let configurationDigest = try digest([
            "visible": Set(desiredConfiguration.visibleItemIDs.map(\.searchDocumentID.value)).sorted(),
            "concealed": Set(desiredConfiguration.concealedItemIDs.map(\.searchDocumentID.value)).sorted(),
        ])
        let effectiveDigest = try digest([
            "concealedBundles": resolved.concealedBundleIdentifiers.sorted(),
            "systemItems": resolved.allowedSystemItemIdentifiers.sorted().map(String.init),
            "allowedBundles": nativeState.allowedBundleIdentifiers.sorted(),
        ])
        let desiredVisibleCount = desiredConfiguration.visibleItemIDs.count
        let desiredHiddenCount = desiredConfiguration.concealedItemIDs.count
        logger.notice(
            "Concealment state: desiredVisible=\(desiredVisibleCount, privacy: .public) desiredHidden=\(desiredHiddenCount, privacy: .public) temporaryVisible=\(temporarilyVisible.count, privacy: .public) concealedBundles=\(resolved.concealedBundleIdentifiers.count, privacy: .public)"
        )
        let visibleBundles = Set(configuration.visibleItemIDs.map { $0.bundleIdentifier.lowercased() })
        let observedBundles = visibleBundles.union(configuration.concealedItemIDs.map { $0.bundleIdentifier.lowercased() })
        let allowedBundles = Set(nativeState.allowedBundleIdentifiers.map { $0.lowercased() })
        let prepared = PreparedState(
            configuration: desiredConfiguration, native: nativeState, running: running,
            observedPublishers: running.filter { observedBundles.contains($0.bundleIdentifier.lowercased()) },
            visiblePublishers: running.filter {
                visibleBundles.contains($0.bundleIdentifier.lowercased()) && allowedBundles.contains($0.bundleIdentifier.lowercased())
            },
            configurationDigest: configurationDigest, effectiveDigest: effectiveDigest,
            hasTemporaryReveal: !temporarilyVisible.isEmpty, revealOwnershipChanged: revealOwnershipChanged
        )
        let hasUnsettledPublisher = !prepared.visiblePublishers.isSubset(of: settledPublishers)
        if permitsPublisherRefresh, hasUnsettledPublisher,
           let appliedNativeState, expectedAssertionState(appliedNativeState) == 1,
           checkedReceipt().hasKnownEffectiveState,
           candidateRevealLedger.visibleItemIDs.isEmpty, self.temporaryRevealLedger.visibleItemIDs.isEmpty,
           let acceptedConfiguration
        {
            try await refreshPublishers(prepared, restoring: acceptedConfiguration, timeout: timeout)
            return
        }
        // Assessment-mode assertions are stateful. Replacing a healthy
        // assertion with an identical one on every shelf click can be rejected
        // by macOS 27 and turns an otherwise-ready shelf into a silent no-op.
        // Keep the committed assertion when the effective allowlists have not
        // changed; real visibility changes still flow through the transactional
        // activate-then-commit path below.
        if appliedNativeState == nativeState,
           checkedReceipt().hasKnownEffectiveState,
           BLNGoldenGateAssessmentCommittedState(opaqueController) == expectedAssertionState(nativeState)
        {
            accept(prepared, nativeTransition: false, crossedDeassertionBoundary: false)
            return
        }
        try await commitNativeState(prepared, timeout: timeout)
    }

    /// Native replacement acknowledgements do not reposition a publisher born
    /// under an earlier restriction. Cross a bounded, receipt-transient clear
    /// edge only for unsettled visible publishers, not ordinary shelf clicks.
    private func refreshPublishers(
        _ prepared: PreparedState,
        restoring previousConfiguration: MenuBarConcealmentConfiguration,
        timeout: Duration
    ) async throws {
        guard let controller = controller(createIfNeeded: false) else {
            throw MenuBarBackendError.interrupted
        }
        receiptLedger.beginNativeTransition()
        BLNGoldenGateAssessmentInvalidate(controller)
        appliedResolution = nil
        appliedNativeState = nil
        hasDeassertionBoundary = true
        do {
            // Candidate interval derived from the independently verified Clock
            // lift (80ms before + 150ms after); installed proof remains required.
            try await Task.sleep(for: .milliseconds(230))
            try Task.checkCancellation()
            try await commitNativeState(prepared, timeout: min(timeout, GoldenGateTiming.clockRestoreBudget))
            logger.notice("Reconciled a newly observed menu bar publisher")
        } catch {
            let candidateError = error
            desiredConfiguration = previousConfiguration
            do {
                // Clearing removed the bridge's previous-assertion rollback.
                // Compensate accepted intent even if the caller was cancelled;
                // never reacquire the gate already held by this transaction.
                try await Task.detached { [self] in
                    // Commit may have succeeded before verification failed.
                    // Its boundary was consumed by that attempt's sample, not
                    // by a publisher born beneath its new assertion. Establish
                    // a fresh boundary before sampling for compensation.
                    receiptLedger.beginNativeTransition()
                    BLNGoldenGateAssessmentInvalidate(controller)
                    appliedResolution = nil
                    appliedNativeState = nil
                    hasDeassertionBoundary = true
                    try await Task.sleep(for: .milliseconds(230))
                    try await applyCurrentState(
                        timeout: GoldenGateTiming.clockRestoreBudget, permitsPublisherRefresh: false
                    )
                }.value
            } catch {
                receiptLedger.markUnknown()
                appliedResolution = nil
                appliedNativeState = nil
                scheduleBackgroundReapply()
                throw MenuBarBackendError.mutationRecoveryFailed
            }
            finishSuccessfulReconciliation()
            throw candidateError
        }
    }

    private func accept(_ prepared: PreparedState, nativeTransition: Bool, crossedDeassertionBoundary: Bool) {
        let asserted = expectedAssertionState(prepared.native) == 1
        appliedResolution = prepared.native.resolution
        appliedNativeState = prepared.native
        acceptedConfiguration = prepared.configuration
        settledPublishers.formIntersection(prepared.running)
        // Only the sample used for this actual native transaction is settled.
        // A process seen before it publishes AX items must remain pending until
        // its first observed item participates in a clean native transition.
        if crossedDeassertionBoundary || !asserted {
            settledPublishers.formUnion(prepared.observedPublishers)
        }
        hasDeassertionBoundary = !asserted
        publisherRefreshPending = asserted && !prepared.visiblePublishers.isSubset(of: settledPublishers)
        receiptLedger.accept(
            configurationDigest: prepared.configurationDigest, effectiveStateDigest: prepared.effectiveDigest,
            hasCommittedAssertion: asserted, hasTemporaryReveal: prepared.hasTemporaryReveal,
            forceObservationChange: nativeTransition || prepared.revealOwnershipChanged
        )
    }

    private func commitNativeState(_ prepared: PreparedState, timeout: Duration) async throws {
        guard let opaqueController = controller() else { throw MenuBarBackendError.interrupted }
        // Native Begin can activate even if subsequent acknowledgement fails.
        // Only this attempt's captured publishers may consume the clear edge.
        // A failure must never donate that witness to a later running sample.
        let crossedDeassertionBoundary = hasDeassertionBoundary
        hasDeassertionBoundary = false
        let bundles = prepared.native.resolution.concealedBundleIdentifiers.sorted() as CFArray
        let systemItems = prepared.native.resolution.allowedSystemItemIdentifiers.sorted().map(NSNumber.init) as CFArray
        let allowedBundles = prepared.native.allowedBundleIdentifiers.sorted() as CFArray
        // Synchronous bridge setup must consume the activation budget too.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        // Begin invokes native activation before logical Commit. Even a zero
        // token can follow an activation exception, so old proof expires now.
        receiptLedger.beginNativeTransition()
        var acknowledged = false
        defer {
            if !acknowledged {
                receiptLedger.markUnknown()
                appliedResolution = nil
                appliedNativeState = nil
            }
        }
        let transaction = BLNGoldenGateAssessmentBegin(opaqueController, bundles, systemItems, allowedBundles)
        guard transaction != 0 else {
            throw MenuBarBackendError.operationFailed("Golden Gate native concealment could not start")
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
                    guard BLNGoldenGateAssessmentCommittedState(opaqueController) == expectedAssertionState(prepared.native) else {
                        throw MenuBarBackendError.mutationRecoveryFailed
                    }
                    accept(prepared, nativeTransition: true, crossedDeassertionBoundary: crossedDeassertionBoundary)
                    acknowledged = true
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

    private func expectedAssertionState(_ state: GoldenGateNativeConcealmentState) -> Int32 {
        state.resolution.concealedBundleIdentifiers.isEmpty &&
            state.resolution.allowedSystemItemIdentifiers == GoldenGateConcealmentPolicy.allSystemItemIdentifiers ? 0 : 1
    }

    private func digest(_ fields: [String: [String]]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
