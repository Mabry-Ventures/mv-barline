import Foundation

/// Bounded observation retries, not mutation retries. An attempt must return
/// .finished once activation is claimed, even when activation/persistence fails.
@MainActor
public final class ProfileDisplayReconnectRetry {
    public enum Outcome: Sendable { case retryObservation, finished }
    public typealias Pause = @Sendable (Duration) async throws -> Void
    private let maximumAttempts: Int
    private let pause: Pause
    private var task: Task<Void, Never>?
    private var epoch: UInt64 = 0

    public init(maximumAttempts: Int = 5, pause: @escaping Pause = { try await Task.sleep(for: $0) }) {
        self.maximumAttempts = min(max(maximumAttempts, 1), 5)
        self.pause = pause
    }

    deinit { task?.cancel() }

    public var isScheduled: Bool {
        task != nil
    }

    public func isCurrent(_ ticket: UInt64) -> Bool {
        epoch == ticket && task != nil
    }

    public func cancel() {
        epoch &+= 1
        task?.cancel()
        task = nil
    }

    /// Duplicate screen notifications do not replace the captured intent or
    /// reset its finite retry budget. A new user intent calls cancel first.
    public func schedule(
        attempt: @escaping @MainActor @Sendable (UInt64) async -> Outcome,
        finished: @escaping @MainActor @Sendable (UInt64) -> Void
    ) {
        guard task == nil else { return }
        epoch &+= 1
        let ticket = epoch, count = maximumAttempts, pause = pause
        task = Task { [weak self] in
            for index in 0 ..< count {
                guard !Task.isCancelled, self?.isCurrent(ticket) == true else { return }
                let outcome = await attempt(ticket)
                guard !Task.isCancelled, self?.isCurrent(ticket) == true else { return }
                if case .finished = outcome {
                    break
                }
                if index + 1 < count {
                    do { try await pause(.milliseconds(100 * (index + 1))) }
                    catch { break }
                }
            }
            guard self?.isCurrent(ticket) == true else { return }
            finished(ticket)
            self?.task = nil
        }
    }

    public func waitUntilFinished() async {
        await task?.value
    }
}
