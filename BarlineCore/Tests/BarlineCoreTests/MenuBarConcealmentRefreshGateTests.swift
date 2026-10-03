@testable import BarlineCore
import Foundation
import Testing

@Suite("Native reconciliation presentation refresh")
struct MenuBarConcealmentRefreshGateTests {
    private func check(_ value: Bool) {
        #expect(value)
    }

    private func receipt(_ revision: UInt64, session: UUID = UUID(), phase: NativeConcealmentReceipt.Phase = .asserted) -> NativeConcealmentReceipt {
        NativeConcealmentReceipt(
            helperSessionID: session, assertionRevision: revision, configurationRevision: 1,
            configurationDigest: String(repeating: "a", count: 64),
            effectiveStateDigest: String(repeating: "b", count: 64), phase: phase
        )
    }

    @Test("Same IDs becoming hideable reload once after native reconciliation, without feedback")
    func repairedPublisherReloadsOnce() {
        let session = UUID()
        var gate = MenuBarConcealmentRefreshGate()
        let before = receipt(1, session: session)
        check(gate.requestRefresh(after: before))
        // ID-only discovery cannot observe the parked -> on-screen repair.
        check(!MenuBarDiscoveryRefreshPolicy.shouldRunDiscovery(
            inventoryChanged: false, displayChanged: false, hasUsableSnapshot: true
        ))
        let after = receipt(3, session: session)
        check(gate.requestRefresh(after: after))
        check(!gate.requestRefresh(after: before))
        check(!gate.requestRefresh(after: receipt(3, session: session, phase: .deasserted)))
        for _ in 0 ..< 100 {
            check(!gate.requestRefresh(after: after))
        }
    }

    @Test("Unknown, transient and absent acknowledgements never request promotion")
    func uncertainReceiptsAreNotAccepted() {
        var gate = MenuBarConcealmentRefreshGate()
        check(!gate.requestRefresh(after: nil))
        check(!gate.requestRefresh(after: receipt(0)))
        check(!gate.requestRefresh(after: receipt(2, phase: .unknown)))
        check(!gate.requestRefresh(after: receipt(2, phase: .transient)))
        check(gate.requestRefresh(after: receipt(2)))
    }

    @Test("New helper session and deassertion request fresh discovery")
    func helperReplacementAndClear() {
        let replacementSession = UUID()
        var gate = MenuBarConcealmentRefreshGate()
        check(gate.requestRefresh(after: receipt(1)))
        check(gate.requestRefresh(after: receipt(1, session: replacementSession)))
        check(gate.requestRefresh(after: receipt(2, session: replacementSession, phase: .deasserted)))
    }

    @Test("Post-reconciliation reload supersedes an in-flight trailing discovery")
    func trailingRefreshCannotDropAcknowledgement() {
        var presentation = MenuBarConcealmentRefreshGate()
        var discovery = MenuBarDiscoveryRefreshGate()
        check(discovery.begin(intent: .automatic))
        check(!discovery.begin(intent: .automatic))
        check(discovery.finish(allowsTrailingAutomaticRefresh: true, reachedUsableTerminalState: true))
        check(discovery.begin(intent: .automatic))
        let acknowledged = receipt(2)
        check(presentation.requestRefresh(after: acknowledged))
        // Manager assigns a newer request ID here; old trailing completion
        // cannot finish that newer request because its ID is superseded.
        check(discovery.begin(intent: .authoritative))
        check(!presentation.requestRefresh(after: acknowledged))
        check(!discovery.finish(allowsTrailingAutomaticRefresh: false, reachedUsableTerminalState: true))
    }

    @Test("A new acknowledged physical state can refresh terminally failed discovery once")
    func acknowledgedRecoveryOfTerminalFailure() {
        var presentation = MenuBarConcealmentRefreshGate()
        var discovery = MenuBarDiscoveryRefreshGate()
        let acknowledged = receipt(4)
        check(presentation.requestRefresh(after: acknowledged))
        check(discovery.begin(intent: .authoritative, terminalFailureWithoutSnapshot: true))
        check(!discovery.finish(allowsTrailingAutomaticRefresh: true, reachedUsableTerminalState: true))
        check(!presentation.requestRefresh(after: acknowledged))
    }
}
