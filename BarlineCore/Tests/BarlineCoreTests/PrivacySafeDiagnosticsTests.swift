@testable import BarlineCore
import Foundation
import Testing

struct PrivacySafeDiagnosticsTests {
    @Test func activationHandoffFailuresUseExactClosedCodes() {
        let cases = [
            (MenuBarBackendCapabilityReason.sourceApplicationResolution, "source_app_unresolved"),
            (MenuBarBackendCapabilityReason.dragSynthesis, "drag_synthesis_unavailable"),
            (MenuBarBackendCapabilityReason.eventDelivery, "event_delivery_unavailable"),
        ]
        for (reason, expected) in cases {
            #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.unavailableCapability(reason)) == expected)
            #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.unavailableCapability(
                reason + " /Users/private"
            )) == "capability_unavailable")
        }
        let idleError = MenuBarInputIdleTimeoutError()
        #expect(PrivacySafeDiagnostics.errorCode(idleError) == "input_idle_timeout")
        #expect(idleError.errorDescription == "Operation could not be completed")
        #expect(idleError.recoverySuggestion == "Stop moving the pointer or pressing keys, then try again.")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
            "User input did not become idle /Users/private"
        )) == "operation_failed")
    }

    @Test func recoveryPreviewFailuresUseClosedCodes() {
        let failures: [WorkspaceRecoveryPlanner.Failure] = [
            .ambiguousIdentity, .displayTopologyChanged, .itemChangedDisplay,
            .invalidLiveState, .incompleteInventory, .exactTargetUnavailable,
        ]
        #expect(failures.map { PrivacySafeDiagnostics.errorCode($0) } == [
            "recovery_ambiguous_identity", "recovery_display_changed", "recovery_item_display_changed",
            "recovery_invalid_live_state", "recovery_inventory_changed", "recovery_target_unavailable",
        ])
    }

    @Test func recoveryFailuresUseExactPayloadFreeCodes() {
        let cases = [
            ("history restore did not reach requested displays", "restore_display_mismatch"),
            ("history restore did not reach requested display identity", "restore_display_identity_mismatch"),
            ("history restore did not reach requested layout", "restore_layout_mismatch"),
        ]
        for (reason, expected) in cases {
            #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(reason)) == expected)
            #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
                reason + " /Users/private/profile"
            )) == "operation_failed")
        }
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarWorkspaceTransactionError.superseded) == "workspace_superseded")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarWorkspaceTransactionError.sideEffectRecoveryFailed) == "workspace_recovery_failed")
    }

    @Test func knownMoveFailuresUseClosedCodes() {
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
            "Menu bar item did not reach requested section"
        )) == "move_section_settlement_failed")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
            "menu bar move did not reach requested section"
        )) == "move_postcondition_failed")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
            "Menu bar event delivery timed out"
        )) == "move_delivery_timed_out")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
            "Menu bar event delivery timed out /Users/private"
        )) == "operation_failed")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
            "native concealment did not reach requested visibility"
        )) == "concealment_postcondition_failed")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
            "Golden Gate native concealment rejected"
        )) == "concealment_native_rejected")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
            "native concealment rollback failed"
        )) == "concealment_rollback_failed")
    }

    @Test func payloadsAreNeverFormatted() {
        let secret = "PRIVATE_PROFILE_TITLE_/Users/private-person/private-file"
        let item = MenuBarItemID(bundleIdentifier: secret, title: secret)
        let errors: [any Error] = [
            MenuBarBackendError.staleItem(item),
            MenuBarBackendError.operationFailed(secret),
            MenuBarBackendError.unavailableCapability(secret),
            MenuBarBackendError.invalidSnapshot(.unstableItemIdentity(item)),
            NSError(domain: secret, code: 7, userInfo: [
                NSLocalizedDescriptionKey: secret,
                NSUnderlyingErrorKey: MenuBarBackendError.staleItem(item),
            ]),
        ]
        let codes = errors.map { PrivacySafeDiagnostics.errorCode($0) }
        #expect(codes == ["stale_item", "operation_failed", "capability_unavailable",
                          "snapshot_unstable_item", "operation_failed"])
        #expect(!String(describing: codes).contains(secret))
    }

    @Test func collapseFailureRemainsDiagnosableWithoutInventory() {
        #expect(PrivacySafeDiagnostics.errorCode(
            MenuBarBackendError.invalidSnapshot(.implausibleSystemItemCollapse(previous: 15, candidate: 4))
        ) == "snapshot_system_item_collapse")
        #expect(PrivacySafeDiagnostics.errorCode(CancellationError()) == "cancelled")
    }

    @Test func everySnapshotCodeIsClosedAndPayloadFree() {
        let secret = "private_payload"
        let item = MenuBarItemID(bundleIdentifier: secret, title: secret)
        let display = MenuBarDisplayID(secret)
        let reasons: [SnapshotRejectionReason] = [
            .missingDisplayGeometry, .invalidActiveSpace, .staleSnapshot, .futureDatedSnapshot,
            .unknownItemDisplay(display), .displayIdentitySetMismatch, .duplicateDisplayIdentity(display),
            .malformedDisplayFingerprint, .duplicateItemIdentity(item), .unstableItemIdentity(item),
            .invalidItemGeometry(item), .missingRequiredControlItem(item),
            .implausibleItemCountCollapse(previous: 99, candidate: 1),
            .implausibleSystemItemCollapse(previous: 99, candidate: 1), .emptySnapshot,
            .nonMonotonicGeneration(previous: 99, candidate: 1),
        ]
        let codes = reasons.map { PrivacySafeDiagnostics.errorCode(MenuBarBackendError.invalidSnapshot($0)) }
        #expect(Set(codes).count == reasons.count)
        for code in codes {
            #expect(code.hasPrefix("snapshot_"))
            #expect(!code.contains(secret))
            #expect(code.allSatisfy { $0.isLowercase || $0 == "_" })
        }
    }

    @Test func wrappedAndSerializationErrorsDropTheirDescriptions() {
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.unsafeMenuTracking) == "menu_tracking_active")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.interrupted) == "helper_interrupted")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.timedOut) == "helper_timed_out")
        #expect(PrivacySafeDiagnostics.errorCode(
            MenuBarBackendError.positionTableIdentityUnresolved
        ) == "position_table_identity_unresolved")
        #expect(PrivacySafeDiagnostics.errorCode(DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "private file path")
        )) == "decode_failed")
        #expect(PrivacySafeDiagnostics.errorCode(EncodingError.invalidValue(
            "private item title", .init(codingPath: [], debugDescription: "private profile name")
        )) == "encode_failed")
    }
}
