public enum MenuBarAssignmentFailurePresentation {
    public static func message(for error: any Error) -> String {
        if case MenuBarBackendError.positionTableAccessNotGranted = error {
            return "Barline needs access to the macOS menu bar preference file before it can change this layout. Choose Allow, select the highlighted com.apple.MenuBar.plist file, then try the move again."
        }
        if case MenuBarBackendError.positionTableIdentityUnresolved = error {
            return "Barline could not safely match this item to its macOS menu bar layout record. No layout was changed. Refresh Menu Bar Layout and try again; if it persists, create a support bundle so we can add support without guessing."
        }
        if case MenuBarBackendError.mutationRecoveryFailed = error {
            return "Barline could not verify that the previous layout was restored. Open Menu Bar Layout to review the current state before trying again."
        }
        // The privacy-safe code lets a screenshot of this alert identify the
        // failing stage without a support bundle.
        let code = PrivacySafeDiagnostics.errorCode(error)
        return "Your existing menu bar layout is unchanged. Please try again. (Reference: \(code))"
    }
}
