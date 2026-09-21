//
//  WelcomeView.swift
//  Barline
//

import BarlineCore
import SwiftUI

/// The first-run walkthrough. Each permission is requested only when the user
/// clicks to allow it, every step can be skipped, and nothing here blocks
/// using the app.
struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissions: AppPermissions
    @ObservedObject var model: WelcomeModel

    var body: some View {
        VStack(spacing: 22) {
            header
            content
                .frame(maxWidth: .infinity, minHeight: 230, alignment: .top)
            footer
        }
        .padding(28)
        .frame(width: 520)
        .fixedSize()
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            progress
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressLabel)
    }

    private var progressLabel: String {
        let steps = WelcomeStep.allCases
        let position = (steps.firstIndex(of: model.step) ?? 0) + 1
        return "Step \(position) of \(steps.count)"
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            welcomeStep
        case .accessibility:
            accessibilityStep
        case .screenRecording:
            screenRecordingStep
        case .barSetup:
            barSetupStep
        case .done:
            doneStep
        }
    }

    private var welcomeStep: some View {
        WelcomeStepContent(
            title: "Welcome to Barline",
            message: """
            Barline keeps the menu bar items you use in view and tucks the rest \
            away. Setup takes about a minute: two permissions, then a quick look \
            at how your bar works.
            """
        ) {
            Label(
                "No account, analytics, or telemetry. Barline never uploads your menu bar.",
                systemImage: "lock.shield"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var accessibilityStep: some View {
        WelcomeStepContent(
            title: "Allow Accessibility",
            message: """
            Barline uses Accessibility to see your menu bar items and move them \
            between sections. Without it, Barline can’t arrange your menu bar.
            """
        ) {
            WelcomePermissionControl(
                permission: permissions.accessibility,
                grantTitle: "Allow Accessibility",
                note: "macOS will ask you to turn on Barline in System Settings. Then come back here."
            )
        }
    }

    /// The walkthrough describes the menu bar model of the system it runs on.
    private var platform: WelcomeMenuBarPlatform {
        if #available(macOS 27.0, *) {
            return .macOS27
        }
        return .macOS26
    }

    private var screenRecordingStep: some View {
        WelcomeStepContent(
            title: "Allow Screen Recording",
            subtitle: "Optional",
            message: WelcomeCopy.screenRecordingMessage(for: platform)
        ) {
            WelcomePermissionControl(
                permission: permissions.screenRecording,
                grantTitle: "Allow Screen Recording",
                note: """
                If macOS asks you to quit and reopen Barline, choose Quit & Reopen. \
                This walkthrough picks up where you left off.
                """
            )
        }
    }

    private var barSetupStep: some View {
        WelcomeStepContent(
            title: "Set Up Your Bar",
            message: "Barline splits your menu bar into sections."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                WelcomeSectionRow(name: "Visible", detail: "Always shown in the menu bar.")
                WelcomeSectionRow(name: "Hidden", detail: "Tucked away until you click the Barline icon.")
                WelcomeSectionRow(name: "Always-Hidden", detail: "Optional. Turn it on in Settings › Advanced.")
            }
            Text(WelcomeCopy.barSetupInstruction(for: platform))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            barSetupNotice
            Button("Open Layout Editor") {
                openLayoutEditor()
            }
        }
    }

    @ViewBuilder
    private var barSetupNotice: some View {
        switch WelcomeFlow.barSetupNotice(
            hasAccessibility: permissions.accessibility.hasPermission,
            menuBarAutoHides: appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults,
            hasScreenRecording: permissions.screenRecording.hasPermission,
            platform: platform
        ) {
        case .ready:
            EmptyView()
        case .needsAccessibility:
            WelcomeNotice("The layout editor needs Accessibility. You can allow it later in Settings.")
        case .menuBarAutoHides:
            WelcomeNotice(WelcomeCopy.menuBarAutoHidesNotice(for: platform))
        case .needsScreenRecording:
            WelcomeNotice(WelcomeCopy.needsScreenRecordingNotice)
        }
    }

    private var doneStep: some View {
        WelcomeStepContent(
            title: "You’re All Set",
            message: "Click the Barline icon in your menu bar to show hidden items. Right-click it for Settings."
        ) {
            Text("You can see this walkthrough again from Settings › General.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.step != .done {
                Button("Finish Later") {
                    close()
                }
                .buttonStyle(.link)
            }
            Spacer()
            if WelcomeFlow.step(before: model.step) != nil {
                Button("Back") {
                    model.goBack()
                }
            }
            primaryButton
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.step {
        case .welcome:
            Button("Get Started") {
                model.advance()
            }
            .keyboardShortcut(.defaultAction)
        case .accessibility:
            Button(permissions.accessibility.hasPermission ? "Continue" : "Skip for Now") {
                model.advance()
            }
            .keyboardShortcut(.defaultAction)
        case .screenRecording:
            Button(permissions.screenRecording.hasPermission ? "Continue" : "Skip for Now") {
                model.advance()
            }
            .keyboardShortcut(.defaultAction)
        case .barSetup:
            Button("Continue") {
                model.advance()
            }
            .keyboardShortcut(.defaultAction)
        case .done:
            Button("Done") {
                close()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Actions

    private func openLayoutEditor() {
        appState.navigationState.settingsNavigationIdentifier = .menuBarLayout
        // `NSApp.delegate` is SwiftUI's adaptor proxy, not `AppDelegate`, so
        // open Settings through the same path as every other entry point.
        appState.activate(withPolicy: .regular)
        appState.openWindow(.settings)
    }

    private func close() {
        model.finish()
        appState.dismissWindow(.welcome)
    }
}

// MARK: - Components

private struct WelcomeStepContent<Accessory: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let message: String
    let accessory: Accessory

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        message: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.message = message
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.title.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            accessory
        }
    }
}

private struct WelcomePermissionControl: View {
    @ObservedObject var permission: Permission
    let grantTitle: LocalizedStringKey
    let note: String

    var body: some View {
        VStack(spacing: 8) {
            if permission.hasPermission {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                // The system permission dialog appears only after this click.
                Button(grantTitle) {
                    permission.performRequest()
                }
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WelcomeSectionRow: View {
    let name: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .fontWeight(.semibold)
                .frame(width: 110, alignment: .leading)
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WelcomeNotice: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
