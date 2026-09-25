//
//  ControlItem.swift
//  Barline
//

import BarlineCore
import Cocoa
import Combine
import OSLog

// MARK: - ControlItem

/// A status item that controls a section in the menu bar.
@MainActor
final class ControlItem {
    /// An identifier for a control item.
    enum Identifier: String, CaseIterable {
        /// The identifier for the control item for the visible section.
        case visible = "Barline.ControlItem.Visible"
        /// The identifier for the control item for the hidden section.
        case hidden = "Barline.ControlItem.Hidden"
        /// The identifier for the control item for the always-hidden section.
        case alwaysHidden = "Barline.ControlItem.AlwaysHidden"

        /// A tag for the control item with this identifier.
        var tag: MenuBarItemTag {
            switch self {
            case .visible: .visibleControlItem
            case .hidden: .hiddenControlItem
            case .alwaysHidden: .alwaysHiddenControlItem
            }
        }

        /// Returns the length associated with this identifier and
        /// the given hiding state.
        func length(for state: HidingState) -> CGFloat {
            switch self {
            case .visible:
                Lengths.standard
            case .hidden, .alwaysHidden:
                switch state {
                case .showSection: Lengths.standard
                case .hideSection: Lengths.expanded
                }
            }
        }
    }

    /// A hiding state for a control item.
    enum HidingState {
        case showSection
        case hideSection
    }

    /// A namespace for control item lengths.
    private enum Lengths {
        static let standard: CGFloat = NSStatusItem.variableLength
        static let expanded: CGFloat = 10000
    }

    /// Storage for a control item's underlying status item.
    private final class StatusItemStorage {
        let statusItem: NSStatusItem
        let constraint: NSLayoutConstraint?

        /// Creates a new storage instance.
        @MainActor
        init(controlItem: ControlItem) {
            ControlItemDefaults.preflightSetup(for: controlItem)

            statusItem = NSStatusBar.system.statusItem(withLength: 0)
            statusItem.autosaveName = controlItem.identifier.rawValue

            if let button = statusItem.button {
                // This could break in a new macOS release, but we need this constraint in order to
                // be able to hide the status item when the `ShowSectionDividers` setting is disabled.
                // A previous implementation used `statusItem.isVisible`, which was more robust, but
                // would completely remove the status item. With the current set of features, we use
                // the control item positions to determine the items in each section, so we need the
                // status item to be present if its section is enabled. The new solution is to remove
                // a constraint from the item's content view prevents it from having a length of zero.
                // Then, we set the length. FIXME: Find a replacement for this.
                if
                    let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal),
                    let constraint = constraints.first(where: Predicates.controlItemConstraint(button: button))
                {
                    assert(constraints.filter(Predicates.controlItemConstraint(button: button)).count == 1)
                    self.constraint = constraint
                } else {
                    constraint = nil
                }

                controlItem.configureAction(for: button)
            } else {
                constraint = nil
            }
        }

        deinit {
            removeStatusItem()
        }

