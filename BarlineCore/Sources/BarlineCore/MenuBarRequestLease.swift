import Foundation

/// Revocable ownership of one bounded transport operation. A timed-out worker
/// must not acquire a replacement session or start another mutation phase.
public final class MenuBarRequestLease: @unchecked Sendable {
    public let admittedEpoch: UInt64
    public let deadline: UInt64
    private let lock = NSLock()
    private var revoked = false
    private var boundGeneration: UInt64?

    public init(admittedEpoch: UInt64, deadline: UInt64) {
        self.admittedEpoch = admittedEpoch
        self.deadline = deadline
    }

    @discardableResult
    public func bind(generation: UInt64, now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked, now < deadline,
              boundGeneration == nil || boundGeneration == generation
        else { return false }
        boundGeneration = generation
        return true
    }

    public func admits(generation: UInt64, now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked && now < deadline && boundGeneration == generation
    }

    public func isLive(now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked && now < deadline
    }

    @discardableResult
    public func revoke() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        revoked = true
        return boundGeneration
    }
}

/// Shared production handshake/replay sequencing, with injectable transport
/// and ownership witnesses for deterministic interruption regressions.
public enum MenuBarRecoveryHandshake {
    public static func run<Response>(
        isCurrent: () -> Bool,
        handshake: () -> Response?,
        isHandshake: (Response) -> Bool,
        replay: () -> Bool
    ) -> Response? {
        guard isCurrent(), let response = handshake(), isHandshake(response),
              isCurrent(), replay(), isCurrent()
        else { return nil }
        return response
    }
}
