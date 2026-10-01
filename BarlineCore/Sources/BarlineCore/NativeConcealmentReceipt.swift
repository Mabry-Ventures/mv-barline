import Foundation

/// Runtime helper evidence only. An assertion acknowledgement does not prove
/// that any native menu-bar control was rendered, absent or usable.
public struct NativeConcealmentReceipt: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case deasserted
        case asserted
        case transient
        case unknown
    }

    public let helperSessionID: UUID
    /// Changes for every native attempt, lift and receipt-relevant transition,
    /// including failed attempts. It is not a successful-commit counter.
    public let assertionRevision: UInt64
    public let configurationRevision: UInt64
    public let configurationDigest: String?
    public let effectiveStateDigest: String?
    public let phase: Phase

    public init(
        helperSessionID: UUID,
        assertionRevision: UInt64,
        configurationRevision: UInt64,
        configurationDigest: String?,
        effectiveStateDigest: String?,
        phase: Phase
    ) {
        self.helperSessionID = helperSessionID
        self.assertionRevision = assertionRevision
        self.configurationRevision = configurationRevision
        self.configurationDigest = configurationDigest
        self.effectiveStateDigest = effectiveStateDigest
        self.phase = phase
    }

    public var hasKnownEffectiveState: Bool {
        phase != .unknown && assertionRevision > 0 && configurationRevision > 0 &&
            Self.isDigest(configurationDigest) && Self.isDigest(effectiveStateDigest)
    }

    public var isStable: Bool {
        hasKnownEffectiveState && (phase == .asserted || phase == .deasserted)
    }

    private static func isDigest(_ digest: String?) -> Bool {
        guard let digest else { return false }
        return digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

/// The helper serializes this ledger with its native transaction gate. Never
/// reconstruct it from a persisted app receipt or accept caller-supplied state.
public struct NativeConcealmentReceiptLedger: Sendable {
    public private(set) var receipt: NativeConcealmentReceipt

    public init() {
        receipt = Self.unknownSession()
    }

    /// Only deterministic overflow tests seed a ledger from arbitrary values.
    init(testReceipt: NativeConcealmentReceipt) {
        receipt = testReceipt
    }

    public mutating func beginNativeTransition() {
        advanceObservationRevision()
        replace(phase: .transient, effectiveDigest: nil)
    }

    public mutating func accept(
        configurationDigest: String,
        effectiveStateDigest: String,
        hasCommittedAssertion: Bool,
        hasTemporaryReveal: Bool,
        forceObservationChange: Bool
    ) {
        let phase: NativeConcealmentReceipt.Phase = hasTemporaryReveal ? .transient :
            (hasCommittedAssertion ? .asserted : .deasserted)
        guard forceObservationChange || receipt.configurationDigest != configurationDigest ||
            receipt.effectiveStateDigest != effectiveStateDigest || receipt.phase != phase
        else { return }
        advanceObservationRevision()
        var configurationRevision = receipt.configurationRevision
        if receipt.configurationDigest != configurationDigest {
            let (next, overflowed) = configurationRevision.addingReportingOverflow(1)
            if overflowed {
                receipt = Self.unknownSession()
                advanceObservationRevision()
                configurationRevision = 1
            } else {
                configurationRevision = next
            }
        }
        receipt = NativeConcealmentReceipt(
            helperSessionID: receipt.helperSessionID,
            assertionRevision: receipt.assertionRevision,
            configurationRevision: configurationRevision,
            configurationDigest: configurationDigest,
            effectiveStateDigest: effectiveStateDigest,
            phase: phase
        )
    }

    public mutating func markUnknown() {
        advanceObservationRevision()
        replace(phase: .unknown, effectiveDigest: nil)
    }

    public mutating func invalidateSession() {
        receipt = Self.unknownSession()
    }

    private mutating func advanceObservationRevision() {
        let (next, overflowed) = receipt.assertionRevision.addingReportingOverflow(1)
        if overflowed {
            receipt = Self.unknownSession()
        }
        receipt = NativeConcealmentReceipt(
            helperSessionID: receipt.helperSessionID,
            assertionRevision: overflowed ? 1 : next,
            configurationRevision: receipt.configurationRevision,
            configurationDigest: receipt.configurationDigest,
            effectiveStateDigest: receipt.effectiveStateDigest,
            phase: receipt.phase
        )
    }

    private mutating func replace(phase: NativeConcealmentReceipt.Phase, effectiveDigest: String?) {
        receipt = NativeConcealmentReceipt(
            helperSessionID: receipt.helperSessionID,
            assertionRevision: receipt.assertionRevision,
            configurationRevision: receipt.configurationRevision,
            configurationDigest: receipt.configurationDigest,
            effectiveStateDigest: effectiveDigest,
            phase: phase
        )
    }

    private static func unknownSession() -> NativeConcealmentReceipt {
        NativeConcealmentReceipt(
            helperSessionID: UUID(), assertionRevision: 0, configurationRevision: 0,
            configurationDigest: nil, effectiveStateDigest: nil, phase: .unknown
        )
    }
}
