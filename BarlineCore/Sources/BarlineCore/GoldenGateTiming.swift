//
//  GoldenGateTiming.swift
//  BarlineCore
//

import Foundation

public enum GoldenGateTiming {
    public static let clockLiftSettleNanoseconds: UInt64 = 80_000_000
    /// Leave room inside the helper's 500ms cancellation grace. Further
    /// activation attempts run under a revocable background recovery lease.
    public static let clockRestoreBudget = Duration.milliseconds(250)

    /// Admission must leave time for the assessment assertion to settle.
    public static func admitsClockPress(now: UInt64, deadline: UInt64, beforeLift: Bool) -> Bool {
        guard now < deadline else { return false }
        return !beforeLift || deadline - now > clockLiftSettleNanoseconds
    }

    public static let snapshotCacheLifetimeMilliseconds: Int64 = 100
    public static let concealmentSyncDebounceBufferMilliseconds: Int64 = 25
    public static let snapshotCacheLifetimeNanoseconds = UInt64(snapshotCacheLifetimeMilliseconds) * 1_000_000
    public static let concealmentSyncDebounce = Duration.milliseconds(
        snapshotCacheLifetimeMilliseconds + concealmentSyncDebounceBufferMilliseconds
    )
}

@MainActor
public final class GoldenGateConcealmentSyncDebouncer {
    typealias WaitOperation = @Sendable (Duration) async throws -> Void

    private let delay: Duration
    private let wait: WaitOperation
    private var task: Task<Void, Never>?

    public init(delay: Duration = GoldenGateTiming.concealmentSyncDebounce) {
        self.delay = delay
        wait = { try await Task.sleep(for: $0) }
    }

    init(delay: Duration, wait: @escaping WaitOperation) {
        self.delay = delay
        self.wait = wait
    }

    deinit {
        task?.cancel()
    }

    public func schedule(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            do {
                try await wait(delay)
                try Task.checkCancellation()
                await operation()
            } catch {
                // Cancellation means a newer presentation request superseded this one.
            }
        }
    }

    public func cancelAndWait() async {
        let pendingTask = task
        task = nil
        pendingTask?.cancel()
        await pendingTask?.value
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
