@testable import BarlineCore
import Foundation
import Testing

@Suite("Native reconciliation presentation refresh")
struct MenuBarConcealmentRefreshGateTests {
    private func check(_ value: Bool) {
        #expect(value)
    }

    private func require(_ value: MenuBarConcealmentRefreshGate.Request?) throws -> MenuBarConcealmentRefreshGate.Request {
        try #require(value)
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
        check(gate.requestRefresh(after: before) != nil)
        // ID-only discovery cannot observe the parked -> on-screen repair.
        check(!MenuBarDiscoveryRefreshPolicy.shouldRunDiscovery(
            inventoryChanged: false, displayChanged: false, hasUsableSnapshot: true
        ))
        let after = receipt(3, session: session)
        check(gate.requestRefresh(after: after) != nil)
        check(gate.requestRefresh(after: before) == nil)
        check(gate.requestRefresh(after: receipt(3, session: session, phase: .deasserted)) == nil)
        for _ in 0 ..< 100 {
            check(gate.requestRefresh(after: after) == nil)
        }
    }

    @Test("Unknown, transient and absent acknowledgements never request promotion")
    func uncertainReceiptsAreNotAccepted() {
        var gate = MenuBarConcealmentRefreshGate()
        check(gate.requestRefresh(after: nil) == nil)
        check(gate.requestRefresh(after: receipt(0)) == nil)
        check(gate.requestRefresh(after: receipt(2, phase: .unknown)) == nil)
        check(gate.requestRefresh(after: receipt(2, phase: .transient)) == nil)
        check(gate.requestRefresh(after: receipt(2)) != nil)
    }

    @Test("New helper session and deassertion request fresh discovery")
    func helperReplacementAndClear() {
        let replacementSession = UUID()
        var gate = MenuBarConcealmentRefreshGate()
        check(gate.requestRefresh(after: receipt(1)) != nil)
        check(gate.requestRefresh(after: receipt(1, session: replacementSession)) != nil)
        check(gate.requestRefresh(after: receipt(2, session: replacementSession, phase: .deasserted)) != nil)
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
        check(presentation.requestRefresh(after: acknowledged) != nil)
        // Manager assigns a newer request ID here; old trailing completion
        // cannot finish that newer request because its ID is superseded.
        check(discovery.begin(intent: .authoritative))
        check(presentation.requestRefresh(after: acknowledged) == nil)
        check(!discovery.finish(allowsTrailingAutomaticRefresh: false, reachedUsableTerminalState: true))
    }

    @Test("A new acknowledged physical state can refresh terminally failed discovery once")
    func acknowledgedRecoveryOfTerminalFailure() {
        var presentation = MenuBarConcealmentRefreshGate()
        var discovery = MenuBarDiscoveryRefreshGate()
        let acknowledged = receipt(4)
        check(presentation.requestRefresh(after: acknowledged) != nil)
        check(discovery.begin(intent: .authoritative, terminalFailureWithoutSnapshot: true))
        check(!discovery.finish(allowsTrailingAutomaticRefresh: true, reachedUsableTerminalState: true))
        check(presentation.requestRefresh(after: acknowledged) == nil)
    }

    @Test("Failed or cancelled reload releases the same receipt, not a preserved old snapshot")
    func failedPublicationCanRetry() throws {
        var gate = MenuBarConcealmentRefreshGate()
        let state = receipt(5)
        let failed = try require(gate.requestRefresh(after: state))
        check(gate.requestRefresh(after: state) == nil)
        gate.finish(failed, succeeded: false)
        let retry = try require(gate.requestRefresh(after: state))
        // A late repeated completion of the failed attempt cannot finish retry.
        gate.finish(failed, succeeded: true)
        check(gate.requestRefresh(after: state) == nil)
        gate.finish(retry, succeeded: true)
        for _ in 0 ..< 100 {
            check(gate.requestRefresh(after: state) == nil)
        }
    }

    @Test("Superseded completion cannot consume or release a newer acknowledgement")
    func staleCompletionCannotAcknowledgeNewReceipt() throws {
        var gate = MenuBarConcealmentRefreshGate()
        let session = UUID()
        let old = receipt(4, session: session)
        let new = receipt(6, session: session)
        let oldRequest = try require(gate.requestRefresh(after: old))
        let newRequest = try require(gate.requestRefresh(after: new))
        gate.finish(oldRequest, succeeded: false)
        check(gate.requestRefresh(after: old) == nil)
        check(gate.requestRefresh(after: new) == nil)
        gate.finish(newRequest, succeeded: false)
        let retry = try require(gate.requestRefresh(after: new))
        gate.finish(oldRequest, succeeded: true)
        gate.finish(retry, succeeded: true)
        check(gate.requestRefresh(after: old) == nil)
        check(gate.requestRefresh(after: new) == nil)
    }
}
