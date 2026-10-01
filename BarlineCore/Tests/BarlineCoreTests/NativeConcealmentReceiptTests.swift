@testable import BarlineCore
import Foundation
import Testing

struct NativeConcealmentReceiptTests {
    private let configuration = String(repeating: "a", count: 64)
    private let effective = String(repeating: "b", count: 64)

    @Test("A new helper ledger supplies no stable or effective proof")
    func initialization() {
        let ledger = NativeConcealmentReceiptLedger()
        #expect(ledger.receipt.phase == .unknown)
        #expect(!ledger.receipt.isStable)
        #expect(!ledger.receipt.hasKnownEffectiveState)
        #expect(ledger.receipt.configurationDigest == nil)
        #expect(ledger.receipt.effectiveStateDigest == nil)
    }

    @Test("Native activation invalidates prior evidence before acknowledgement")
    func beginCommitAndFailure() {
        var ledger = acceptedLedger()
        let accepted = ledger.receipt
        ledger.beginNativeTransition()
        #expect(ledger.receipt.phase == .transient)
        #expect(ledger.receipt.assertionRevision > accepted.assertionRevision)
        #expect(!ledger.receipt.hasKnownEffectiveState)
        #expect(ledger.receipt.configurationRevision == accepted.configurationRevision)
        ledger.markUnknown()
        #expect(ledger.receipt.phase == .unknown)
        #expect(ledger.receipt.configurationDigest == accepted.configurationDigest)
        #expect(ledger.receipt.effectiveStateDigest == nil)
        #expect(ledger.receipt != accepted)
        ledger.beginNativeTransition()
        accept(&ledger)
        #expect(ledger.receipt.isStable)
        #expect(ledger.receipt.assertionRevision > accepted.assertionRevision)
        #expect(ledger.receipt.configurationRevision == accepted.configurationRevision)
    }

    @Test("Identical accepted state is a true receipt no-op")
    func noOp() {
        var ledger = acceptedLedger()
        let accepted = ledger.receipt
        accept(&ledger, force: false)
        #expect(ledger.receipt == accepted)
    }

    @Test("Logical configuration changes invalidate proof without a native change")
    func logicalChange() {
        var ledger = acceptedLedger()
        let accepted = ledger.receipt
        ledger.accept(
            configurationDigest: String(repeating: "c", count: 64), effectiveStateDigest: effective,
            hasCommittedAssertion: true, hasTemporaryReveal: false, forceObservationChange: false
        )
        #expect(ledger.receipt.assertionRevision > accepted.assertionRevision)
        #expect(ledger.receipt.configurationRevision == accepted.configurationRevision + 1)
        #expect(ledger.receipt.effectiveStateDigest == accepted.effectiveStateDigest)
    }

    @Test("Reveal ownership is transient even if the assertion is fully cleared")
    func revealLeases() {
        var ledger = acceptedLedger()
        let accepted = ledger.receipt
        ledger.beginNativeTransition()
        accept(&ledger, hasAssertion: false, temporary: true)
        #expect(ledger.receipt.phase == .transient)
        #expect(ledger.receipt.hasKnownEffectiveState)
        #expect(!ledger.receipt.isStable)
        let first = ledger.receipt
        accept(&ledger, hasAssertion: false, temporary: true)
        #expect(ledger.receipt.assertionRevision > first.assertionRevision)
        #expect(ledger.receipt.configurationRevision == accepted.configurationRevision)
        ledger.beginNativeTransition()
        accept(&ledger)
        #expect(ledger.receipt.isStable)
        #expect(ledger.receipt != accepted)
    }

    @Test("Clock lift and reapplication cannot reuse pre-lift receipt")
    func clockLift() {
        var ledger = acceptedLedger()
        let accepted = ledger.receipt
        ledger.beginNativeTransition()
        ledger.beginNativeTransition()
        accept(&ledger)
        #expect(ledger.receipt.phase == accepted.phase)
        #expect(ledger.receipt.effectiveStateDigest == accepted.effectiveStateDigest)
        #expect(ledger.receipt.configurationRevision == accepted.configurationRevision)
        #expect(ledger.receipt.assertionRevision == accepted.assertionRevision + 3)
    }

