@testable import BarlineCore
import Testing

@Suite("Menu bar assignment session")
@MainActor
struct MenuBarAssignmentSessionTests {
    private actor Suspension {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("Opposite-section assignment is rejected while the first assignment is suspended")
    func rejectsOverlappingAssignmentAcrossSuspension() async {
        let session = MenuBarAssignmentSession()
        let suspension = Suspension()
        var firstOperationRan = false
        var overlappingOperationRan = false

        let first = Task { @MainActor in
            await session.run {
                firstOperationRan = true
                await suspension.wait()
            }
        }

        while !session.isInFlight {
            await Task.yield()
        }

        let overlapAccepted = await session.run {
            overlappingOperationRan = true
        }

        #expect(overlapAccepted == false)
        #expect(overlappingOperationRan == false)
        #expect(session.isInFlight)

        await suspension.resume()
        #expect(await first.value)
        #expect(firstOperationRan)
        #expect(session.isInFlight == false)
    }

    @Test("Session is released after an assignment settles")
    func releasesAfterSettlement() async {
        let session = MenuBarAssignmentSession()
        var completedOperations = 0

        #expect(await session.run { completedOperations += 1 })
        #expect(await session.run { completedOperations += 1 })
        #expect(completedOperations == 2)
        #expect(session.isInFlight == false)
    }

    @Test("App-lifetime session remains locked across view owner replacement")
    func remainsLockedAcrossOwnerReplacement() async {
        let appLifetimeSession = MenuBarAssignmentSession()
        let suspension = Suspension()

        let firstViewOwner = appLifetimeSession
        let first = Task { @MainActor in
            await firstViewOwner.run {
                await suspension.wait()
            }
        }

        while !appLifetimeSession.isInFlight {
            await Task.yield()
        }

        let replacementViewOwner = appLifetimeSession
        var replacementOperationRan = false
        #expect(await replacementViewOwner.run {
            replacementOperationRan = true
        } == false)
        #expect(replacementOperationRan == false)

        await suspension.resume()
        #expect(await first.value)
        #expect(await replacementViewOwner.run {})
    }
}
