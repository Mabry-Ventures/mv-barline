public enum MenuBarAssignmentFailurePresentation {
    public static func message(for error: any Error) -> String {
        if case MenuBarBackendError.positionTableAccessNotGranted = error {
            return "Barline needs access to the macOS menu bar preferences before it can change this layout. Choose Allow, select the highlighted Preferences folder, then try the move again."
        }
        if case MenuBarBackendError.mutationRecoveryFailed = error {
            return "Barline could not verify that the previous layout was restored. Open Menu Bar Layout to review the current state before trying again."
        }
        return "Your existing menu bar layout is unchanged. Please try again."
    }
}
