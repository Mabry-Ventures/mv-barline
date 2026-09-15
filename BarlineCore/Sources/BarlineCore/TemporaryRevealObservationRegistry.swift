/// Idempotently owns temporary-reveal observations across async restoration
/// attempts and backend lifecycle resets.
public struct TemporaryRevealObservationRegistry: Equatable, Sendable {
    public struct Reservation: Equatable, Sendable {
        public let token: MenuBarRevealObservationToken
        public let item: MenuBarItemID
        fileprivate let epoch: UInt64
    }

    private var epoch: UInt64 = 0
    private var items = [MenuBarRevealObservationToken: MenuBarItemID]()
    private var restartIsActive = false

    public init() {}

    public var lifecycleEpoch: UInt64 {
        epoch
    }

    public var canAdmitOperations: Bool {
        !restartIsActive
    }

    @discardableResult
    public mutating func register(
        _ token: MenuBarRevealObservationToken,
        item: MenuBarItemID,
        at expectedEpoch: UInt64
    ) -> Bool {
        guard !restartIsActive, expectedEpoch == epoch, items[token] == nil else { return false }
        items[token] = item
        return true
    }

    public mutating func reserve(_ token: MenuBarRevealObservationToken) -> Reservation? {
        guard let item = items.removeValue(forKey: token) else { return nil }
        return Reservation(token: token, item: item, epoch: epoch)
    }

    @discardableResult
    public mutating func restoreFailed(_ reservation: Reservation) -> Bool {
        guard reservation.epoch == epoch, items[reservation.token] == nil else { return false }
        items[reservation.token] = reservation.item
        return true
    }

    @discardableResult
    public mutating func beginRestart() -> Bool {
        guard !restartIsActive else { return false }
        restartIsActive = true
        epoch &+= 1
        items.removeAll()
        return true
    }

    public mutating func finishRestart() {
        restartIsActive = false
    }
}
