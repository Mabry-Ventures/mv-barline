//
//  StateCoordinator.swift
//  Barline
//

import Foundation
import OSLog

public enum MenuBarAuthorityRefreshError: Error, Equatable, Sendable {
    case staleGeneration(expected: UInt64, actual: UInt64?)
}

public enum ProfileAuthorityAssessment: Sendable, Equatable {
    case matches
    case mismatch
    case temporarilyUnavailable
}

public enum MenuBarMutation: Sendable {
    case move(MenuBarMoveOperation)
    case transientReveal(MenuBarMoveOperation)
    case transientMove(MenuBarMoveOperation)
    case reveal(MenuBarItemID)
    case restoreLastKnownGood

    fileprivate var recordsLayoutHistory: Bool {
        switch self {
        case .transientReveal, .transientMove:
            false
        case .move, .reveal, .restoreLastKnownGood:
            true
        }
    }

    fileprivate var moveOperation: MenuBarMoveOperation? {
        switch self {
        case let .move(operation), let .transientReveal(operation), let .transientMove(operation):
            operation
        case .reveal, .restoreLastKnownGood:
            nil
        }
    }
}

public struct MenuBarWorkspaceCheckpoint: Codable, Hashable, Sendable {
    public let snapshot: MenuBarSnapshot
    public let activeProfileID: UUID?
    public let activeDisplayID: MenuBarDisplayID?
    public let workspace: ProfileWorkspaceState

    public init(
        snapshot: MenuBarSnapshot,
        activeProfileID: UUID?,
        activeDisplayID: MenuBarDisplayID? = nil,
        workspace: ProfileWorkspaceState
    ) {
        self.snapshot = snapshot
        self.activeProfileID = activeProfileID
        self.activeDisplayID = activeDisplayID
        self.workspace = workspace
    }
}

public enum MenuBarConditionalRestoreResult: Sendable, Equatable {
    case restored(MenuBarSnapshot)
    case superseded
}

/// A confirmation binds to both the original checkpoint and an observed live
/// workspace. Callers cannot construct or alter a prepared recovery.
public struct MenuBarPreparedWorkspaceRecovery: Sendable {
    public let preview: WorkspaceRecoveryPlanner.Preview
    public let checkpoint: MenuBarWorkspaceCheckpoint
    fileprivate let source: MenuBarWorkspaceCheckpoint
    fileprivate let target: MenuBarWorkspaceCheckpoint
    fileprivate let mutationGeneration: UInt64
    fileprivate let workspaceRevision: UInt64?
}

public enum PendingProfileActivationRecoveryResult: Sendable, Equatable {
    case promoted(ResolvedProfilePresentation)
    case restored(MenuBarSnapshot)
    case unchanged(MenuBarSnapshot)
    case inconclusive
}

public enum MenuBarWorkspaceTransactionError: Error, Equatable, Sendable {
    case superseded
    case sideEffectRecoveryFailed
}

/// Keeps each failed transaction boundary distinguishable without formatting
/// underlying errors. Compensation and authority rules are unchanged.
public struct ProfileActivationRecoveryFailure: Error, Sendable {
    public let activationError: any Error
    public let workspaceRollbackError: (any Error)?
    public let layoutRollbackError: (any Error)?

    public init(
        activationError: any Error,
        workspaceRollbackError: (any Error)?,
        layoutRollbackError: (any Error)?
    ) {
        self.activationError = activationError
        self.workspaceRollbackError = workspaceRollbackError
        self.layoutRollbackError = layoutRollbackError
    }
}

public struct MenuBarWorkspaceTransaction: Sendable {
    fileprivate let captureClosure: @Sendable () async throws -> ProfileWorkspaceState
    fileprivate let applyClosure: @Sendable (ProfileWorkspaceState) async throws -> Void
    fileprivate let currentRevisionClosure: (@Sendable () async -> UInt64)?
    fileprivate let applyIfCurrentClosure: (
        @Sendable (ProfileWorkspaceState, UInt64) async throws -> UInt64?
    )?
    fileprivate let rollbackSupersededClosure: (
        @Sendable (ProfileWorkspaceState, ProfileWorkspaceState) async throws -> UInt64?
    )?

    public init(
        capture: @escaping @Sendable () async throws -> ProfileWorkspaceState,
        apply: @escaping @Sendable (ProfileWorkspaceState) async throws -> Void
    ) {
        captureClosure = capture
        applyClosure = apply
        currentRevisionClosure = nil
        applyIfCurrentClosure = nil
        rollbackSupersededClosure = nil
    }

    public init(
        capture: @escaping @Sendable () async throws -> ProfileWorkspaceState,
        apply: @escaping @Sendable (ProfileWorkspaceState) async throws -> Void,
        currentRevision: @escaping @Sendable () async -> UInt64,
        applyIfCurrent: @escaping @Sendable (
            ProfileWorkspaceState,
            UInt64
        ) async throws -> UInt64?,
        rollbackSuperseded: @escaping @Sendable (
            ProfileWorkspaceState,
            ProfileWorkspaceState
        ) async throws -> UInt64?
    ) {
        captureClosure = capture
        applyClosure = apply
        currentRevisionClosure = currentRevision
        applyIfCurrentClosure = applyIfCurrent
        rollbackSupersededClosure = rollbackSuperseded
    }

    fileprivate func capture() async throws -> ProfileWorkspaceState {
        try await captureClosure()
    }

    fileprivate func apply(_ workspace: ProfileWorkspaceState) async throws {
        try await applyClosure(workspace)
    }

    fileprivate func currentRevision() async -> UInt64? {
        await currentRevisionClosure?()
    }

    fileprivate func apply(
        _ workspace: ProfileWorkspaceState,
        ifCurrentRevision revision: UInt64
    ) async throws -> UInt64? {
        guard let applyIfCurrentClosure else {
            try await applyClosure(workspace)
            return nil
        }
        return try await applyIfCurrentClosure(workspace, revision)
    }

    fileprivate func rollbackSuperseded(
        from applied: ProfileWorkspaceState,
        to original: ProfileWorkspaceState
    ) async throws -> UInt64? {
        try await rollbackSupersededClosure?(applied, original)
    }
}

public struct RetryPolicy: Sendable {
    public let maximumAttempts: Int
    public let baseDelay: Duration
    public let maximumDelay: Duration
    public let maximumJitterPermille: Int

    public init(
        maximumAttempts: Int = 4,
        baseDelay: Duration = .milliseconds(100),
        maximumDelay: Duration = .seconds(2),
        maximumJitterPermille: Int = 200
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.maximumJitterPermille = min(max(maximumJitterPermille, 0), 1000)
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        delay(forAttempt: attempt, jitterPermille: 0)
    }

    public func delay(forAttempt attempt: Int, jitterPermille: Int) -> Duration {
        let shift = min(max(attempt, 0), 20)
        let multiplier = 1 << shift
        let exponential = min(baseDelay * multiplier, maximumDelay)
        let boundedJitter = min(max(jitterPermille, 0), maximumJitterPermille)
        return min(exponential + (exponential * boundedJitter / 1000), maximumDelay)
    }
}

