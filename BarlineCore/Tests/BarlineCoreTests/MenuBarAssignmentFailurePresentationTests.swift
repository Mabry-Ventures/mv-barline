@testable import BarlineCore
import Testing

@Suite("Menu bar assignment failure presentation")
struct MenuBarAssignmentFailurePresentationTests {
    @Test("Failed compensation never claims the previous layout is unchanged")
    func rollbackFailureIsUnknownState() {
        let message = MenuBarAssignmentFailurePresentation.message(
            for: MenuBarBackendError.mutationRecoveryFailed
        )

        #expect(message.contains("could not verify"))
        #expect(message.contains("review the current state"))
        #expect(!message.contains("unchanged"))
    }

    @Test("Ordinary rejected assignments retain verified unchanged guidance")
    func ordinaryFailureIsUnchanged() {
        let message = MenuBarAssignmentFailurePresentation.message(
            for: MenuBarBackendError.operationFailed("menu bar item cannot be hidden")
        )

        #expect(message.contains("unchanged"))
    }

    @Test("Denied macOS 27 menu-bar access explains the targeted recovery")
    func positionTableAccessExplainsHowToRetry() {
        let message = MenuBarAssignmentFailurePresentation.message(
            for: MenuBarBackendError.positionTableAccessNotGranted
        )

        #expect(message.contains("menu bar preferences"))
        #expect(message.contains("Preferences folder"))
        #expect(!message.contains("unchanged"))
    }
}
