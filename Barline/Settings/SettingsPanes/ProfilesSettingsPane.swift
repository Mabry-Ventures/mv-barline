//
//  ProfilesSettingsPane.swift
//  Barline
//

import BarlineCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesSettingsPane: View {
    private static let focusSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Focus-Settings.extension"
    )!

    @EnvironmentObject var appState: AppState
    @ObservedObject var manager: ProfileManager
    @State private var profileName = "Work"
    @StateObject private var captureSubmission = ProfileCaptureSubmission()
    @State private var editedProfile: BarlineProfile?
    @State private var exportDocument: ProfileArchiveDocument?
    @State private var showsArchiveExporter = false
    @State private var showsArchiveImporter = false
    @State private var archiveSelectionNotice: String?
    @State private var focusLayoutID: UUID?
    @State private var confirmedRecoveryToken: UUID?
    @State private var showsFocusRecoveryConfirmation = false
    @State private var availableRecovery: MenuBarPreparedWorkspaceRecovery?
    @State private var showsAvailableRecoveryConfirmation = false
    @State private var archivedRecoveryToken: UUID?
    @State private var showsArchiveRemovalConfirmation = false

    private var focusLayout: BarlineProfile? {
        manager.profiles.first { $0.id == focusLayoutID }
    }

    private var operationsBusy: Bool {
        manager.isBusy || captureSubmission.isSubmitting
    }

    var body: some View {
        Form {
            focusSetupSection
                .disabled(operationsBusy)

            Section("Menu Bar Layouts") {
                if manager.profiles.isEmpty {
                    ContentUnavailableView(
                        "No Saved Layouts",
                        systemImage: "rectangle.topthird.inset.filled",
                        description: Text(
                            "Capture a menu bar layout, then assign it to a macOS Focus using Focus Settings."
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .gridCellColumns(2)
                } else {
                    ForEach(manager.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(profile.name, systemImage: profile.symbol ?? "menubar.rectangle")
                                if !profile.displayOverrides.isEmpty {
                                    Text("\(profile.displayOverrides.count) saved display variants · Review in Edit")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if manager.activeProfileID == profile.id {
                                Text("Active").foregroundStyle(.secondary)
                            }
                            Button("Apply") { Task { await manager.activate(profile) } }
                                .accessibilityLabel("Apply \(profile.name) profile")
                                .disabled(!appState.permissions.accessibility.hasPermission)
                            Button("Edit") { editedProfile = profile }
                                .accessibilityLabel("Edit \(profile.name) profile")
                            Button(role: .destructive) { Task { await manager.delete(profile) } } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete \(profile.name) profile")
                        }
                    }
                }
            }
            .disabled(operationsBusy)

            Section("Create Menu Bar Layout") {
                // Do not disable the first-responder text field as part of an
                // asynchronous capture's environment transition.
                TextField("Layout name", text: $profileName)
                HStack {
                    Button("Capture Current Layout") {
                        captureSubmission.submit(
                            name: profileName,
                            whenAllowed: !manager.isBusy && appState.permissions.accessibility.hasPermission
                        ) { capturedName in
                            await manager.captureCurrentProfile(named: capturedName)
                        }
                    }
                    .disabled(operationsBusy)
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .disabled(!appState.permissions.accessibility.hasPermission)
                }
                if !appState.permissions.accessibility.hasPermission {
                    Text("Profile management remains available, but capturing or applying menu bar layouts requires Accessibility.")
                        .foregroundStyle(.secondary)
                }
            }

            displayLayoutsSection
                .disabled(operationsBusy)

            ContextualRulesSection(manager: appState.contextualRules, profiles: manager.profiles)
                .disabled(operationsBusy)

            Section("Import and Export") {
                HStack {
                    Button("Import from Ice…") {
                        Task { await manager.discoverIceImports() }
                    }
                    .disabled(!appState.permissions.accessibility.hasPermission)
                    Button("Import Layout Archive…") {
                        archiveSelectionNotice = nil
                        showsArchiveImporter = true
                    }
                    Button("Export All Layouts…") {
                        Task {
                            guard let data = await manager.archiveData() else { return }
                            exportDocument = ProfileArchiveDocument(data: data)
                            showsArchiveExporter = true
                        }
                    }
                    .disabled(manager.profiles.isEmpty)
                }
                Text("Imports are validated and previewed before anything is saved. Existing profiles are never replaced without explicit approval.")
                    .foregroundStyle(.secondary)
            }
            .disabled(operationsBusy)

            if !manager.pendingIceImports.isEmpty {
                Section("Ice Import Preview") {
                    ForEach(manager.pendingIceImports, id: \.source) { preview in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(preview.profile.name, systemImage: "snowflake")
                                .font(.headline)
                            Text("Imports \(preview.importedComponents.count) supported setting groups from \(preview.source.displayName).")
                            if !preview.warnings.isEmpty {
                                Text("\(preview.warnings.count) unsupported or ambiguous setting\(preview.warnings.count == 1 ? "" : "s") will require manual review.")
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Import") {
                                    Task { await manager.commitIceImport(preview, replacingExisting: false) }
                                }
                                if manager.profiles.contains(where: { $0.id == preview.profile.id }) {
                                    Button("Replace Existing", role: .destructive) {
                                        Task { await manager.commitIceImport(preview, replacingExisting: true) }
                                    }
                                }
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) { manager.cancelIceImports() }
                }
                .disabled(operationsBusy)
            }

            if let preview = manager.pendingArchiveImport {
                Section("Import Preview") {
                    Text(preview.summary)
                    ForEach(preview.profiles) { profile in
                        HStack {
                            Label(profile.name, systemImage: profile.symbol ?? "menubar.rectangle")
                            Spacer()
                            if preview.conflictingProfileIDs.contains(profile.id) {
                                Text("Existing profile")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    HStack {
                        Button("Cancel", role: .cancel) {
                            manager.cancelArchiveImport()
                        }
                        Spacer()
                        if preview.hasConflicts {
                            Button("Import New Only") {
                                Task { await manager.commitArchiveImport(replacingExisting: false) }
                            }
                            Button("Replace Existing and Import", role: .destructive) {
                                Task { await manager.commitArchiveImport(replacingExisting: true) }
                            }
                        } else {
                            Button("Import Layouts") {
                                Task { await manager.commitArchiveImport(replacingExisting: false) }
                            }
                        }
                    }
                }
                .disabled(operationsBusy)
            }

            Section("Recovery") {
                TemporaryItemRecoveryView(manager: appState.itemManager)
                if let token = manager.archivedFocusRecoveryToken {
                    Text("A previous partial recovery checkpoint is kept for manual recovery. It is not an active Focus. Discard it only if you no longer need the original arrangement; a new partial recovery will not overwrite it.")
                        .foregroundStyle(.secondary)
                    Button("Discard Archived Checkpoint…") {
                        archivedRecoveryToken = token
                        showsArchiveRemovalConfirmation = true
                    }
                    .accessibilityIdentifier("discard-archived-focus-recovery")
                }
                if let token = manager.interruptedFocusRecoveryToken {
                    Text("A saved pre-Focus checkpoint is available for recovery. It may belong to an interrupted transaction or a previous partial recovery. Restore its layout and appearance only if you want to replace the current arrangement.")
                        .foregroundStyle(.secondary)
                    Button("Restore Pre-Focus Layout…") {
                        confirmedRecoveryToken = token
                        showsFocusRecoveryConfirmation = true
                    }
                    .disabled(!appState.permissions.accessibility.hasPermission)
                    .accessibilityIdentifier("restore-interrupted-focus-layout")
                    Button("Review Available-Item Recovery…") {
                        confirmedRecoveryToken = token
                        Task {
                            availableRecovery = await manager.previewAvailableFocusRecovery(confirmedToken: token)
                            showsAvailableRecoveryConfirmation = availableRecovery != nil
                        }
                    }
                    .disabled(!appState.permissions.accessibility.hasPermission)
                    .accessibilityIdentifier("preview-available-focus-recovery")
                }
                HStack {
                    Button("Undo Layout Change") {
                        guard !operationsBusy else { return }
                        Task {
                            guard !operationsBusy else { return }
                            await manager.undoLayoutChange()
                        }
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    Button("Redo Layout Change") {
                        guard !operationsBusy else { return }
                        Task {
                            guard !operationsBusy else { return }
                            await manager.redoLayoutChange()
                        }
                    }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    Button("Restore Last-Known-Good Layout") {
                        guard !operationsBusy else { return }
                        Task {
                            guard !operationsBusy else { return }
                            await manager.restoreLastKnownGoodLayout()
                        }
                    }
                }
                .disabled(!appState.permissions.accessibility.hasPermission)
                Text("Undo and redo keep a bounded in-memory layout history. Last-known-good restore does not delete profiles or reset unrelated settings.")
                    .foregroundStyle(.secondary)
            }
            .disabled(operationsBusy)

            if let statusMessage = manager.statusMessage {
                Section { Text(statusMessage).accessibilityIdentifier("profile-status") }
            }
            if let archiveSelectionNotice {
                Section { Text(archiveSelectionNotice) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore the pre-Focus layout?", isPresented: $showsFocusRecoveryConfirmation) {
            Button("Restore Pre-Focus Layout") {
                guard !operationsBusy, let token = confirmedRecoveryToken else { return }
                Task {
                    guard !operationsBusy else { return }
                    await manager.restoreInterruptedFocusLayout(confirmedToken: token)
                }
            }
            .disabled(operationsBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current menu bar arrangement and layout settings with the saved pre-Focus checkpoint. Saved layouts are not deleted. If restoration cannot be verified, the checkpoint is retained.")
        }
        .alert("Restore available items?", isPresented: $showsAvailableRecoveryConfirmation) {
            Button("Restore Available Items") {
                guard !operationsBusy, let token = confirmedRecoveryToken, let prepared = availableRecovery else { return }
                Task {
                    guard !operationsBusy else { return }
                    availableRecovery = nil
                    await manager.restoreAvailableFocusLayout(confirmedToken: token, prepared: prepared)
                }
            }
            .disabled(operationsBusy)
            Button("Cancel", role: .cancel) { availableRecovery = nil }
        } message: {
            Text("\(availableRecovery?.preview.missingItemIDs.count ?? 0) saved items are unavailable; \(availableRecovery?.preview.addedItemIDs.count ?? 0) new items will be preserved. This replaces the available items’ arrangement and layout settings. The original checkpoint stays available. Any change since this preview cancels recovery.")
        }
        .confirmationDialog("Discard the archived recovery checkpoint?", isPresented: $showsArchiveRemovalConfirmation) {
            Button("Discard Archived Checkpoint", role: .destructive) {
                guard !operationsBusy, let token = archivedRecoveryToken else { return }
                manager.discardArchivedFocusRecovery(confirmedToken: token)
            }
            .disabled(operationsBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes only the previous partial recovery checkpoint. The current arrangement, saved layouts, and any newer interrupted Focus transaction are preserved.")
        }
        .onChange(of: manager.profiles.map(\.id), initial: true) {
            guard focusLayout == nil else { return }
            focusLayoutID = manager.profiles.first { $0.id == manager.activeProfileID }?.id
                ?? manager.profiles.first?.id
        }
        .onChange(of: appState.navigationState.requestedProfileEditorID, initial: true) {
            guard let profileID = appState.navigationState.requestedProfileEditorID,
                  let profile = manager.profiles.first(where: { $0.id == profileID })
            else { return }
            editedProfile = profile
            appState.navigationState.requestedProfileEditorID = nil
        }
        .sheet(item: $editedProfile) { profile in
            ProfileEditorSheet(
                profile: profile,
                canResetFromWorkspace: appState.permissions.accessibility.hasPermission,
                canPerformOperations: !operationsBusy
            ) { name, symbol, groups, spacers, variants in
                guard !operationsBusy else { return false }
                return await manager.update(
                    profile,
                    name: name,
                    symbol: symbol,
                    groups: groups,
                    spacers: spacers,
                    displayOverrides: variants
                )
            } onReset: {
                guard !operationsBusy else { return false }
                return await manager.resetFromCurrentWorkspace(profile)
            } onCapture: { draft in
                guard !operationsBusy else {
                    throw MenuBarBackendError.operationFailed("another profile operation is in progress")
                }
                return try await appState.compatibilityCoordinator.captureDisplayVariant(profile: draft)
            }
        }
        .fileImporter(
            isPresented: $showsArchiveImporter,
            allowedContentTypes: [.barlineProfileArchive, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                guard !operationsBusy else {
                    archiveSelectionNotice = "Finish the current operation, then select the layout archive again."
                    return
                }
                Task {
                    guard !operationsBusy else {
                        archiveSelectionNotice = "Finish the current operation, then select the layout archive again."
                        return
                    }
                    await manager.previewArchiveImport(from: url)
                }
            case .failure:
                guard !operationsBusy else { return }
                manager.statusMessage = "No profile archive was selected."
            }
        }
        .fileExporter(
            isPresented: $showsArchiveExporter,
            document: exportDocument,
            contentType: .barlineProfileArchive,
            defaultFilename: "Barline Layouts.json"
        ) { result in
            exportDocument = nil
            guard !operationsBusy else { return }
            switch result {
            case .success:
                manager.statusMessage = "Profile archive exported."
            case .failure:
                manager.statusMessage = "The profile archive was not saved."
            }
        }
    }

    private var focusSetupSection: some View {
        Section("Use a Layout with macOS Focus") {
            Text("Focus modes stay in System Settings. Barline uses Apple's Focus Filters; it does not create or list your Focus modes.")
                .foregroundStyle(.secondary)

            FocusSetupStep(number: 1, title: "Choose a saved menu bar layout") {
                if manager.profiles.isEmpty {
                    Text("Arrange your menu bar, then use Capture Current Layout below. Give it a name you will recognize in Focus Settings.")
                } else {
                    Picker("Layout for setup", selection: $focusLayoutID) {
                        Text("Choose a layout").tag(UUID?.none)
                        ForEach(manager.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .accessibilityIdentifier("focus-setup-layout")
                    Text("This selection is a setup reference, not a Focus assignment.")
                        .font(.caption)
                }
            }

            FocusSetupStep(number: 2, title: "Open your Focus in System Settings") {
                Text("Choose the Focus you want to configure, then find Focus Filters and add a filter.")
                Link("Open Focus Settings", destination: Self.focusSettingsURL)
                    .accessibilityIdentifier("open-native-focus-settings")
            }

            FocusSetupStep(number: 3, title: "Add Barline's Menu Bar Layout filter") {
                if let focusLayout {
                    Text("Choose Barline, set Menu Bar Layout to “\(focusLayout.name)”, then save the filter in System Settings.")
                } else {
                    Text("Save and choose a layout in step 1 first. Then select that layout in Barline's Menu Bar Layout filter.")
                }
                Text("Repeat these steps inside each Focus you want to use with Barline.")
            }

            DisclosureGroup("Verify your setup") {
                Text("Turn that Focus on and check the menu bar layout. Turn it off and check that the previous workspace returns. If a change is blocked, review the status and Recovery sections below.")
                    .foregroundStyle(.secondary)
                Text("Barline cannot confirm the filter assignment from this screen. Opening Focus Settings or choosing a layout here does not complete the setup.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayLayoutsSection: some View {
        Section("Layouts for Different Displays") {
            Text("For a laptop and a desk setup, arrange each workspace and capture a separately named layout. Use Apply when you want to switch, or assign a saved layout through a native Focus Filter above.")
                .foregroundStyle(.secondary)
            Text("Connecting a display does not select a different saved layout. To capture a display-specific variant within a saved layout, choose Edit, then Capture Current Menu Bar Display. Review or remove variants there; changes are saved only when you click Save.")
                .foregroundStyle(.secondary)
            if let activeID = manager.activeProfileID,
               let activeProfile = manager.profiles.first(where: { $0.id == activeID }),
               let presentation = manager.activePresentation
            {
                LabeledContent("Current presentation") {
                    switch presentation.source {
                    case .base:
                        Text("\(activeProfile.name) · Base layout")
                    case .displayOverride:
                        Text("\(activeProfile.name) · Display variant")
                    }
                }
                Button("Review Active Layout…") { editedProfile = activeProfile }
            }
        }
    }
}

private struct FocusSetupStep<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number). \(title)")
                .font(.headline)
            content()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct TemporaryItemRecoveryView: View {
    @ObservedObject var manager: MenuBarItemManager
    @State private var confirmsCurrentPositions = false

    var body: some View {
        if manager.hasPendingRestorations {
            VStack(alignment: .leading, spacing: 8) {
                Text("An item was temporarily revealed. Restore it before applying another layout.")
                    .foregroundStyle(.secondary)
                Button("Retry Item Restoration") {
                    Task { await manager.retryPendingRestorations() }
                }
                .disabled(!manager.allowsPickerPresentation || manager.recoveryRecordsUnavailable)
                Button("Keep Current Item Positions…") { confirmsCurrentPositions = true }
                    .disabled(!manager.allowsPickerPresentation)
            }
            .alert("Keep current item positions?", isPresented: $confirmsCurrentPositions) {
                Button("Keep Positions", role: .destructive) {
                    Task { await manager.keepCurrentItemPositions() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cancels pending item restoration without moving any icons. Old recovery records are archived, not deleted.")
            }
        }
    }
}
