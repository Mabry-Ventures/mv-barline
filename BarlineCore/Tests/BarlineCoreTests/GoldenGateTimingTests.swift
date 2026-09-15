//
//  GoldenGateTimingTests.swift
//  BarlineCoreTests
//

@testable import BarlineCore
import Testing

private actor DebounceRecorder {
    private(set) var values = [Int]()

    func append(_ value: Int) {
        values.append(value)
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
    }

    @MainActor
    @Test("A request burst runs only the newest concealment synchronization")
    func debouncerRunsOnlyNewestRequest() async throws {
        let recorder = DebounceRecorder()
        let debouncer = GoldenGateConcealmentSyncDebouncer(delay: .milliseconds(30))

        for value in 0 ..< 4 {
            debouncer.schedule {
                await recorder.append(value)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(60))

        #expect(await recorder.values == [3])
    }

    @MainActor
    @Test("Assignment cancels pending concealment synchronization")
    func debouncerCancelsPendingRequest() async throws {
        let recorder = DebounceRecorder()
        let debouncer = GoldenGateConcealmentSyncDebouncer(delay: .milliseconds(30))

        debouncer.schedule {
            await recorder.append(1)
        }
        await debouncer.cancelAndWait()
        try await Task.sleep(for: .milliseconds(45))

        #expect(await recorder.values.isEmpty)
    }
}
