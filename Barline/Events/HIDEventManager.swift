//
//  HIDEventManager.swift
//  Barline
//

import BarlineCore
import Cocoa
import Combine
import OSLog

/// Manager that monitors input events and implements the features
/// that are triggered by them, such as showing hidden items on
/// click/hover/scroll.
@MainActor
final class HIDEventManager: ObservableObject {
    /// A Boolean value that indicates whether the user is dragging
    /// a menu bar item.
    @Published private(set) var isDraggingMenuBarItem = false

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// History of the manager's enabled states.
    private var enabledStateStack = [Bool]()
    private var mouseDownSequence: UInt64 = 0

    /// A Boolean value that indicates whether the manager is enabled.
    private var isEnabled = false {
        didSet {
            if isEnabled {
                for monitor in allMonitors {
                    monitor.start()
                }
            } else {
                for monitor in allMonitors {
                    monitor.stop()
                }
            }
        }
    }

    // MARK: Monitors

    /// Monitor for mouse down events.
    private(set) lazy var mouseDownMonitor = EventMonitor.universal(
        for: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
        guard let self, isEnabled, let appState, let screen = bestScreen(appState: appState) else {
            return event
        }
        mouseDownSequence &+= 1
        switch event.type {
        case .leftMouseDown:
            schedulePrimaryControlActionRecovery(
                with: event,
                appState: appState
            )
            handleShowOnClick(with: event, appState: appState, screen: screen)
            handleSmartRehide(with: event, appState: appState, screen: screen)
        case .rightMouseDown:
            handleSecondaryContextMenu(appState: appState, screen: screen)
        default:
            return event
        }
        handlePreventShowOnHover(with: event, appState: appState, screen: screen)
        return event
    }

    /// Monitor for mouse up events.
    private(set) lazy var mouseUpMonitor = EventMonitor.universal(
        for: .leftMouseUp
    ) { [weak self] event in
        guard let self, isEnabled, let appState else {
            return event
        }
        handleMenuBarItemDragStop(appState: appState)
        return event
    }

    /// Monitor for mouse dragged events.
    private(set) lazy var mouseDraggedMonitor = EventMonitor.universal(
        for: .leftMouseDragged
    ) { [weak self] event in
        if let self, isEnabled, let appState, let screen = bestScreen(appState: appState) {
            handleMenuBarItemDragStart(with: event, appState: appState, screen: screen)
        }
        return event
    }

    /// Tap for mouse moved events.
    private(set) lazy var mouseMovedTap = EventTap(
        type: .mouseMoved,
        location: .hidEventTap,
        placement: .tailAppendEventTap,
        option: .listenOnly
    ) { [weak self] _, event in
        if let self, isEnabled, let appState, let screen = bestScreen(appState: appState) {
            handleShowOnHover(appState: appState, screen: screen)
        }
        return event
    }

    /// Monitor for scroll wheel events.
    private(set) lazy var scrollWheelMonitor = EventMonitor.universal(
        for: .scrollWheel
    ) { [weak self] event in
        if let self, isEnabled, let appState, let screen = bestScreen(appState: appState) {
            handleShowOnScroll(with: event, appState: appState, screen: screen)
        }
        return event
    }

    // MARK: All Monitors

    /// All monitors maintained by the manager.
    private lazy var allMonitors: [any EventMonitorProtocol] = [
        mouseDownMonitor,
        mouseUpMonitor,
        mouseDraggedMonitor,
        mouseMovedTap,
        scrollWheelMonitor,
    ]

    // MARK: Setup

