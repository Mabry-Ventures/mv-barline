import Foundation

/// Describes why menu bar discovery was requested.
public enum MenuBarDiscoveryRefreshIntent: Sendable {
    /// A direct user action or an operation that changed the physical layout.
    case authoritative
    /// A lifecycle signal that may be emitted repeatedly while AppKit rebuilds
    /// status-item windows.
    case automatic
}

/// Keeps noisy AppKit lifecycle signals from indefinitely restarting discovery.
public enum MenuBarDiscoveryRefreshPolicy {
    public static func shouldStart(
        intent: MenuBarDiscoveryRefreshIntent,
        discoveryIsInFlight: Bool,
        terminalFailureWithoutSnapshot: Bool = false
    ) -> Bool {
        switch intent {
        case .authoritative:
            true
        case .automatic:
            !discoveryIsInFlight && !terminalFailureWithoutSnapshot
        }
    }

    /// Decides whether the user's session becoming available again — the
    /// screen unlocking, or returning to this user after a switch — should
    /// restart discovery. A discovery that ran while the screen was locked
    /// (for example, a relaunch after an overnight update) sees no menu bar
    /// and fails terminally, and automatic lifecycle signals deliberately
    /// cannot restart a terminal failure. Session availability is a single,
    /// user-driven event rather than an AppKit storm, so it may retry once.
    public static func shouldRetryWhenSessionBecomesAvailable(
        state: MenuBarItemDiscoveryState
    ) -> Bool {
        state == .failed && !state.hasUsableSnapshot
    }

    /// Determines whether an inventory observation requires a full discovery.
    /// A cold manager must always establish a terminal snapshot even when the
    /// observed inventory happens to match the actor's initially empty cache.
    public static func shouldRunDiscovery(
        inventoryChanged: Bool,
        displayChanged: Bool,
        hasUsableSnapshot: Bool
    ) -> Bool {
        inventoryChanged || displayChanged || !hasUsableSnapshot
    }
}

/// Main-actor-owned admission state for bounded discovery refresh bursts.
/// State changes are synchronous so no caller can suspend between checking and
/// reserving the in-flight slot.
public struct MenuBarDiscoveryRefreshGate: Sendable {
    public private(set) var isInFlight = false
    public private(set) var hasPendingAutomaticRefresh = false

    public init() {}

    @discardableResult
    public mutating func begin(
        intent: MenuBarDiscoveryRefreshIntent,
        terminalFailureWithoutSnapshot: Bool = false
    ) -> Bool {
        guard MenuBarDiscoveryRefreshPolicy.shouldStart(
            intent: intent,
            discoveryIsInFlight: isInFlight,
            terminalFailureWithoutSnapshot: terminalFailureWithoutSnapshot
        ) else {
            if case .automatic = intent, isInFlight {
                hasPendingAutomaticRefresh = true
            }
            return false
        }
        isInFlight = true
        return true
    }

    /// Finishes the current owner and returns whether it should schedule one
    /// trailing automatic pass. A trailing pass calls this with `false`, which
    /// consumes further churn without forming an unbounded loop.
    @discardableResult
    public mutating func finish(
        allowsTrailingAutomaticRefresh: Bool,
        reachedUsableTerminalState: Bool
    ) -> Bool {
        isInFlight = false
        let shouldRunTrailingRefresh =
            allowsTrailingAutomaticRefresh &&
            hasPendingAutomaticRefresh &&
            reachedUsableTerminalState
        hasPendingAutomaticRefresh = false
        return shouldRunTrailingRefresh
    }
}

/// Bounded, payload-free discovery telemetry suitable for a support bundle.
public enum MenuBarItemDiscoveryFailureCode: String, Codable, Sendable {
    case recentMovement = "recent_movement"
    case snapshotUnavailable = "snapshot_unavailable"
    case incompleteSnapshot = "incomplete_snapshot"
    case missingControlItems = "missing_control_items"
    case missingRequiredControlItems = "missing_required_control_items"
}

public struct MenuBarItemDiscoveryDiagnostics: Codable, Equatable, Sendable {
    public private(set) var authoritativeStartCount = 0
    public private(set) var automaticStartCount = 0
    public private(set) var coalescedAutomaticCount = 0
    public private(set) var lastAttemptCount = 0
    public private(set) var lastManagedItemCount: Int?
    public private(set) var lastOutcomeCode = "not_run"
    public private(set) var lastAttemptFailureCode: String?

    public init() {}

    public mutating func recordStartedRequest(intent: MenuBarDiscoveryRefreshIntent) {
        switch intent {
        case .authoritative:
            Self.incrementSaturating(&authoritativeStartCount)
        case .automatic:
            Self.incrementSaturating(&automaticStartCount)
        }
    }

    public mutating func recordCoalescedAutomaticRequest() {
        Self.incrementSaturating(&coalescedAutomaticCount)
    }

    public mutating func recordAttemptFailure(code: MenuBarItemDiscoveryFailureCode) {
        lastAttemptFailureCode = code.rawValue
    }

    public mutating func recordCompletion(attemptCount: Int, managedItemCount: Int) {
        lastAttemptCount = attemptCount
        lastManagedItemCount = managedItemCount
        lastOutcomeCode = managedItemCount == 0 ? "empty" : "ready"
        lastAttemptFailureCode = nil
    }

    public mutating func recordFailure(attemptCount: Int) {
        lastAttemptCount = attemptCount
        lastManagedItemCount = nil
        lastOutcomeCode = "failed"
    }

    private static func incrementSaturating(_ value: inout Int) {
        if value < Int.max {
            value += 1
        }
    }
}
