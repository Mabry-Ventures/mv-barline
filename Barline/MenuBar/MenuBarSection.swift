//
//  MenuBarSection.swift
//  Barline
//

import BarlineCore
import OSLog
import SwiftUI

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    enum Name: CaseIterable {
        case visible
        case hidden
        case alwaysHidden

        /// A string to show in the interface.
        var displayString: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            case .alwaysHidden: "Always-Hidden"
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .visible: "visible section"
            case .hidden: "hidden section"
            case .alwaysHidden: "always-hidden section"
            }
        }

        /// Localized string key representation.
        var localized: LocalizedStringKey {
            LocalizedStringKey(displayString)
        }
    }

    /// The name of the section.
    let name: Name

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// A timer that manages rehiding the section.
    private var rehideTimer: Timer?

    /// An event monitor that handles starting the rehide timer when the mouse
    /// is outside of the menu bar.
    private var rehideMonitor: EventMonitor?

    /// A Boolean value that indicates whether the Barline Bar should be used.
    private var useBarlineShelf: Bool {
        guard let appState else { return false }
        // The shelf cannot reliably position/capture against an auto-hidden
        // system bar. Keep the preference, but use native section reveal in
        // this configuration so existing hidden items remain accessible.
        return MenuBarPresentationPolicy.usesShelf(
            requestedShelf: appState.settings.general.useBarlineShelf,
            systemAutoHideEnabled: appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults
        )
    }

    /// A weak reference to the menu bar manager.
    private weak var menuBarManager: MenuBarManager? {
        appState?.menuBarManager
    }

    /// The best screen to show the Barline Bar on.
    private weak var screenForBarlineShelf: NSScreen? {
        guard let appState else {
            return nil
        }
        if appState.activeSpace.isFullscreen {
            return NSScreen.screenWithMouse ?? NSScreen.main
        } else {
            return NSScreen.screenWithActiveMenuBar ?? NSScreen.main ?? NSScreen.screenWithMouse
        }
    }

    /// A Boolean value that indicates whether the section is hidden.
    var isHidden: Bool {
        if useBarlineShelf {
            if controlItem.state == .showSection {
                return false
            }
            switch name {
            case .visible, .hidden:
                return menuBarManager?.barlineShelfPanel.currentSection != .hidden
            case .alwaysHidden:
                return menuBarManager?.barlineShelfPanel.currentSection != .alwaysHidden
            }
        }
        switch name {
        case .visible, .hidden:
            if menuBarManager?.barlineShelfPanel.currentSection == .hidden {
                return false
            }
            return controlItem.state == .hideSection
        case .alwaysHidden:
            if menuBarManager?.barlineShelfPanel.currentSection == .alwaysHidden {
                return false
            }
            return controlItem.state == .hideSection
        }
    }

    /// A Boolean value that indicates whether the section is enabled.
    var isEnabled: Bool {
        MenuBarSectionAvailabilityPolicy.isEnabled(
            isPrimarySection: name == .visible,
            controlItemIsAdded: controlItem.isAddedToMenuBar
        )
    }

    /// The hotkey to toggle the section.
    var hotkey: Hotkey? {
        guard let hotkeys = appState?.settings.hotkeys else {
            return nil
        }
        return switch name {
        case .visible: nil
        case .hidden: hotkeys.hotkey(withAction: .toggleHiddenSection)
        case .alwaysHidden: hotkeys.hotkey(withAction: .toggleAlwaysHiddenSection)
        }
    }

    /// Creates a section with the given name and control item.
    init(name: Name, controlItem: ControlItem) {
        self.name = name
        self.controlItem = controlItem
    }

    /// Creates a section with the given name.
    convenience init(name: Name) {
        let controlItem = switch name {
        case .visible:
            ControlItem(identifier: .visible)
        case .hidden:
            ControlItem(identifier: .hidden)
        case .alwaysHidden:
            ControlItem(identifier: .alwaysHidden)
        }
        self.init(name: name, controlItem: controlItem)
    }

    /// Performs the initial setup of the section.
    func performSetup(with appState: AppState) {
        self.appState = appState
        controlItem.performSetup(with: appState)
    }

    /// Shows the section.
    func show(useShelf: Bool? = nil, keyboardFocus: Bool = false) {
        guard appState?.itemManager.allowsPickerPresentation == true else {
            Logger.default.notice("Shelf show rejected: item interaction is busy")
            return
        }
        menuBarManager?.refreshSystemMenuBarConfiguration()
        guard let menuBarManager, isHidden else {
            Logger.default.notice("Shelf show rejected: section is already visible or unavailable")
            return
        }

        guard isEnabled else {
            // The section is disabled.
            Logger.default.notice("Shelf show rejected: section is disabled")
            return
        }

        let willUseShelf = MenuBarPresentationPolicy.usesShelf(
            requestedShelf: useShelf ?? useBarlineShelf,
            systemAutoHideEnabled: menuBarManager.isMenuBarHiddenBySystemUserDefaults
        )
        Logger.default.notice(
            "Shelf show decision useShelf=\(willUseShelf, privacy: .public) systemAutoHide=\(menuBarManager.isMenuBarHiddenBySystemUserDefaults, privacy: .public)"
        )

        if willUseShelf {
            guard let screen = screenForBarlineShelf else {
                Logger.default.error("Shelf show rejected: no active screen")
                return
            }

            // Make sure hidden and always-hidden control items are collapsed.
            // Still update the visible control item (Barline icon) state to show
            // its alternate icon.
            for section in menuBarManager.sections {
                switch section.name {
                case .visible:
                    section.controlItem.state = .showSection
                case .hidden, .alwaysHidden:
                    section.controlItem.state = .hideSection
                }
            }

            let panel = menuBarManager.barlineShelfPanel
            let section: Name = switch name {
            case .visible, .hidden:
                .hidden
            case .alwaysHidden:
                .alwaysHidden
            }

            guard let presentation = panel.beginPresentation(for: section) else {
                Logger.default.error("Shelf show rejected: panel could not begin presentation")
                return
            }

            Task {
                let didShow = await panel.show(presentation, on: screen)
                if didShow {
                    appState?.itemManager.scheduleGoldenGateConcealmentSync()
                    if keyboardFocus {
                        panel.focusItemsForKeyboard()
                    }
                    startRehideChecks()
                } else {
                    Logger.default.error("Shelf show rejected: panel did not commit presentation")
                }
            }

            return // We're done.
        }

        // If we made it here, we're not using the Barline Bar.
        // Make sure it's closed.
        menuBarManager.barlineShelfPanel.close()

        switch name {
        case .visible, .hidden:
            for section in menuBarManager.sections where section.name != .alwaysHidden {
                section.controlItem.state = .showSection
            }
        case .alwaysHidden:
            for section in menuBarManager.sections {
                section.controlItem.state = .showSection
            }
        }

        startRehideChecks()
        appState?.itemManager.scheduleGoldenGateConcealmentSync()
    }

    /// User-selected recovery route that does not change the saved shelf or
    /// macOS auto-hide preference. macOS still owns showing the system bar.
    func showInMenuBar() {
        hide()
        show(useShelf: false)
    }

    enum DeferredHideReason: String {
        case smartSpaceChange, smartApplication, hover, timer, focusedApplication
    }

    /// Hides only the presentation that originally scheduled this work.
    func hide(ifOwnedBy lease: PresentationEpoch.Lease, reason: DeferredHideReason) {
        let ownsPresentation = menuBarManager?.barlineShelfPanel.ownsDismissal(lease) == true
        Logger.default.notice("Deferred rehide evaluated reason=\(reason.rawValue, privacy: .public) ownsPresentation=\(ownsPresentation, privacy: .public)")
        guard ownsPresentation else {
            return
        }
        hide()
    }

    /// Hides the section immediately in response to current user intent.
    func hide() {
        guard let menuBarManager, !isHidden else {
            return
        }

        menuBarManager.barlineShelfPanel.close() // Make sure Barline Bar is always closed.
        menuBarManager.showOnHoverAllowed = true

        switch name {
        case _ where useBarlineShelf, .visible, .hidden:
            for section in menuBarManager.sections {
                section.controlItem.state = .hideSection
            }
        case .alwaysHidden:
            controlItem.state = .hideSection
        }

        stopRehideChecks()
        appState?.itemManager.scheduleGoldenGateConcealmentSync()
    }

    /// Toggles the visibility of the section.
    func toggle(keyboardFocus: Bool = false) {
        if isHidden {
            show(keyboardFocus: keyboardFocus)
        } else {
            hide()
        }
    }

    /// Starts running checks to determine when to rehide the section.
    private func startRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()

        guard
            let appState,
            appState.settings.general.autoRehide,
            case .timed = appState.settings.general.rehideStrategy
        else {
            return
        }

        rehideMonitor = EventMonitor.universal(for: .mouseMoved) { [weak self] event in
            guard
                let self,
                let screen = NSScreen.main
            else {
                return event
            }
            if NSEvent.mouseLocation.y < screen.visibleFrame.maxY {
                if rehideTimer == nil {
                    let lease = appState.menuBarManager.barlineShelfPanel.dismissalLease
                    rehideTimer = .scheduledTimer(
                        withTimeInterval: appState.settings.general.rehideInterval,
                        repeats: false
                    ) { [weak self] _ in
                        guard
                            let self,
                            let screen = NSScreen.main
                        else {
                            return
                        }
                        if NSEvent.mouseLocation.y < screen.visibleFrame.maxY {
                            Task {
                                await self.hide(ifOwnedBy: lease, reason: .timer)
                            }
                        } else {
                            Task {
                                await self.startRehideChecks()
                            }
                        }
                    }
                }
            } else {
                rehideTimer?.invalidate()
                rehideTimer = nil
            }
            return event
        }

        rehideMonitor?.start()
    }

    /// Stops running checks to determine when to rehide the section.
    private func stopRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()
        rehideTimer = nil
        rehideMonitor = nil
    }
}