        /// Removes the status item from the status bar.
        private func removeStatusItem() {
            // Removing the status item has the unwanted side effect of
            // deleting the preferred position. Cache and restore it.
            let autosaveName = statusItem.autosaveName as String
            let cached = ControlItemDefaults[.preferredPosition, autosaveName]
            NSStatusBar.system.removeStatusItem(statusItem)
            ControlItemDefaults[.preferredPosition, autosaveName] = cached
        }
    }

    /// The control item's hiding state (`@Published`).
    @Published var state = HidingState.hideSection

    /// The control item's window (`@Published`).
    @Published private(set) var window: NSWindow?

    /// The control item's frame (`@Published`).
    @Published private(set) var frame: CGRect?

    /// The control item's screen (`@Published`).
    @Published private(set) var screen: NSScreen?

    /// The control item's frame, if it is onscreen (`@Published`).
    @Published private(set) var onScreenFrame: CGRect?

    /// The control item's identifier.
    let identifier: Identifier

    /// Lazy storage for the control item's underlying status item.
    private lazy var storage = StatusItemStorage(controlItem: self)

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Privacy-safe lifecycle diagnostics for status-item action delivery.
    private let logger = Logger(category: "ControlItem")

    /// Coordinates native target/action delivery with the bounded mouse-down
    /// fallback used while a scene-backed status item reconnects.
    private var actionRecoveryCoordinator = StatusItemActionRecoveryCoordinator()
    private var actionRecoveryTask: Task<Void, Never>?

    /// The control item's underlying status item.
    private var statusItem: NSStatusItem {
        storage.statusItem
    }

    /// A horizontal constraint for the control item's content view.
    private var constraint: NSLayoutConstraint? {
        storage.constraint
    }

    /// A Boolean value that indicates whether the control item serves as
    /// a divider between sections.
    var isSectionDivider: Bool {
        identifier != .visible
    }

    /// A Boolean value that indicates whether the control item is currently
    /// displayed in the menu bar.
    var isAddedToMenuBar: Bool {
        statusItem.isVisible
    }

    /// The corresponding section name for the control item.
    var sectionName: MenuBarSection.Name {
        switch identifier {
        case .visible: .visible
        case .hidden: .hidden
        case .alwaysHidden: .alwaysHidden
        }
    }

    /// Creates a control item with the given identifier.
    init(identifier: Identifier) {
        self.identifier = identifier
    }

    /// Performs the initial setup of the control item.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
    }

    /// Configures the internal observers for the control item.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &c)

        statusItem.publisher(for: \.isVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard
                    let self,
                    let menuBarManager = appState?.menuBarManager,
                    let section = menuBarManager.section(withName: sectionName),
                    let hotkey = section.hotkey
                else {
                    return
                }
                if isVisible {
                    hotkey.enable()
                } else {
                    hotkey.disable()
                }
            }
            .store(in: &c)

        statusItem.publisher(for: \.button)
            .handleEvents(receiveOutput: { [weak self] button in
                if let button {
                    self?.configureAction(for: button)
                }
            })
            .removeDuplicates()
            .latestOptionalValue(on: DispatchQueue.main) { $0.publisher(for: \.window).eraseToAnyPublisher() }
            .sink { [weak self] window in
                self?.window = window
            }
            .store(in: &c)

        $window.removeDuplicates()
            .latestOptionalValue(on: DispatchQueue.main) { $0.publisher(for: \.frame).map(Optional.some).eraseToAnyPublisher() }
            .removeDuplicates()
            .sink { [weak self] frame in
                self?.frame = frame
            }
            .store(in: &c)

        $window.removeDuplicates()
            .latestOptionalValue(on: DispatchQueue.main) { $0.publisher(for: \.screen).eraseToAnyPublisher() }
            .sink { [weak self] screen in
                self?.screen = screen
            }
            .store(in: &c)

        $screen.removeDuplicates()
            .latestOptionalValue(on: DispatchQueue.main) { $0.publisher(for: \.frame).map(Optional.some).eraseToAnyPublisher() }
            .combineLatest($frame)
            .removeDuplicates()
            .sink { [weak self] screenFrame, frame in
                guard let self else {
                    return
                }
                if let screenFrame, let frame, screenFrame.intersects(frame) {
                    onScreenFrame = frame
                } else {
                    onScreenFrame = nil
                }
            }
            .store(in: &c)

        if let appState {
            appState.$isDraggingMenuBarItem
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isDragging in
                    guard let self else {
                        return
                    }
                    if isDragging {
                        updateStatusItem()
                    }
                }
                .store(in: &c)

            if identifier == .visible {
                appState.settings.general.$showBarlineIcon
                    .combineLatest(statusItem.publisher(for: \.isVisible))
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] shouldShow, _ in
                        guard let self else {
                            return
                        }
                        if shouldShow {
                            addToMenuBar()
                        } else {
                            removeFromMenuBar()
                        }
                    }
                    .store(in: &c)

                appState.settings.general.$barlineIcon
                    .combineLatest(appState.settings.general.$customBarlineIconIsTemplate)
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        self?.updateStatusItem()
                    }
                    .store(in: &c)
            }

            if identifier == .alwaysHidden {
                appState.settings.advanced.$enableAlwaysHiddenSection
                    .combineLatest(statusItem.publisher(for: \.isVisible))
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] shouldEnable, _ in
                        guard let self else {
                            return
                        }
                        if shouldEnable {
                            addToMenuBar()
                        } else {
                            removeFromMenuBar()
                        }
                    }
                    .store(in: &c)
            }

            if isSectionDivider {
                appState.settings.advanced.$sectionDividerStyle
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        self?.updateStatusItem()
                    }
                    .store(in: &c)
            }
        }

        cancellables = c
    }

    /// Configures the click behavior for the status item's current button.
    ///
    /// AppKit can replace the button while reconnecting a scene-backed status
    /// item after an app update. Reapply the action whenever that happens so
    /// the replacement does not retain a stale/default event mask.
    private func configureAction(for button: NSStatusBarButton) {
        button.setAccessibilityIdentifier(identifier.rawValue)
        button.target = self
        button.action = #selector(performAction)
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
    }

    /// Schedules a one-shot fallback for a primary click whose hosted status
    /// window exists but whose AppKit target/action connection may not yet be live.
    func schedulePrimaryActionRecovery(
        sequence: UInt64,
        eventTimestamp: TimeInterval,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard identifier == .visible,
              actionRecoveryCoordinator.observeMouseDown(
                  sequence: sequence,
                  eventTimestamp: eventTimestamp
              )
        else { return }

        actionRecoveryTask?.cancel()
        actionRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self,
                  actionRecoveryCoordinator.claimFallback(sequence: sequence)
            else { return }
            logger.notice("Recovered a missing scene-backed status-item action")
            performPrimaryAction(modifierFlags: modifierFlags)
        }
    }

    func notePhysicalMouseDown(eventTimestamp: TimeInterval) {
        actionRecoveryCoordinator.notePhysicalMouseDown(eventTimestamp: eventTimestamp)
    }

    /// Updates the appearance of the status item using the current hiding state.
    private func updateStatusItem() {
        guard
            let appState,
            let button = statusItem.button
        else {
            return
        }

        button.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        button.title = ""
        button.image = nil

        switch identifier {
        case .visible:
            updateStatusItemVisibility(true)
            button.appearsDisabled = false

            let icon = appState.settings.general.barlineIcon

            // We can usually just create the image directly from the icon.
            var image = switch state {
            case .showSection: icon.visible.nsImage(for: appState)
            case .hideSection: icon.hidden.nsImage(for: appState)
            }

            if
                case .custom = icon.name,
                let originalImage = image
            {
                // Custom icons need to be resized to fit inside the button.
                let originalWidth = originalImage.size.width
                let originalHeight = originalImage.size.height
                let ratio = max(originalWidth / 25, originalHeight / 17)
                let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
                image = originalImage.resized(to: newSize)
            }

            button.image = image
        case .hidden, .alwaysHidden:
            switch state {
            case .showSection:
                switch appState.settings.advanced.sectionDividerStyle {
                case .noDivider:
                    updateStatusItemVisibility(false)
                    button.appearsDisabled = true
                    button.isHighlighted = false

                    if appState.isDraggingMenuBarItem, appState.settings.advanced.showAllSectionsOnUserDrag {
                        // We still want a subtle marker between sections.
                        button.title = "|"
                    }
                case .chevron:
                    updateStatusItemVisibility(true)
                    button.appearsDisabled = false

                    button.image = switch identifier {
                    case .hidden:
                        ControlItemImage.builtin(.chevronLarge).nsImage(for: appState)
                    case .alwaysHidden:
                        ControlItemImage.builtin(.chevronSmall).nsImage(for: appState)
                    case .visible: nil
                    }
                }
            case .hideSection:
                updateStatusItemVisibility(true)
                button.appearsDisabled = true
                button.isHighlighted = false
            }
        }
    }

    /// Updates the visibility of the status item.
    ///
    /// The hidden and always-hidden control items must always be present in
    /// the menu bar, as we use their positions to determine the items in each
    /// section. Setting `statusItem.isVisible` to `false` completely removes
    /// the item. Instead, we toggle the width constraint on the item's content
    /// view, update the item's length, then adjust the content size of the
    /// item's window if needed.
    private func updateStatusItemVisibility(_ isVisible: Bool) {
        guard let appState else {
            return
        }

        if isVisible {
            constraint?.isActive = true
            statusItem.length = identifier.length(for: state)
        } else {
            let showOnDrag = appState.settings.advanced.showAllSectionsOnUserDrag
            let isDragging = appState.isDraggingMenuBarItem

            let shouldShow = showOnDrag && isDragging
            // Golden Gate parks status items shorter than the native divider
            // floor below the physical display. Keep three transparent points
            // in the menu-bar row so the public Accessibility inventory retains
            // the divider geometry
            // required to classify hidden items. Earlier releases continue to
            // use the established zero-length behavior.
            let collapsedLength: CGFloat = if #available(macOS 27.0, *) {
                3
            } else {
                0
            }

            let effectiveLength: CGFloat = shouldShow ? 3 : collapsedLength
            constraint?.isActive = false
            statusItem.length = effectiveLength

            if let window {
                let size = withMutableCopy(of: window.frame.size) { $0.width = max(effectiveLength, 1) }
                window.setContentSize(size)
            }
        }
    }

    /// Adds the control item to the menu bar.
    private func addToMenuBar() {
        guard !isAddedToMenuBar else {
            return
        }
        statusItem.isVisible = true
    }

    /// Removes the control item from the menu bar.
    private func removeFromMenuBar() {
        guard isAddedToMenuBar else {
            return
        }
        // Setting `statusItem.isVisible` to `false` has the unwanted side
        // effect of deleting the preferred position. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = ControlItemDefaults[.preferredPosition, autosaveName]
        statusItem.isVisible = false
        ControlItemDefaults[.preferredPosition, autosaveName] = cached
    }

    /// Synchronous event ownership must not depend on the published window,
    /// which can lag a status-button replacement by a main-queue delivery.
    func ownsEventWindow(_ eventWindow: NSWindow?) -> Bool {
        guard let eventWindow else { return false }
        return eventWindow === statusItem.button?.window || eventWindow === window
    }

    /// Compare WindowServer's mouse-down target to the live status button.
    /// Do not treat the menu-bar container or an unknown window as ownership.
    func ownsWindowNumber(_ number: Int) -> Bool {
        guard number > 0 else { return false }
        return number == statusItem.button?.window?.windowNumber || number == window?.windowNumber
    }

    /// Global hosted events may not expose an NSWindow. Resolve their captured
    /// point against the button's exact screen geometry before considering the
    /// cached frame. A scene-backed button's window can span the whole menu bar
    /// on macOS 27, so the window frame is not proof that the control was hit.
    func containsEventLocation(_ location: CGPoint) -> Bool {
        if let button = statusItem.button, let window = button.window {
            let candidateFrames = [
                button.accessibilityFrame(),
                window.convertToScreen(button.convert(button.bounds, to: nil)),
            ]
            if let exactFrame = candidateFrames.first(where: {
                StatusItemActionRecoveryCoordinator.isPlausibleExactButtonFrame(
                    width: $0.width,
                    height: $0.height
                )
            }) {
                return exactFrame.contains(location)
            }
        }
        return false
    }

    /// Performs the control item's action.
    @objc private func performAction() {
        guard appState != nil, let event = NSApp.currentEvent else {
            return
        }

        let eventPhase = switch event.type {
        case .leftMouseDown: "left-down"
        case .leftMouseUp: "left-up"
        case .rightMouseUp: "right-up"
        default: "other"
        }
        let loggedSection = sectionName.logString
        logger.notice(
            "Control action delivered for \(loggedSection, privacy: .public), phase=\(eventPhase, privacy: .public)"
        )

        switch event.type {
        // Scene-backed status items can briefly deliver their default mouse-up
        // action while reconnecting after an update. Accept either phase. The
        // configured event mask above still emits only one primary action.
        case .leftMouseDown, .leftMouseUp:
            let modifierFlags = NSEvent.modifierFlags
            if identifier == .visible {
                guard actionRecoveryCoordinator.claimNativeAction(
                    eventTimestamp: event.timestamp,
                    isMouseUp: event.type == .leftMouseUp
                ) else {
                    logger.notice("Suppressed a late duplicate status-item action")
                    return
                }
                actionRecoveryTask?.cancel()
            }
            performPrimaryAction(modifierFlags: modifierFlags)
        case .rightMouseUp:
            showMenu()
        default:
            return
        }
    }

    private func performPrimaryAction(modifierFlags: NSEvent.ModifierFlags) {
        guard let menuBarManager = appState?.menuBarManager else { return }

        // Running this from a Task improves the visual responsiveness of the
        // status item's button and keeps native and recovered delivery identical.
        Task {
            if modifierFlags == .control {
                showMenu()
                return
            }

            if
                modifierFlags == .option,
                let section = menuBarManager.section(withName: .alwaysHidden),
                section.isEnabled
            {
                section.toggle()
                return
            }

            if
                let section = menuBarManager.section(withName: sectionName),
                section.isEnabled
            {
                section.toggle()
            }
        }
    }

    /// Creates a menu to show under the control item.
    private func createMenu(with appState: AppState) -> NSMenu {
        func hotkey(withAction action: HotkeyAction) -> Hotkey? {
            appState.settings.hotkeys.hotkey(withAction: action)
        }

        let menu = NSMenu(title: "Barline")

        let settingsItem = NSMenuItem(
            title: "Barline Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let searchItem = NSMenuItem(
            title: "Search Menu Bar Items",
            action: #selector(showSearchPanel),
            keyEquivalent: ""
        )
        if
            let hotkey = hotkey(withAction: .searchMenuBarItems),
            let keyCombination = hotkey.keyCombination
        {
            searchItem.keyEquivalent = keyCombination.key.keyEquivalent
            searchItem.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
        }
        searchItem.target = self
        menu.addItem(searchItem)

        menu.addItem(.separator())

        // Add items to toggle the hidden and always-hidden sections.
        for name: MenuBarSection.Name in [.hidden, .alwaysHidden] {
            guard
                let section = appState.menuBarManager.section(withName: name),
                section.isEnabled
            else {
                continue
            }
            let item = NSMenuItem(
                title: "\(section.isHidden ? "Show" : "Hide") \(name.displayString) Section",
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            if
                let hotkey = section.hotkey,
                let keyCombination = hotkey.keyCombination
            {
                item.keyEquivalent = keyCombination.key.keyEquivalent
                item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
            }
            item.target = self
            item.representedObject = section
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if UpdatesManager.isEnabled {
            let checkForUpdatesItem = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            checkForUpdatesItem.target = self
            menu.addItem(checkForUpdatesItem)

            menu.addItem(.separator())
        }

        let quitItem = NSMenuItem(
            title: "Quit Barline",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    /// Shows the control item's menu.
    private func showMenu() {
        guard let appState else {
            return
        }
        let menu = createMenu(with: appState)
        statusItem.showMenu(menu)
    }

    /// Toggles the menu bar section associated with the given menu item.
    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        guard let section = menuItem.representedObject as? MenuBarSection else {
            return
        }
        section.toggle()
    }

    /// Opens the menu bar search panel.
    @objc private func showSearchPanel() {
        appState?.menuBarManager.searchPanel.show()
    }

    /// Opens the settings window and checks for app updates.
    @objc private func checkForUpdates() {
        guard let appState else {
            return
        }
        appState.updatesManager.checkForUpdates()
    }
}

// MARK: - ControlItemDefaults

/// Proxy getters and setters for a control item's stored
/// UserDefaults values.
enum ControlItemDefaults {
    /// Accesses the value associated with the specified key
    /// and autosave name.
    static subscript<Value>(key: Key<Value>, autosaveName: String) -> Value? {
        get {
            let stringKey = key.stringKey(for: autosaveName)
            return UserDefaults.standard.object(forKey: stringKey) as? Value
        }
        set {
            let stringKey = key.stringKey(for: autosaveName)
            return UserDefaults.standard.set(newValue, forKey: stringKey)
        }
    }

    /// Migrates the given control item defaults key from an old
    /// autosave name to a new autosave name.
    static func migrate(key: Key<some Any>, from oldAutosaveName: String, to newAutosaveName: String) {
        guard newAutosaveName != oldAutosaveName else {
            return
        }
        Self[key, newAutosaveName] = Self[key, oldAutosaveName]
        Self[key, oldAutosaveName] = nil
    }

    /// Performs some initial required setup work before the
    /// creation of a control item.
    fileprivate static func preflightSetup(for controlItem: ControlItem) {
        let autosaveName = controlItem.identifier.rawValue

        // Visible and hidden control items should be added before
        // existing items in the status bar.
        if ControlItemDefaults[.preferredPosition, autosaveName] == nil {
            switch controlItem.identifier {
            case .visible:
                ControlItemDefaults[.preferredPosition, autosaveName] = 0
            case .hidden:
                ControlItemDefaults[.preferredPosition, autosaveName] = 1
            case .alwaysHidden:
                break
            }
        }

        // The control item should be visible by default. We change
        // this after finishing setup, if needed.
        if ControlItemDefaults[.visible, autosaveName] == nil {
            ControlItemDefaults[.visible, autosaveName] = true
        }
        if
            #available(macOS 26.0, *),
            ControlItemDefaults[.visibleCC, autosaveName] == nil
        {
            ControlItemDefaults[.visibleCC, autosaveName] = true
        }
    }
}

// MARK: - ControlItemDefaults.Key

extension ControlItemDefaults {
    /// Keys used to look up UserDefaults values for control items.
    struct Key<Value> {
        /// The raw value of the key.
        let rawValue: String

        /// Returns the full string key for the given autosave name.
        func stringKey(for autosaveName: String) -> String {
            "NSStatusItem \(rawValue) \(autosaveName)"
        }
    }
}

// MARK: ControlItemDefaults.Key<CGFloat>

extension ControlItemDefaults.Key<CGFloat> {
    /// String key: "NSStatusItem Preferred Position autosaveName"
    static let preferredPosition = Self(rawValue: "Preferred Position")
}

// MARK: ControlItemDefaults.Key<Bool>

extension ControlItemDefaults.Key<Bool> {
    /// String key: "NSStatusItem Visible autosaveName"
    static let visible = Self(rawValue: "Visible")

    /// String key: "NSStatusItem VisibleCC autosaveName"
    static let visibleCC = Self(rawValue: "VisibleCC")
}
