@testable import BarlineCore
import Foundation
import Testing

private enum ClockTransactionEvent: Equatable, Sendable {
    case lift
    case sleep(Duration)
    case press
    case restore(cancelled: Bool)
}

private enum ClockTransactionFailure: Error, Equatable {
    case restorationRejected
}

private final class ClockTransactionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents = [ClockTransactionEvent]()
    private var instant: UInt64
    private var pointerStamp: MenuBarPointerEventStamp
    private let acceptsPress: Bool
    private let failsRestoration: Bool

    init(
        now: UInt64,
        stamp: MenuBarPointerEventStamp,
        acceptsPress: Bool,
        failsRestoration: Bool
    ) {
        instant = now
        pointerStamp = stamp
        self.acceptsPress = acceptsPress
        self.failsRestoration = failsRestoration
    }

    var events: [ClockTransactionEvent] {
        lock.withLock { recordedEvents }
    }

    func now() -> UInt64 {
        lock.withLock { instant }
    }

    func setNow(_ value: UInt64) {
        lock.withLock { instant = value }
    }

    func isCurrent(_ stamp: MenuBarPointerEventStamp) -> Bool {
        lock.withLock { pointerStamp == stamp }
    }

    func replaceStamp(_ stamp: MenuBarPointerEventStamp) {
        lock.withLock { pointerStamp = stamp }
    }

    func append(_ event: ClockTransactionEvent) {
        lock.withLock { recordedEvents.append(event) }
    }

    func press() -> Bool {
        lock.withLock {
            recordedEvents.append(.press)
            return acceptsPress
        }
    }

    func restore() throws {
        append(.restore(cancelled: Task.isCancelled))
        try Task.checkCancellation()
        if failsRestoration {
            throw ClockTransactionFailure.restorationRejected
        }
    }
}

/// Each injected delay stays suspended until the test resumes or cancels it.
/// Registration checkpoints ensure no scheduler timing or wall-clock wait is
/// needed to change the click's deadline or pointer witness while it settles.
private actor ManualClockTransactionSleeper {
    private let recorder: ClockTransactionRecorder
    private var pending = [Int: CheckedContinuation<Void, Error>]()
    private var registrations = 0
    private var registrationWaiters = [(target: Int, continuation: CheckedContinuation<Void, Never>)]()

    init(recorder: ClockTransactionRecorder) {
        self.recorder = recorder
    }

    func sleep(for duration: Duration) async throws {
        registrations += 1
        let registration = registrations
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recorder.append(.sleep(duration))
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending[registration] = continuation
                }
                let ready = registrationWaiters.filter { registrations >= $0.target }
                registrationWaiters.removeAll { registrations >= $0.target }
                ready.forEach { $0.continuation.resume() }
            }
        }, onCancel: {
            Task { await self.cancel(registration) }
        })
    }

    func waitForRegistrations(_ target: Int) async {
        guard registrations < target else { return }
        await withCheckedContinuation { continuation in
            registrationWaiters.append((target, continuation))
        }
    }

    func resumeNext() {
        guard let registration = pending.keys.min() else { return }
        pending.removeValue(forKey: registration)?.resume()
    }

    private func cancel(_ registration: Int) {
        pending.removeValue(forKey: registration)?.resume(throwing: CancellationError())
    }
}

private struct ClockTransactionHarness: Sendable {
    static let stamp = MenuBarPointerEventStamp(leftDown: 4, rightDown: 7, otherDown: 2)
    static let settle = Duration.nanoseconds(Int64(GoldenGateTiming.clockLiftSettleNanoseconds))
    static let presentation = Duration.milliseconds(150)

    let recorder: ClockTransactionRecorder
    let sleeper: ManualClockTransactionSleeper
    let deadline: UInt64

    init(
        now: UInt64 = 100,
        deadline: UInt64 = 1_000_000_000,
        acceptsPress: Bool = true,
        failsRestoration: Bool = false
    ) {
        let recorder = ClockTransactionRecorder(
            now: now,
            stamp: Self.stamp,
            acceptsPress: acceptsPress,
            failsRestoration: failsRestoration
        )
        self.recorder = recorder
        sleeper = ManualClockTransactionSleeper(recorder: recorder)
        self.deadline = deadline
    }