public actor MenuBarStateCoordinator {
    private static let logger = Logger(
        subsystem: "com.mabryventures.Barline",
        category: "StateCoordinator"
    )
    private struct HistoryCheckpoint: Sendable {
        let snapshot: MenuBarSnapshot
        let activeProfileID: UUID?
        let workspace: ProfileWorkspaceState?
        let workspaceRevision: UInt64?
    }

    private struct LogicalLayoutItem: Hashable, Sendable {
        let id: MenuBarItemID
        let displayID: MenuBarDisplayID?
        let section: MenuBarSection
        let order: Int
    }

    private struct ProfileObservationSignature: Equatable, Sendable {
        struct Item: Hashable, Sendable {
            let id: MenuBarItemID
            let displayID: MenuBarDisplayID?
            let section: MenuBarSection
        }

        let items: Set<Item>
        let hiddenOrder: [MenuBarItemID]
        let alwaysHiddenOrder: [MenuBarItemID]

        init(snapshot: MenuBarSnapshot) {
            items = Set(snapshot.items.map {
                Item(id: $0.id, displayID: $0.displayID, section: $0.section)
            })
            let ordered = snapshot.items.sorted { $0.order < $1.order }
            hiddenOrder = ordered.filter { $0.section == .hidden }.map(\.id)
            alwaysHiddenOrder = ordered.filter { $0.section == .alwaysHidden }.map(\.id)
        }
    }

    public private(set) var currentSnapshot: MenuBarSnapshot? {
        didSet {
            // Synthetic/legacy publications cannot inherit a previous scan.
            // Connected paths explicitly publish their own local envelope.
            currentAuthorityObservation = nil
        }
    }

    public private(set) var currentAuthorityObservation: MenuBarAuthorityObservation?
    public private(set) var lastKnownGoodSnapshot: MenuBarSnapshot?
    public private(set) var lastRejection: SnapshotRejectionReason?
    public private(set) var mutationGeneration: UInt64 = 0
    /// User/profile/history intent supersedes temporary reveals, but helper
    /// reconnects and other transient moves do not.
    public private(set) var layoutAuthorityGeneration: UInt64 = 0
    private var beforeAuthoritativeLayoutMutation: (@Sendable () async throws -> Void)?
    public private(set) var activeProfileID: UUID?
    public private(set) var backendHealth = MenuBarBackendHealth(
        backendName: "Unprobed",
        state: .unavailable
    )

    public var capabilities: MenuBarCapabilities {
        get async { await backend.capabilities }
    }

    private let backend: any MenuBarBackend
    private let validator: SnapshotValidator
    private var activePlatformPresenceContract: MenuBarPlatformPresenceContract?
    private var latestBackendAuthorityObservation: MenuBarAuthorityObservation?
    private var qualifiedPlatformPresenceContractHasBeenEstablished = false
    private let retryPolicy: RetryPolicy
    private let compensationTimeout: Duration
    private let historyLimit = 50
    private var mutationIsActive = false
    private var mutationWaiters = [CheckedContinuation<Void, Never>]()
    private var undoCheckpoints = [HistoryCheckpoint]()
    private var redoCheckpoints = [HistoryCheckpoint]()
    private var backendGenerationOffset: UInt64 = 0
    private var lastKnownGoodProfileID: UUID?
    private var activeItemInteractionID: UUID?
    private var itemInteractionWaiters = [UUID: CheckedContinuation<Void, Never>]()

    public init(
        backend: any MenuBarBackend,
        validator: SnapshotValidator = SnapshotValidator(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        compensationTimeout: Duration = .seconds(35)
    ) {
        self.backend = backend
        self.validator = validator
        self.retryPolicy = retryPolicy
        self.compensationTimeout = max(.milliseconds(1), compensationTimeout)
    }

    public func setBeforeAuthoritativeLayoutMutation(
        _ action: @escaping @Sendable () async throws -> Void
    ) {
        beforeAuthoritativeLayoutMutation = action
    }

    private func supersedeTemporaryReveals() async throws {
        // The app refuses new layout intent while durable reveal compensation
        // remains. Never erase it before an operation that could fail/roll back.
        try await beforeAuthoritativeLayoutMutation?()
        layoutAuthorityGeneration &+= 1
    }

    /// Reserves authority across a reveal / activate / observe / restore journey
    /// without holding the reentrant mutation turn across the caller's body.
    /// Only refreshes and mutations carrying this lease can run until it ends.
    public func withItemInteraction<Value: Sendable>(
        _ body: @Sendable (UUID) async throws -> Value
    ) async throws -> Value {
        let interactionID = try await reserveItemInteraction()
        defer { finishItemInteraction(interactionID) }
        try Task.checkCancellation()
        let value = try await body(interactionID)
        try Task.checkCancellation()
        return value
    }

    private func finishItemInteraction(_ interactionID: UUID) {
        guard activeItemInteractionID == interactionID else { return }
        activeItemInteractionID = nil
        let waiters = itemInteractionWaiters.values
        itemInteractionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForItemInteractionToFinish() async throws {
        try Task.checkCancellation()
        guard activeItemInteractionID != nil else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if activeItemInteractionID == nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    itemInteractionWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelItemInteractionWaiter(waiterID) }
        }
        try Task.checkCancellation()
    }

    private func cancelItemInteractionWaiter(_ waiterID: UUID) {
        itemInteractionWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func reserveItemInteraction() async throws -> UUID {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try Task.checkCancellation()
        try requireItemInteraction(nil)
        let interactionID = UUID()
        activeItemInteractionID = interactionID
        return interactionID
    }

    private func requireItemInteraction(_ interactionID: UUID?) throws {
        guard activeItemInteractionID == interactionID else {
            throw MenuBarBackendError.unsafeMenuTracking
        }
    }

    @discardableResult
    public func refresh(now: Date? = nil, interactionID: UUID? = nil) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(interactionID)

        return try await refreshAssumingMutationTurn(now: now)
    }

    /// Performs one backend snapshot attempt. Callers that own a larger retry
    /// budget use this to avoid multiplying independent retry loops.
    @discardableResult
    public func refreshOnce(
        now: Date? = nil,
        interactionID: UUID? = nil
    ) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(interactionID)

        return try await refreshAssumingMutationTurn(now: now, maximumAttempts: 1)
    }

    /// Refreshes only while the caller's previously validated authority is
    /// still current. The check and refresh share the mutation turn, preventing
    /// a layout mutation from slipping between them.
    @discardableResult
    public func refreshAuthority(
        expectedGeneration: UInt64,
        now: Date? = nil,
        interactionID: UUID? = nil
    ) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(interactionID)
        try requireCurrentGeneration(expectedGeneration)
        return try await refreshAssumingMutationTurn(now: now)
    }

    /// Reconciles transient native presentation with the latest logical layout
    /// while owning the same mutation turn as move, profile and history
    /// transactions. Callers provide section presentation only; item identity
    /// is derived after admission so delayed work cannot replay stale item
    /// assignments over a newer authoritative mutation.
    public func synchronizeConcealment(
        concealedSections: [MenuBarSection]
    ) async throws {
        _ = try await synchronizeConcealmentWithReceipt(concealedSections: concealedSections)
    }

    /// Returns the helper's acknowledgement so presentation can invalidate a
    /// pre-transition cache without inventing item or display authority.
    public func synchronizeConcealmentWithReceipt(
        concealedSections: [MenuBarSection]
    ) async throws -> NativeConcealmentReceipt? {
        try await acquireUnleasedMutationTurn()
        defer { releaseMutationTurn() }
        try Task.checkCancellation()

        // The macOS 27 provider intentionally caches discovery briefly. A sync
        // commonly follows the discovery that published the current snapshot,
        // so its first read can legitimately repeat that generation. Keep the
        // normal bounded retry policy: the production backoff crosses the cache
        // lifetime while the shared mutation turn prevents intervening writes.
        let snapshot = try await refreshAssumingMutationTurn(now: nil)
        try Task.checkCancellation()
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: snapshot.items.filter {
                !$0.isBarlineControlItem && !concealedSections.contains($0.section)
            }.map(\.id),
            concealedItemIDs: snapshot.items.filter {
                !$0.isBarlineControlItem && concealedSections.contains($0.section)
            }.map(\.id)
        )
        Self.logger.notice(
            "Concealment sync: visible=\(configuration.visibleItemIDs.count, privacy: .public) hidden=\(configuration.concealedItemIDs.count, privacy: .public)"
        )
        // Once the backend acknowledges the complete configuration, do not
        // reinterpret caller cancellation as failure: the native side effect
        // has already committed and is now the latest serialized state.
        return try await backend.configureConcealmentWithReceipt(configuration)
    }

    /// Waits out an item activation lease without losing the latest requested
    /// presentation. The lease intentionally releases the mutation turn between
    /// reveal/activate/observe steps, so ordinary admission alone is insufficient.
    private func acquireUnleasedMutationTurn() async throws {
        while true {
            await acquireMutationTurn()
            do {
                try Task.checkCancellation()
            } catch {
                releaseMutationTurn()
                throw error
            }
            guard activeItemInteractionID != nil else { return }
            releaseMutationTurn()
            try await waitForItemInteractionToFinish()
        }
    }

    private func refreshAssumingMutationTurn(
        now: Date?,
        maximumAttempts: Int? = nil,
        freshness: MenuBarObservationFreshness = .cachedAllowed
    ) async throws -> MenuBarSnapshot {
        var mostRecentError: (any Error)?

        let attemptCount = max(1, maximumAttempts ?? retryPolicy.maximumAttempts)

        for attempt in 0 ..< attemptCount {
            try Task.checkCancellation()
            do {
                let observation = try await normalizedBackendObservation(freshness: freshness)
                switch validateBackendObservation(observation, previous: currentSnapshot, now: now ?? Date()) {
                case let .success(snapshot):
                    let presenceContract = activePlatformPresenceContract ??
                        MenuBarPlatformPresenceContract.admitting(observation)
                    if let currentSnapshot,
                       logicalLayout(of: currentSnapshot, using: presenceContract) !=
                       logicalLayout(of: snapshot, using: presenceContract)
                    {
                        activeProfileID = nil
                    }
                    currentSnapshot = snapshot
                    currentAuthorityObservation = observation
                    lastKnownGoodSnapshot = snapshot
                    lastKnownGoodProfileID = activeProfileID
                    lastRejection = nil
                    backendHealth = await backend.health()
                    return snapshot
                case let .failure(reason):
                    lastRejection = reason
                    let health = await backend.health()
                    backendHealth = MenuBarBackendHealth(
                        backendName: health.backendName,
                        state: .degraded,
                        message: String(describing: reason)
                    )
                    mostRecentError = MenuBarBackendError.invalidSnapshot(reason)
                }
            } catch {
                mostRecentError = error
                let health = await backend.health()
                backendHealth = MenuBarBackendHealth(
                    backendName: health.backendName,
                    state: health.state == .healthy ? .degraded : health.state,
                    message: error.localizedDescription
                )
            }

            if attempt + 1 < attemptCount {
                let jitter = Int.random(in: 0 ... retryPolicy.maximumJitterPermille)
                try await Task.sleep(
                    for: retryPolicy.delay(forAttempt: attempt, jitterPermille: jitter)
                )
            }
        }

        throw mostRecentError ?? MenuBarBackendError.operationFailed("snapshot refresh failed")
    }

    @discardableResult
    public func perform(
        _ mutation: MenuBarMutation,
        now: Date? = nil,
        interactionID: UUID? = nil
    ) async throws -> MenuBarSnapshot {
        try await perform(mutation, expectedGeneration: nil, now: now, interactionID: interactionID)
    }

    /// Executes only if the refreshed snapshot used by the caller is still
    /// authoritative when the mutation acquires its serialized turn.
    @discardableResult
    public func perform(
        _ mutation: MenuBarMutation,
        expectedGeneration: UInt64,
        now: Date? = nil,
        interactionID: UUID? = nil
    ) async throws -> MenuBarSnapshot {
        try await perform(mutation, expectedGeneration: expectedGeneration as UInt64?, now: now, interactionID: interactionID)
    }

    /// Delivers a status-item activation without treating the click as a
    /// transactional layout mutation. The target may open a menu, mutate its
    /// own status item, or perform a direct action while handling the event;
    /// none of those side effects are a Barline layout postcondition.
    public func activateItem(
        _ itemID: MenuBarItemID,
        button: MenuBarMouseButton,
        expectedGeneration: UInt64? = nil,
        now: Date? = nil,
        interactionID: UUID? = nil
    ) async throws {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(interactionID)
        try Task.checkCancellation()
        if let expectedGeneration {
            try requireCurrentGeneration(expectedGeneration)
        }
        let before = try await validatedStartingSnapshot(now: now)
        guard !before.menuTrackingIsActive else {
            throw MenuBarBackendError.unsafeMenuTracking
        }
        guard before.items.contains(where: { $0.id == itemID }) else {
            throw MenuBarBackendError.staleItem(itemID)
        }

        // A successful transport return is the activation acknowledgement.
        // Do not snapshot, validate, roll back, or check cancellation after
        // delivery: the target owns every side effect from this point onward.
        try await backend.activate(itemID, button: button)
    }

    /// Admits a native activation before temporarily revealing its target.
    /// Reveal receipts are intentionally transient and never authorize a new
    /// layout scan. Keep admission, reveal and delivery in one mutation turn
    /// instead of asking for mutation authority after changing presentation.
    /// The caller owns the returned observation until the interface closes.
    public func activateItemWithRevealObservation(
        _ itemID: MenuBarItemID,
        button: MenuBarMouseButton,
        expectedGeneration: UInt64,
        interactionID: UUID
    ) async throws -> MenuBarRevealObservationToken {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(interactionID)
        try Task.checkCancellation()
        try requireCurrentGeneration(expectedGeneration)
        let before = try await refreshedQualifiedStartingSnapshot(now: nil)
        guard !before.menuTrackingIsActive,
              before.items.contains(where: { $0.id == itemID }),
              let scene = currentAuthorityObservation?.scan?.finalEnvironment,
              let receipt = scene.nativeConcealmentReceipt, receipt.isStable,
              !scene.activeSpaceIsFullscreen, !scene.menuTrackingIsActive,
              try await backend.environment() == scene
        else { throw MenuBarBackendError.interrupted }
        try Task.checkCancellation()
        let token = try await backend.beginRevealObservation(itemID)
        do {
            let revealed = try await backend.environment()
            guard scene.hasSameValidScene(as: revealed),
                  !revealed.activeSpaceIsFullscreen, !revealed.menuTrackingIsActive,
                  let acknowledged = revealed.nativeConcealmentReceipt,
                  acknowledged.hasKnownEffectiveState,
                  acknowledged.helperSessionID == receipt.helperSessionID,
                  acknowledged.configurationRevision == receipt.configurationRevision,
                  acknowledged.configurationDigest == receipt.configurationDigest,
                  acknowledged.assertionRevision >= receipt.assertionRevision
            else { throw MenuBarBackendError.interrupted }
            // Both native activation adapters resolve the target's live owner
            // and geometry again. No transient inventory is published as
            // current, last-known-good, profile, undo or mutation authority.
            try Task.checkCancellation()
            try await backend.activate(itemID, button: button)
            return token
        } catch {
            await backend.endRevealObservation(token)
            throw error
        }
    }

    private func perform(
        _ mutation: MenuBarMutation,
        expectedGeneration: UInt64?,
        now: Date?,
        interactionID: UUID?
    ) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(interactionID)
        try Task.checkCancellation()
        if let expectedGeneration {
            try requireCurrentGeneration(expectedGeneration)
        }
        let restoreTarget: MenuBarSnapshot? = if case .restoreLastKnownGood = mutation {
            lastKnownGoodSnapshot
        } else {
            nil
        }
        let restoreProfileID: UUID? = if case .restoreLastKnownGood = mutation {
            lastKnownGoodProfileID
        } else {
            nil
        }
        if case .restoreLastKnownGood = mutation, restoreTarget == nil {
            throw MenuBarBackendError.operationFailed("no last-known-good snapshot")
        }
        let before = try await validatedStartingSnapshot(now: now)
        let priorPlatformPresenceContract = activePlatformPresenceContract
        activePlatformPresenceContract = currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        defer { activePlatformPresenceContract = priorPlatformPresenceContract }
        let backendCapabilities = await backend.capabilities
        let moveDestinationSupport = backendCapabilities.moveDestinationSupport
        let probedVisibilityAssignmentGranularity = backendCapabilities.arrangement?
            .visibilityAssignmentGranularity
        // The macOS 27 logical-section backend has one fixed native contract:
        // third-party visibility is application-group scoped and known Apple
        // items are individually addressable. Its helper capability probe can
        // transiently time out during cold-start replacement even though the
        // subsequent native write succeeds. Once that write returns, do not
        // verify it with the stale pre-write `.unavailable` fallback.
        let visibilityAssignmentGranularity = if
            moveDestinationSupport == .logicalSectionsPreserveNativeOrder,
            probedVisibilityAssignmentGranularity == .unavailable
        {
            MenuBarVisibilityAssignmentGranularity.applicationGroupAndKnownSystemItem
        } else {
            probedVisibilityAssignmentGranularity
        }
        guard !before.menuTrackingIsActive else {
            throw MenuBarBackendError.unsafeMenuTracking
        }
        try validateReferences(for: mutation, in: before)
        if mutation.recordsLayoutHistory {
            try await supersedeTemporaryReveals()
        }
        mutationGeneration &+= 1
        let generation = mutationGeneration

        do {
            try await apply(mutation, restoreTarget: restoreTarget)
            try Task.checkCancellation()
            let snapshot = try await verifiedPostMutationSnapshot(
                for: mutation,
                from: before,
                restoreTarget: restoreTarget,
                moveDestinationSupport: moveDestinationSupport,
                visibilityAssignmentGranularity: visibilityAssignmentGranularity,
                now: now ?? Date()
            )
            guard generation == mutationGeneration else {
                throw CancellationError()
            }
            currentSnapshot = snapshot
            currentAuthorityObservation = platformAuthorityObservation(matching: snapshot)
            lastKnownGoodSnapshot = snapshot
            lastRejection = nil
            if mutation.recordsLayoutHistory {
                recordUndoCheckpoint(before, activeProfileID: activeProfileID)
                activeProfileID = restoreTarget == nil ? nil : restoreProfileID
            }
            lastKnownGoodProfileID = activeProfileID
            return snapshot
        } catch {
            let mutationError = error
            if Self.mutationDidNotStart(mutationError) {
                // Preflight failed before the backend wrote native state.
                // `validatedStartingSnapshot` already published that snapshot
                // together with its fresh authority envelope. Reassigning the
                // same value would trigger `currentSnapshot.didSet`, revoke the
                // envelope, and let a retry reuse cached state without another
                // qualified platform-presence admission.
                lastKnownGoodSnapshot = before
                throw mutationError
            }
            if Self.mutationRequiresNativeObservation(mutationError) {
                // The backend established either that another native value won
                // or that durable recovery authority appeared before this
                // proposal was staged. A compensating restore would overwrite
                // state that this caller does not own with its stale `before`
                // snapshot, defeating the backend's compare/rebase guard.
                if let observed = try? await normalizedBackendSnapshot(requiresFreshObservation: true),
                   case let .success(snapshot) = validateBackendSnapshot(
                       observed,
                       previous: nil,
                       now: now ?? Date()
                   )
                {
                    currentSnapshot = snapshot
                    currentAuthorityObservation = platformAuthorityObservation(matching: snapshot)
                    lastKnownGoodSnapshot = snapshot
                } else {
                    currentSnapshot = nil
                }
                activeProfileID = nil
                lastKnownGoodProfileID = nil
                throw mutationError
            }
            if moveDestinationSupport == .logicalSectionsPreserveNativeOrder,
               let operation = mutation.moveOperation
            {
                do {
                    let rollbackSnapshot = try await withCompensation {
                        try await self.compensateLogicalMove(
                            restoring: before,
                            operation: operation,
                            now: now ?? Date()
                        )
                    }
                    currentSnapshot = rollbackSnapshot
                    currentAuthorityObservation = platformAuthorityObservation(matching: rollbackSnapshot)
                    lastKnownGoodSnapshot = rollbackSnapshot
                    lastKnownGoodProfileID = activeProfileID
                } catch {
                    currentSnapshot = nil
                    activeProfileID = nil
                    throw MenuBarBackendError.mutationRecoveryFailed
                }
                throw mutationError
            }
            guard await backend.capabilities.canRestore else {
                currentSnapshot = nil
                activeProfileID = nil
                // Once apply has started, an error is not evidence that the
                // native side effect did not occur. Without a verified restore
                // path, report the layout as unknown instead of promising that
                // the prior state survived.
                throw MenuBarBackendError.mutationRecoveryFailed
            }
            do {
                let rollbackCandidate = try await compensationSnapshot(restoring: before)
                let rollbackSnapshot: MenuBarSnapshot
                switch validateBackendSnapshot(rollbackCandidate, previous: nil, now: now ?? Date()) {
                case let .success(snapshot):
                    try validateHistoryResult(snapshot, matches: before)
                    rollbackSnapshot = snapshot
                case let .failure(reason):
                    throw MenuBarBackendError.invalidSnapshot(reason)
                }
                currentSnapshot = rollbackSnapshot
                currentAuthorityObservation = platformAuthorityObservation(matching: rollbackSnapshot)
                lastKnownGoodSnapshot = rollbackSnapshot
                lastKnownGoodProfileID = activeProfileID
            } catch {
                currentSnapshot = nil
                activeProfileID = nil
                throw MenuBarBackendError.mutationRecoveryFailed
            }
            throw mutationError
        }
    }

    private func compensateLogicalMove(
        restoring before: MenuBarSnapshot,
        operation: MenuBarMoveOperation,
        now: Date
    ) async throws -> MenuBarSnapshot {
        guard let source = before.items.first(where: { $0.id == operation.itemID }) else {
            throw MenuBarBackendError.mutationRecoveryFailed
        }
        let orderedSourceSection = before.items
            .filter { $0.section == source.section && $0.displayID == source.displayID }
            .sorted { $0.order < $1.order }
        guard let index = orderedSourceSection.firstIndex(where: { $0.id == source.id }) else {
            throw MenuBarBackendError.mutationRecoveryFailed
        }
        _ = try await backend.move(MenuBarMoveOperation(
            itemID: source.id,
            section: source.section,
            index: index,
            destinationDisplayID: source.displayID
        ))

        let validationClockStartedAt = Date()
        var mostRecentError: (any Error)?
        for attempt in 0 ..< max(2, retryPolicy.maximumAttempts + 2) {
            do {
                let candidate = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                let validationNow = now.addingTimeInterval(
                    Date().timeIntervalSince(validationClockStartedAt)
                )
                let restored = try validateBackendSnapshot(
                    candidate,
                    previous: nil,
                    now: validationNow
                ).get()
                guard matchesLogicalArrangement(restored, target: before) else {
                    throw MenuBarBackendError.operationFailed(
                        "logical move compensation did not restore the prior layout"
                    )
                }
                return restored
            } catch {
                mostRecentError = error
            }
            if attempt + 1 < max(2, retryPolicy.maximumAttempts + 2) {
                try await Task.sleep(for: retryPolicy.delay(forAttempt: attempt))
            }
        }
        throw mostRecentError ?? MenuBarBackendError.mutationRecoveryFailed
    }

    private func matchesLogicalArrangement(
        _ snapshot: MenuBarSnapshot,
        target: MenuBarSnapshot
    ) -> Bool {
        let snapshot = layoutAuthoritySnapshot(snapshot)
        let target = layoutAuthoritySnapshot(target)
        guard Set(snapshot.items.map(\.id)) == Set(target.items.map(\.id)) else {
            return false
        }
        let observed = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        guard target.items.allSatisfy({ expected in
            observed[expected.id]?.section == expected.section &&
                observed[expected.id]?.displayID == expected.displayID
        }) else { return false }
        for section in [MenuBarSection.hidden, .alwaysHidden] {
            let expected = target.items.sorted { $0.order < $1.order }
                .filter { $0.section == section }.map(\.id)
            let actual = snapshot.items.sorted { $0.order < $1.order }
                .filter { $0.section == section }.map(\.id)
            guard actual == expected else { return false }
        }
        return true
    }

    /// macOS 27 publishes visibility changes through several cooperating
    /// processes. Immediately after a successful native assignment, its AX
    /// inventory can briefly omit one member of an application group before
    /// reaching the committed state. Observe that convergence without
    /// replaying the mutation; every attempt remains subject to structural
    /// validation and the complete logical postcondition.
    private func verifiedPostMutationSnapshot(
        for mutation: MenuBarMutation,
        from before: MenuBarSnapshot,
        restoreTarget: MenuBarSnapshot?,
        moveDestinationSupport: MenuBarMoveDestinationSupport?,
        visibilityAssignmentGranularity: MenuBarVisibilityAssignmentGranularity?,
        now: Date
    ) async throws -> MenuBarSnapshot {
        let retriesEventuallyConsistentVisibility = mutation.moveOperation != nil &&
            visibilityAssignmentGranularity == .applicationGroupAndKnownSystemItem
        let retriesTransientMove = switch mutation {
        case .transientReveal, .transientMove: true
        default: false
        }
        let attemptCount = retriesEventuallyConsistentVisibility
            // Golden Gate's compatibility inventory request can consume one
            // complete attempt while its XPC generation is replaced. A
            // second extra observation is required to prove that the first
            // valid post-write inventory has actually settled. Neither event
            // should reduce the caller's ordinary recovery budget.
            ? max(2, retryPolicy.maximumAttempts + 2)
            // The native helper can observe a successful status-item drag
            // before the app's next WindowServer inventory has caught up. A single
            // stale read must not trigger a whole-layout compensation while
            // the item is actually in the requested section.
            : (retriesTransientMove ? retryPolicy.maximumAttempts : 1)
        var mostRecentError: (any Error)?
        var previousSuccessfulVisibilitySignature: VisibilityObservationSignature?
        let validationClockStartedAt = Date()

        for attempt in 0 ..< attemptCount {
            try Task.checkCancellation()
            do {
                let candidate = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                // `now` is captured before the mutation starts so callers can
                // deterministically bind validation to one transaction. The
                // native Golden Gate inventory can take several seconds to
                // converge, though, and every later snapshot is necessarily
                // captured after that original instant. Advance the reference
                // by elapsed wall-clock time instead of misclassifying fresh
                // recovery snapshots as future-dated.
                let validationNow = now.addingTimeInterval(
                    Date().timeIntervalSince(validationClockStartedAt)
                )
                let snapshot: MenuBarSnapshot
                switch validateBackendSnapshot(candidate, previous: before, now: validationNow) {
                case let .success(validated):
                    lastRejection = nil
                    snapshot = validated
                case let .failure(reason):
                    lastRejection = reason
                    throw MenuBarBackendError.invalidSnapshot(reason)
                }

                let authoritySnapshot = layoutAuthoritySnapshot(snapshot)
                let authorityBefore = layoutAuthoritySnapshot(before)

                if let operation = mutation.moveOperation,
                   !(Self.isVisibleTransientReveal(
                       mutation,
                       operation: operation,
                       destinationSupport: moveDestinationSupport,
                       in: authoritySnapshot
                   ) ?? Self.isHiddenTransientRestoration(
                       mutation,
                       operation: operation,
                       destinationSupport: moveDestinationSupport,
                       in: authoritySnapshot,
                       from: authorityBefore
                   ) ?? MenuBarMovePlanner().resultMatches(
                       operation,
                       in: authoritySnapshot,
                       from: authorityBefore,
                       destinationSupport: moveDestinationSupport,
                       visibilityAssignmentGranularity: visibilityAssignmentGranularity
                   ))
                {
                    if retriesTransientMove,
                       let operation = mutation.moveOperation
                    {
                        let observed = authoritySnapshot.items.first { $0.id == operation.itemID }
                        Self.logger.notice(
                            "Transient move postcondition: section=\(observed?.section.rawValue ?? "missing", privacy: .public) onScreen=\(observed?.isOnScreen == true, privacy: .public) displayMatched=\(operation.destinationDisplayID.map { observed?.displayID == $0 } ?? true, privacy: .public)"
                        )
                    }
                    if moveDestinationSupport == .logicalSectionsPreserveNativeOrder,
                       let failure = MenuBarMovePlanner().logicalSectionVerificationFailure(
                           operation,
                           in: authoritySnapshot,
                           from: authorityBefore,
                           visibilityAssignmentGranularity: visibilityAssignmentGranularity
                       )
                    {
                        Self.logger.notice(
                            "Visibility logical postcondition mismatch: \(failure.rawValue, privacy: .public)"
                        )
                    }
                    throw MenuBarBackendError.operationFailed(
                        "menu bar move did not reach requested section"
                    )
                }
                if retriesEventuallyConsistentVisibility,
                   let operation = mutation.moveOperation
                {
                    let signature = VisibilityObservationSignature(
                        operation: operation,
                        snapshot: authoritySnapshot
                    )
                    guard previousSuccessfulVisibilitySignature == signature else {
                        previousSuccessfulVisibilitySignature = signature
                        throw MenuBarBackendError.operationFailed(
                            "menu bar visibility observation has not settled"
                        )
                    }
                }
                if case let .reveal(itemID) = mutation {
                    guard let beforeItem = authorityBefore.items.first(where: { $0.id == itemID }),
                          let revealedItem = authoritySnapshot.items.first(where: { $0.id == itemID }),
                          revealedItem.section == .visible,
                          revealedItem.isOnScreen,
                          revealedItem.displayID == beforeItem.displayID
                    else {
                        throw MenuBarBackendError.operationFailed(
                            "menu bar reveal did not produce a visible item on the requested display"
                        )
                    }
                }
                if let restoreTarget {
                    try validateHistoryResult(snapshot, matches: restoreTarget)
                }
                return snapshot
            } catch let error as MenuBarBackendError {
                mostRecentError = error
                Self.logger.notice(
                    "Visibility verification attempt \(attempt + 1, privacy: .public)/\(attemptCount, privacy: .public) rejected: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)"
                )
                if case .operationFailed("menu bar visibility observation has not settled") = error {
                    // Preserve the first valid observation so only an identical
                    // consecutive observation can commit the mutation.
                } else {
                    previousSuccessfulVisibilitySignature = nil
                }
            } catch {
                mostRecentError = error
                Self.logger.notice(
                    "Visibility verification attempt \(attempt + 1, privacy: .public)/\(attemptCount, privacy: .public) rejected: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)"
                )
                previousSuccessfulVisibilitySignature = nil
            }

            if attempt + 1 < attemptCount {
                try await Task.sleep(for: retryPolicy.delay(forAttempt: attempt))
            }
        }

        throw mostRecentError ?? MenuBarBackendError.operationFailed(
            "menu bar mutation postcondition was unavailable"
        )
    }

    /// A temporary reveal needs a usable on-screen item, not a particular
    /// insertion slot. macOS can place a newly revealed status item beside a
    /// different neighbor while preserving its visible section. Permanent
    /// moves and visible-section restoration still require the exact slot.
    private static func isVisibleTransientReveal(
        _ mutation: MenuBarMutation,
        operation: MenuBarMoveOperation,
        destinationSupport: MenuBarMoveDestinationSupport?,
        in snapshot: MenuBarSnapshot
    ) -> Bool? {
        guard case .transientReveal = mutation else { return nil }
        guard destinationSupport != .logicalSectionsPreserveNativeOrder else { return nil }
        guard operation.section == .visible,
              let item = snapshot.items.first(where: { $0.id == operation.itemID })
        else { return false }
        return item.section == .visible && item.isOnScreen &&
            operation.destinationDisplayID.map { item.displayID == $0 } != false
    }

    /// A temporary reveal is finished once its item is safely hidden again.
    /// macOS may reinsert a rehidden status item beside a different hidden
    /// neighbor; treating that harmless order drift as failure would roll the
    /// item back into the visible menu bar. Permanent layout edits retain the
    /// exact-neighbor postcondition.
    private static func isHiddenTransientRestoration(
        _ mutation: MenuBarMutation,
        operation: MenuBarMoveOperation,
        destinationSupport: MenuBarMoveDestinationSupport?,
        in snapshot: MenuBarSnapshot,
        from before: MenuBarSnapshot
    ) -> Bool? {
        guard case .transientMove = mutation,
              destinationSupport != .logicalSectionsPreserveNativeOrder,
              operation.section == .hidden || operation.section == .alwaysHidden
        else { return nil }
        guard let item = snapshot.items.first(where: { $0.id == operation.itemID }),
              item.section == operation.section,
              !item.isOnScreen,
              operation.destinationDisplayID.map({ item.displayID == $0 }) != false,
              snapshot.displayIDs == before.displayIDs,
              Set(snapshot.items.map(\.id)) == Set(before.items.map(\.id))
        else { return false }
        return before.items.allSatisfy { original in
            guard original.id != operation.itemID,
                  let current = snapshot.items.first(where: { $0.id == original.id })
            else { return original.id == operation.itemID }
            return current.section == original.section &&
                current.displayID == original.displayID
        }
    }

    private struct VisibilityObservationSignature: Equatable {
        private struct SemanticIdentity: Hashable {
            let bundleIdentifier: String
            let accessibilityIdentifier: String?
            let title: String?
            let fallbackFingerprint: String?

            init(_ id: MenuBarItemID) {
                bundleIdentifier = id.bundleIdentifier
                accessibilityIdentifier = id.accessibilityIdentifier
                title = id.title
                fallbackFingerprint = id.fallbackFingerprint
            }
        }

        private let identities: Set<SemanticIdentity>
        private let sections: Set<MenuBarSection>
        private let displayIDs: Set<MenuBarDisplayID?>

        init(operation: MenuBarMoveOperation, snapshot: MenuBarSnapshot) {
            let isApplicationGroup = !operation.itemID.bundleIdentifier
                .lowercased()
                .hasPrefix("com.apple.")
            let observed = snapshot.items.filter { item in
                if isApplicationGroup {
                    item.id.bundleIdentifier == operation.itemID.bundleIdentifier
                } else {
                    item.id == operation.itemID
                }
            }
            identities = Set(observed.map { SemanticIdentity($0.id) })
            sections = Set(observed.map(\.section))
            displayIDs = Set(observed.map(\.displayID))
        }
    }

    private func validateProfileResult(
        _ plan: ProfileLayoutReconciler.DisplayPlan,
        in snapshot: MenuBarSnapshot
    ) throws {
        let snapshot = layoutAuthoritySnapshot(snapshot)
        guard plan.matches(items: snapshot.items) else {
            throw MenuBarBackendError.operationFailed(
                "profile activation did not reach requested layout"
            )
        }
    }

    private func validateArrangementResult(
        layout: ProfileLayout,
        displayID: MenuBarDisplayID?,
        plan: MenuBarArrangementExecutionPlan,
        admittedLayoutPlan: ProfileLayoutReconciler.DisplayPlan,
        in snapshot: MenuBarSnapshot
    ) throws {
        let snapshot = layoutAuthoritySnapshot(snapshot)
        if plan.nativeOrder == .applySavedOrder,
           plan.shelfOrder == .applySavedOrder
        {
            try validateProfileResult(admittedLayoutPlan, in: snapshot)
            return
        }

        if plan.nativeOrder == .preserveCurrentOrder {
            guard admittedLayoutPlan.matchesLogicalArrangement(
                items: snapshot.items,
                validateShelfOrder: plan.shelfOrder == .applySavedOrder
            ) else {
                Self.logLogicalProfileMismatch(admittedLayoutPlan, snapshot: snapshot)
                throw MenuBarBackendError.operationFailed(
                    "profile activation changed an unrequested section or display"
                )
            }
            return
        }

        let scopedItems = displayID.map { requestedDisplayID in
            snapshot.items.filter { $0.displayID == requestedDisplayID }
        } ?? snapshot.items
        let byID = Dictionary(uniqueKeysWithValues: scopedItems.map { ($0.id, $0) })
        let requestedSections = Dictionary(uniqueKeysWithValues:
            layout.visible.map { ($0, MenuBarSection.visible) } +
                layout.hidden.map { ($0, MenuBarSection.hidden) } +
                layout.alwaysHidden.map { ($0, MenuBarSection.alwaysHidden) })
        guard requestedSections.allSatisfy({ itemID, section in
            byID[itemID]?.section == section
        }) else {
            throw MenuBarBackendError.operationFailed(
                "profile activation did not reach requested visibility"
            )
        }

        if plan.shelfOrder == .applySavedOrder {
            for requested in [layout.hidden, layout.alwaysHidden] {
                let requestedSet = Set(requested)
                let observed = scopedItems
                    .sorted { $0.order < $1.order }
                    .filter { requestedSet.contains($0.id) }
                    .map(\.id)
                guard observed == requested else {
                    throw MenuBarBackendError.operationFailed(
                        "profile activation did not reach requested shelf order"
                    )
                }
            }
        }
    }

    private static func shouldApply(
        _ operation: MenuBarMoveOperation,
        to snapshot: MenuBarSnapshot,
        arrangementPlan: MenuBarArrangementExecutionPlan
    ) -> Bool {
        guard let source = snapshot.items.first(where: { $0.id == operation.itemID }) else {
            return true
        }
        if source.section != operation.section {
            return arrangementPlan.concealment != nil
        }
        if operation.section == .visible {
            return arrangementPlan.nativeOrder == .applySavedOrder
        }
        return arrangementPlan.shelfOrder == .applySavedOrder
    }

    /// Native group assignments can move several siblings at once. Translate
    /// the complete admitted target against each new observation, never replay
    /// a stale sibling operation or shelf index from the original plan.
    private static func nextLogicalProfileOperation(
        target: ProfileLayoutReconciler.DisplayPlan,
        snapshot: MenuBarSnapshot,
        displayID: MenuBarDisplayID?,
        arrangementPlan: MenuBarArrangementExecutionPlan,
        destinationSupport: MenuBarMoveDestinationSupport
    ) throws -> MenuBarMoveOperation? {
        guard !snapshot.menuTrackingIsActive else { throw MenuBarBackendError.unsafeMenuTracking }
        let observed = snapshot.items.filter { displayID == nil || $0.displayID == displayID }
        let expectedIDs = Set(target.targets.flatMap(\.layout.allItemIDs))
        guard Set(observed.map(\.id)) == expectedIDs,
              target.targets.allSatisfy({ scoped in
                  Set(observed.filter { $0.displayID == scoped.displayID }.map(\.id)) ==
                      Set(scoped.layout.allItemIDs)
              })
        else {
            logLogicalProfileMismatch(target, snapshot: snapshot)
            throw MenuBarBackendError.operationFailed("profile activation changed an unrequested section or display")
        }
        let layout = ProfileLayout(
            visible: target.targets.flatMap(\.layout.visible),
            hidden: target.targets.flatMap(\.layout.hidden),
            alwaysHidden: target.targets.flatMap(\.layout.alwaysHidden)
        )
        let remaining = try ProfileLayoutReconciler.planAcrossDisplays(
            layout: preservingNativeVisibleOrder(in: layout, snapshot: snapshot),
            items: snapshot.items, displayID: displayID, destinationSupport: destinationSupport
        )
        return remaining.operations.first {
            shouldApply($0, to: snapshot, arrangementPlan: arrangementPlan)
        }
    }

    /// Only counts and booleans cross the diagnostic boundary. Inventory and
    /// control guards remain strict; this does not adopt a changed inventory.
    private static func logLogicalProfileMismatch(
        _ target: ProfileLayoutReconciler.DisplayPlan,
        snapshot: MenuBarSnapshot
    ) {
        let expected = Set(target.targets.flatMap(\.layout.allItemIDs))
        let relevantItems = target.isGloballyScoped ? snapshot.items : snapshot.items.filter { item in
            target.targets.contains { $0.displayID == item.displayID }
        }
        let observed = Set(relevantItems.map(\.id))
        let missing = expected.subtracting(observed)
        let added = observed.subtracting(expected)
        let missingSystem = missing.count { $0.bundleIdentifier.lowercased().hasPrefix("com.apple.") }
        let missingApplication = missing.count - missingSystem
        let sectionMismatch = target.targets.reduce(0) { total, scoped in
            let sections = Dictionary(uniqueKeysWithValues:
                scoped.layout.visible.map { ($0, MenuBarSection.visible) } +
                    scoped.layout.hidden.map { ($0, MenuBarSection.hidden) } +
                    scoped.layout.alwaysHidden.map { ($0, MenuBarSection.alwaysHidden) })
            return total + relevantItems.count { item in
                sections[item.id].map { $0 != item.section } ?? false
            }
        }
        Self.logger.error(
            "Profile observation mismatch: expected=\(expected.count, privacy: .public) observed=\(observed.count, privacy: .public) missing=\(missing.count, privacy: .public) added=\(added.count, privacy: .public) missingSystem=\(missingSystem, privacy: .public) missingApplication=\(missingApplication, privacy: .public) sections=\(sectionMismatch, privacy: .public)"
        )
    }

    /// A fresh replan is not permission to overwrite changes outside the move.
    /// Unexpected concurrent edits take the existing superseded/observation-only
    /// path, withdrawing authority without blindly restoring the old layout.
    private func validateLogicalProfileStep(
        operation: MenuBarMoveOperation,
        before: MenuBarSnapshot,
        after: MenuBarSnapshot
    ) throws {
        let before = layoutAuthoritySnapshot(before)
        let after = layoutAuthoritySnapshot(after)
        guard let source = before.items.first(where: { $0.id == operation.itemID }) else {
            throw MenuBarBackendError.staleItem(operation.itemID)
        }
        let affected = Self.logicalMutationItemIDs(operation: operation, source: source, before: before)
        let currentByID = Dictionary(uniqueKeysWithValues: after.items.map { ($0.id, $0) })
        guard before.items.allSatisfy({ prior in
            currentByID[prior.id].map { $0.displayID == prior.displayID } ?? true
        }) else { throw MenuBarBackendError.mutationSuperseded }
        let beforeUnchanged = before.items.filter { !affected.contains($0.id) }
        let afterUnchanged = after.items.filter { !affected.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: afterUnchanged.map { ($0.id, $0) })
        guard beforeUnchanged.allSatisfy({ prior in
            guard let current = byID[prior.id] else { return true }
            return prior.section == current.section && prior.displayID == current.displayID
        }) else { throw MenuBarBackendError.mutationSuperseded }
        let shared = Set(beforeUnchanged.map(\.id)).intersection(Set(afterUnchanged.map(\.id)))
        for display in Set(beforeUnchanged.map(\.displayID)) {
            for section in [MenuBarSection.hidden, .alwaysHidden] {
                let previousOrder = beforeUnchanged.filter {
                    $0.displayID == display && $0.section == section && shared.contains($0.id)
                }.sorted { $0.order < $1.order }.map(\.id)
                let currentOrder = afterUnchanged.filter {
                    $0.displayID == display && $0.section == section && shared.contains($0.id)
                }.sorted { $0.order < $1.order }.map(\.id)
                guard previousOrder == currentOrder else { throw MenuBarBackendError.mutationSuperseded }
            }
        }
    }

    private static func logicalMutationItemIDs(
        operation: MenuBarMoveOperation,
        source: MenuBarItemDescriptor,
        before: MenuBarSnapshot
    ) -> Set<MenuBarItemID> {
        let changesGroupVisibility = source.section != operation.section &&
            !source.id.bundleIdentifier.lowercased().hasPrefix("com.apple.")
        return Set(before.items.filter { item in
            changesGroupVisibility ? item.id.bundleIdentifier == source.id.bundleIdentifier : item.id == source.id
        }.map(\.id))
    }

    private static func preservingNativeVisibleOrder(
        in layout: ProfileLayout,
        snapshot: MenuBarSnapshot
    ) -> ProfileLayout {
        let requestedVisible = Set(layout.visible)
        return ProfileLayout(
            visible: snapshot.items
                .sorted { $0.order < $1.order }
                .filter { requestedVisible.contains($0.id) }
                .map(\.id),
            hidden: layout.hidden,
            alwaysHidden: layout.alwaysHidden
        )
    }

    private static func layout(
        from snapshot: MenuBarSnapshot,
        displayID: MenuBarDisplayID?
    ) -> ProfileLayout {
        let ordered = snapshot.items
            .filter { !$0.isBarlineControlItem && (displayID == nil || $0.displayID == displayID) }
            .sorted { $0.order < $1.order }
        return ProfileLayout(
            visible: ordered.filter { $0.section == .visible }.map(\.id),
            hidden: ordered.filter { $0.section == .hidden }.map(\.id),
            alwaysHidden: ordered.filter { $0.section == .alwaysHidden }.map(\.id)
        )
    }

    private func verifiedProfileSnapshot(
        before: MenuBarSnapshot,
        layout: ProfileLayout,
        displayID: MenuBarDisplayID?,
        arrangementPlan: MenuBarArrangementExecutionPlan?,
        admittedLayoutPlan: ProfileLayoutReconciler.DisplayPlan,
        now: Date
    ) async throws -> MenuBarSnapshot {
        let retriesLogicalConvergence = arrangementPlan?.nativeOrder == .preserveCurrentOrder
        let attemptCount = retriesLogicalConvergence
            ? max(2, retryPolicy.maximumAttempts + 2)
            : 1
        let validationClockStartedAt = Date()
        var previousSignature: ProfileObservationSignature?
        var mostRecentError: (any Error)?

        for attempt in 0 ..< attemptCount {
            try Task.checkCancellation()
            do {
                let candidate = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                let validationNow = now.addingTimeInterval(
                    Date().timeIntervalSince(validationClockStartedAt)
                )
                let snapshot: MenuBarSnapshot
                switch validateBackendSnapshot(candidate, previous: before, now: validationNow) {
                case let .success(validated):
                    lastRejection = nil
                    snapshot = validated
                case let .failure(reason):
                    lastRejection = reason
                    throw MenuBarBackendError.invalidSnapshot(reason)
                }
                if let arrangementPlan {
                    try validateArrangementResult(
                        layout: layout,
                        displayID: displayID,
                        plan: arrangementPlan,
                        admittedLayoutPlan: admittedLayoutPlan,
                        in: snapshot
                    )
                } else {
                    try validateProfileResult(admittedLayoutPlan, in: snapshot)
                }
                if retriesLogicalConvergence {
                    let signature = ProfileObservationSignature(snapshot: layoutAuthoritySnapshot(snapshot))
                    guard previousSignature == signature else {
                        previousSignature = signature
                        throw MenuBarBackendError.operationFailed(
                            "profile visibility observation has not settled"
                        )
                    }
                }
                return snapshot
            } catch {
                mostRecentError = error
                if let backendError = error as? MenuBarBackendError,
                   case .operationFailed("profile visibility observation has not settled") = backendError
                {
                    // Preserve the first accepted observation for the required
                    // consecutive-stability proof.
                } else {
                    previousSignature = nil
                }
            }
            if attempt + 1 < attemptCount {
                try await Task.sleep(for: retryPolicy.delay(forAttempt: attempt))
            }
        }
        throw mostRecentError ?? MenuBarBackendError.operationFailed(
            "profile activation postcondition was unavailable"
        )
    }

    private func compensateSupportedArrangement(
        restoring before: MenuBarSnapshot,
        displayID: MenuBarDisplayID?,
        arrangementPlan: MenuBarArrangementExecutionPlan,
        destinationSupport: MenuBarMoveDestinationSupport,
        transactionOwnedItemIDs: Set<MenuBarItemID>,
        now: Date
    ) async throws -> MenuBarSnapshot {
        guard arrangementPlan.nativeOrder == .preserveCurrentOrder else {
            throw MenuBarBackendError.unavailableCapability("restore")
        }
        let validationClockStartedAt = Date()
        let observed = try await normalizedBackendSnapshot(requiresFreshObservation: true)
        var current = try validateBackendSnapshot(
            observed,
            previous: nil,
            now: now.addingTimeInterval(Date().timeIntervalSince(validationClockStartedAt))
        ).get()
        let authorityBefore = layoutAuthoritySnapshot(before)
        current = layoutAuthoritySnapshot(current)
        if Set(current.items.map(\.id)) != Set(authorityBefore.items.map(\.id)) {
            guard destinationSupport == .logicalSectionsPreserveNativeOrder,
                  GoldenGateConcealmentPolicy.permitsFocusDeassertionRecovery(
                      original: authorityBefore, current: current,
                      transactionOwnedItemIDs: transactionOwnedItemIDs
                  )
            else {
                throw MenuBarBackendError.operationFailed("profile recovery inventory changed")
            }
            try Task.checkCancellation()
            try await backend.configureConcealment(MenuBarConcealmentConfiguration(
                visibleItemIDs: authorityBefore.items.filter { !$0.isBarlineControlItem }.map(\.id),
                concealedItemIDs: []
            ))
            var stableSignature: ProfileObservationSignature?
            var recovered: MenuBarSnapshot?
            let attempts = max(2, retryPolicy.maximumAttempts + 2)
            for attempt in 0 ..< attempts {
                try Task.checkCancellation()
                let rawCandidate = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                let validatedCandidate = try validateBackendSnapshot(
                    rawCandidate, previous: current,
                    now: now.addingTimeInterval(Date().timeIntervalSince(validationClockStartedAt))
                ).get()
                let candidate = layoutAuthoritySnapshot(validatedCandidate)
                guard GoldenGateConcealmentPolicy.preservesUnownedRecoveryInventory(
                    original: authorityBefore, current: candidate,
                    transactionOwnedItemIDs: transactionOwnedItemIDs
                ) else { throw MenuBarBackendError.mutationSuperseded }
                if Set(candidate.items.map(\.id)) == Set(authorityBefore.items.map(\.id)) {
                    let signature = ProfileObservationSignature(snapshot: candidate)
                    if signature == stableSignature {
                        recovered = candidate
                        break
                    }
                    stableSignature = signature
                } else {
                    stableSignature = nil
                }
                current = candidate
                if attempt + 1 < attempts {
                    try await Task.sleep(for: retryPolicy.delay(forAttempt: attempt))
                }
            }
            guard let recovered else {
                throw MenuBarBackendError.operationFailed("profile recovery inventory did not return")
            }
            current = recovered
        }
        let originalLayout = Self.layout(from: authorityBefore, displayID: displayID)
        let admittedLayout = Self.preservingNativeVisibleOrder(
            in: originalLayout,
            snapshot: current
        )
        let plan = try ProfileLayoutReconciler.planAcrossDisplays(
            layout: admittedLayout,
            items: layoutAuthoritySnapshot(current).items,
            displayID: displayID,
            destinationSupport: destinationSupport
        )
        if destinationSupport == .logicalSectionsPreserveNativeOrder {
            var executionSnapshot = layoutAuthoritySnapshot(current)
            let maximumMoves = max(1, current.items.count * 4)
            var completedMoves = 0
            while let operation = try Self.nextLogicalProfileOperation(
                target: plan, snapshot: executionSnapshot, displayID: displayID,
                arrangementPlan: arrangementPlan, destinationSupport: destinationSupport
            ) {
                guard completedMoves < maximumMoves else {
                    throw MenuBarBackendError.operationFailed("profile layout execution did not converge")
                }
                try Task.checkCancellation()
                _ = try await backend.move(operation)
                completedMoves += 1
                let rawNextSnapshot = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                let nextSnapshot = try validateBackendSnapshot(
                    rawNextSnapshot, previous: executionSnapshot,
                    now: now.addingTimeInterval(Date().timeIntervalSince(validationClockStartedAt))
                ).get()
                let projectedNextSnapshot = layoutAuthoritySnapshot(nextSnapshot)
                try validateLogicalProfileStep(
                    operation: operation, before: executionSnapshot, after: projectedNextSnapshot
                )
                executionSnapshot = projectedNextSnapshot
            }
        } else {
            for operation in plan.operations where Self.shouldApply(
                operation, to: current, arrangementPlan: arrangementPlan
            ) {
                _ = try await backend.move(operation)
            }
        }
        let candidate = try await normalizedBackendSnapshot(requiresFreshObservation: true)
        let restored = try validateBackendSnapshot(
            candidate,
            previous: nil,
            now: now.addingTimeInterval(Date().timeIntervalSince(validationClockStartedAt))
        ).get()
        try validateArrangementResult(
            layout: originalLayout,
            displayID: displayID,
            plan: arrangementPlan,
            admittedLayoutPlan: plan,
            in: restored
        )
        return restored
    }

    /// Captures a fresh, uniquely identified active display without mutating it.
    public func captureDisplayVariant(profile: BarlineProfile) async throws -> DisplayProfileOverride {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)
        try Task.checkCancellation()
        let environment = try await backend.environment()
        guard let displayID = environment.activeStableDisplayID else {
            throw DisplayVariantCapture.Failure.unavailable
        }
        let candidate = try await normalizedBackendSnapshot(requiresFreshObservation: true)
        let snapshot = try validateBackendSnapshot(candidate, previous: currentSnapshot, now: Date()).get()
        guard try await backend.environment().activeStableDisplayID == displayID else {
            throw DisplayVariantCapture.Failure.unavailable
        }
        return try DisplayVariantCapture.capture(profile: profile, snapshot: snapshot, displayID: displayID)
    }

    /// Applies a profile transactionally; failures restore prior layout and authority.
    @discardableResult
    public func activate(
        profile: BarlineProfile,
        on displayID: MenuBarDisplayID? = nil,
        now: Date? = nil,
        expectedGeneration: UInt64? = nil,
        workspaceTransaction: MenuBarWorkspaceTransaction? = nil,
        admission: (@Sendable () async throws -> Void)? = nil,
        prepareCheckpoint: (
            @Sendable (MenuBarWorkspaceCheckpoint, ResolvedProfilePresentation) async throws -> Void
        )? = nil
    ) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)

        try Task.checkCancellation()
        try await admission?()
        if let expectedGeneration {
            try requireCurrentGeneration(expectedGeneration)
        }
        try ProfileValidator().validate(profile)
        let startingWorkspaceRevision = await workspaceTransaction?.currentRevision()
        let workspaceBefore = try await workspaceTransaction?.capture()
        if let startingWorkspaceRevision,
           await workspaceTransaction?.currentRevision() != startingWorkspaceRevision
        {
            throw MenuBarBackendError.operationFailed(
                "workspace changed while profile activation was starting"
            )
        }
        let startingCheckpoint: HistoryCheckpoint
        if workspaceTransaction != nil {
            startingCheckpoint = try await refreshedHistoryStartingCheckpoint(
                workspace: workspaceBefore,
                workspaceRevision: startingWorkspaceRevision,
                now: now
            )
        } else {
            let snapshot = try await validatedStartingSnapshot(now: now)
            startingCheckpoint = HistoryCheckpoint(
                snapshot: snapshot,
                activeProfileID: activeProfileID,
                workspace: workspaceBefore,
                workspaceRevision: startingWorkspaceRevision
            )
        }
        let before = startingCheckpoint.snapshot
        let priorPlatformPresenceContract = activePlatformPresenceContract
        activePlatformPresenceContract = currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        defer { activePlatformPresenceContract = priorPlatformPresenceContract }
        let authorityBefore = layoutAuthoritySnapshot(before)
        guard !before.menuTrackingIsActive else {
            throw MenuBarBackendError.unsafeMenuTracking
        }

        let activeDisplayID: MenuBarDisplayID? = if let displayID {
            displayID
        } else if let environment = try? await backend.environment(),
                  let environmentDisplayID = environment.activeStableDisplayID,
                  before.displayIDs.contains(environmentDisplayID)
        {
            environmentDisplayID
        } else {
            nil
        }
        if let activeDisplayID, !before.displayIDs.contains(activeDisplayID) {
            throw MenuBarBackendError.operationFailed("requested profile display is unavailable")
        }
        let matchingDisplayOverride = activeDisplayID.flatMap { activeDisplayID in
            DisplayProfileOverrideResolver().resolve(
                profile: profile,
                requestedDisplayID: activeDisplayID,
                snapshot: authorityBefore
            )
        }
        // A base profile can contain items from every display. Only a matching
        // display override is scoped and retargeted to the active display;
        // applying the base layout preserves each item's source display.
        let unresolvedPresentation = profile.resolvedPresentation(using: matchingDisplayOverride)
        let presentation: ResolvedProfilePresentation
        if let activePlatformPresenceContract {
            guard let projectedPresentation = activePlatformPresenceContract.projecting(unresolvedPresentation) else {
                throw MenuBarBackendError.operationFailed("macOS Focus cannot be assigned to a hidden section")
            }
            presentation = try projectedPresentation.resolvingItemIdentities(in: authorityBefore)
        } else {
            presentation = try unresolvedPresentation.resolvingItemIdentities(in: before)
        }
        let profileDisplayID = presentation.destinationDisplayID
        let layout = presentation.layout
        let knownItemIDs = Set(authorityBefore.items.map(\.id))
        for itemID in layout.allItemIDs where !knownItemIDs.contains(itemID) {
            throw MenuBarBackendError.staleItem(itemID)
        }
        // Reject an impossible physical destination before journaling or changing
        // workspace state. The helper's own admission checks remain authoritative.
        let backendCapabilities = await backend.capabilities
        let destinationSupport = backendCapabilities.moveDestinationSupport ?? .existingItemRequired
        let admittedLayout = if backendCapabilities.arrangement?.canApplySavedNativeOrder == false {
            Self.preservingNativeVisibleOrder(in: layout, snapshot: authorityBefore)
        } else {
            layout
        }
        let layoutPlan = try ProfileLayoutReconciler.planAcrossDisplays(
            layout: admittedLayout, items: authorityBefore.items, displayID: profileDisplayID,
            destinationSupport: destinationSupport
        )
        let arrangementPlan = try backendCapabilities.arrangement.map {
            try MenuBarArrangementPolicy().plan(
                layout: layout,
                snapshot: authorityBefore,
                capabilities: $0,
                barlineBundleIdentifier: "com.mabryventures.Barline"
            )
        }

        let priorProfileID = startingCheckpoint.activeProfileID
        if let prepareCheckpoint {
            guard let workspaceBefore else {
                throw MenuBarBackendError.operationFailed(
                    "checkpoint preparation requires a workspace transaction"
                )
            }
            try await prepareCheckpoint(
                MenuBarWorkspaceCheckpoint(
                    snapshot: before,
                    activeProfileID: priorProfileID,
                    activeDisplayID: workspaceBefore.presentation?.destinationDisplayID,
                    workspace: workspaceBefore
                ),
                presentation
            )
        }
        var targetWorkspace = ProfileWorkspaceState(profile: profile)
        targetWorkspace.presentation = presentation
        try await admission?()
        try await supersedeTemporaryReveals()
        try Task.checkCancellation()
        try await admission?()
        mutationGeneration &+= 1
        let generation = mutationGeneration
        var didBeginLayoutMutation = false
        var completedLayoutMutationCount = 0
        var attemptedLogicalMutationItemIDs = Set<MenuBarItemID>()
        var didBeginWorkspaceMutation = false
        var appliedWorkspaceRevision: UInt64?

        do {
            if let workspaceTransaction {
                if let startingWorkspaceRevision {
                    do {
                        guard let revision = try await workspaceTransaction.apply(
                            targetWorkspace,
                            ifCurrentRevision: startingWorkspaceRevision
                        ) else {
                            throw MenuBarWorkspaceTransactionError.superseded
                        }
                        appliedWorkspaceRevision = revision
                        didBeginWorkspaceMutation = true
                    } catch let transactionError as MenuBarWorkspaceTransactionError {
                        throw transactionError
                    } catch {
                        didBeginWorkspaceMutation = true
                        throw error
                    }
                } else {
                    didBeginWorkspaceMutation = true
                    try await workspaceTransaction.apply(targetWorkspace)
                }
            }
            if let arrangementPlan,
               destinationSupport == .logicalSectionsPreserveNativeOrder
            {
                var executionSnapshot = authorityBefore
                let executionStartedAt = Date()
                let maximumMoves = max(1, before.items.count * 4)
                while let operation = try Self.nextLogicalProfileOperation(
                    target: layoutPlan, snapshot: executionSnapshot, displayID: profileDisplayID,
                    arrangementPlan: arrangementPlan, destinationSupport: destinationSupport
                ) {
                    guard completedLayoutMutationCount < maximumMoves else {
                        throw MenuBarBackendError.operationFailed("profile layout execution did not converge")
                    }
                    try Task.checkCancellation()
                    try await admission?()
                    didBeginLayoutMutation = true
                    if let source = executionSnapshot.items.first(where: { $0.id == operation.itemID }) {
                        attemptedLogicalMutationItemIDs.formUnion(Self.logicalMutationItemIDs(
                            operation: operation, source: source, before: executionSnapshot
                        ))
                    }
                    _ = try await backend.move(operation)
                    completedLayoutMutationCount += 1
                    let rawNextSnapshot = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                    let nextSnapshot = try validateBackendSnapshot(
                        rawNextSnapshot, previous: executionSnapshot,
                        now: (now ?? executionStartedAt).addingTimeInterval(Date().timeIntervalSince(executionStartedAt))
                    ).get()
                    let nextAuthoritySnapshot = layoutAuthoritySnapshot(nextSnapshot)
                    try validateLogicalProfileStep(
                        operation: operation, before: executionSnapshot, after: nextAuthoritySnapshot
                    )
                    executionSnapshot = nextAuthoritySnapshot
                }
            } else {
                for operation in layoutPlan.operations {
                    if let arrangementPlan,
                       !Self.shouldApply(operation, to: before, arrangementPlan: arrangementPlan)
                    {
                        continue
                    }
                    try Task.checkCancellation()
                    try await admission?()
                    didBeginLayoutMutation = true
                    _ = try await backend.move(operation)
                    completedLayoutMutationCount += 1
                }
            }

            try Task.checkCancellation()
            let snapshot = try await verifiedProfileSnapshot(
                before: before,
                layout: layout,
                displayID: profileDisplayID,
                arrangementPlan: arrangementPlan,
                admittedLayoutPlan: layoutPlan,
                now: now ?? Date()
            )
            try await admission?()
            guard generation == mutationGeneration else {
                throw CancellationError()
            }
            if let matchingDisplayOverride, let profileDisplayID {
                guard let verifiedMatch = DisplayProfileOverrideResolver().resolve(
                    profile: profile,
                    requestedDisplayID: profileDisplayID,
                    snapshot: snapshot
                ),
                    verifiedMatch.override.displayID == matchingDisplayOverride.override.displayID,
                    verifiedMatch.override.displayFingerprint
                    == matchingDisplayOverride.override.displayFingerprint
                else {
                    throw MenuBarBackendError.operationFailed(
                        "profile display identity changed during activation"
                    )
                }
                if let fingerprint = matchingDisplayOverride.override.displayFingerprint {
                    let matchingIdentities = snapshot.displayIdentities?.count {
                        $0.hardwareFingerprint == fingerprint
                    } ?? 0
                    guard matchingIdentities == 1 else {
                        throw MenuBarBackendError.operationFailed(
                            "profile display identity became ambiguous during activation"
                        )
                    }
                }
            }
            if layoutPlan.isGloballyScoped, snapshot.displayIDs != before.displayIDs {
                throw MenuBarBackendError.operationFailed("profile display topology changed during activation")
            }
            try await admission?()
            if let appliedWorkspaceRevision,
               await workspaceTransaction?.currentRevision() != appliedWorkspaceRevision
            {
                throw MenuBarWorkspaceTransactionError.superseded
            }
            try Task.checkCancellation()
            currentSnapshot = snapshot
            currentAuthorityObservation = platformAuthorityObservation(matching: snapshot)
            lastKnownGoodSnapshot = snapshot
            lastRejection = nil
            activeProfileID = profile.id
            lastKnownGoodProfileID = profile.id
            recordUndoCheckpoint(
                before,
                activeProfileID: priorProfileID,
                workspace: workspaceBefore
            )
            return snapshot
        } catch {
            let activationError = error
            Self.logger.error(
                "Profile activation rejected: \(PrivacySafeDiagnostics.errorCode(activationError), privacy: .public)"
            )
            // A preflight rejection describes only the move that threw. A
            // prior move in this same profile may already have succeeded and
            // still requires verified compensation.
            let layoutDidNotStart = completedLayoutMutationCount == 0 &&
                Self.mutationDidNotStart(activationError)
            let layoutWasSuperseded = Self.mutationRequiresNativeObservation(activationError)
            if activationError is MenuBarWorkspaceTransactionError,
               !didBeginWorkspaceMutation,
               !didBeginLayoutMutation
            {
                activeProfileID = nil
                lastKnownGoodProfileID = nil
                throw activationError
            }
            var workspaceRollbackError: (any Error)?
            var layoutRollbackError: (any Error)?
            var verifiedRollbackSnapshot: MenuBarSnapshot?
            var workspaceWasSuperseded = false
            var rollbackWorkspaceRevision = startingWorkspaceRevision
            if let workspaceBefore, let workspaceTransaction {
                do {
                    if let appliedWorkspaceRevision {
                        let restoredRevision = try await withCompensation {
                            try await workspaceTransaction.apply(workspaceBefore, ifCurrentRevision: appliedWorkspaceRevision)
                        }
                        if let restoredRevision {
                            rollbackWorkspaceRevision = restoredRevision
                        } else {
                            workspaceWasSuperseded = true
                            let appliedWorkspace = targetWorkspace
                            rollbackWorkspaceRevision = try await withCompensation {
                                try await workspaceTransaction.rollbackSuperseded(from: appliedWorkspace, to: workspaceBefore)
                            }
                        }
                    } else {
                        try await withCompensation { try await workspaceTransaction.apply(workspaceBefore) }
                        rollbackWorkspaceRevision = await workspaceTransaction.currentRevision()
                    }
                } catch {
                    workspaceRollbackError = error
                }
            }
            if layoutDidNotStart {
                verifiedRollbackSnapshot = before
            } else if layoutWasSuperseded {
                do {
                    let observed = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                    switch validateBackendSnapshot(observed, previous: nil, now: now ?? Date()) {
                    case let .success(snapshot):
                        verifiedRollbackSnapshot = snapshot
                    case let .failure(reason):
                        throw MenuBarBackendError.invalidSnapshot(reason)
                    }
                } catch {
                    layoutRollbackError = error
                }
            } else if didBeginLayoutMutation || didBeginWorkspaceMutation {
                if await backend.capabilities.canRestore {
                    do {
                        let candidate = try await compensationSnapshot(restoring: before)
                        switch validateBackendSnapshot(candidate, previous: nil, now: now ?? Date()) {
                        case let .success(snapshot):
                            try validateHistoryResult(snapshot, matches: before)
                            verifiedRollbackSnapshot = snapshot
                        case let .failure(reason):
                            throw MenuBarBackendError.invalidSnapshot(reason)
                        }
                    } catch {
                        layoutRollbackError = error
                    }
                } else if let arrangementPlan,
                          arrangementPlan.nativeOrder == .preserveCurrentOrder
                {
                    do {
                        let ownedItemIDs = attemptedLogicalMutationItemIDs
                        verifiedRollbackSnapshot = try await withCompensation {
                            try await self.compensateSupportedArrangement(
                                restoring: before,
                                displayID: profileDisplayID,
                                arrangementPlan: arrangementPlan,
                                destinationSupport: destinationSupport,
                                transactionOwnedItemIDs: ownedItemIDs,
                                now: now ?? Date()
                            )
                        }
                    } catch {
                        layoutRollbackError = error
                    }
                } else {
                    layoutRollbackError = MenuBarBackendError.unavailableCapability("restore")
                }
            } else {
                verifiedRollbackSnapshot = before
            }
            if workspaceRollbackError == nil,
               layoutRollbackError == nil,
               let verifiedRollbackSnapshot
            {
                if let rollbackWorkspaceRevision,
                   await workspaceTransaction?.currentRevision() != rollbackWorkspaceRevision
                {
                    workspaceWasSuperseded = true
                }
                currentSnapshot = verifiedRollbackSnapshot
                currentAuthorityObservation = platformAuthorityObservation(matching: verifiedRollbackSnapshot)
                lastKnownGoodSnapshot = verifiedRollbackSnapshot
                activeProfileID = workspaceWasSuperseded || layoutWasSuperseded ? nil : priorProfileID
                lastKnownGoodProfileID = workspaceWasSuperseded || layoutWasSuperseded ? nil : priorProfileID
                throw activationError
            }
            currentSnapshot = nil
            activeProfileID = nil
            throw ProfileActivationRecoveryFailure(
                activationError: activationError,
                workspaceRollbackError: workspaceRollbackError,
                layoutRollbackError: layoutRollbackError
            )
        }
    }

    private func acquireMutationTurn() async {
        guard mutationIsActive else {
            mutationIsActive = true
            return
        }

        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationTurn() {
        guard !mutationWaiters.isEmpty else {
            mutationIsActive = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    /// Internal observability for deterministic concurrency tests. These expose
    /// counts only, never mutation authority or continuations.
    var queuedMutationTurnCount: Int {
        mutationWaiters.count
    }

    var queuedItemInteractionWaiterCount: Int {
        itemInteractionWaiters.count
    }

    public func recover(now: Date? = nil) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)

        let preservedCurrent = currentSnapshot
        let preservedLastKnownGood = lastKnownGoodSnapshot
        let preservedLastKnownGoodProfileID = lastKnownGoodProfileID
        mutationGeneration &+= 1
        backendHealth = MenuBarBackendHealth(backendName: "XPC", state: .restarting)
        currentAuthorityObservation = nil
        latestBackendAuthorityObservation = nil
        activePlatformPresenceContract = nil
        await backend.restart()

        do {
            let restoredLastKnownGood: Bool
            if let preservedLastKnownGood, await backend.capabilities.canRestore {
                _ = try await backend.restore(preservedLastKnownGood)
                restoredLastKnownGood = true
            } else {
                restoredLastKnownGood = false
            }
            let observation = try await backend.authorityObservation(freshness: .freshRequired)
            let raw = observation.snapshot
            let priorGeneration = max(
                preservedCurrent?.generation ?? 0,
                preservedLastKnownGood?.generation ?? 0
            )
            if raw.generation <= priorGeneration {
                let (nextGeneration, overflowed) = priorGeneration.addingReportingOverflow(1)
                guard !overflowed else {
                    throw MenuBarBackendError.operationFailed("helper generation rebase overflow")
                }
                backendGenerationOffset = nextGeneration - raw.generation
            } else {
                backendGenerationOffset = 0
            }
            let normalizedObservation = try normalizeGeneration(of: observation)
            latestBackendAuthorityObservation = normalizedObservation
            let priorPlatformPresenceContract = activePlatformPresenceContract
            activePlatformPresenceContract = MenuBarPlatformPresenceContract.admitting(normalizedObservation)
            defer { activePlatformPresenceContract = priorPlatformPresenceContract }
            let continuityBaseline = preservedCurrent ?? preservedLastKnownGood
            let validationNow = now ?? Date()
            switch validateBackendObservation(
                normalizedObservation, previous: continuityBaseline, now: validationNow
            ) {
            case let .success(snapshot):
                if restoredLastKnownGood, let preservedLastKnownGood {
                    try validateHistoryResult(snapshot, matches: preservedLastKnownGood)
                } else if let continuityBaseline,
                          logicalLayout(of: snapshot, using: activePlatformPresenceContract) !=
                          logicalLayout(of: continuityBaseline, using: activePlatformPresenceContract)
                {
                    activeProfileID = nil
                }
                currentSnapshot = snapshot
                currentAuthorityObservation = normalizedObservation
                lastKnownGoodSnapshot = snapshot
                lastKnownGoodProfileID = restoredLastKnownGood
                    ? preservedLastKnownGoodProfileID
                    : activeProfileID
                lastRejection = nil
                backendHealth = await backend.health()
                return snapshot
            case let .failure(reason):
                lastRejection = reason
                throw MenuBarBackendError.invalidSnapshot(reason)
            }
        } catch {
            currentSnapshot = nil
            lastKnownGoodSnapshot = preservedLastKnownGood
            lastKnownGoodProfileID = preservedLastKnownGoodProfileID
            activeProfileID = nil
            backendGenerationOffset = 0
            backendHealth = MenuBarBackendHealth(
                backendName: backendHealth.backendName, state: .degraded,
                message: "helper recovery failed"
            )
            throw error
        }
    }

    public var canUndo: Bool {
        !undoCheckpoints.isEmpty
    }

    public var canRedo: Bool {
        !redoCheckpoints.isEmpty
    }

    /// Clears profile identity without claiming that the current layout or
    /// workspace settings still correspond to a saved profile.
    public func clearActiveProfileAuthority() async {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        guard activeItemInteractionID == nil else { return }
        activeProfileID = nil
        lastKnownGoodProfileID = nil
    }

    @discardableResult
    public func clearActiveProfileAuthority(ifMatches profileID: UUID) async -> Bool {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        guard activeItemInteractionID == nil else { return false }
        guard activeProfileID == profileID else { return false }
        activeProfileID = nil
        if lastKnownGoodProfileID == profileID {
            lastKnownGoodProfileID = nil
        }
        return true
    }

    /// Re-establishes durable profile ownership after process relaunch only
    /// when one validated snapshot can both reconnect the persisted display
    /// presentation and exactly match the live layout and modeled workspace.
    @discardableResult
    public func rehydrateActiveProfileAuthority(
        profile: BarlineProfile,
        persistedPresentation: ResolvedProfilePresentation,
        workspaceTransaction: MenuBarWorkspaceTransaction,
        now: Date? = nil
    ) async throws -> ResolvedProfilePresentation? {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)
        try ProfileValidator().validate(profile)
        let snapshot = try await refreshAssumingMutationTurn(now: now, freshness: .freshRequired)
        let platformContract = currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        guard let resolvedPresentation = DisplayProfileOverrideResolver()
            .resolvePersistedPresentation(
                profile: profile,
                persisted: persistedPresentation,
                snapshot: snapshot,
                platformContract: platformContract
            )
        else {
            activeProfileID = nil
            return nil
        }
        var workspace = try await workspaceTransaction.capture()
        guard workspace.presentation == persistedPresentation else {
            activeProfileID = nil
            return nil
        }
        workspace.presentation = resolvedPresentation
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: snapshot,
            activeProfileID: profile.id,
            activeDisplayID: resolvedPresentation.destinationDisplayID,
            workspace: workspace
        )
        let destinationSupport = await backend.capabilities.moveDestinationSupport ?? .existingItemRequired
        guard ProfileAuthorityMatcher.matches(
            profile: profile,
            checkpoint: checkpoint,
            destinationSupport: destinationSupport,
            platformContract: platformContract
        ) else {
            activeProfileID = nil
            return nil
        }
        activeProfileID = profile.id
        lastKnownGoodProfileID = profile.id
        return resolvedPresentation
    }

    /// Resolves a crash-interrupted activation while holding the mutation turn.
    /// An exactly applied target is promoted; every other valid in-flight state
    /// is rolled back to the durable pre-activation checkpoint.
    public func recoverPendingProfileActivation(
        profile: BarlineProfile,
        persistedPresentation: ResolvedProfilePresentation,
        checkpoint: MenuBarWorkspaceCheckpoint,
        workspaceTransaction: MenuBarWorkspaceTransaction,
        now: Date? = nil
    ) async throws -> PendingProfileActivationRecoveryResult {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)
        try ProfileValidator().validate(profile)
        try ProfileValidator().validate(checkpoint.workspace)
        switch validator.validate(
            checkpoint.snapshot,
            previous: nil,
            now: checkpoint.snapshot.capturedAt
        ) {
        case .success:
            break
        case let .failure(reason):
            throw MenuBarBackendError.invalidSnapshot(reason)
        }

        let live = try await refreshedHistoryStartingCheckpoint(
            workspaceTransaction: workspaceTransaction,
            now: now
        )
        let platformContract = currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        guard var liveWorkspace = live.workspace else {
            throw MenuBarBackendError.operationFailed("workspace capture is unavailable")
        }
        if liveWorkspace == checkpoint.workspace,
           logicalLayout(of: live.snapshot, using: platformContract) ==
           logicalLayout(of: checkpoint.snapshot, using: platformContract),
           live.snapshot.displayIDs == checkpoint.snapshot.displayIDs
        {
            activeProfileID = checkpoint.activeProfileID
            lastKnownGoodProfileID = checkpoint.activeProfileID
            return .unchanged(live.snapshot)
        }
        guard liveWorkspace.presentation == persistedPresentation,
              let resolvedPresentation = DisplayProfileOverrideResolver()
              .resolvePersistedPresentation(
                  profile: profile,
                  persisted: persistedPresentation,
                  snapshot: live.snapshot,
                  platformContract: platformContract
              )
        else {
            return .inconclusive
        }
        liveWorkspace.presentation = resolvedPresentation
        let liveCheckpoint = MenuBarWorkspaceCheckpoint(
            snapshot: live.snapshot,
            activeProfileID: profile.id,
            activeDisplayID: resolvedPresentation.destinationDisplayID,
            workspace: liveWorkspace
        )
        let destinationSupport = await backend.capabilities.moveDestinationSupport ?? .existingItemRequired
        if ProfileAuthorityMatcher.matches(
            profile: profile,
            checkpoint: liveCheckpoint,
            destinationSupport: destinationSupport,
            platformContract: platformContract
        ) {
            activeProfileID = profile.id
            lastKnownGoodProfileID = profile.id
            return .promoted(resolvedPresentation)
        }
        var targetWorkspace = ProfileWorkspaceState(profile: profile)
        targetWorkspace.presentation = resolvedPresentation
        guard liveWorkspace == targetWorkspace else {
            return .inconclusive
        }

        let target = HistoryCheckpoint(
            snapshot: checkpoint.snapshot,
            activeProfileID: checkpoint.activeProfileID,
            workspace: checkpoint.workspace,
            workspaceRevision: nil
        )
        let restored = try await restoreHistoryCheckpoint(
            target,
            previous: live,
            now: now,
            workspaceTransaction: workspaceTransaction
        )
        recordUndoCheckpoint(
            live.snapshot,
            activeProfileID: live.activeProfileID,
            workspace: live.workspace
        )
        return .restored(restored)
    }

    public func captureWorkspaceCheckpoint(
        workspaceTransaction: MenuBarWorkspaceTransaction,
        now: Date? = nil
    ) async throws -> MenuBarWorkspaceCheckpoint {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)
        let snapshot = try await refreshAssumingMutationTurn(now: now)
        let workspace = try await workspaceTransaction.capture()
        let activeDisplayID: MenuBarDisplayID? = if let presentation = workspace.presentation {
            presentation.destinationDisplayID
        } else if let environment = try? await backend.environment(),
                  let displayID = environment.activeStableDisplayID,
                  snapshot.displayIDs.contains(displayID)
        {
            displayID
        } else {
            nil
        }
        return MenuBarWorkspaceCheckpoint(
            snapshot: snapshot,
            activeProfileID: activeProfileID,
            activeDisplayID: activeDisplayID,
            workspace: workspace
        )
    }

    /// Assesses saved-profile authority against the latest coordinator snapshot.
    /// A benign refresh may advance generation/time when its logical layout and
    /// display topology are unchanged. Transient menu tracking and unavailable
    /// observations defer destructive revocation until a stable read is possible.
    public func assessProfileAuthority(
        profile: BarlineProfile,
        checkpoint: MenuBarWorkspaceCheckpoint
    ) async -> ProfileAuthorityAssessment {
        let destinationSupport = await backend.capabilities.moveDestinationSupport ?? .existingItemRequired
        // Capability lookup is async and may yield this actor. Revalidate all
        // live state after that suspension, then perform the pure match without
        // another await so a routine refresh cannot race the comparison.
        guard let snapshot = currentSnapshot else { return .temporarilyUnavailable }
        guard snapshot.activeSpaceIsValid, !snapshot.menuTrackingIsActive else {
            return .temporarilyUnavailable
        }
        guard let observation = currentAuthorityObservation,
              observation.snapshot == snapshot
        else { return .temporarilyUnavailable }
        let checkpointDisplayIdentities = checkpoint.snapshot.displayIdentities.map { Set($0) }
        let currentDisplayIdentities = snapshot.displayIdentities.map { Set($0) }
        guard checkpoint.snapshot.displayIDs == snapshot.displayIDs,
              checkpointDisplayIdentities == currentDisplayIdentities,
              checkpoint.snapshot.activeSpaceIsValid == snapshot.activeSpaceIsValid
        else { return .mismatch }
        let platformContract = MenuBarPlatformPresenceContract.admitting(observation)
        guard logicalLayout(of: checkpoint.snapshot, using: platformContract) ==
            logicalLayout(of: snapshot, using: platformContract)
        else { return .mismatch }
        let liveCheckpoint = MenuBarWorkspaceCheckpoint(
            snapshot: snapshot,
            activeProfileID: checkpoint.activeProfileID,
            activeDisplayID: checkpoint.activeDisplayID,
            workspace: checkpoint.workspace
        )
        return ProfileAuthorityMatcher.matches(
            profile: profile,
            checkpoint: liveCheckpoint,
            destinationSupport: destinationSupport,
            platformContract: platformContract
        ) ? .matches : .mismatch
    }

    @discardableResult
    public func restoreWorkspaceCheckpoint(
        _ checkpoint: MenuBarWorkspaceCheckpoint,
        workspaceTransaction: MenuBarWorkspaceTransaction,
        now: Date? = nil
    ) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)
        try ProfileValidator().validate(checkpoint.workspace)
        switch validator.validate(
            checkpoint.snapshot,
            previous: nil,
            now: checkpoint.snapshot.capturedAt
        ) {
        case .success:
            break
        case let .failure(reason):
            throw MenuBarBackendError.invalidSnapshot(reason)
        }
        let live = try await refreshedHistoryStartingCheckpoint(
            workspaceTransaction: workspaceTransaction,
            now: now
        )
        let platformContract = currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        // Reject stale or impossible exact recovery before applying workspace
        // settings. The helper repeats admission against its own live inventory.
        _ = try await WorkspaceRecoveryPlanner.exactPlan(
            saved: platformContract?.projecting(checkpoint.snapshot) ?? checkpoint.snapshot,
            live: platformContract?.projecting(live.snapshot) ?? live.snapshot,
            destinationSupport: backend.capabilities.moveDestinationSupport ?? .existingItemRequired
        )
        let target = HistoryCheckpoint(
            snapshot: checkpoint.snapshot,
            activeProfileID: checkpoint.activeProfileID,
            workspace: checkpoint.workspace,
            workspaceRevision: nil
        )
        let restored = try await restoreHistoryCheckpoint(
            target,
            previous: live,
            now: now,
            workspaceTransaction: workspaceTransaction
        )
        recordUndoCheckpoint(
            live.snapshot,
            activeProfileID: live.activeProfileID,
            workspace: live.workspace
        )
        return restored
    }

    public func prepareAvailableWorkspaceRecovery(
        _ checkpoint: MenuBarWorkspaceCheckpoint,
        workspaceTransaction: MenuBarWorkspaceTransaction,
        now: Date? = nil
    ) async throws -> MenuBarPreparedWorkspaceRecovery {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)
        try ProfileValidator().validate(checkpoint.workspace)
        if case let .failure(reason) = validator.validate(
            checkpoint.snapshot, previous: nil, now: checkpoint.snapshot.capturedAt
        ) {
            throw MenuBarBackendError.invalidSnapshot(reason)
        }
        let live = try await refreshedHistoryStartingCheckpoint(workspaceTransaction: workspaceTransaction, now: now)
        guard let workspace = live.workspace else { throw MenuBarWorkspaceTransactionError.superseded }
        let platformContract = currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        try validatePlatformPresenceHistoryTarget(checkpoint.snapshot, contract: platformContract)
        let preview = try await WorkspaceRecoveryPlanner.preview(
            saved: platformContract?.projecting(checkpoint.snapshot) ?? checkpoint.snapshot,
            live: platformContract?.projecting(live.snapshot) ?? live.snapshot,
            destinationSupport: backend.capabilities.moveDestinationSupport ?? .existingItemRequired
        )
        return try MenuBarPreparedWorkspaceRecovery(
            preview: preview,
            checkpoint: checkpoint,
            source: MenuBarWorkspaceCheckpoint(
                snapshot: live.snapshot, activeProfileID: live.activeProfileID, workspace: workspace
            ),
            target: MenuBarWorkspaceCheckpoint(
                snapshot: preview.targetSnapshot(from: live.snapshot),
                activeProfileID: nil, activeDisplayID: checkpoint.activeDisplayID, workspace: checkpoint.workspace
            ),
            mutationGeneration: mutationGeneration,
            workspaceRevision: live.workspaceRevision
        )
    }

    public func restoreAvailableWorkspaceRecovery(
        _ prepared: MenuBarPreparedWorkspaceRecovery,
        workspaceTransaction: MenuBarWorkspaceTransaction,
        now: Date? = nil
    ) async throws -> MenuBarWorkspaceCheckpoint {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)
        guard prepared.mutationGeneration == mutationGeneration else {
            throw MenuBarWorkspaceTransactionError.superseded
        }
        let live = try await refreshedHistoryStartingCheckpoint(workspaceTransaction: workspaceTransaction, now: now)
        try validateHistoryResult(live.snapshot, matches: prepared.source.snapshot)
        guard live.workspace == prepared.source.workspace,
              live.workspaceRevision == prepared.workspaceRevision,
              live.activeProfileID == prepared.source.activeProfileID
        else { throw MenuBarWorkspaceTransactionError.superseded }
        let restored = try await restoreHistoryCheckpoint(
            HistoryCheckpoint(
                snapshot: prepared.target.snapshot, activeProfileID: nil,
                workspace: prepared.target.workspace, workspaceRevision: nil
            ),
            previous: live, now: now, workspaceTransaction: workspaceTransaction,
            admittedRecoveryPlan: prepared.preview.availableItemsPlan
        )
        recordUndoCheckpoint(live.snapshot, activeProfileID: live.activeProfileID, workspace: live.workspace)
        let observedDisplay: MenuBarDisplayID? = if let destination = prepared.target.workspace.presentation?.destinationDisplayID {
            destination
        } else {
            try? await backend.environment().activeStableDisplayID
        }
        return MenuBarWorkspaceCheckpoint(
            snapshot: restored, activeProfileID: nil,
            activeDisplayID: observedDisplay.flatMap { restored.displayIDs.contains($0) ? $0 : nil },
            workspace: prepared.target.workspace
        )
    }

    /// Restores a journaled workspace only while the profile that created it
    /// still owns the exact current layout and modeled workspace. The ownership
    /// check and restore share one mutation turn, so a newer activation cannot
    /// be overwritten between them.
    public func restoreWorkspaceCheckpoint(
        _ checkpoint: MenuBarWorkspaceCheckpoint,
        ifCurrentMatches expectedProfile: BarlineProfile,
        authorityIsCurrent: Bool,
        workspaceTransaction: MenuBarWorkspaceTransaction,
        now: Date? = nil
    ) async throws -> MenuBarConditionalRestoreResult {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)
        try ProfileValidator().validate(checkpoint.workspace)
        try ProfileValidator().validate(expectedProfile)
        switch validator.validate(
            checkpoint.snapshot,
            previous: nil,
            now: checkpoint.snapshot.capturedAt
        ) {
        case .success:
            break
        case let .failure(reason):
            throw MenuBarBackendError.invalidSnapshot(reason)
        }
        let live = try await refreshedHistoryStartingCheckpoint(
            workspaceTransaction: workspaceTransaction,
            now: now
        )
        let platformContract = currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        guard let liveWorkspace = live.workspace else {
            throw MenuBarBackendError.operationFailed("workspace capture is unavailable")
        }
        let activeDisplayID = liveWorkspace.presentation?.destinationDisplayID
        let liveCheckpoint = MenuBarWorkspaceCheckpoint(
            snapshot: live.snapshot,
            activeProfileID: live.activeProfileID,
            activeDisplayID: activeDisplayID,
            workspace: liveWorkspace
        )
        let destinationSupport = await backend.capabilities.moveDestinationSupport ?? .existingItemRequired
        guard authorityIsCurrent,
              ProfileAuthorityMatcher.matches(
                  profile: expectedProfile,
                  checkpoint: liveCheckpoint,
                  destinationSupport: destinationSupport,
                  platformContract: platformContract
              )
        else {
            return .superseded
        }
        let target = HistoryCheckpoint(
            snapshot: checkpoint.snapshot,
            activeProfileID: checkpoint.activeProfileID,
            workspace: checkpoint.workspace,
            workspaceRevision: nil
        )
        let restored = try await restoreHistoryCheckpoint(
            target,
            previous: live,
            now: now,
            workspaceTransaction: workspaceTransaction
        )
        recordUndoCheckpoint(
            live.snapshot,
            activeProfileID: live.activeProfileID,
            workspace: live.workspace
        )
        return .restored(restored)
    }

    @discardableResult
    public func undo(
        now: Date? = nil,
        workspaceTransaction: MenuBarWorkspaceTransaction? = nil
    ) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)

        guard let target = undoCheckpoints.last else {
            throw MenuBarBackendError.operationFailed("no layout undo checkpoint")
        }
        let before = try await refreshedHistoryStartingCheckpoint(
            workspaceTransaction: workspaceTransaction,
            now: now
        )
        let restored = try await restoreHistoryCheckpoint(
            target,
            previous: before,
            now: now,
            workspaceTransaction: workspaceTransaction
        )
        undoCheckpoints.removeLast()
        redoCheckpoints.append(before)
        trimHistory(&redoCheckpoints)
        return restored
    }

    @discardableResult
    public func redo(
        now: Date? = nil,
        workspaceTransaction: MenuBarWorkspaceTransaction? = nil
    ) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)

        guard let target = redoCheckpoints.last else {
            throw MenuBarBackendError.operationFailed("no layout redo checkpoint")
        }
        let before = try await refreshedHistoryStartingCheckpoint(
            workspaceTransaction: workspaceTransaction,
            now: now
        )
        let restored = try await restoreHistoryCheckpoint(
            target,
            previous: before,
            now: now,
            workspaceTransaction: workspaceTransaction
        )
        redoCheckpoints.removeLast()
        undoCheckpoints.append(before)
        trimHistory(&undoCheckpoints)
        return restored
    }

    private func restoreHistoryCheckpoint(
        _ target: HistoryCheckpoint,
        previous: HistoryCheckpoint,
        now: Date?,
        workspaceTransaction: MenuBarWorkspaceTransaction? = nil,
        admittedRecoveryPlan: ProfileLayoutReconciler.DisplayPlan? = nil
    ) async throws -> MenuBarSnapshot {
        let backendCapabilities = await backend.capabilities
        let destinationSupport = backendCapabilities.moveDestinationSupport ?? .existingItemRequired
        let usesLogicalSectionRestore = !backendCapabilities.canRestore &&
            destinationSupport == .logicalSectionsPreserveNativeOrder
        guard backendCapabilities.canRestore || usesLogicalSectionRestore else {
            throw MenuBarBackendError.unavailableCapability("restore")
        }
        let priorPlatformPresenceContract = activePlatformPresenceContract
        activePlatformPresenceContract = currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        defer { activePlatformPresenceContract = priorPlatformPresenceContract }
        try validatePlatformPresenceHistoryTarget(
            target.snapshot,
            contract: activePlatformPresenceContract
        )
        let logicalRestoreContext: (
            layout: ProfileLayout,
            plan: ProfileLayoutReconciler.DisplayPlan,
            arrangement: MenuBarArrangementExecutionPlan
        )?
        if usesLogicalSectionRestore {
            let startingSnapshot = layoutAuthoritySnapshot(previous.snapshot)
            let targetSnapshot = layoutAuthoritySnapshot(target.snapshot)
            try validateHistoryDisplayIdentity(previous.snapshot, matches: target.snapshot)
            let startingIDs = Set(startingSnapshot.items.map(\.id))
            let targetIDs = Set(targetSnapshot.items.map(\.id))
            let startingDisplays = Dictionary(uniqueKeysWithValues: startingSnapshot.items.map { ($0.id, $0.displayID) })
            guard startingIDs == targetIDs,
                  targetSnapshot.items.allSatisfy({ startingDisplays[$0.id] == $0.displayID })
            else {
                throw WorkspaceRecoveryPlanner.Failure.exactTargetUnavailable
            }
            guard let arrangementCapabilities = backendCapabilities.arrangement,
                  !arrangementCapabilities.canApplySavedNativeOrder,
                  !arrangementCapabilities.canReorderNativeItems
            else {
                throw MenuBarBackendError.unavailableCapability("logical history arrangement")
            }
            var targetLayout = Self.layout(from: target.snapshot, displayID: nil)
            if let activePlatformPresenceContract {
                guard let projected = activePlatformPresenceContract.projecting(targetLayout) else {
                    throw MenuBarBackendError.operationFailed(
                        "macOS Focus cannot be restored to a hidden section"
                    )
                }
                targetLayout = projected
            }
            targetLayout = Self.preservingNativeVisibleOrder(in: targetLayout, snapshot: startingSnapshot)
            let plan = try admittedRecoveryPlan ?? ProfileLayoutReconciler.planAcrossDisplays(
                layout: targetLayout,
                items: startingSnapshot.items,
                destinationSupport: destinationSupport
            )
            guard plan.matchesLogicalArrangement(items: targetSnapshot.items, validateShelfOrder: true) else {
                throw WorkspaceRecoveryPlanner.Failure.exactTargetUnavailable
            }
            let plannedLayout = ProfileLayout(
                visible: plan.targets.flatMap(\.layout.visible),
                hidden: plan.targets.flatMap(\.layout.hidden),
                alwaysHidden: plan.targets.flatMap(\.layout.alwaysHidden)
            )
            let arrangement = try MenuBarArrangementPolicy().plan(
                layout: plannedLayout,
                snapshot: startingSnapshot,
                capabilities: arrangementCapabilities,
                barlineBundleIdentifier: "com.mabryventures.Barline"
            )
            guard arrangement.nativeOrder == .preserveCurrentOrder else {
                throw MenuBarBackendError.unavailableCapability("native menu bar history order")
            }
            if arrangement.shelfOrder == .preserveCurrentOrder {
                let startingLayout = Self.layout(from: startingSnapshot, displayID: nil)
                guard startingLayout.hidden == plannedLayout.hidden,
                      startingLayout.alwaysHidden == plannedLayout.alwaysHidden
                else {
                    throw MenuBarBackendError.unavailableCapability("menu bar shelf history order")
                }
            }
            logicalRestoreContext = (plannedLayout, plan, arrangement)
        } else {
            logicalRestoreContext = nil
        }
        if target.workspace != nil, workspaceTransaction == nil {
            throw MenuBarBackendError.operationFailed(
                "workspace history requires a rollback-capable transaction"
            )
        }
        try await supersedeTemporaryReveals()
        mutationGeneration &+= 1
        var didBeginLayoutMutation = false
        var didBeginWorkspaceMutation = false
        var appliedWorkspaceRevision: UInt64?
        var workspaceWasSuperseded = false
        var completedLogicalMutationCount = 0
        var attemptedLogicalMutationItemIDs = Set<MenuBarItemID>()
        do {
            if let workspace = target.workspace, let workspaceTransaction {
                if let startingRevision = previous.workspaceRevision {
                    do {
                        guard let revision = try await workspaceTransaction.apply(
                            workspace,
                            ifCurrentRevision: startingRevision
                        ) else {
                            workspaceWasSuperseded = true
                            activeProfileID = nil
                            lastKnownGoodProfileID = nil
                            throw MenuBarWorkspaceTransactionError.superseded
                        }
                        appliedWorkspaceRevision = revision
                        didBeginWorkspaceMutation = true
                    } catch let transactionError as MenuBarWorkspaceTransactionError {
                        throw transactionError
                    } catch {
                        didBeginWorkspaceMutation = true
                        throw error
                    }
                } else {
                    didBeginWorkspaceMutation = true
                    try await workspaceTransaction.apply(workspace)
                }
            }
            let candidate: MenuBarSnapshot
            if let logicalRestoreContext {
                let executionStartedAt = Date()
                var executionSnapshot = layoutAuthoritySnapshot(previous.snapshot)
                let maximumMoves = max(1, executionSnapshot.items.count * 4)
                while let operation = try Self.nextLogicalProfileOperation(
                    target: logicalRestoreContext.plan,
                    snapshot: executionSnapshot,
                    displayID: nil,
                    arrangementPlan: logicalRestoreContext.arrangement,
                    destinationSupport: destinationSupport
                ) {
                    guard completedLogicalMutationCount < maximumMoves else {
                        throw MenuBarBackendError.operationFailed("history layout execution did not converge")
                    }
                    try Task.checkCancellation()
                    if let source = executionSnapshot.items.first(where: { $0.id == operation.itemID }) {
                        attemptedLogicalMutationItemIDs.formUnion(Self.logicalMutationItemIDs(
                            operation: operation,
                            source: source,
                            before: executionSnapshot
                        ))
                    }
                    didBeginLayoutMutation = true
                    _ = try await backend.move(operation)
                    completedLogicalMutationCount += 1
                    let observed = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                    let next = try validateBackendSnapshot(
                        observed,
                        previous: executionSnapshot,
                        now: (now ?? executionStartedAt).addingTimeInterval(
                            Date().timeIntervalSince(executionStartedAt)
                        )
                    ).get()
                    let authoritySnapshot = layoutAuthoritySnapshot(next)
                    try validateLogicalProfileStep(
                        operation: operation,
                        before: executionSnapshot,
                        after: authoritySnapshot
                    )
                    executionSnapshot = authoritySnapshot
                }
                candidate = try await verifiedProfileSnapshot(
                    before: previous.snapshot,
                    layout: logicalRestoreContext.layout,
                    displayID: nil,
                    arrangementPlan: logicalRestoreContext.arrangement,
                    admittedLayoutPlan: logicalRestoreContext.plan,
                    now: now ?? Date()
                )
                try validateHistoryDisplayIdentity(candidate, matches: target.snapshot)
            } else {
                didBeginLayoutMutation = true
                _ = try await backend.restore(target.snapshot)
                candidate = try await normalizedBackendSnapshot(requiresFreshObservation: true)
            }
            // History restoration intentionally targets an older logical layout;
            // structural validation remains strict, but monotonic comparison with
            // the newer pre-undo snapshot would reject a correct restore.
            switch validateBackendSnapshot(candidate, previous: nil, now: now ?? Date()) {
            case let .success(snapshot):
                if usesLogicalSectionRestore {
                    guard let historyPlan = admittedRecoveryPlan ?? logicalRestoreContext?.plan else {
                        throw WorkspaceRecoveryPlanner.Failure.exactTargetUnavailable
                    }
                    try validateHistoryDisplayIdentity(snapshot, matches: target.snapshot)
                    guard historyPlan.matchesLogicalArrangement(
                        items: layoutAuthoritySnapshot(snapshot).items,
                        validateShelfOrder: true
                    ) else {
                        throw MenuBarBackendError.operationFailed(
                            "logical history restore did not reach requested sections and shelf order"
                        )
                    }
                } else if let admittedRecoveryPlan {
                    guard snapshot.displayIDs == target.snapshot.displayIDs,
                          snapshot.displayIdentities == target.snapshot.displayIdentities,
                          admittedRecoveryPlan.matches(items: layoutAuthoritySnapshot(snapshot).items)
                    else { throw WorkspaceRecoveryPlanner.Failure.exactTargetUnavailable }
                } else {
                    try validateHistoryResult(snapshot, matches: target.snapshot)
                }
                let revisionToValidate = appliedWorkspaceRevision ?? previous.workspaceRevision
                if let revisionToValidate,
                   await workspaceTransaction?.currentRevision() != revisionToValidate
                {
                    workspaceWasSuperseded = true
                    throw MenuBarWorkspaceTransactionError.superseded
                }
                currentSnapshot = snapshot
                currentAuthorityObservation = platformAuthorityObservation(matching: snapshot)
                lastKnownGoodSnapshot = snapshot
                lastRejection = nil
                activeProfileID = target.activeProfileID
                lastKnownGoodProfileID = target.activeProfileID
                return snapshot
            case let .failure(reason):
                lastRejection = reason
                throw MenuBarBackendError.invalidSnapshot(reason)
            }
        } catch {
            let historyRestoreError = error
            let layoutDidNotStart = completedLogicalMutationCount == 0 &&
                Self.mutationDidNotStart(historyRestoreError)
            let layoutWasSuperseded = Self.mutationRequiresNativeObservation(historyRestoreError)
            if historyRestoreError is MenuBarWorkspaceTransactionError,
               !didBeginWorkspaceMutation,
               !didBeginLayoutMutation
            {
                activeProfileID = nil
                lastKnownGoodProfileID = nil
                throw historyRestoreError
            }
            var workspaceRollbackError: (any Error)?
            var rollbackWorkspaceRevision = previous.workspaceRevision
            if let targetWorkspace = target.workspace,
               let previousWorkspace = previous.workspace,
               let workspaceTransaction
            {
                do {
                    if let appliedWorkspaceRevision {
                        let restoredRevision = try await withCompensation {
                            try await workspaceTransaction.apply(previousWorkspace, ifCurrentRevision: appliedWorkspaceRevision)
                        }
                        if let restoredRevision {
                            rollbackWorkspaceRevision = restoredRevision
                        } else {
                            workspaceWasSuperseded = true
                            guard let mergedRevision = try await withCompensation({
                                try await workspaceTransaction.rollbackSuperseded(from: targetWorkspace, to: previousWorkspace)
                            }) else {
                                throw MenuBarWorkspaceTransactionError.superseded
                            }
                            rollbackWorkspaceRevision = mergedRevision
                        }
                    } else if didBeginWorkspaceMutation {
                        try await withCompensation { try await workspaceTransaction.apply(previousWorkspace) }
                        rollbackWorkspaceRevision = await workspaceTransaction.currentRevision()
                    }
                } catch {
                    workspaceRollbackError = error
                }
            }
            var layoutRollbackError: (any Error)?
            var rollbackSnapshot: MenuBarSnapshot?
            do {
                if layoutDidNotStart {
                    rollbackSnapshot = previous.snapshot
                } else if layoutWasSuperseded {
                    let observed = try await normalizedBackendSnapshot(requiresFreshObservation: true)
                    switch validateBackendSnapshot(observed, previous: nil, now: now ?? Date()) {
                    case let .success(snapshot):
                        rollbackSnapshot = snapshot
                    case let .failure(reason):
                        throw MenuBarBackendError.invalidSnapshot(reason)
                    }
                } else if didBeginLayoutMutation {
                    if let logicalRestoreContext {
                        let ownedLogicalMutationItemIDs = attemptedLogicalMutationItemIDs
                        rollbackSnapshot = try await withCompensation {
                            try await self.compensateSupportedArrangement(
                                restoring: previous.snapshot,
                                displayID: nil,
                                arrangementPlan: logicalRestoreContext.arrangement,
                                destinationSupport: destinationSupport,
                                transactionOwnedItemIDs: ownedLogicalMutationItemIDs,
                                now: now ?? Date()
                            )
                        }
                    } else {
                        let rollbackCandidate = try await compensationSnapshot(restoring: previous.snapshot)
                        switch validateBackendSnapshot(rollbackCandidate, previous: nil, now: now ?? Date()) {
                        case let .success(snapshot):
                            try validateHistoryResult(snapshot, matches: previous.snapshot)
                            rollbackSnapshot = snapshot
                        case let .failure(reason):
                            throw MenuBarBackendError.invalidSnapshot(reason)
                        }
                    }
                } else {
                    rollbackSnapshot = previous.snapshot
                }
            } catch {
                layoutRollbackError = error
            }
            if workspaceRollbackError == nil,
               layoutRollbackError == nil,
               let rollbackSnapshot
            {
                if let rollbackWorkspaceRevision,
                   await workspaceTransaction?.currentRevision() != rollbackWorkspaceRevision
                {
                    workspaceWasSuperseded = true
                }
                currentSnapshot = rollbackSnapshot
                currentAuthorityObservation = platformAuthorityObservation(matching: rollbackSnapshot)
                lastKnownGoodSnapshot = rollbackSnapshot
                activeProfileID = workspaceWasSuperseded || layoutWasSuperseded ? nil : previous.activeProfileID
                lastKnownGoodProfileID = workspaceWasSuperseded || layoutWasSuperseded ? nil : previous.activeProfileID
                throw historyRestoreError
            }
            currentSnapshot = nil
            activeProfileID = nil
            lastKnownGoodProfileID = nil
            let workspaceDescription = workspaceRollbackError.map(String.init(describing:)) ?? "none"
            let layoutDescription = layoutRollbackError.map(String.init(describing:)) ?? "none"
            throw MenuBarBackendError.operationFailed(
                "history restore failed: \(historyRestoreError); rollback failed: workspace \(workspaceDescription); layout \(layoutDescription)"
            )
        }
    }

    private static func mutationDidNotStart(_ error: any Error) -> Bool {
        guard let backendError = error as? MenuBarBackendError else { return false }
        return switch backendError {
        case .positionTableAccessNotGranted, .positionTableIdentityUnresolved, .mutationNotStarted:
            true
        default:
            false
        }
    }

    private static func mutationRequiresNativeObservation(_ error: any Error) -> Bool {
        guard let backendError = error as? MenuBarBackendError else { return false }
        return switch backendError {
        case .mutationSuperseded, .mutationRecoveryRequired:
            true
        default:
            false
        }
    }

    private func validateHistoryResult(
        _ snapshot: MenuBarSnapshot,
        matches target: MenuBarSnapshot
    ) throws {
        try validateHistoryDisplayIdentity(snapshot, matches: target)
        let evidenceContract = activePlatformPresenceContract ?? latestBackendAuthorityObservation
            .flatMap { $0.snapshot == snapshot ? MenuBarPlatformPresenceContract.admitting($0) : nil }
        let layoutSnapshot = evidenceContract?.projecting(snapshot) ?? snapshot
        let layoutTarget = evidenceContract?.projecting(target) ?? target
        let restoredLayout = Set(layoutSnapshot.items.map {
            LogicalLayoutItem(
                id: $0.id,
                displayID: $0.displayID,
                section: $0.section,
                order: $0.order
            )
        })
        let targetLayout = Set(layoutTarget.items.map {
            LogicalLayoutItem(
                id: $0.id,
                displayID: $0.displayID,
                section: $0.section,
                order: $0.order
            )
        })
        guard restoredLayout == targetLayout else {
            throw MenuBarBackendError.operationFailed(
                "history restore did not reach requested layout"
            )
        }
    }

    private func validatePlatformPresenceHistoryTarget(
        _ snapshot: MenuBarSnapshot,
        contract: MenuBarPlatformPresenceContract?
    ) throws {
        guard let contract else { return }
        let requestedLayout = Self.layout(from: snapshot, displayID: nil)
        guard contract.projecting(requestedLayout) != nil else {
            throw MenuBarBackendError.operationFailed(
                "macOS Focus cannot be restored to a hidden section"
            )
        }
    }

    private func validateHistoryDisplayIdentity(
        _ snapshot: MenuBarSnapshot,
        matches target: MenuBarSnapshot
    ) throws {
        guard snapshot.displayIDs == target.displayIDs else {
            throw MenuBarBackendError.operationFailed(
                "history restore did not reach requested displays"
            )
        }
        if let targetIdentities = target.displayIdentities {
            for identity in targetIdentities {
                guard let fingerprint = identity.hardwareFingerprint else { continue }
                let targetMatches = targetIdentities.count {
                    $0.hardwareFingerprint == fingerprint
                }
                let restoredMatches = snapshot.displayIdentities?.count {
                    $0.hardwareFingerprint == fingerprint
                } ?? 0
                guard targetMatches == 1,
                      restoredMatches == 1,
                      snapshot.displayIdentity(for: identity.runtimeID)?.hardwareFingerprint
                      == fingerprint
                else {
                    throw MenuBarBackendError.operationFailed(
                        "history restore did not reach requested display identity"
                    )
                }
            }
        }
    }

    private func recordUndoCheckpoint(
        _ snapshot: MenuBarSnapshot,
        activeProfileID: UUID?,
        workspace: ProfileWorkspaceState? = nil
    ) {
        undoCheckpoints.append(
            HistoryCheckpoint(
                snapshot: snapshot,
                activeProfileID: activeProfileID,
                workspace: workspace,
                workspaceRevision: nil
            )
        )
        trimHistory(&undoCheckpoints)
        redoCheckpoints.removeAll(keepingCapacity: true)
    }

    private func trimHistory(_ history: inout [HistoryCheckpoint]) {
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    private func validateReferences(
        for mutation: MenuBarMutation,
        in snapshot: MenuBarSnapshot
    ) throws {
        let itemID: MenuBarItemID? = switch mutation {
        case let .move(operation), let .transientReveal(operation), let .transientMove(operation):
            operation.itemID
        case let .reveal(referencedItemID):
            referencedItemID
        case .restoreLastKnownGood:
            nil
        }

        if let itemID, !snapshot.items.contains(where: { $0.id == itemID }) {
            throw MenuBarBackendError.staleItem(itemID)
        }

        if case let .move(operation) = mutation,
           operation.section != .visible,
           snapshot.items.first(where: { $0.id == operation.itemID })?.canBeHidden == false
        {
            throw MenuBarBackendError.operationFailed("menu bar item cannot be hidden")
        }
        switch mutation {
        case let .transientReveal(operation):
            guard operation.section == .visible else {
                throw MenuBarBackendError.operationFailed("temporary reveal must target visible section")
            }
        case let .transientMove(operation):
            if operation.section != .visible,
               snapshot.items.first(where: { $0.id == operation.itemID })?.canBeHidden == false
            {
                throw MenuBarBackendError.operationFailed("menu bar item cannot be hidden")
            }
        case .move, .reveal, .restoreLastKnownGood:
            break
        }
    }

    private func validatedStartingSnapshot(now: Date?) async throws -> MenuBarSnapshot {
        if qualifiedPlatformPresenceContractHasBeenEstablished {
            // Once this coordinator has entered the qualified platform lane,
            // a cached last-known-good snapshot cannot replace a lost scan
            // envelope. Re-admit every mutation from a fresh native scan.
            return try await refreshedQualifiedStartingSnapshot(now: now)
        }
        if let currentSnapshot {
            if let currentAuthorityObservation,
               currentAuthorityObservation.snapshot == currentSnapshot,
               MenuBarPlatformPresenceContract.admitting(currentAuthorityObservation) != nil
            {
                return try await refreshAssumingMutationTurn(now: now, freshness: .freshRequired)
            }
            // A successful mutation deliberately drops ordinary scan context:
            // only a platform-presence contract may cross the transaction
            // boundary. Its exact postcondition has already passed strict live
            // validation, and matching last-known-good proves this is still
            // that committed snapshot rather than an unverified proposal.
            if currentAuthorityObservation?.snapshot == currentSnapshot ||
                lastKnownGoodSnapshot == currentSnapshot
            {
                return currentSnapshot
            }
        }
        return try await refreshAssumingMutationTurn(now: now)
    }

    private func refreshedQualifiedStartingSnapshot(now: Date?) async throws -> MenuBarSnapshot {
        let snapshot = try await refreshAssumingMutationTurn(now: now, freshness: .freshRequired)
        guard let observation = currentAuthorityObservation,
              observation.snapshot == snapshot,
              MenuBarPlatformPresenceContract.admitting(observation) != nil
        else {
            throw MenuBarBackendError.invalidSnapshot(.platformPresenceContractChanged)
        }
        return snapshot
    }

    private func refreshedHistoryStartingCheckpoint(
        workspace: ProfileWorkspaceState?,
        workspaceRevision: UInt64? = nil,
        now: Date?
    ) async throws -> HistoryCheckpoint {
        let cached = currentSnapshot
        let requiresFreshPlatformPresence = qualifiedPlatformPresenceContractHasBeenEstablished ||
            currentAuthorityObservation.flatMap {
                MenuBarPlatformPresenceContract.admitting($0)
            } != nil
        let live = try await refreshAssumingMutationTurn(
            now: now,
            freshness: requiresFreshPlatformPresence ? .freshRequired : .cachedAllowed
        )
        if qualifiedPlatformPresenceContractHasBeenEstablished {
            guard let observation = currentAuthorityObservation,
                  observation.snapshot == live,
                  MenuBarPlatformPresenceContract.admitting(observation) != nil
            else {
                throw MenuBarBackendError.invalidSnapshot(.platformPresenceContractChanged)
            }
        }
        let presenceContract = activePlatformPresenceContract ?? currentAuthorityObservation.flatMap {
            MenuBarPlatformPresenceContract.admitting($0)
        }
        if let cached,
           logicalLayout(of: cached, using: presenceContract) !=
           logicalLayout(of: live, using: presenceContract)
        {
            activeProfileID = nil
        }
        return HistoryCheckpoint(
            snapshot: live,
            activeProfileID: activeProfileID,
            workspace: workspace,
            workspaceRevision: workspaceRevision
        )
    }

    private func refreshedHistoryStartingCheckpoint(
        workspaceTransaction: MenuBarWorkspaceTransaction?,
        now: Date?
    ) async throws -> HistoryCheckpoint {
        let revision = await workspaceTransaction?.currentRevision()
        let workspace = try await workspaceTransaction?.capture()
        if let revision, await workspaceTransaction?.currentRevision() != revision {
            activeProfileID = nil
            lastKnownGoodProfileID = nil
            throw MenuBarWorkspaceTransactionError.superseded
        }
        let checkpoint = try await refreshedHistoryStartingCheckpoint(
            workspace: workspace,
            workspaceRevision: revision,
            now: now
        )
        if let revision, await workspaceTransaction?.currentRevision() != revision {
            activeProfileID = nil
            lastKnownGoodProfileID = nil
            throw MenuBarWorkspaceTransactionError.superseded
        }
        return checkpoint
    }

    private func logicalLayout(
        of snapshot: MenuBarSnapshot,
        using contract: MenuBarPlatformPresenceContract? = nil
    ) -> Set<LogicalLayoutItem> {
        let snapshot = contract?.projecting(snapshot) ?? snapshot
        return Set(snapshot.items.map {
            LogicalLayoutItem(
                id: $0.id,
                displayID: $0.displayID,
                section: $0.section,
                order: $0.order
            )
        })
    }

    /// Compensation must not inherit the cancellation that interrupted the
    /// forward operation. The structured timeout cancels and drains its work;
    /// the caller still holds the mutation turn until this awaited task ends.
    /// Backends must honor cancellation/deadlines: we never abandon a live
    /// rollback and allow a later user operation to race its side effects.
    private func withCompensation<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let timeout = compensationTimeout
        let compensation = Task.detached {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MenuBarBackendError.timedOut
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else {
                    throw MenuBarBackendError.interrupted
                }
                return value
            }
        }
        return try await compensation.value
    }

    private func compensationSnapshot(restoring target: MenuBarSnapshot) async throws -> MenuBarSnapshot {
        let backend = backend
        let observation = try await withCompensation {
            _ = try await backend.restore(target)
            return try await backend.authorityObservation(freshness: .freshRequired)
        }
        let normalized = try normalizeGeneration(of: observation)
        latestBackendAuthorityObservation = normalized
        return normalized.snapshot
    }

    private func normalizedBackendSnapshot(
        requiresFreshObservation: Bool
    ) async throws -> MenuBarSnapshot {
        try await normalizedBackendObservation(
            freshness: requiresFreshObservation ? .freshRequired : .cachedAllowed
        ).snapshot
    }

    private func normalizedBackendObservation(
        freshness: MenuBarObservationFreshness
    ) async throws -> MenuBarAuthorityObservation {
        let normalized = try await normalizeGeneration(of: backend.authorityObservation(freshness: freshness))
        latestBackendAuthorityObservation = normalized
        return normalized
    }

    private func validateBackendSnapshot(
        _ snapshot: MenuBarSnapshot,
        previous: MenuBarSnapshot?,
        now: Date
    ) -> Result<MenuBarSnapshot, SnapshotRejectionReason> {
        guard let observation = latestBackendAuthorityObservation,
              observation.snapshot == snapshot
        else {
            return validator.validate(snapshot, previous: previous, now: now)
        }
        return validateBackendObservation(observation, previous: previous, now: now)
    }

    private func validateBackendObservation(
        _ observation: MenuBarAuthorityObservation,
        previous: MenuBarSnapshot?,
        now: Date
    ) -> Result<MenuBarSnapshot, SnapshotRejectionReason> {
        if MenuBarPlatformPresenceContract.admitting(observation) != nil {
            qualifiedPlatformPresenceContractHasBeenEstablished = true
        }
        if let activePlatformPresenceContract {
            return validator.validate(
                observation,
                previous: previous,
                platformContract: activePlatformPresenceContract,
                now: now
            )
        }
        return validator.validate(observation, previous: previous, now: now)
    }

    private func layoutAuthoritySnapshot(_ snapshot: MenuBarSnapshot) -> MenuBarSnapshot {
        activePlatformPresenceContract?.projecting(snapshot) ?? snapshot
    }

    /// Mutation publication must not carry an arbitrary helper scan forward.
    /// Preserve runtime context only when the active transaction was admitted
    /// with the platform-presence contract and this exact post-write scan still
    /// proves the same native publisher and helper session.
    private func platformAuthorityObservation(
        matching snapshot: MenuBarSnapshot
    ) -> MenuBarAuthorityObservation? {
        guard let activePlatformPresenceContract,
              let observation = latestBackendAuthorityObservation,
              observation.snapshot == snapshot,
              activePlatformPresenceContract.accepts(observation)
        else { return nil }
        return observation
    }

    private func normalizeGeneration(of observation: MenuBarAuthorityObservation) throws -> MenuBarAuthorityObservation {
        let (generation, overflowed) = observation.snapshot.generation.addingReportingOverflow(
            backendGenerationOffset
        )
        guard !overflowed else {
            throw MenuBarBackendError.operationFailed("helper generation normalization overflow")
        }
        return observation.rebasingGeneration(to: generation)
    }

    private func requireCurrentGeneration(_ expectedGeneration: UInt64) throws {
        guard currentSnapshot?.generation == expectedGeneration else {
            throw MenuBarAuthorityRefreshError.staleGeneration(
                expected: expectedGeneration,
                actual: currentSnapshot?.generation
            )
        }
    }

    private func apply(
        _ mutation: MenuBarMutation,
        restoreTarget: MenuBarSnapshot? = nil
    ) async throws {
        switch mutation {
        case let .move(operation), let .transientReveal(operation), let .transientMove(operation):
            _ = try await backend.move(operation)
        case let .reveal(itemID):
            _ = try await backend.reveal(itemID)
        case .restoreLastKnownGood:
            guard let restoreTarget else {
                throw MenuBarBackendError.operationFailed("no last-known-good snapshot")
            }
            _ = try await backend.restore(restoreTarget)
        }
    }
}
