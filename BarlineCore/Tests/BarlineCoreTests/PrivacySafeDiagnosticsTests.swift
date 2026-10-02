@testable import BarlineCore
import Foundation
import Testing

struct PrivacySafeDiagnosticsTests {
    @Test func nativeDiscoveryFailuresUseClosedStageCodes() {
        let cases = [
            ("active menu bar scene", "native_scene_unavailable"),
            ("stable menu bar scene", "native_scene_changed"),
            ("verified macOS 27 MenuBarAgent observation", "native_scope_unqualified"),
            ("verified macOS 27 Focus presence", "native_presence_unqualified"),
            ("associated macOS 27 Focus presence", "native_presence_unassociated"),
            ("Golden Gate native concealment", "native_concealment_unavailable"),
        ]
        for (reason, expected) in cases {
            #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.unavailableCapability(reason)) == expected)
            #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.unavailableCapability(
                reason + " /Users/private/item"
            )) == "capability_unavailable")
        }
    }

    @Test func profileTransactionStagesUseExactClosedCodes() {
        let cases = [
            ("saved menu bar identities are ambiguous", "saved_identity_ambiguous"),
            ("profile activation did not reach requested layout", "profile_layout_mismatch"),
            ("profile activation changed an unrequested section or display", "profile_section_or_display_mismatch"),
            ("profile activation did not reach requested visibility", "profile_visibility_mismatch"),
            ("profile activation did not reach requested shelf order", "profile_shelf_order_mismatch"),
            ("profile visibility observation has not settled", "profile_observation_unsettled"),
            ("profile activation postcondition was unavailable", "profile_postcondition_unavailable"),
            ("workspace changed while profile activation was starting", "workspace_changed_at_admission"),
            ("workspace journal persistence failed", "workspace_journal_persistence_failed"),
            ("profile display identity changed during activation", "profile_display_identity_changed"),
            ("profile display identity became ambiguous during activation", "profile_display_identity_ambiguous"),
            ("profile display topology changed during activation", "profile_display_topology_changed"),
            ("profile layout execution did not converge", "profile_execution_unsettled"),
            ("profile recovery inventory changed", "profile_recovery_inventory_changed"),
            ("profile recovery inventory did not return", "profile_recovery_inventory_unsettled"),
            ("item spacing changed repeatedly during profile rollback", "workspace_spacing_rollback_unsettled"),
        ]
        for (reason, expected) in cases {
            #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(reason)) == expected)
            #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.operationFailed(
                reason + " /Users/private/profile"
            )) == "operation_failed")
        }
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.unavailableCapability(
            "macOS 27 native menu bar reorder"
        )) == "native_reorder_unavailable")
        #expect(PrivacySafeDiagnostics.errorCode(MenuBarBackendError.unavailableCapability(
            "macOS 27 native menu bar reorder /Users/private/profile"
        )) == "capability_unavailable")
    }

    @Test func wrappedActivationFailureRetainsBoundariesWithoutLeakingPayloads() throws {
        let secret = "PRIVATE_PROFILE_/Users/private/profile"
        let item = MenuBarItemID(bundleIdentifier: secret, title: secret)
        let failure = ProfileActivationRecoveryFailure(
            activationError: MenuBarBackendError.operationFailed(secret),
            workspaceRollbackError: MenuBarWorkspaceTransactionError.superseded,
            layoutRollbackError: SnapshotRejectionReason.unstableItemIdentity(item)
        )
        let workspaceRollback = try #require(failure.workspaceRollbackError)
        let layoutRollback = try #require(failure.layoutRollbackError)
        let codes = [
            PrivacySafeDiagnostics.errorCode(failure),
            PrivacySafeDiagnostics.errorCode(failure.activationError),
            PrivacySafeDiagnostics.errorCode(workspaceRollback),
            PrivacySafeDiagnostics.errorCode(layoutRollback),
        ]
        #expect(codes == ["profile_activation_recovery_failed", "operation_failed",
                          "workspace_superseded", "snapshot_unstable_item"])
        #expect(!codes.joined().contains(secret))
        let noWorkspaceFailure = ProfileActivationRecoveryFailure(
            activationError: CancellationError(), workspaceRollbackError: nil, layoutRollbackError: nil
        )
        #expect(noWorkspaceFailure.workspaceRollbackError == nil)
        #expect(noWorkspaceFailure.layoutRollbackError == nil)
        #expect(noWorkspaceFailure.activationError is CancellationError)
        #expect(PrivacySafeDiagnostics.errorCode(ProfileValidationError.invalidAppearance) == "profile_appearance_invalid")
        #expect(PrivacySafeDiagnostics.errorCode(ProfileValidationError.malformedDocument(secret)) == "profile_validation_failed")
    }

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
        #expect(reasons.map { PrivacySafeDiagnostics.errorCode($0) } == codes)
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
