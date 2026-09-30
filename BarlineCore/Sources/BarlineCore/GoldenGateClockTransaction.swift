import Foundation

/// A pointer-down witness shared with the helper. Later clicks supersede a
/// clock action without waiting for another message on the busy XPC queue.
public struct MenuBarPointerEventStamp: Codable, Equatable, Sendable {
    public let leftDown: UInt32
    public let rightDown: UInt32
    public let otherDown: UInt32

    public init(leftDown: UInt32, rightDown: UInt32, otherDown: UInt32) {
        self.leftDown = leftDown
        self.rightDown = rightDown
        self.otherDown = otherDown
    }
}

/// Pure lifecycle authority for a recovery worker. Restart or a successful
/// replacement configuration revokes every older worker's authority.
public struct GoldenGateRecoveryLease: Sendable {
    private var generation: UInt64 = 0
    private var active: UInt64?

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        active = generation
        return generation
    }

    public mutating func invalidate() {
        generation &+= 1
        active = nil
    }

    public func contains(_ token: UInt64) -> Bool {
        active == token
    }
}

/// The tested lift/press/restore ordering, independent of private macOS APIs.
/// The caller holds the concealment gate throughout. Restoration is a single
/// bounded attempt; further retries belong to the controller's recovery lease.
public enum GoldenGateClockTransaction {
    public static func run(
        deadline: UInt64,
        now: @escaping @Sendable () -> UInt64,
        isCurrent: @escaping @Sendable () -> Bool,
        lift: @Sendable () -> Void,
        press: @Sendable () -> Bool,
        restore: @escaping @Sendable () async throws -> Void,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Bool {
        guard !Task.isCancelled, isCurrent(),
              GoldenGateTiming.admitsClockPress(now: now(), deadline: deadline, beforeLift: true)
        else { return false }
        lift()
        try? await sleep(.nanoseconds(Int64(GoldenGateTiming.clockLiftSettleNanoseconds)))
        let pressed = !Task.isCancelled && isCurrent() &&
            GoldenGateTiming.admitsClockPress(now: now(), deadline: deadline, beforeLift: false) && press()
        if pressed {
            try? await sleep(.milliseconds(150))
        }
        // Cancellation of the initiating click must not strand lifted items.
        // Unlike the old four-attempt loop, this stays inside the XPC budget.
        try await Task.detached { try await restore() }.value
        return pressed
    }
}
