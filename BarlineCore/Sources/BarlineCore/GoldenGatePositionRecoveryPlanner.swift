import Foundation

public enum GoldenGatePositionRecoveryPhase: String, Codable, Equatable, Sendable {
    case staged
    case applied
    case verified
}

public enum GoldenGatePositionRecoveryAction: Equatable, Sendable {
    case clearOriginalJournal
    case commitVerifiedCompanion
    case rollback(GoldenGatePositionMutation)
    case preserveExternalStateAndClearJournal
}

/// Pure crash-recovery policy for one durable position-table transaction.
public enum GoldenGatePositionRecoveryPlanner {
    public static func action(
        phase: GoldenGatePositionRecoveryPhase,
        mutation: GoldenGatePositionMutation,
        currentPositions: [String: Int]
    ) -> GoldenGatePositionRecoveryAction {
        let isOriginal = mutation.changes.allSatisfy {
            currentPositions[$0.key] == $0.originalValue
        }
        if isOriginal {
            return .clearOriginalJournal
        }
        let isProposed = mutation.changes.allSatisfy {
            currentPositions[$0.key] == $0.proposedValue
        }
        if phase == .verified, isProposed {
            return .commitVerifiedCompanion
        }
        if isProposed,
           let rollback = GoldenGatePositionTablePlanner.conditionalRollback(
               for: mutation,
               currentPositions: currentPositions
           )
        {
            return .rollback(rollback)
        }
        return .preserveExternalStateAndClearJournal
    }
}
