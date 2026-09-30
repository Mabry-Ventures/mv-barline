//
//  BarlineApp.swift
//  Barline
//

import SwiftUI

struct BarlineApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        SettingsWindow(appState: appDelegate.appState)
        WelcomeWindow(appState: appDelegate.appState)
    }
}

/// SwiftUI otherwise creates its own NSApplication subclass and bypasses the
/// shelf's Accessibility window registration, despite NSPrincipalClass.
@main
enum BarlineBootstrap {
    @MainActor
    static func main() {
        _ = BarlineApplication.shared
        BarlineApp.main()
    }
}
