@testable import BarlineCore
import Foundation
import Testing

@Suite("Async exclusive operation gate")
struct AsyncExclusiveOperationGateTests {
    private actor Probe {
        var active = 0
        var maximum = 0
        var cancelledOperationRan = false

        func enter() {
            active += 1
            maximum = max(maximum, active)
        }

        func leave() {
            active -= 1
        }

        func markCancelledOperationRan() {
            cancelledOperationRan = true
        }
    }

    @Test("Operations remain exclusive across suspension")
    func serializesSuspendingOperations() async throws {
        let gate = AsyncExclusiveOperationGate()
        let probe = Probe()
        let tasks = (0 ..< 8).map { _ in
            Task {
                try await gate.withLock {
                    await probe.enter()
                    try await Task.sleep(for: .milliseconds(5))
                    await probe.leave()
                }
            }
        }
        for task in tasks {
            try await task.value
        }
        #expect(await probe.maximum == 1)
    }

    @Test("A cancelled waiter never enters the protected operation")
    func cancellationRemovesWaiter() async throws {
        let gate = AsyncExclusiveOperationGate()
        let probe = Probe()
        let holder = Task {
            try await gate.withLock {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let waiter = Task {
            try await gate.withLock {
                await probe.markCancelledOperationRan()
            }
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        try await holder.value
        #expect(await probe.cancelledOperationRan == false)
    }
}
