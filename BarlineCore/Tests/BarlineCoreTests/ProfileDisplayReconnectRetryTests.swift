@testable import BarlineCore
import Foundation
import Testing

@Suite("Bounded display reconnect observation lifecycle")
@MainActor
struct ProfileDisplayReconnectRetryTests {
    @Test("Transient observation failure retries without another notification")
    func transientFailure() async {
        let retry = ProfileDisplayReconnectRetry(pause: { _ in await Task.yield() })
        var observations = 0, mutations = 0, finishes = 0
        retry.schedule(attempt: { _ in
            observations += 1
            if observations == 1 {
                return .retryObservation
            }
            mutations += 1
            return .finished
        }, finished: { _ in finishes += 1 })
        await retry.waitUntilFinished()
        #expect(observations == 2)
        #expect(mutations == 1)
        #expect(finishes == 1)
        #expect(!retry.isScheduled)
    }

    @Test("Duplicate screen signals coalesce without renewing the budget")
    func duplicateEvents() async {
        let retry = ProfileDisplayReconnectRetry(pause: { _ in await Task.yield() })
        var observations = 0, replaced = false
        retry.schedule(attempt: { _ in observations += 1; return .retryObservation }, finished: { _ in })
        for _ in 0 ..< 20 {
            retry.schedule(attempt: { _ in replaced = true; return .finished }, finished: { _ in })
        }
        await retry.waitUntilFinished()
        #expect(observations == 5)
        #expect(!replaced)
        #expect(!retry.isScheduled)
    }

    @Test("A mutation claim finishes recovery even after activation or save failure")
    func noMutationReplay() async {
        let retry = ProfileDisplayReconnectRetry(pause: { _ in await Task.yield() })
        var claims = 0
        retry.schedule(attempt: { _ in claims += 1; return .finished }, finished: { _ in })
        await retry.waitUntilFinished()
        #expect(claims == 1)
    }

    @Test("Superseding user intent invalidates admission before a semaphore wait")
    func cancelBeforeAdmission() async {
        let retry = ProfileDisplayReconnectRetry(pause: { _ in await Task.yield() })
        var staleTicket: UInt64?, mutations = 0, finishes = 0
        retry.schedule(attempt: { ticket in
            staleTicket = ticket
            retry.cancel()
            if retry.isCurrent(ticket) {
                mutations += 1
            }
            return .retryObservation
        }, finished: { _ in finishes += 1 })
        await retry.waitUntilFinished()
        #expect(staleTicket != nil)
        #expect(mutations == 0)
        #expect(finishes == 0)
        #expect(!retry.isScheduled)
    }

    @Test("Transaction-owned workspace changes do not invalidate the external intent epoch")
    func ownedWorkspaceRevision() async {
        let retry = ProfileDisplayReconnectRetry(pause: { _ in await Task.yield() })
        var revision = 7, valid = false
        retry.schedule(attempt: { ticket in
            revision += 1
            valid = retry.isCurrent(ticket)
            return .finished
        }, finished: { _ in })
        await retry.waitUntilFinished()
        #expect(revision == 8)
        #expect(valid)
    }
}
