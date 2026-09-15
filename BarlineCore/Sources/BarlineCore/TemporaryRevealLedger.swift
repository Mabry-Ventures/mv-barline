import Foundation

/// Reference-counted native reveal ownership. Callers commit a returned
/// candidate only after the corresponding native configuration succeeds.
public struct TemporaryRevealLedger: Equatable, Sendable {
    private var counts: [MenuBarItemID: Int]

    public init() {
        counts = [:]
    }

    public var visibleItemIDs: Set<MenuBarItemID> {
        Set(counts.keys)
    }

    public func beginning(_ item: MenuBarItemID) -> Self {
        var candidate = self
        candidate.counts[item, default: 0] += 1
        return candidate
    }

    public func ending(_ item: MenuBarItemID) -> Self? {
        guard let count = counts[item] else { return nil }
        var candidate = self
        candidate.counts[item] = count > 1 ? count - 1 : nil
        return candidate
    }
}
