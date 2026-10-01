/// Failed commands that need a new user decision must not replay on a timer.
/// This policy never treats rejection as successful layout activation.
public enum IntentCommandFailurePolicy {
    /// Native Focus ownership is independent of whether its layout succeeded.
    public static func requestedFocusState(for command: BarlineIntentCommand) -> Bool? {
        switch command.kind {
        case .setFocusProfile: command.profileID != nil
        case .setPresentationMode: command.presentationModeEnabled
        case .openDestination, .activateProfile: nil
        }
    }

    public static func requiresUserReview(_ error: any Error) -> Bool {
        if error is ProfileAuthorityPersistenceError {
            return true
        }
        if let layoutError = error as? ProfileLayoutReconciler.Failure {
            switch layoutError {
            case .ambiguousIdentity, .missingItem, .immovableSectionChange,
                 .immovableOrderChange, .cannotHideItem, .unsupportedDestination:
                return true
            }
        }
        if let arrangementError = error as? MenuBarArrangementPolicyError {
            switch arrangementError {
            case .visibilityUnavailable, .unsupportedVisibilityAssignment:
                return true
            }
        }
        guard let backend = error as? MenuBarBackendError else { return false }
        if case .staleItem = backend {
            return true
        }
        return false
    }

    /// Planning rejections need a new request after the layout, inventory, or
    /// capabilities change. Never retry the same rejected command on a timer.
    public static func planningFailureMessage(_ error: any Error) -> String? {
        let explanation: String
        if let layoutError = error as? ProfileLayoutReconciler.Failure {
            explanation = switch layoutError {
            case .ambiguousIdentity:
                "Saved items could not be matched uniquely. Review or recapture the layout."
            case .missingItem:
                "A saved item is unavailable. Open its app or update the layout."
            case .immovableSectionChange:
                "This layout moves an item between sections that Barline cannot move."
            case .immovableOrderChange:
                "This layout conflicts with fixed item positions. Review its ordering."
            case .cannotHideItem:
                "This layout hides an item that must remain visible."
            case .unsupportedDestination:
                "This layout requests an unsupported destination. Review its sections and ordering."
            }
        } else if let arrangementError = error as? MenuBarArrangementPolicyError {
            explanation = switch arrangementError {
            case .visibilityUnavailable:
                "Barline cannot apply this layout's visibility changes on the current system."
            case .unsupportedVisibilityAssignment:
                "This layout requests an unsupported visibility combination. Review its visibility assignments."
            }
        } else {
            return nil
        }
        return explanation + " Automatic retries stopped; any recovery checkpoint is retained."
    }
}