    func run() async throws -> Bool {
        try await GoldenGateClockTransaction.run(
            deadline: deadline,
            now: { recorder.now() },
            isCurrent: { recorder.isCurrent(Self.stamp) },
            lift: { recorder.append(.lift) },
            press: { recorder.press() },
            restore: { try recorder.restore() },
            sleep: { try await sleeper.sleep(for: $0) }
        )
    }

    func start() -> Task<Bool, Error> {
        Task { try await run() }
    }
}

@Suite("Golden Gate clock transaction")
struct GoldenGateClockTransactionTests {
    private enum InitialRejection: CaseIterable, Sendable {
        case expired
        case insufficientSettleBudget
        case superseded
        case cancelled
    }

    @Test("Lift settles before pressing, and presentation finishes before restoration")
    func successfulOrdering() async throws {
        let harness = ClockTransactionHarness()
        let task = harness.start()

        await harness.sleeper.waitForRegistrations(1)
        #expect(harness.recorder.events == [.lift, .sleep(ClockTransactionHarness.settle)])

        harness.recorder.setNow(harness.deadline - 1)
        await harness.sleeper.resumeNext()
        await harness.sleeper.waitForRegistrations(2)
        #expect(harness.recorder.events == [
            .lift, .sleep(ClockTransactionHarness.settle),
            .press, .sleep(ClockTransactionHarness.presentation),
        ])

        await harness.sleeper.resumeNext()
        #expect(try await task.value)
        #expect(harness.recorder.events == [
            .lift, .sleep(ClockTransactionHarness.settle),
            .press, .sleep(ClockTransactionHarness.presentation),
            .restore(cancelled: false),
        ])
    }

    @Test("A click rejected before lift performs no delay, press, or restoration", arguments: InitialRejection.allCases)
    private func noLiftNeedsNoRestoration(_ reason: InitialRejection) async throws {
        let harness = ClockTransactionHarness()
        switch reason {
        case .expired:
            harness.recorder.setNow(harness.deadline)
        case .insufficientSettleBudget:
            harness.recorder.setNow(harness.deadline - GoldenGateTiming.clockLiftSettleNanoseconds)
        case .superseded:
            harness.recorder.replaceStamp(.init(leftDown: 5, rightDown: 7, otherDown: 2))
        case .cancelled:
            break
        }
        let task = Task {
            if reason == .cancelled {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return try await harness.run()
        }

        #expect(try await task.value == false)
        #expect(harness.recorder.events.isEmpty)
    }

    @Test("Expiry during settle skips the press and still restores lifted items")
    func expiryDuringSettle() async throws {
        let harness = ClockTransactionHarness(
            deadline: 101 + GoldenGateTiming.clockLiftSettleNanoseconds
        )
        let task = harness.start()

        await harness.sleeper.waitForRegistrations(1)
        harness.recorder.setNow(harness.deadline)
        await harness.sleeper.resumeNext()

        #expect(try await task.value == false)
        #expect(harness.recorder.events == [
            .lift, .sleep(ClockTransactionHarness.settle), .restore(cancelled: false),
        ])
    }

    @Test("Any newer pointer-down stamp during settle supersedes the click", arguments: [
        MenuBarPointerEventStamp(leftDown: 5, rightDown: 7, otherDown: 2),
        MenuBarPointerEventStamp(leftDown: 4, rightDown: 8, otherDown: 2),
        MenuBarPointerEventStamp(leftDown: 4, rightDown: 7, otherDown: 3),
    ])
    func supersededDuringSettle(_ replacement: MenuBarPointerEventStamp) async throws {
        let harness = ClockTransactionHarness()
        let task = harness.start()

        await harness.sleeper.waitForRegistrations(1)
        harness.recorder.replaceStamp(replacement)
        await harness.sleeper.resumeNext()

        #expect(try await task.value == false)
        #expect(harness.recorder.events == [
            .lift, .sleep(ClockTransactionHarness.settle), .restore(cancelled: false),
        ])
    }

    @Test("A rejected press skips presentation and restores once")
    func rejectedPress() async throws {
        let harness = ClockTransactionHarness(acceptsPress: false)
        let task = harness.start()

        await harness.sleeper.waitForRegistrations(1)
        await harness.sleeper.resumeNext()

        #expect(try await task.value == false)
        #expect(harness.recorder.events == [
            .lift, .sleep(ClockTransactionHarness.settle), .press, .restore(cancelled: false),
        ])
    }

    @Test("Cancellation during settle restores from a task that is not cancelled")
    func cancellationDuringSettle() async throws {
        let harness = ClockTransactionHarness()
        let task = harness.start()

        await harness.sleeper.waitForRegistrations(1)
        task.cancel()

        #expect(try await task.value == false)
        #expect(harness.recorder.events == [
            .lift, .sleep(ClockTransactionHarness.settle), .restore(cancelled: false),
        ])
    }

    @Test("Cancellation during presentation preserves the accepted press and restores")
    func cancellationDuringPresentation() async throws {
        let harness = ClockTransactionHarness()
        let task = harness.start()

        await harness.sleeper.waitForRegistrations(1)
        await harness.sleeper.resumeNext()
        await harness.sleeper.waitForRegistrations(2)
        task.cancel()

        #expect(try await task.value)
        #expect(harness.recorder.events == [
            .lift, .sleep(ClockTransactionHarness.settle),
            .press, .sleep(ClockTransactionHarness.presentation),
            .restore(cancelled: false),
        ])
    }

    @Test("Restoration failures propagate after exactly one foreground attempt", arguments: [false, true])
    func restorationFailureIsNotRetried(_ acceptsPress: Bool) async {
        let harness = ClockTransactionHarness(acceptsPress: acceptsPress, failsRestoration: true)
        let task = harness.start()

        await harness.sleeper.waitForRegistrations(1)
        await harness.sleeper.resumeNext()
        if acceptsPress {
            await harness.sleeper.waitForRegistrations(2)
            await harness.sleeper.resumeNext()
        }

        await #expect(throws: ClockTransactionFailure.restorationRejected) { try await task.value }
        var expected: [ClockTransactionEvent] = [.lift, .sleep(ClockTransactionHarness.settle), .press]
        if acceptsPress {
            expected.append(.sleep(ClockTransactionHarness.presentation))
        }
        expected.append(.restore(cancelled: false))
        #expect(harness.recorder.events == expected)
    }

    @Test("Restoration failure still propagates after cancellation")
    func restorationFailureAfterCancellation() async {
        let harness = ClockTransactionHarness(failsRestoration: true)
        let task = harness.start()

        await harness.sleeper.waitForRegistrations(1)
        task.cancel()

        await #expect(throws: ClockTransactionFailure.restorationRejected) { try await task.value }
        #expect(harness.recorder.events == [
            .lift, .sleep(ClockTransactionHarness.settle), .restore(cancelled: false),
        ])
    }

    @Test("Invalidation revokes the active recovery worker and a later lease stays distinct")
    func recoveryLeaseRevocation() {
        var lease = GoldenGateRecoveryLease()
        #expect(lease.contains(0) == false)

        let original = lease.begin()
        #expect(lease.contains(original))
        lease.invalidate()
        #expect(lease.contains(original) == false)
        lease.invalidate()

        let restarted = lease.begin()
        #expect(restarted != original)
        #expect(lease.contains(restarted))
        #expect(lease.contains(original) == false)
    }

    @Test("A replacement recovery lease gives authority only to the newest worker")
    func replacementRecoveryLease() {
        var lease = GoldenGateRecoveryLease()
        let original = lease.begin()
        let replacement = lease.begin()
        let newest = lease.begin()

        #expect(original != replacement)
        #expect(replacement != newest)
        #expect(lease.contains(original) == false)
        #expect(lease.contains(replacement) == false)
        #expect(lease.contains(newest))
    }

    @Test("Pointer stamps preserve all three counters in the Codable message", arguments: [
        MenuBarPointerEventStamp(leftDown: 0, rightDown: 0, otherDown: 0),
        MenuBarPointerEventStamp(leftDown: 4, rightDown: 7, otherDown: 2),
        MenuBarPointerEventStamp(leftDown: UInt32.max, rightDown: UInt32.max - 1, otherDown: UInt32.max - 2),
    ])
    func pointerStampCodable(_ stamp: MenuBarPointerEventStamp) throws {
        let data = try JSONEncoder().encode(stamp)
        let decoded = try JSONDecoder().decode(MenuBarPointerEventStamp.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: NSNumber])

        #expect(decoded == stamp)
        #expect(Set(object.keys) == Set(["leftDown", "rightDown", "otherDown"]))
        #expect(object["leftDown"]?.uint32Value == stamp.leftDown)
        #expect(object["rightDown"]?.uint32Value == stamp.rightDown)
        #expect(object["otherDown"]?.uint32Value == stamp.otherDown)
    }
}
