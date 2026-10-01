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
        guard let backend = error as? MenuBarBackendError else { return false }
        if case .staleItem = backend {
            return true
        }
        return false
    }
}
