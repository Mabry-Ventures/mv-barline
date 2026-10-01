@testable import BarlineCore
import Foundation
import Testing

struct IntentCommandFailurePolicyTests {
    @Test func nativeFocusOwnershipDoesNotDependOnActivationSuccess() {
        #expect(IntentCommandFailurePolicy.requestedFocusState(for: .setFocusProfile(UUID())) == true)
        #expect(IntentCommandFailurePolicy.requestedFocusState(for: .setFocusProfile(nil)) == false)
        #expect(IntentCommandFailurePolicy.requestedFocusState(for: .setPresentationMode(true)) == true)
        #expect(IntentCommandFailurePolicy.requestedFocusState(for: .setPresentationMode(false)) == false)
        #expect(IntentCommandFailurePolicy.requestedFocusState(for: .activateProfile(UUID())) == nil)
        #expect(IntentCommandFailurePolicy.requestedFocusState(for: .open(.search)) == nil)
    }

    @Test func unavailableSavedItemRequiresNewUserDecision() {
        let error = MenuBarBackendError.staleItem(.init(bundleIdentifier: "fixture", title: "item"))
        #expect(IntentCommandFailurePolicy.requiresUserReview(error))
    }

    @Test func planningRejectionsUseClosedCodesAndRequireFreshCommands() {
        let cases: [(any Error, String)] = [
            (ProfileLayoutReconciler.Failure.ambiguousIdentity, "layout_ambiguous_identity"),
            (ProfileLayoutReconciler.Failure.missingItem, "layout_missing_item"),
            (ProfileLayoutReconciler.Failure.immovableSectionChange, "layout_fixed_section"),
            (ProfileLayoutReconciler.Failure.immovableOrderChange, "layout_fixed_order"),
            (ProfileLayoutReconciler.Failure.cannotHideItem, "layout_item_not_hideable"),
            (ProfileLayoutReconciler.Failure.unsupportedDestination, "layout_destination_unsupported"),
            (MenuBarArrangementPolicyError.visibilityUnavailable, "layout_visibility_unavailable"),
            (MenuBarArrangementPolicyError.unsupportedVisibilityAssignment,
             "layout_visibility_assignment_unsupported"),
        ]
        for (error, code) in cases {
            #expect(PrivacySafeDiagnostics.errorCode(error) == code)
            #expect(IntentCommandFailurePolicy.requiresUserReview(error))
            let message = IntentCommandFailurePolicy.planningFailureMessage(error)
            #expect(message?.contains("Automatic retries stopped") == true)
            #expect(message?.contains("recovery checkpoint is retained") == true)
        }
        #expect(Set(cases.compactMap { IntentCommandFailurePolicy.planningFailureMessage($0.0) }).count == 8)
    }

    @Test func transientAndUnknownErrorsKeepExistingRetrySemantics() {
        let errors: [any Error] = [
            MenuBarBackendError.interrupted,
            MenuBarBackendError.timedOut,
            MenuBarBackendError.unsafeMenuTracking,
            MenuBarBackendError.unavailableCapability("fixture"),
            MenuBarBackendError.operationFailed("stale_item"),
            MenuBarWorkspaceTransactionError.sideEffectRecoveryFailed,
            CancellationError(),
        ]
        for error in errors {
            #expect(!IntentCommandFailurePolicy.requiresUserReview(error))
            #expect(IntentCommandFailurePolicy.planningFailureMessage(error) == nil)
        }
    }
}
