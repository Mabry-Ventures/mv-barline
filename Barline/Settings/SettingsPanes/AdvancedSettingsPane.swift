//
//  AdvancedSettingsPane.swift
//  Barline
//

import AppKit
import BarlineCore
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings: AdvancedSettings
    @State private var maxSliderLabelWidth: CGFloat = 0
    @State private var supportBundlePreview: SupportBundlePreview?
    @State private var supportBundleStatus: String?
    @State private var showsSupportBundleReview = false

    private var menuBarManager: MenuBarManager {
        appState.menuBarManager
    }

    private func formattedToSeconds(_ interval: TimeInterval) -> LocalizedStringKey {
        let formatted = interval.formatted()
        return if interval == 1 {
            LocalizedStringKey(formatted + " second")
        } else {
            LocalizedStringKey(formatted + " seconds")
        }
    }

    var body: some View {
        BarlineForm {
            BarlineSection("Menu Bar Sections") {
                enableAlwaysHiddenSection
                showAllSectionsOnUserDrag
                sectionDividerStyle
            }
            BarlineSection("Other") {
                hideApplicationMenus
                enableSecondaryContextMenu
                showOnHoverDelay
                tempShowInterval
            }
            BarlineSection("Permissions") {
                allPermissions
            }
            BarlineSection("Diagnostics") {
                supportBundleControls
            }
        }
        .alert(
            "Review Support Bundle",
            isPresented: $showsSupportBundleReview,
            presenting: supportBundlePreview
        ) { preview in
            Button("Cancel", role: .cancel) {}
            Button("Choose Save Location") {
                chooseSupportBundleDestination(for: preview)
            }
        } message: { preview in
            Text("This JSON contains only \(preview.summary). Review the file before sharing it.")
        }
    }

    private var enableAlwaysHiddenSection: some View {
        Toggle(
            "Enable the always-hidden section",
            isOn: $settings.enableAlwaysHiddenSection
        )
    }

    private var showAllSectionsOnUserDrag: some View {
        Toggle(
            "Show all sections when ⌘ Command + dragging menu bar items",
            isOn: $settings.showAllSectionsOnUserDrag
        )
    }

    private var sectionDividerStyle: some View {
        BarlinePicker("Section divider style", selection: $settings.sectionDividerStyle) {
            ForEach(SectionDividerStyle.allCases) { style in
                Text(style.localized).tag(style)
            }
        }
    }

    private var hideApplicationMenus: some View {
        Toggle(
            "Hide app menus when showing menu bar items",
            isOn: $settings.hideApplicationMenus
        )
        .disabled(appState.settings.general.hideDockIcon)
        .annotation {
            Text(
                appState.settings.general.hideDockIcon
                    ? "Hide Dock icon is enabled, so Barline will not take over the app-menu area."
                    : """
                    Make more room in the menu bar by hiding the current app menus if \
                    needed. macOS requires Barline to make itself visible in the Dock while \
                    this setting is in effect.
                    """
            )
            .padding(.trailing, 75)
        }
    }

    private var enableSecondaryContextMenu: some View {
        Toggle(
            "Enable secondary context menu",
            isOn: $settings.enableSecondaryContextMenu
        )
        .annotation {
            Text(
                """
                Right-click in an empty area of the menu bar to display a minimal \
                version of Barline's menu. Disable this setting if you encounter conflicts \
                with other apps.
                """
            )
            .padding(.trailing, 75)
        }
    }

    private var showOnHoverDelay: some View {
        LabeledContent {
            BarlineSlider(
                formattedToSeconds(settings.showOnHoverDelay),
                value: $settings.showOnHoverDelay,
                in: 0 ... 1,
                step: 0.1
            )
        } label: {
            Text("Show on hover delay")
                .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                .onFrameChange { frame in
                    maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                }
        }
        .annotation("The amount of time to wait before showing on hover.")
    }

    private var tempShowInterval: some View {
        LabeledContent {
            BarlineSlider(
                formattedToSeconds(settings.tempShowInterval),
                value: $settings.tempShowInterval,
                in: 0 ... 60,
                step: 1
            )
        } label: {
            Text("Temporarily shown item delay")
                .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                .onFrameChange { frame in
                    maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                }
        }
        .annotation("The amount of time to wait before hiding temporarily shown menu bar items.")
    }

    private var allPermissions: some View {
        ForEach(appState.permissions.allPermissions) { permission in
            LabeledContent {
                if permission.hasPermission {
                    Label {
                        Text("Permission Granted")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                } else {
                    Button("Grant Permission") {
                        permission.performRequest()
                    }
                }
            } label: {
                Text(permission.title)
            }
            .frame(height: 22)
        }
    }

    @ViewBuilder
    private var supportBundleControls: some View {
        LabeledContent {
            Button("Create Support Bundle") {
                prepareSupportBundle()
            }
        } label: {
            Text("Privacy-bounded diagnostics")
        }
        .annotation("Creates a local JSON preview with no paths, item names, screenshots, process list, or logs.")

        if let supportBundleStatus {
            Text(supportBundleStatus)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("support-bundle-status")
        }
    }

    private func prepareSupportBundle() {
        supportBundleStatus = "Preparing preview…"
        Task {
            do {
                let health = await appState.compatibilityCoordinator.backendHealth
                let snapshot = await appState.compatibilityCoordinator.currentSnapshot
                let capabilities = await (try? BarlineMenuService.Connection.shared.capabilities()) ?? .fallback
                let preview = try await SupportBundleExporter().preview(
                    permissions: .init(
                        accessibility: appState.permissions.accessibility.hasPermission,
                        screenRecording: appState.permissions.screenRecording.hasPermission
                    ),
                    compatibility: health,
                    capabilities: capabilities,
                    itemDiscovery: appState.itemManager.itemDiscoveryDiagnostics,
                    lastSnapshotAt: snapshot?.capturedAt,
                    lastSnapshotRejectionCode: nil,
                    searchAvailabilityCode: Self.searchAvailabilityCode(),
                    recentErrorCodes: [appState.profileManager.lastOperationErrorCode].compactMap(\.self)
                )
                supportBundlePreview = preview
                supportBundleStatus = "Preview ready. Choose whether to save it."
                showsSupportBundleReview = true
            } catch {
                supportBundleStatus = "The support bundle preview could not be created."
            }
        }
    }

    private func chooseSupportBundleDestination(for preview: SupportBundlePreview) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = preview.suggestedFilename
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            do {
                try await SupportBundleExporter().write(preview, to: destination)
                supportBundleStatus = "Support bundle saved. Review it before sharing."
            } catch {
                supportBundleStatus = "The support bundle could not be saved."
            }
        }
    }

    private static func searchAvailabilityCode() -> String {
        switch SearchRuntimeAvailability.current().coreSpotlight {
        case .available:
            "core_spotlight_available"
        case let .unavailable(reason):
            "core_spotlight_\(reason.rawValue)"
        }
    }
}
