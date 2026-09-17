import Combine

/// Owns the user-facing lifetime of one menu-bar assignment.
///
/// A single session is shared by every layout section in the Settings pane so
/// opposite-section clicks and drops cannot start competing transactions while
/// the first transaction is suspended in the native macOS backend.
@MainActor
public final class MenuBarAssignmentSession: ObservableObject {
    @Published public private(set) var isInFlight = false

    public init() {}

    /// Runs an assignment when the session is idle. Returns `false` without
    /// invoking `operation` when another assignment already owns the session.
    @discardableResult
    public func run(_ operation: () async -> Void) async -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        defer { isInFlight = false }
        await operation()
        return true
    }
}
