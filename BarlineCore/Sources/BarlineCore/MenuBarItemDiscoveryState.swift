/// User-visible state for a bounded menu bar item discovery request.
public enum MenuBarItemDiscoveryState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case empty
    case failed

    public var hasUsableSnapshot: Bool {
        self == .ready || self == .empty
    }

    public static func completed(managedItemCount: Int) -> Self {
        managedItemCount > 0 ? .ready : .empty
    }

    /// A failed refresh must not replace a previously usable snapshot.
    public func preservingUsableSnapshotOrFailure() -> Self {
        hasUsableSnapshot ? self : .failed
    }
}
