import Foundation

/// Closed diagnostic vocabulary. Never include an error's associated payload,
/// description, userInfo, identity, title, path, or a nested error in a log.
public enum PrivacySafeDiagnostics {
    public static func errorCode(_ error: any Error) -> String {
        if let recoveryError = error as? WorkspaceRecoveryPlanner.Failure {
            switch recoveryError {
            case .ambiguousIdentity: return "recovery_ambiguous_identity"
            case .displayTopologyChanged: return "recovery_display_changed"
            case .itemChangedDisplay: return "recovery_item_display_changed"
            case .invalidLiveState: return "recovery_invalid_live_state"
            case .incompleteInventory: return "recovery_inventory_changed"
            case .exactTargetUnavailable: return "recovery_target_unavailable"
            }
        }
        if let transactionError = error as? MenuBarWorkspaceTransactionError {
            switch transactionError {
            case .superseded: return "workspace_superseded"
            case .sideEffectRecoveryFailed: return "workspace_recovery_failed"
            }
        }
        if error is MenuBarInputIdleTimeoutError {
            return "input_idle_timeout"
        }
        guard let backendError = error as? MenuBarBackendError else {
            if error is CancellationError {
                return "cancelled"
            }
            if error is DecodingError {
                return "decode_failed"
            }
            if error is EncodingError {
                return "encode_failed"
            }
            return "operation_failed"
        }
        switch backendError {
        case let .unavailableCapability(reason):
            switch reason {
            case MenuBarBackendCapabilityReason.sourceApplicationResolution: return "source_app_unresolved"
            case MenuBarBackendCapabilityReason.dragSynthesis: return "drag_synthesis_unavailable"
            case MenuBarBackendCapabilityReason.eventDelivery: return "event_delivery_unavailable"
            default: return "capability_unavailable"
            }
        case .staleItem: return "stale_item"
        case .unsafeMenuTracking: return "menu_tracking_active"
        case let .invalidSnapshot(reason): return snapshotCode(reason)
        case .interrupted: return "helper_interrupted"
        case .timedOut: return "helper_timed_out"
        case .mutationRecoveryFailed: return "mutation_recovery_failed"
        case let .operationFailed(reason): return operationCode(reason)
        }
    }

    /// Exact known literals select constants; unknown payloads never escape.
    private static func operationCode(_ reason: String) -> String {
        switch reason {
        case "Menu bar item did not respond to move": "move_no_geometry_change"
        case "Menu bar event delivery timed out": "move_delivery_timed_out"
        case "Menu bar event delivery failed": "move_delivery_failed"
        case "No destination item is available": "move_destination_unavailable"
        case "No destination item is available on the requested display": "move_display_unavailable"
        case "menu bar move did not reach requested section": "move_postcondition_failed"
        case "native concealment did not reach requested visibility": "concealment_postcondition_failed"
        case "Golden Gate native concealment rejected": "concealment_native_rejected"
        case "native concealment rollback failed": "concealment_rollback_failed"
        case "history restore did not reach requested displays": "restore_display_mismatch"
        case "history restore did not reach requested display identity": "restore_display_identity_mismatch"
        case "history restore did not reach requested layout": "restore_layout_mismatch"
        default: "operation_failed"
        }
    }

    private static func snapshotCode(_ reason: SnapshotRejectionReason) -> String {
        switch reason {
        case .missingDisplayGeometry: "snapshot_missing_display"
        case .invalidActiveSpace: "snapshot_invalid_space"
        case .staleSnapshot: "snapshot_stale"
        case .futureDatedSnapshot: "snapshot_future_dated"
        case .unknownItemDisplay: "snapshot_unknown_display"
        case .displayIdentitySetMismatch: "snapshot_display_mismatch"
        case .duplicateDisplayIdentity: "snapshot_duplicate_display"
        case .malformedDisplayFingerprint: "snapshot_invalid_display"
        case .duplicateItemIdentity: "snapshot_duplicate_item"
        case .unstableItemIdentity: "snapshot_unstable_item"
        case .invalidItemGeometry: "snapshot_invalid_geometry"
        case .missingRequiredControlItem: "snapshot_missing_control"
        case .implausibleItemCountCollapse: "snapshot_item_collapse"
        case .implausibleSystemItemCollapse: "snapshot_system_item_collapse"
        case .emptySnapshot: "snapshot_empty"
        case .nonMonotonicGeneration: "snapshot_stale_generation"
        }
    }
}
