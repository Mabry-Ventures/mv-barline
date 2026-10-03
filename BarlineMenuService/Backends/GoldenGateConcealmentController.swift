import AppKit
import BarlineCore
import CryptoKit
import Foundation
import OSLog

/// Ephemeral kernel birth evidence, not signing, item or display authority.
struct GoldenGatePublisherLifetime: Hashable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    init?(pid: Int32, reportedPID: UInt32, bytes: Int32, expectedBytes: Int32, seconds: UInt64, microseconds: UInt64) {
        guard pid > 0, reportedPID == UInt32(pid), expectedBytes > 0, bytes == expectedBytes,
              seconds > 0, microseconds < 1_000_000 else { return nil }
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

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
        let lifetime: GoldenGatePublisherLifetime
    }

    private struct RunningPublisher: Hashable, Sendable {
        let bundleIdentifier: String
        let processIdentifier: Int32
    }

    private struct PreparedState: Sendable {
        let configuration: MenuBarConcealmentConfiguration
        let native: GoldenGateNativeConcealmentState
        let running: Set<PublisherInstance>
        let observedPublishers: Set<PublisherInstance>
        let visiblePublishers: Set<PublisherInstance>
        let pendingPublishers: Set<PublisherInstance>
        let hasUnverifiedPendingPublisher: Bool
        let proposedRevealBundles: Set<String>
        let requiresPublisherRefresh: Bool
        let configurationDigest: String
        let effectiveDigest: String
        let hasTemporaryReveal: Bool
        let revealOwnershipChanged: Bool
    }

    private var acceptedConfiguration: MenuBarConcealmentConfiguration?
    private var settledPublishers = Set<PublisherInstance>()
    private var hasDeassertionBoundary = true
    private var publisherRefreshPending = false
    private var lastProbedPublisherPID: Int32 = 0
    /// Raw bundle/PID keys schedule observations only. Unknown birth reads do
    /// not renew deadlines or establish publisher settlement/input authority.
    private var publisherObservationBudget = MenuBarPublisherObservationBudget<RunningPublisher, GoldenGatePublisherLifetime>()
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
            try await applyCurrentState(timeout: GoldenGateTiming.clockRestoreBudget, observesPublishers: false)
            finishSuccessfulReconciliation()
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
            guard let self else { return }
            try? await transactionGate.withLock { [self] in
                guard recoveryLease.contains(lease) else { return }
                recoveryLease.invalidate()
                recoveryTask = nil
                logger.error("Concealment reconciliation exhausted its bounded recovery attempts")
            }
        }
    }

    private func cancelBackgroundRecovery() {
        recoveryLease.invalidate()
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func finishSuccessfulReconciliation() {
        if publisherRefreshPending, temporaryRevealLedger.visibleItemIDs.isEmpty {
            // A no-op configure cannot restart the same observation window or
            // keep its worker perpetually one second away from actually running.
            if recoveryTask == nil {
                scheduleBackgroundReapply()
            }
        } else {
            cancelBackgroundRecovery()
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
                publisherObservationBudget = MenuBarPublisherObservationBudget()
                desiredConfiguration = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [])
                receiptLedger.invalidateSession()
                initialEnvironmentStatePending = true
            }
        }.value
    }

    private func applyCurrentState(
        temporaryRevealLedger: TemporaryRevealLedger? = nil,
        timeout: Duration = .seconds(3),
        permitsPublisherRefresh: Bool = true,
        observesPublishers: Bool = true
    ) async throws {
        initialEnvironmentStatePending = false
        guard let opaqueController = controller() else {
            throw MenuBarBackendError.unavailableCapability("Golden Gate native concealment")
        }
        let candidateRevealLedger = temporaryRevealLedger ?? self.temporaryRevealLedger
        let prepared = try await prepareState(candidateRevealLedger: candidateRevealLedger, observesPublishers: observesPublishers)
        if permitsPublisherRefresh, observesPublishers, prepared.requiresPublisherRefresh,
           let appliedNativeState, expectedAssertionState(appliedNativeState) == 1,
           checkedReceipt().hasKnownEffectiveState,
           self.temporaryRevealLedger.visibleItemIDs.isEmpty,
           let acceptedConfiguration
        {
            try await refreshPublishers(candidateRevealLedger: candidateRevealLedger, restoring: acceptedConfiguration, timeout: timeout)
            return
        }
        // Identical healthy assertions must not churn on ordinary shelf clicks.
        if appliedNativeState == prepared.native,
           checkedReceipt().hasKnownEffectiveState,
           BLNGoldenGateAssessmentCommittedState(opaqueController) == expectedAssertionState(prepared.native)
        {
            accept(prepared, nativeTransition: false, crossedDeassertionBoundary: false)
            return
        }
        try await commitNativeState(prepared, timeout: timeout)
    }

    private func prepareState(candidateRevealLedger: TemporaryRevealLedger, observesPublishers: Bool) async throws -> PreparedState {
        let temporarilyVisible = candidateRevealLedger.visibleItemIDs
        let revealOwnershipChanged = candidateRevealLedger != temporaryRevealLedger
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
        let applications = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { application -> RunningPublisher? in
                guard !application.isTerminated, application.processIdentifier > 0,
                      let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty
                else { return nil }
                return RunningPublisher(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: application.processIdentifier
                )
            }
        }
        try Task.checkCancellation()
        let running = Set(applications.compactMap { application -> PublisherInstance? in
            guard let lifetime = GoldenGateAXInventory.publisherLifetime(for: application.processIdentifier) else { return nil }
            return PublisherInstance(
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: application.processIdentifier, lifetime: lifetime
            )
        })
        let nativeState = GoldenGateNativeConcealmentState(
            // A missing kernel witness must not remove an otherwise allowed app.
            resolution: resolved, runningBundleIdentifiers: applications.map(\.bundleIdentifier),
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
        let configuredPublishers = running.filter { observedBundles.contains($0.bundleIdentifier.lowercased()) }
        // Known native system controls use the existing enum-backed path, not
        // a fictitious standalone app publisher. All other authority stays in
        // normal discovery and activation's fresh target resolution.
        let proposedRevealBundles = Set(temporarilyVisible.filter {
            GoldenGateConcealmentPolicy.systemItemIdentifier(for: $0) == nil
        }.map { $0.bundleIdentifier.lowercased() })
        let proposedRevealPublishers = running.filter { proposedRevealBundles.contains($0.bundleIdentifier.lowercased()) }
        let allowedVisiblePublishers = configuredPublishers.filter {
            visibleBundles.contains($0.bundleIdentifier.lowercased()) && allowedBundles.contains($0.bundleIdentifier.lowercased())
        }
        let observedPublishers = observesPublishers ? observedPublishers(
            configuredPublishers, proposed: proposedRevealPublishers, visible: allowedVisiblePublishers
        ) : configuredPublishers.intersection(settledPublishers)
        let verifiedRunningPIDs = Set(running.map(\.processIdentifier))
        let uncertainVisible = applications.filter {
            visibleBundles.contains($0.bundleIdentifier.lowercased()) &&
                allowedBundles.contains($0.bundleIdentifier.lowercased()) &&
                !verifiedRunningPIDs.contains($0.processIdentifier)
        }
        var observationCandidates = [RunningPublisher: GoldenGatePublisherLifetime?]()
        for publisher in allowedVisiblePublishers {
            observationCandidates.updateValue(publisher.lifetime, forKey: RunningPublisher(
                bundleIdentifier: publisher.bundleIdentifier, processIdentifier: publisher.processIdentifier
            ))
        }
        for publisher in uncertainVisible {
            observationCandidates.updateValue(nil, forKey: publisher)
        }
        let pendingObservations = publisherObservationBudget.pending(observationCandidates, now: DispatchTime.now().uptimeNanoseconds)
        let settledRunningBundles = Set(running.intersection(settledPublishers).map { $0.bundleIdentifier.lowercased() })
        let needsFirstRevealBoundary = !proposedRevealBundles.isSubset(of: settledRunningBundles)
        let observedVisible = allowedVisiblePublishers.intersection(observedPublishers)
        if revealOwnershipChanged, temporaryRevealLedger.visibleItemIDs.isEmpty,
           !proposedRevealBundles.isSubset(of: Set(proposedRevealPublishers.map { $0.bundleIdentifier.lowercased() }))
        {
            throw MenuBarBackendError.operationFailed("Menu bar publisher lifetime is unavailable")
        }
        return PreparedState(
            configuration: desiredConfiguration, native: nativeState, running: running,
            observedPublishers: observedPublishers,
            visiblePublishers: allowedVisiblePublishers,
            pendingPublishers: allowedVisiblePublishers.filter {
                pendingObservations.contains(RunningPublisher(bundleIdentifier: $0.bundleIdentifier, processIdentifier: $0.processIdentifier))
            },
            hasUnverifiedPendingPublisher: uncertainVisible.contains { pendingObservations.contains($0) },
            proposedRevealBundles: proposedRevealBundles,
            requiresPublisherRefresh: !observedVisible.isSubset(of: settledPublishers) || needsFirstRevealBoundary,
            configurationDigest: configurationDigest, effectiveDigest: effectiveDigest,
            hasTemporaryReveal: !temporarilyVisible.isEmpty, revealOwnershipChanged: revealOwnershipChanged
        )
    }

    private func observedPublishers(
        _ candidates: Set<PublisherInstance>, proposed: Set<PublisherInstance>, visible: Set<PublisherInstance>
    ) -> Set<PublisherInstance> {
        var observed = candidates.intersection(settledPublishers)
        // A single bounded read budget, only for previously unsettled owners.
        // Missing AX evidence is pending, not a reason to clear repeatedly.
        let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
        func priority(_ candidate: PublisherInstance) -> Int {
            proposed.contains(candidate) ? 0 : visible.contains(candidate) ? 1 : 2
        }
        let cursor = lastProbedPublisherPID
        // A foreground reveal probes its target only. Unrelated unresponsive
        // hidden owners must not add latency or starve a readable clicked item.
        let probeCandidates = proposed.isEmpty ? candidates : proposed
        let ordered = probeCandidates.subtracting(settledPublishers).sorted {
            if priority($0) != priority($1) {
                return priority($0) < priority($1)
            }
            if ($0.processIdentifier > cursor) != ($1.processIdentifier > cursor) {
                return $0.processIdentifier > cursor
            }
            return $0.processIdentifier < $1.processIdentifier
        }
        for (index, candidate) in ordered.enumerated() {
            let now = DispatchTime.now().uptimeNanoseconds
            guard !Task.isCancelled, now < deadline else { break }
            // Reserve an equal share of the remaining budget for each owner.
            // A stalled same-bundle companion cannot consume the whole first
            // click opportunity before a readable new publisher is visited.
            // A timeout remains unknown, not evidence of a silent publisher.
            let ownerDeadline = now + (deadline - now) / UInt64(ordered.count - index)
            lastProbedPublisherPID = candidate.processIdentifier
            if GoldenGateAXInventory.publisherHasStatusItem(
                processIdentifier: candidate.processIdentifier, bundleIdentifier: candidate.bundleIdentifier,
                lifetime: candidate.lifetime, deadline: ownerDeadline
            ) {
                observed.insert(candidate)
            }
        }
        return observed
    }

    /// Native replacement acknowledgements do not reposition a publisher born
    /// under an earlier restriction. Cross a bounded, receipt-transient clear
    /// edge only for unsettled visible publishers, not ordinary shelf clicks.
    private func refreshPublishers(
        candidateRevealLedger: TemporaryRevealLedger,
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
        let deassertionDeadline = ContinuousClock.now.advanced(by: .milliseconds(230))
        var attemptedNativeCommit = false
        do {
            // Candidate interval derived from the independently verified Clock
            // lift (80ms before + 150ms after); installed proof remains required.
            try await Task.sleep(until: deassertionDeadline, clock: .continuous)
            try Task.checkCancellation()
            // Hidden owners may have no AX surface until the assertion lifts.
            // This clear may settle only live observations of the exact sampled
            // lifetime, never retained configuration IDs or a replaced process.
            let refreshed = try await prepareState(candidateRevealLedger: candidateRevealLedger, observesPublishers: true)
            // Bundle coverage is advisory only; one silent same-bundle process
            // must not reject its real publisher. Fresh exact-item resolution
            // after native reveal still owns identity and ambiguity rejection.
            let observedBundles = Set(refreshed.observedPublishers.map { $0.bundleIdentifier.lowercased() })
            guard refreshed.proposedRevealBundles.isSubset(of: observedBundles) else {
                throw MenuBarBackendError.operationFailed("Menu bar publisher has not published its item")
            }
            attemptedNativeCommit = true
            try await commitNativeState(refreshed, timeout: min(timeout, GoldenGateTiming.clockRestoreBudget))
            logger.notice("Reconciled a newly observed menu bar publisher")
        } catch {
            let candidateError = error
            let renewBoundary = attemptedNativeCommit
            desiredConfiguration = previousConfiguration
            do {
                // Clearing removed the bridge's previous-assertion rollback.
                // Compensate accepted intent even if the caller was cancelled;
                // never reacquire the gate already held by this transaction.
                try await Task.detached { [self] in
                    // Begin may activate before Commit or verification fails,
                    // consuming this boundary. Only those attempts need a new
                    // full wait. Pre-Begin failure or cancellation completes
                    // the existing clear interval, without a second 230ms wait.
                    receiptLedger.beginNativeTransition()
                    BLNGoldenGateAssessmentInvalidate(controller)
                    appliedResolution = nil
                    appliedNativeState = nil
                    hasDeassertionBoundary = true
                    if renewBoundary {
                        try await Task.sleep(for: .milliseconds(230))
                    } else if ContinuousClock.now < deassertionDeadline {
                        try await Task.sleep(until: deassertionDeadline, clock: .continuous)
                    }
                    try await applyCurrentState(
                        timeout: GoldenGateTiming.clockRestoreBudget, permitsPublisherRefresh: false, observesPublishers: false
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
        let observedVisible = prepared.visiblePublishers.intersection(prepared.observedPublishers)
        publisherRefreshPending = asserted && (
            !observedVisible.isSubset(of: settledPublishers) ||
                !prepared.pendingPublishers.isSubset(of: settledPublishers) || prepared.hasUnverifiedPendingPublisher
        )
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
