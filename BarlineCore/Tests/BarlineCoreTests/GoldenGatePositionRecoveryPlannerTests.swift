@testable import BarlineCore
import Testing

@Suite("Golden Gate transaction recovery")
struct GoldenGatePositionRecoveryPlannerTests {
    private let key = "status:Example::Item"

    @Test("A staged transaction at its original value clears without writing")
    func stagedOriginalClears() {
        #expect(action(.staged, current: 100) == .clearOriginalJournal)
    }

    @Test("An applied but unverified transaction rolls back")
    func appliedProposalRollsBack() {
        #expect(action(.applied, current: 200) == .rollback(
            GoldenGatePositionMutation(changes: [
                GoldenGatePositionChange(key: key, originalValue: 200, proposedValue: 100),
            ])
        ))
    }

    @Test("A crash between preference write and phase update still rolls back")
    func stagedProposalRollsBack() {
        #expect(action(.staged, current: 200) == .rollback(
            GoldenGatePositionMutation(changes: [
                GoldenGatePositionChange(key: key, originalValue: 200, proposedValue: 100),
            ])
        ))
    }

    @Test("A verified proposal survives relaunch")
    func verifiedProposalClears() {
        #expect(action(.verified, current: 200) == .commitVerifiedCompanion)
    }

    @Test("A verified transaction already restored to original does not commit companion state")
    func verifiedOriginalClearsWithoutCompanion() {
        #expect(action(.verified, current: 100) == .clearOriginalJournal)
    }

    @Test("An external writer always wins")
    func externalWriterWins() {
        #expect(action(.applied, current: 300) == .preserveExternalStateAndClearJournal)
    }

    private func action(
        _ phase: GoldenGatePositionRecoveryPhase,
        current: Int
    ) -> GoldenGatePositionRecoveryAction {
        GoldenGatePositionRecoveryPlanner.action(
            phase: phase,
            mutation: GoldenGatePositionMutation(changes: [
                GoldenGatePositionChange(key: key, originalValue: 100, proposedValue: 200),
            ]),
            currentPositions: [key: current]
        )
    }
}
