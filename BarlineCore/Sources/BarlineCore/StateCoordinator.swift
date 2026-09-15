//
//  StateCoordinator.swift
//  Barline
//

import Foundation

public enum MenuBarAuthorityRefreshError: Error, Equatable, Sendable {
    case staleGeneration(expected: UInt64, actual: UInt64?)
}

public enum MenuBarMutation: Sendable {
    case move(MenuBarMoveOperation)
    case transientMove(MenuBarMoveOperation)
    case reveal(MenuBarItemID)
    case restoreLastKnownGood

    fileprivate var recordsLayoutHistory: Bool {
        if case .transientMove = self {
            false
        } else {
            true
        }
    }

    fileprivate var moveOperation: MenuBarMoveOperation? {
        switch self {
        case let .move(operation), let .transientMove(operation):
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

    public private(set) var currentSnapshot: MenuBarSnapshot?
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
        defer { activeItemInteractionID = nil }
        try Task.checkCancellation()
        let value = try await body(interactionID)
        try Task.checkCancellation()
        return value
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

    private func refreshAssumingMutationTurn(
        now: Date?,
        maximumAttempts: Int? = nil
    ) async throws -> MenuBarSnapshot {
        var mostRecentError: (any Error)?

        let attemptCount = max(1, maximumAttempts ?? retryPolicy.maximumAttempts)

        for attempt in 0 ..< attemptCount {
            try Task.checkCancellation()
            do {
                let candidate = try await normalizedBackendSnapshot()
                switch validator.validate(candidate, previous: currentSnapshot, now: now ?? Date()) {
                case let .success(snapshot):
                    if let currentSnapshot,
                       logicalLayout(of: currentSnapshot) != logicalLayout(of: snapshot)
                    {
                        activeProfileID = nil
                    }
                    currentSnapshot = snapshot
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
            let candidate = try await normalizedBackendSnapshot()
            switch validator.validate(candidate, previous: before, now: now ?? Date()) {
            case let .success(snapshot):
                guard generation == mutationGeneration else {
                    throw CancellationError()
                }
                if let operation = mutation.moveOperation,
                   !MenuBarMovePlanner().resultMatches(
                       operation,
                       in: snapshot,
                       from: before
                   )
                {
                    throw MenuBarBackendError.operationFailed(
                        "menu bar move did not reach requested section"
                    )
                }
                if case let .reveal(itemID) = mutation {
                    guard let beforeItem = before.items.first(where: { $0.id == itemID }),
                          let revealedItem = snapshot.items.first(where: { $0.id == itemID }),
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
                currentSnapshot = snapshot
                lastKnownGoodSnapshot = snapshot
                lastRejection = nil
                if mutation.recordsLayoutHistory {
                    recordUndoCheckpoint(before, activeProfileID: activeProfileID)
                    activeProfileID = restoreTarget == nil ? nil : restoreProfileID
                }
                lastKnownGoodProfileID = activeProfileID
                return snapshot
            case let .failure(reason):
                lastRejection = reason
                throw MenuBarBackendError.invalidSnapshot(reason)
            }
        } catch {
            let mutationError = error
            guard await backend.capabilities.canRestore else {
                currentSnapshot = nil
                activeProfileID = nil
                throw mutationError
            }
            do {
                let rollbackCandidate = try await compensationSnapshot(restoring: before)
                let rollbackSnapshot: MenuBarSnapshot
                switch validator.validate(rollbackCandidate, previous: nil, now: now ?? Date()) {
                case let .success(snapshot):
                    try validateHistoryResult(snapshot, matches: before)
                    rollbackSnapshot = snapshot
                case let .failure(reason):
                    throw MenuBarBackendError.invalidSnapshot(reason)
                }
                currentSnapshot = rollbackSnapshot
                lastKnownGoodSnapshot = rollbackSnapshot
                lastKnownGoodProfileID = activeProfileID
            } catch {
                let rollbackError = error
                currentSnapshot = nil
                activeProfileID = nil
                throw MenuBarBackendError.operationFailed(
                    "mutation failed: \(mutationError); rollback failed: \(rollbackError)"
                )
            }
            throw mutationError
        }
    }

    private func validateProfileResult(
        _ plan: ProfileLayoutReconciler.DisplayPlan,
        in snapshot: MenuBarSnapshot
    ) throws {
        guard plan.matches(items: snapshot.items) else {
            throw MenuBarBackendError.operationFailed(
                "profile activation did not reach requested layout"
            )
        }
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
        let candidate = try await normalizedBackendSnapshot()
        let snapshot = try validator.validate(candidate, previous: currentSnapshot, now: Date()).get()
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
                snapshot: before
            )
        }
        // A base profile can contain items from every display. Only a matching
        // display override is scoped and retargeted to the active display;
        // applying the base layout preserves each item's source display.
        let presentation = try profile.resolvedPresentation(using: matchingDisplayOverride)
            .resolvingItemIdentities(in: before)
        let profileDisplayID = presentation.destinationDisplayID
        let layout = presentation.layout
        let knownItemIDs = Set(before.items.map(\.id))
        for itemID in layout.allItemIDs where !knownItemIDs.contains(itemID) {
            throw MenuBarBackendError.staleItem(itemID)
        }
        // Reject an impossible physical destination before journaling or changing
        // workspace state. The helper's own admission checks remain authoritative.
        let destinationSupport = await backend.capabilities.moveDestinationSupport ?? .existingItemRequired
        let layoutPlan = try ProfileLayoutReconciler.planAcrossDisplays(
            layout: layout, items: before.items, displayID: profileDisplayID,
            destinationSupport: destinationSupport
        )

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
            for operation in layoutPlan.operations {
                try Task.checkCancellation()
                try await admission?()
                didBeginLayoutMutation = true
                _ = try await backend.move(operation)
            }

            try Task.checkCancellation()
            let candidate = try await normalizedBackendSnapshot()
            try await admission?()
            switch validator.validate(candidate, previous: before, now: now ?? Date()) {
            case let .success(snapshot):
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
                try validateProfileResult(layoutPlan, in: snapshot)
                try await admission?()
                if let appliedWorkspaceRevision,
                   await workspaceTransaction?.currentRevision() != appliedWorkspaceRevision
                {
                    throw MenuBarWorkspaceTransactionError.superseded
                }
                try Task.checkCancellation()
                currentSnapshot = snapshot
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
            case let .failure(reason):
                lastRejection = reason
                throw MenuBarBackendError.invalidSnapshot(reason)
            }
        } catch {
            let activationError = error
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
            if didBeginLayoutMutation || didBeginWorkspaceMutation {
                if await backend.capabilities.canRestore {
                    do {
                        let candidate = try await compensationSnapshot(restoring: before)
                        switch validator.validate(candidate, previous: nil, now: now ?? Date()) {
                        case let .success(snapshot):
                            try validateHistoryResult(snapshot, matches: before)
                            verifiedRollbackSnapshot = snapshot
                        case let .failure(reason):
                            throw MenuBarBackendError.invalidSnapshot(reason)
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
                lastKnownGoodSnapshot = verifiedRollbackSnapshot
                activeProfileID = workspaceWasSuperseded ? nil : priorProfileID
                lastKnownGoodProfileID = workspaceWasSuperseded ? nil : priorProfileID
                throw activationError
            }
            currentSnapshot = nil
            activeProfileID = nil
            let workspaceDescription = workspaceRollbackError.map(String.init(describing:)) ?? "none"
            let layoutDescription = layoutRollbackError.map(String.init(describing:)) ?? "none"
            throw MenuBarBackendError.operationFailed(
                "profile activation failed: \(activationError); workspace rollback: \(workspaceDescription); layout rollback: \(layoutDescription)"
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

    public func recover(now: Date? = nil) async throws -> MenuBarSnapshot {
        await acquireMutationTurn()
        defer { releaseMutationTurn() }
        try requireItemInteraction(nil)

        let preservedCurrent = currentSnapshot
        let preservedLastKnownGood = lastKnownGoodSnapshot
        let preservedLastKnownGoodProfileID = lastKnownGoodProfileID
        mutationGeneration &+= 1
        backendHealth = MenuBarBackendHealth(backendName: "XPC", state: .restarting)
        await backend.restart()

        do {
            let restoredLastKnownGood: Bool
            if let preservedLastKnownGood, await backend.capabilities.canRestore {
                _ = try await backend.restore(preservedLastKnownGood)
                restoredLastKnownGood = true
            } else {
                restoredLastKnownGood = false
            }
            let raw = try await backend.snapshot()
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
            let candidate = try normalizeGeneration(of: raw)
            let continuityBaseline = preservedCurrent ?? preservedLastKnownGood
            let validationNow = now ?? Date()
            switch validator.validate(candidate, previous: continuityBaseline, now: validationNow) {
            case let .success(snapshot):
                if restoredLastKnownGood, let preservedLastKnownGood {
                    try validateHistoryResult(snapshot, matches: preservedLastKnownGood)
                } else if let continuityBaseline,
                          logicalLayout(of: snapshot) != logicalLayout(of: continuityBaseline)
                {
                    activeProfileID = nil
                }
                currentSnapshot = snapshot
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
        let snapshot = try await refreshAssumingMutationTurn(now: now)
        guard let resolvedPresentation = DisplayProfileOverrideResolver()
            .resolvePersistedPresentation(
                profile: profile,
                persisted: persistedPresentation,
                snapshot: snapshot
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
        guard ProfileAuthorityMatcher.matches(profile: profile, checkpoint: checkpoint) else {
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
        guard var liveWorkspace = live.workspace else {
            throw MenuBarBackendError.operationFailed("workspace capture is unavailable")
        }
        if liveWorkspace == checkpoint.workspace,
           logicalLayout(of: live.snapshot) == logicalLayout(of: checkpoint.snapshot),
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
                  snapshot: live.snapshot
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
        if ProfileAuthorityMatcher.matches(profile: profile, checkpoint: liveCheckpoint) {
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
        // Reject stale or impossible exact recovery before applying workspace
        // settings. The helper repeats admission against its own live inventory.
        _ = try await WorkspaceRecoveryPlanner.exactPlan(
            saved: checkpoint.snapshot,
            live: live.snapshot,
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
        let preview = try await WorkspaceRecoveryPlanner.preview(
            saved: checkpoint.snapshot, live: live.snapshot,
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
        guard authorityIsCurrent,
              ProfileAuthorityMatcher.matches(
                  profile: expectedProfile,
                  checkpoint: liveCheckpoint
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
        guard await backend.capabilities.canRestore else {
            throw MenuBarBackendError.unavailableCapability("restore")
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
            didBeginLayoutMutation = true
            _ = try await backend.restore(target.snapshot)
            let candidate = try await normalizedBackendSnapshot()
            // History restoration intentionally targets an older logical layout;
            // structural validation remains strict, but monotonic comparison with
            // the newer pre-undo snapshot would reject a correct restore.
            switch validator.validate(candidate, previous: nil, now: now ?? Date()) {
            case let .success(snapshot):
                if let admittedRecoveryPlan {
                    guard snapshot.displayIDs == target.snapshot.displayIDs,
                          snapshot.displayIdentities == target.snapshot.displayIdentities,
                          admittedRecoveryPlan.matches(items: snapshot.items)
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
                if didBeginLayoutMutation {
                    let rollbackCandidate = try await compensationSnapshot(restoring: previous.snapshot)
                    switch validator.validate(rollbackCandidate, previous: nil, now: now ?? Date()) {
                    case let .success(snapshot):
                        try validateHistoryResult(snapshot, matches: previous.snapshot)
                        rollbackSnapshot = snapshot
                    case let .failure(reason):
                        throw MenuBarBackendError.invalidSnapshot(reason)
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
                lastKnownGoodSnapshot = rollbackSnapshot
                activeProfileID = workspaceWasSuperseded ? nil : previous.activeProfileID
                lastKnownGoodProfileID = workspaceWasSuperseded ? nil : previous.activeProfileID
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

    private func validateHistoryResult(
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
        let restoredLayout = Set(snapshot.items.map {
            LogicalLayoutItem(
                id: $0.id,
                displayID: $0.displayID,
                section: $0.section,
                order: $0.order
            )
        })
        let targetLayout = Set(target.items.map {
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
        case let .move(operation), let .transientMove(operation):
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
        if case let .transientMove(operation) = mutation,
           operation.section != .visible,
           snapshot.items.first(where: { $0.id == operation.itemID })?.canBeHidden == false
        {
            throw MenuBarBackendError.operationFailed("menu bar item cannot be hidden")
        }
    }

    private func validatedStartingSnapshot(now: Date?) async throws -> MenuBarSnapshot {
        if let currentSnapshot {
            return currentSnapshot
        }
        return try await refreshAssumingMutationTurn(now: now)
    }

    private func refreshedHistoryStartingCheckpoint(
        workspace: ProfileWorkspaceState?,
        workspaceRevision: UInt64? = nil,
        now: Date?
    ) async throws -> HistoryCheckpoint {
        let cached = currentSnapshot
        let live = try await refreshAssumingMutationTurn(now: now)
        if let cached, logicalLayout(of: cached) != logicalLayout(of: live) {
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

    private func logicalLayout(of snapshot: MenuBarSnapshot) -> Set<LogicalLayoutItem> {
        Set(snapshot.items.map {
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
        let snapshot = try await withCompensation {
            _ = try await backend.restore(target)
            return try await backend.snapshot()
        }
        return try normalizeGeneration(of: snapshot)
    }

    private func normalizedBackendSnapshot() async throws -> MenuBarSnapshot {
        try await normalizeGeneration(of: backend.snapshot())
    }

    private func normalizeGeneration(of snapshot: MenuBarSnapshot) throws -> MenuBarSnapshot {
        let (generation, overflowed) = snapshot.generation.addingReportingOverflow(
            backendGenerationOffset
        )
        guard !overflowed else {
            throw MenuBarBackendError.operationFailed("helper generation normalization overflow")
        }
        guard backendGenerationOffset != 0 else { return snapshot }
        return MenuBarSnapshot(
            generation: generation,
            capturedAt: snapshot.capturedAt,
            items: snapshot.items,
            displayIDs: snapshot.displayIDs,
            displayIdentities: snapshot.displayIdentities,
            activeSpaceIsValid: snapshot.activeSpaceIsValid,
            menuTrackingIsActive: snapshot.menuTrackingIsActive
        )
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
        case let .move(operation), let .transientMove(operation):
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