    /// Sets up the manager.
    func performSetup(with appState: AppState, startsEnabled: Bool = true) {
        self.appState = appState
        if startsEnabled {
            startAll()
        }
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState, let hiddenSection = appState.menuBarManager.section(withName: .hidden) {
            // In fullscreen mode, the menu bar slides down from the top on hover. Observe the
            // frame of the hidden section's control item, which we know will always be in the
            // menu bar, and run the show-on-hover check when it changes.
            Publishers.CombineLatest3(
                hiddenSection.controlItem.$frame,
                appState.$activeSpace.map(\.isFullscreen),
                appState.menuBarManager.$isMenuBarHiddenBySystem
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] _, isFullscreen, isMenuBarHiddenBySystem in
                guard let self, isEnabled, let appState, isFullscreen || isMenuBarHiddenBySystem else {
                    return
                }
                if let screen = bestScreen(appState: appState) {
                    handleShowOnHover(appState: appState, screen: screen)
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    // MARK: Start/Stop

    /// Starts all monitors.
    func startAll() {
        isEnabled = enabledStateStack.popLast() ?? true
    }

    /// Stops all monitors.
    func stopAll() {
        enabledStateStack.append(isEnabled)
        isEnabled = false
    }
}

// MARK: - Handler Methods

extension HIDEventManager {
    private func schedulePrimaryControlActionRecovery(
        with event: NSEvent,
        appState: AppState
    ) {
        guard
            let click = event.cgEvent,
            let control = appState.menuBarManager.controlItem(withName: .visible),
            control.containsEventLocation(click.unflippedLocation)
        else { return }

        control.schedulePrimaryActionRecovery(
            sequence: mouseDownSequence,
            eventTimestamp: event.timestamp,
            modifierFlags: event.modifierFlags
        )
    }

    // MARK: Handle Show On Click

    private func handleShowOnClick(with event: NSEvent, appState: AppState, screen: NSScreen) {
        // Local target-action owns a control-window click even if hosted
        // geometry or the global cursor snapshot is temporarily out of date.
        let targetsPrimaryControl = appState.menuBarManager.controlItem(withName: .visible)?
            .ownsEventWindow(event.window) == true
        guard
            appState.settings.general.showOnClick,
            let click = event.cgEvent,
            isMouseInsideEmptyMenuBarSpace(
                appState: appState,
                screen: screen,
                appKitLocation: click.unflippedLocation,
                coreGraphicsLocation: click.location,
                eventTargetsPrimaryControlItem: targetsPrimaryControl
            )
        else {
            return
        }

        let clickLocation = click.location
        let clickModifiers = event.modifierFlags
        let requestSequence = mouseDownSequence
        Task {
            // A cached gap is only a candidate. System status items may have
            // moved since the last snapshot; failed lookup is not empty-space proof.
            guard let context = try? await BarlineMenuService.Connection.shared.pointContext(at: clickLocation),
                  !context.isInsideMenuBarItem,
                  isEnabled,
                  appState.settings.general.showOnClick,
                  requestSequence == mouseDownSequence
            else { return }
            if clickModifiers == .control {
                handleSecondaryContextMenu(appState: appState, screen: screen)
                return
            }

            let targetSection: MenuBarSection

            if
                clickModifiers == .option,
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden),
                alwaysHiddenSection.isEnabled
            {
                targetSection = alwaysHiddenSection
            } else if
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                hiddenSection.isEnabled
            {
                targetSection = hiddenSection
            } else {
                return
            }

            Logger.default.notice("Empty-space click toggling section")
            targetSection.toggle()
        }
    }

    // MARK: Handle Smart Rehide

    private func handleSmartRehide(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.autoRehide,
            case .smart = appState.settings.general.rehideStrategy,
            let click = event.cgEvent
        else {
            return
        }

        let panel = appState.menuBarManager.barlineShelfPanel
        let control = appState.menuBarManager.controlItem(withName: .visible)
        guard MenuBarClickArbitrationPolicy.shouldScheduleSmartRehide(
            hasVisibleSection: appState.menuBarManager.hasVisibleSection,
            eventTargetsPrimaryControlItem: control?.ownsEventWindow(event.window) == true,
            isInsidePrimaryControlItem: control?.containsEventLocation(click.unflippedLocation) == true,
            isInsideShelf: event.window === panel || (panel.isVisible && panel.frame.contains(click.unflippedLocation)),
            isInsideMenuBar: isMouseInsideMenuBar(appState: appState, screen: screen, location: click.unflippedLocation)
        )
        else {
            return
        }

        // The event's position is immutable; the live pointer may have moved
        // by the time the asynchronous helper lookup completes.
        let clickLocation = click.location
        let lease = appState.menuBarManager.barlineShelfPanel.dismissalLease
        Logger.default.notice("Smart rehide scheduled for outside click")

        Task {
            guard let initialEnvironment = try? await BarlineMenuService.Connection.shared.environment() else {
                return
            }
            // Give the window under the mouse a chance to focus.
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            // Don't bother checking the window if the click caused
            // a space change.
            guard let currentEnvironment = try? await BarlineMenuService.Connection.shared.environment() else {
                return
            }
            if currentEnvironment.activeSpaceToken != initialEnvironment.activeSpaceToken {
                for section in appState.menuBarManager.sections {
                    section.hide(ifOwnedBy: lease, reason: .smartSpaceChange)
                }
                return
            }

            // Get the window that was clicked.
            guard
                let context = try? await BarlineMenuService.Connection.shared.pointContext(at: clickLocation),
                let bundleIdentifier = context.applicationBundleIdentifier
            else {
                return
            }

            // Note: The Dock is an exception to the following check.
            if bundleIdentifier != "com.apple.dock" {
                // Only continue if the clicked app is active, and has
                // a regular activation policy.
                guard
                    context.applicationIsActive,
                    context.applicationUsesRegularActivationPolicy
                else {
                    return
                }
            }

            // All checks have passed, hide the sections.
            for section in appState.menuBarManager.sections {
                section.hide(ifOwnedBy: lease, reason: .smartApplication)
            }
        }
    }

    // MARK: Handle Secondary Context Menu

    private func handleSecondaryContextMenu(appState: AppState, screen: NSScreen) {
        Task {
            guard
                appState.settings.advanced.enableSecondaryContextMenu,
                isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen),
                let mouseLocation = MouseHelpers.locationAppKit
            else {
                return
            }
            // Delay prevents the menu from immediately closing.
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            appState.menuBarManager.showSecondaryContextMenu(at: mouseLocation)
        }
    }

    // MARK: Handle Menu Bar Item Drag Stop

    private func handleMenuBarItemDragStop(appState: AppState) {
        guard isDraggingMenuBarItem else { return }
        isDraggingMenuBarItem = false
        Task {
            // AppKit publishes the final status-item frames just after mouse-up.
            // Capture that verified native arrangement once, then the collapsed
            // Golden Gate divider can reuse it without polling or flashing.
            try? await Task.sleep(for: .milliseconds(200))
            await appState.itemManager.cacheItemsRegardless(intent: .automatic)
        }
    }

    // MARK: Handle Menu Bar Item Drag Start

    private func handleMenuBarItemDragStart(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            !isDraggingMenuBarItem,
            event.modifierFlags.contains(.command),
            isMouseInsideMenuBar(appState: appState, screen: screen)
        else {
            return
        }

        isDraggingMenuBarItem = true

        if appState.settings.advanced.showAllSectionsOnUserDrag {
            for section in appState.menuBarManager.sections {
                section.controlItem.state = .showSection
            }
        }
    }

    // MARK: Handle Show On Hover

    private func handleShowOnHover(appState: AppState, screen: NSScreen) {
        // Make sure the "ShowOnHover" feature is enabled and allowed.
        guard
            appState.settings.general.showOnHover,
            appState.menuBarManager.showOnHoverAllowed
        else {
            return
        }

        // Only continue if we have a hidden section (we should).
        guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }

        let delay = appState.settings.advanced.showOnHoverDelay

        if hiddenSection.isHidden {
            guard isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen) else {
                return
            }
            Task {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                // Make sure the mouse is still inside.
                guard isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen) else {
                    return
                }
                hiddenSection.show()
            }
        } else {
            guard
                !isMouseInsideMenuBar(appState: appState, screen: screen),
                !isMouseInsideBarlineShelf(appState: appState)
            else {
                return
            }
            let lease = appState.menuBarManager.barlineShelfPanel.dismissalLease
            Task {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                // Make sure the mouse is still outside.
                guard
                    !isMouseInsideMenuBar(appState: appState, screen: screen),
                    !isMouseInsideBarlineShelf(appState: appState)
                else {
                    return
                }
                hiddenSection.hide(ifOwnedBy: lease, reason: .hover)
            }
        }
    }

    // MARK: Handle Prevent Show On Hover

    private func handlePreventShowOnHover(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnHover,
            !appState.settings.general.useBarlineShelf
        else {
            return
        }

        guard isMouseInsideMenuBar(appState: appState, screen: screen) else {
            return
        }

        if isMouseInsideMenuBarItem(appState: appState, screen: screen) {
            switch event.type {
            case .leftMouseDown:
                if appState.menuBarManager.hasVisibleSection {
                    break
                }
                if isMouseInsideBarlineIcon(appState: appState) {
                    break
                }
                return
            case .rightMouseDown:
                if appState.menuBarManager.hasVisibleSection {
                    break
                }
                return
            default:
                return
            }
        } else if isMouseInsideApplicationMenu(appState: appState, screen: screen) {
            return
        }

        // Mouse is inside the menu bar, outside an item or application
        // menu, so it must be inside an empty menu bar space.
        appState.menuBarManager.showOnHoverAllowed = false
    }

    // MARK: Handle Show On Scroll

    private func handleShowOnScroll(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnScroll,
            isMouseInsideMenuBar(appState: appState, screen: screen),
            let hiddenSection = appState.menuBarManager.section(withName: .hidden)
        else {
            return
        }

        let averageDelta = (event.scrollingDeltaX + event.scrollingDeltaY) / 2

        if averageDelta > 5 {
            hiddenSection.show()
        } else if averageDelta < -5 {
            hiddenSection.hide()
        }
    }
}

