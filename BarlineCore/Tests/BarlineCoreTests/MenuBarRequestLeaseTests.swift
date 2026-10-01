@testable import BarlineCore
import Foundation
import Testing

@Suite("Bounded helper recovery ownership")
struct MenuBarRequestLeaseTests {
    @Test("Expired queue admission cannot acquire a session")
    func expiredAdmission() {
        let lease = MenuBarRequestLease(admittedEpoch: 3, deadline: 100)
        #expect(!lease.isLive(now: 100))
        #expect(!lease.bind(generation: 4, now: 100))
        #expect(lease.revoke() == nil)
    }

    @Test("A revoked worker cannot bind or switch to a replacement generation")
    func revokedOwnership() {
        let lease = MenuBarRequestLease(admittedEpoch: 3, deadline: 100)
        #expect(lease.bind(generation: 4, now: 10))
        #expect(!lease.bind(generation: 5, now: 11))
        #expect(!lease.admits(generation: 5, now: 11))
        #expect(lease.revoke() == 4)
        #expect(!lease.admits(generation: 4, now: 12))
        #expect(!lease.bind(generation: 5, now: 12))
    }

    @Test("Failed restoration never reports a ready handshake", arguments: [false, true])
    func replayFailure(missingHandshake: Bool) {
        var replayCount = 0
        let result: Int? = MenuBarRecoveryHandshake.run(
            isCurrent: { true },
            handshake: { missingHandshake ? nil : 1 },
            isHandshake: { $0 == 1 },
            replay: { replayCount += 1; return false }
        )
        #expect(result == nil)
        #expect(replayCount == (missingHandshake ? 0 : 1))
    }

    @Test("Expiry between handshake and replay prevents the second transport phase")
    func deadlineBeforeReplay() {
        let lease = MenuBarRequestLease(admittedEpoch: 3, deadline: 100)
        #expect(lease.bind(generation: 4, now: 10))
        var now: UInt64 = 10
        var replayCount = 0
        let result: Int? = MenuBarRecoveryHandshake.run(
            isCurrent: { lease.admits(generation: 4, now: now) },
            handshake: { now = 100; return 1 },
            isHandshake: { $0 == 1 },
            replay: { replayCount += 1; return true }
        )
        #expect(result == nil)
        #expect(replayCount == 0)
    }

    @Test("A suspended old recovery cannot replay after replacement accepts a new configuration")
    func oldRecoveryResumesAfterReplacement() async {
        let lease = MenuBarRequestLease(admittedEpoch: 3, deadline: 100)
        #expect(lease.bind(generation: 4, now: 10))
        let reachedHandshake = DispatchSemaphore(value: 0)
        let resumeHandshake = DispatchSemaphore(value: 0)
        let replayCount = LockedCount()
        let oldRecovery = Task.detached {
            MenuBarRecoveryHandshake.run(
                isCurrent: { lease.admits(generation: 4, now: 10) },
                handshake: {
                    reachedHandshake.signal()
                    guard resumeHandshake.wait(timeout: .now() + 2) == .success else { return nil as Int? }
                    return 1
                },
                isHandshake: { $0 == 1 },
                replay: { replayCount.increment(); return true }
            )
        }
        let reached = await Task.detached { waitForHandshake(reachedHandshake) }.value
        #expect(reached)
        #expect(lease.revoke() == 4)
        let replacement = MenuBarRequestLease(admittedEpoch: 5, deadline: 100)
        #expect(replacement.bind(generation: 6, now: 10))
        resumeHandshake.signal()
        #expect(await oldRecovery.value == nil)
        #expect(replayCount.value == 0)
        #expect(replacement.admits(generation: 6, now: 10))
    }

    @Test("A successful bounded restoration is ready only after replay")
    func acceptedRestoration() {
        var replayed = false
        let result: Int? = MenuBarRecoveryHandshake.run(
            isCurrent: { true }, handshake: { 1 }, isHandshake: { $0 == 1 },
            replay: { replayed = true; return true }
        )
        #expect(result == 1)
        #expect(replayed)
    }
}

private func waitForHandshake(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
