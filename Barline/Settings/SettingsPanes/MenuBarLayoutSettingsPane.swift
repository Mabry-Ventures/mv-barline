//
//  MenuBarLayoutSettingsPane.swift
//  Barline
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager

    var body: some View {
        if !appState.permissions.accessibility.hasPermission {
            missingAccessibilityPermission
        } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermissions
        } else {
            BarlineForm(spacing: 20) {
                header
                layoutContent
            }
        }
    }

    private var missingAccessibilityPermission: some View {
        VStack(spacing: 10) {
            Text("Menu bar arrangement is unavailable in degraded mode.")
                .font(.title2)
            Text("Saved settings and profiles remain available without Accessibility.")
                .foregroundStyle(.secondary)
            Button("Enable Accessibility") {
                appState.permissions.accessibility.performRequest()
            }
        }
    }

    private var header: some View {
        BarlineSection {
            VStack(spacing: 3) {
                Text("Drag to arrange your menu bar items into different sections.")
                    .font(.title3.bold())
                Text("Items can also be arranged by ⌘ Command + dragging them in the menu bar.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(15)
        }
    }

    @ViewBuilder
    private var layoutContent: some View {
        switch itemManager.itemDiscoveryState {
        case .idle, .loading:
            loadingMenuBarItems
        case .ready:
            layoutBars
        case .empty:
            emptyMenuBarItems
        case .failed:
            failedMenuBarItems
        }
    }

    private var layoutBars: some View {
        VStack(spacing: 20) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                layoutBar(for: section)
            }
        }
    }

    private var cannotArrange: some View {
        VStack(spacing: 14) {
            Text("Your menu bar is set to automatically hide")
                .font(.title3.bold())
            Text("The Barline Bar and drag layout editor require an always-visible menu bar. Your saved layouts are unchanged.")
                .foregroundStyle(.secondary)
            Text("You can still show hidden items in the macOS menu bar. Move the pointer to the top of the screen, then use the items normally or ⌘ Command-drag to arrange them.")
                .foregroundStyle(.secondary)
            Button("Show Hidden Items in Menu Bar") {
                appState.menuBarManager.section(withName: .hidden)?.showInMenuBar()
            }
            Button("Open Menu Bar System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 540)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var missingScreenRecordingPermissions: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions.")
                .font(.title2)

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            } label: {
                Text("Go to Advanced Settings")
            }
            .buttonStyle(.link)
        }
    }

    private var loadingMenuBarItems: some View {
        VStack(spacing: 10) {
            Text("Loading menu bar items…")
            ProgressView()
        }
        .font(.title)
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityIdentifier("Barline.Layout.Loading")
    }

    private var emptyMenuBarItems: some View {
        VStack(spacing: 10) {
            Text("No menu bar items found")
                .font(.title2.bold())
            Text("Barline found its controls, but there are no items available to arrange.")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityIdentifier("Barline.Layout.Empty")
    }

    private var failedMenuBarItems: some View {
        VStack(spacing: 12) {
            Text("Menu bar items could not be loaded")
                .font(.title2.bold())
            Text("Your existing layout is unchanged. Try loading the menu bar again.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Try Again") {
                    Task {
                        await itemManager.cacheItemsRegardless()
                    }
                }
                Button("Open Diagnostics") {
                    appState.navigationState.settingsNavigationIdentifier = .advanced
                }
                .buttonStyle(.link)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityIdentifier("Barline.Layout.LoadFailed")
    }

    @ViewBuilder
    private func layoutBar(for name: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: name),
            section.isEnabled
        {
            VStack(alignment: .leading) {
                Text(name.localized)
                    .font(.headline)
                    .padding(.leading, 8)

                LayoutBar(imageCache: appState.imageCache, section: name)
            }
        }
    }
}
