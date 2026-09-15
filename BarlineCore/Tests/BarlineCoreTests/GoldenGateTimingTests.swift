//
//  GoldenGateTimingTests.swift
//  BarlineCoreTests
//

@testable import BarlineCore
import Foundation
import Testing

private actor DebounceRecorder {
    private(set) var values = [Int]()
    private var countWaiters = [(target: Int, continuation: CheckedContinuation<Void, Never>)]()

    func append(_ value: Int) {
        values.append(value)
        let ready = countWaiters.filter { values.count >= $0.target }
        countWaiters.removeAll { values.count >= $0.target }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForCount(_ target: Int) async {
        guard values.count < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }
}

private actor ManualDebounceSleeper {
    private var pending = [UUID: CheckedContinuation<Void, Error>]()
    private var registrationWaiters = [(target: Int, continuation: CheckedContinuation<Void, Never>)]()
    private var registrationCount = 0

    func sleep(for _: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                registrationCount += 1
                let ready = registrationWaiters.filter { registrationCount >= $0.target }
                registrationWaiters.removeAll { registrationCount >= $0.target }
                ready.forEach { $0.continuation.resume() }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    func waitForRegistrations(_ target: Int) async {
        guard registrationCount < target else { return }
        await withCheckedContinuation { continuation in
            registrationWaiters.append((target, continuation))
        }
    }

    func resumeAll() {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@Suite("Golden Gate timing")
struct GoldenGateTimingTests {
    @Test("Concealment synchronization starts outside the snapshot cache window")
    func debounceExceedsSnapshotCacheLifetime() {
        #expect(GoldenGateTiming.concealmentSyncDebounceBufferMilliseconds > 0)
        #expect(
            GoldenGateTiming.snapshotCacheLifetimeNanoseconds ==
                UInt64(GoldenGateTiming.snapshotCacheLifetimeMilliseconds) * 1_000_000
        )
        #expect(
            GoldenGateTiming.concealmentSyncDebounce >
                .milliseconds(GoldenGateTiming.snapshotCacheLifetimeMilliseconds)
        )
    }

    @MainActor
    @Test("A request burst runs only the newest concealment synchronization")
    func debouncerRunsOnlyNewestRequest() async {
        let recorder = DebounceRecorder()
        let sleeper = ManualDebounceSleeper()
        let debouncer = GoldenGateConcealmentSyncDebouncer(
            delay: .milliseconds(30),
            wait: { try await sleeper.sleep(for: $0) }
        )

        for value in 0 ..< 4 {
            debouncer.schedule {
                await recorder.append(value)
            }
            await sleeper.waitForRegistrations(value + 1)
        }
        await sleeper.resumeAll()
        await recorder.waitForCount(1)

        #expect(await recorder.values == [3])
    }

    @MainActor
    @Test("Assignment cancels pending concealment synchronization")
    func debouncerCancelsPendingRequest() async {
        let recorder = DebounceRecorder()
        let sleeper = ManualDebounceSleeper()
        let debouncer = GoldenGateConcealmentSyncDebouncer(
            delay: .milliseconds(30),
            wait: { try await sleeper.sleep(for: $0) }
        )

        debouncer.schedule {
            await recorder.append(1)
        }
        await sleeper.waitForRegistrations(1)
        await debouncer.cancelAndWait()

        #expect(await recorder.values.isEmpty)
    }
}