    @Test("Invalidation rotates lifetime and discards accepted proof")
    func invalidation() {
        var ledger = acceptedLedger()
        let accepted = ledger.receipt
        ledger.invalidateSession()
        #expect(ledger.receipt.helperSessionID != accepted.helperSessionID)
        #expect(ledger.receipt.assertionRevision == 0)
        #expect(ledger.receipt.configurationRevision == 0)
        #expect(!ledger.receipt.isStable)
    }

    @Test("Revision exhaustion rotates lifetime rather than wrapping proof", arguments: [true, false])
    func overflow(assertion: Bool) {
        let initial = NativeConcealmentReceipt(
            helperSessionID: UUID(), assertionRevision: assertion ? .max : 5,
            configurationRevision: assertion ? 1 : .max,
            configurationDigest: configuration, effectiveStateDigest: effective, phase: .asserted
        )
        var ledger = NativeConcealmentReceiptLedger(testReceipt: initial)
        if assertion {
            ledger.beginNativeTransition()
        } else {
            ledger.accept(
                configurationDigest: String(repeating: "c", count: 64), effectiveStateDigest: effective,
                hasCommittedAssertion: true, hasTemporaryReveal: false, forceObservationChange: false
            )
        }
        #expect(ledger.receipt.helperSessionID != initial.helperSessionID)
        #expect(ledger.receipt.assertionRevision == 1)
        #expect(ledger.receipt.configurationRevision < .max)
        if assertion {
            #expect(!ledger.receipt.isStable)
        }
    }

    @Test("Malformed digest cannot supply stable proof", arguments: ["", "abc", String(repeating: "A", count: 64), String(repeating: "z", count: 64)])
    func invalidDigest(digest: String) {
        let receipt = NativeConcealmentReceipt(
            helperSessionID: UUID(), assertionRevision: 3, configurationRevision: 1,
            configurationDigest: digest, effectiveStateDigest: effective, phase: .asserted
        )
        #expect(!receipt.isStable)
    }

    @Test("Environment and service response preserve receipts; legacy peers omit proof")
    func transport() throws {
        let receipt = acceptedLedger().receipt
        let environment = MenuBarEnvironmentSnapshot(
            activeDisplayID: 1, activeStableDisplayID: MenuBarDisplayID("a"), activeSpaceToken: 2,
            activeSpaceIsFullscreen: false, menuTrackingIsActive: false,
            nativeConcealmentReceipt: receipt
        )
        let response = MenuBarServiceResponse.environment(environment)
        let decoded = try JSONDecoder().decode(MenuBarServiceResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded == response)
        let legacy = Data(#"{"activeDisplayID":1,"activeSpaceToken":2,"activeSpaceIsFullscreen":false}"#.utf8)
        #expect(try JSONDecoder().decode(MenuBarEnvironmentSnapshot.self, from: legacy).nativeConcealmentReceipt == nil)
        #expect(environment.replacingConcealmentReceipt(receipt).hasSameValidScene(as: environment))
    }

    private func acceptedLedger() -> NativeConcealmentReceiptLedger {
        var ledger = NativeConcealmentReceiptLedger()
        ledger.beginNativeTransition()
        accept(&ledger)
        return ledger
    }

    private func accept(
        _ ledger: inout NativeConcealmentReceiptLedger,
        hasAssertion: Bool = true, temporary: Bool = false, force: Bool = true
    ) {
        ledger.accept(
            configurationDigest: configuration, effectiveStateDigest: effective,
            hasCommittedAssertion: hasAssertion, hasTemporaryReveal: temporary,
            forceObservationChange: force
        )
    }
}