// MARK: - Helper Methods

extension HIDEventManager {
    /// Returns the best screen to use for event manager calculations.
    func bestScreen(appState: AppState) -> NSScreen? {
        guard
            appState.activeSpace.isFullscreen,
            let screen = NSScreen.screenWithMouse
        else {
            return NSScreen.main
        }
        return screen
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the menu bar.
    func isMouseInsideMenuBar(
        appState: AppState, screen: NSScreen, location: CGPoint? = MouseHelpers.locationAppKit
    ) -> Bool {
        // Barline icon must be vertically visible. Otherwise, we can infer
        // that the menu bar is hidden and the mouse is not inside.
        guard
            let barlineIcon = appState.menuBarManager.controlItem(withName: .visible),
            let barlineIconFrame = barlineIcon.frame,
            barlineIconFrame.maxY <= screen.frame.maxY,
            let mouseLocation = location
        else {
            return false
        }

        // Infer the menu bar frame from the screen frame.
        return mouseLocation.x >= screen.frame.minX &&
            mouseLocation.x <= screen.frame.maxX &&
            mouseLocation.y <= screen.frame.maxY &&
            mouseLocation.y >= screen.visibleFrame.maxY
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the current application menu.
    func isMouseInsideApplicationMenu(
        appState _: AppState, screen: NSScreen, location: CGPoint? = MouseHelpers.locationCoreGraphics
    ) -> Bool {
        guard
            let mouseLocation = location,
            var applicationMenuFrame = screen.getApplicationMenuFrame()
        else {
            return false
        }
        applicationMenuFrame.size.width += applicationMenuFrame.origin.x - screen.frame.origin.x
        applicationMenuFrame.origin.x = screen.frame.origin.x
        return applicationMenuFrame.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of a menu bar item.
    func isMouseInsideMenuBarItem(
        appState: AppState, screen _: NSScreen, location: CGPoint? = MouseHelpers.locationCoreGraphics
    ) -> Bool {
        guard let mouseLocation = location else {
            return false
        }
        return appState.itemManager.itemCache.hitTestItems.contains {
            $0.isOnScreen && $0.bounds.contains(mouseLocation)
        }
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the screen's notch, if it has one.
    ///
    /// If the screen does not have a notch, this property returns `false`.
    func isMouseInsideNotch(
        appState _: AppState, screen: NSScreen, location: CGPoint? = MouseHelpers.locationAppKit
    ) -> Bool {
        guard
            let mouseLocation = location,
            var frameOfNotch = screen.frameOfNotch
        else {
            return false
        }
        frameOfNotch.size.height += 1
        return frameOfNotch.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of an empty space in the menu bar.
    func isMouseInsideEmptyMenuBarSpace(
        appState: AppState,
        screen: NSScreen,
        appKitLocation: CGPoint? = MouseHelpers.locationAppKit,
        coreGraphicsLocation: CGPoint? = MouseHelpers.locationCoreGraphics,
        eventTargetsPrimaryControlItem: Bool = false
    ) -> Bool {
        MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
            isInsideMenuBar: isMouseInsideMenuBar(appState: appState, screen: screen, location: appKitLocation),
            isInsideApplicationMenu: isMouseInsideApplicationMenu(appState: appState, screen: screen, location: coreGraphicsLocation),
            // The compatibility cache can briefly omit Barline's own icon
            // while the helper reconnects after an update. Its live control
            // item frame remains authoritative and prevents the same click
            // from toggling once here and again through target-action.
            isInsidePrimaryControlItem: isMouseInsideBarlineIcon(appState: appState, location: appKitLocation),
            isInsideCachedMenuBarItem: isMouseInsideMenuBarItem(appState: appState, screen: screen, location: coreGraphicsLocation),
            isInsideNotch: isMouseInsideNotch(appState: appState, screen: screen, location: appKitLocation),
            eventTargetsPrimaryControlItem: eventTargetsPrimaryControlItem,
            hasHitTestSnapshot: !appState.itemManager.itemCache.hitTestItems.isEmpty
        )
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Barline Bar panel.
    func isMouseInsideBarlineShelf(appState: AppState) -> Bool {
        guard let mouseLocation = MouseHelpers.locationAppKit else {
            return false
        }
        let panel = appState.menuBarManager.barlineShelfPanel
        // Pad the frame to be more forgiving if the user accidentally
        // moves their mouse outside of the Barline Bar.
        let paddedFrame = panel.frame.insetBy(dx: -15, dy: -15)
        return paddedFrame.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Barline icon.
    func isMouseInsideBarlineIcon(
        appState: AppState, location: CGPoint? = MouseHelpers.locationAppKit
    ) -> Bool {
        guard
            let visibleSection = appState.menuBarManager.section(withName: .visible),
            let mouseLocation = location
        else {
            return false
        }
        return visibleSection.controlItem.containsEventLocation(mouseLocation)
    }
}

// MARK: - EventMonitor Helpers

/// Helper protocol to enable group operations across event
/// monitoring types.
@MainActor
private protocol EventMonitorProtocol {
    func start()
    func stop()
}

extension EventMonitor: EventMonitorProtocol {}

extension EventTap: EventMonitorProtocol {
    fileprivate func start() {
        enable()
    }

    fileprivate func stop() {
        disable()
    }
}
