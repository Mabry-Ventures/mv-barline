//
//  AppState.swift
//  Barline
//

import BarlineCore
import Combine
import OSLog
import SwiftUI

/// The model for app-wide state.
@MainActor
final class AppState: ObservableObject {
    /// Information for the active space.
    @Published private(set) var activeSpace = SpaceInfo.activeSpace()

    /// A Boolean value that indicates whether the user is dragging a menu bar item.
    @Published private(set) var isDraggingMenuBarItem = false

    /// Model for the app's settings.
    let settings = AppSettings()

    /// Model for the app's permissions.
    let permissions = AppPermissions()

    /// Model for app-wide navigation.
    let navigationState = AppNavigationState()

    /// Model for the first-run walkthrough.
    let welcome = WelcomeModel()

    /// Manager for the state of the menu bar.
    let menuBarManager = MenuBarManager()

    /// Manager for the menu bar's appearance.
    let appearanceManager = MenuBarAppearanceManager()

    /// Manager for menu bar item spacing.
    let spacingManager = MenuBarItemSpacingManager()

    /// Manager for menu bar items.
    let itemManager = MenuBarItemManager()

    /// Global cache for menu bar item images.
    let imageCache = MenuBarItemImageCache()

    /// Manager for input events received by the app.
    let hidEventManager = HIDEventManager()

    /// Manager for app updates.
    let updatesManager = UpdatesManager()

    /// Serialized authority for validated compatibility snapshots and recovery.
    let compatibilityCoordinator = MenuBarItem.snapshotCoordinator

    let temporaryRevealJournal = TemporaryRevealJournal(
        directoryURL: URL.applicationSupportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Barline", isDirectory: true)
            .appendingPathComponent("TemporaryReveals", isDirectory: true)
    )

    /// Persistence and transactional activation for menu bar profiles.
    let profileManager = ProfileManager()
    let contextualRules = ContextualRulesManager()

    /// Manager for user notifications.
    let userNotificationManager = UserNotificationManager()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The Accessibility value already applied to HID setup. This suppresses
    /// only an identical initial publisher emission while still reconciling a
    /// grant or revocation that races the asynchronous setup sequence.
    private var reconciledAccessibilityPermission: Bool?

    /// Logger for the app state.
    private let logger = Logger(category: "AppState")

    /// The menu-bar controls are installed before compatibility inventory,
    /// profiles, and image caching finish. Input must be able to use those
    /// controls without waiting for the slower best-effort work.
    private var menuBarAgentSetupReady = false
    private var menuBarAgentSetupWaiters = [CheckedContinuation<Void, Never>]()

    /// Async setup actions, run once on first access.
    private lazy var setupTask = Task { @MainActor in
        settings.performSetup(with: self)
        menuBarManager.performSetup(with: self)
        markMenuBarAgentSetupReady()

        if #available(macOS 26.0, *) {
            await BarlineMenuService.Connection.shared.start()
            do {
                _ = try await compatibilityCoordinator.refresh()
            } catch {
                logger.warning("Compatibility snapshot unavailable during setup: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
            }
        }

        appearanceManager.performSetup(with: self)
        await compatibilityCoordinator.setBeforeAuthoritativeLayoutMutation { [temporaryRevealJournal] in
            guard try await temporaryRevealJournal.load().isEmpty else {
                throw MenuBarBackendError.operationFailed("temporary item restoration must finish before changing layouts")
            }
        }
        await profileManager.performSetup(with: self)

        let initialAccessibilityPermission = permissions.accessibility.hasPermission
        hidEventManager.performSetup(
            with: self,
            startsEnabled: initialAccessibilityPermission
        )
        reconciledAccessibilityPermission = initialAccessibilityPermission
        await itemManager.performSetup(with: self)
        imageCache.performSetup(with: self)
        updatesManager.performSetup(with: self)
        userNotificationManager.performSetup(with: self)

        configureCancellables()
        await contextualRules.performSetup(with: self)
    }

    /// Performs app state setup. Compatibility-dependent features fail closed
    /// when Accessibility is unavailable; the rest of the app remains usable.
    func performSetup() {
        Task {
            logger.debug("Setting up app state")
            await setupTask.value
            logger.debug("Finished setting up app state")
        }
    }

    /// Waits for the one-time setup sequence before a production recovery
    /// request competes for the compatibility connection.
    func waitForSetup() async {
        await setupTask.value
    }

    /// Waits only for the synchronous menu-bar-agent setup boundary. This is
    /// deliberately earlier than `waitForSetup()`: a user can press a status
    /// item while bounded compatibility discovery is still recovering.
    func waitForMenuBarAgentSetup() async {
        guard !menuBarAgentSetupReady else { return }
        await withCheckedContinuation { continuation in
            menuBarAgentSetupWaiters.append(continuation)
        }
    }

    private func markMenuBarAgentSetupReady() {
        guard !menuBarAgentSetupReady else { return }
        menuBarAgentSetupReady = true
        let waiters = menuBarAgentSetupWaiters
        menuBarAgentSetupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Configures the internal observers for the app state.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Listen for changes to the active space. We need handle some special
        // cases that NSWorkspace.shared.notificationCenter seems to miss.
        //
        // Special cases:
        //
        // * Changes to the frontmost application -- may indicate that a space
        //   on another display was made active.
        // * Left mouse down -- user may have clicked into a fullscreen space.
        //   To account for variations in system timing, we publish a value
        //   immediately upon receipt of the event, then publish another value
        //   after a delay.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .discardMerge(NSWorkspace.shared.publisher(for: \.frontmostApplication))
            .discardMerge(EventMonitor.publish(events: .leftMouseDown, scope: .universal).flatMap { _ in
                let initial = Just(())
                let delayed = initial.delay(for: 0.1, scheduler: DispatchQueue.main)
                return Publishers.Merge(initial, delayed)
            })
            .sink { [weak self] _ in
                Task {
                    guard let environment = try? await BarlineMenuService.Connection.shared.environment() else {
                        return
                    }
                    self?.activeSpace = SpaceInfo(
                        spaceID: environment.activeSpaceToken,
                        isFullscreen: environment.activeSpaceIsFullscreen
                    )
                }
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .map { $0 == .current }
            .removeDuplicates()
            .sink { [weak self] isFrontmost in
                self?.navigationState.isAppFrontmost = isFrontmost
            }
            .store(in: &c)

        publisherForWindow(.settings)
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .replaceEmpty(with: false)
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .sink { [weak self] isPresented in
                self?.navigationState.isSettingsPresented = isPresented
            }
            .store(in: &c)

        publisherForWindow(.welcome)
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .replaceEmpty(with: false)
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .sink { [weak self] isPresented in
                self?.navigationState.isWelcomePresented = isPresented
            }
            .store(in: &c)

        hidEventManager.$isDraggingMenuBarItem
            .removeDuplicates()
            .sink { [weak self] isDragging in
                self?.isDraggingMenuBarItem = isDragging
            }
            .store(in: &c)

        permissions.accessibility.$hasPermission
            .removeDuplicates()
            .sink { [weak self] isGranted in
                Task {
                    await self?.accessibilityPermissionDidChange(isGranted)
                }
            }
            .store(in: &c)

        permissions.screenRecording.$hasPermission
            .removeDuplicates()
            .sink { [weak self] isGranted in
                self?.imageCache.permissionDidChange(isGranted)
            }
            .store(in: &c)

        // TCC has no public change notification. While pixels or permission
        // controls are visible, a low-frequency nonprompting preflight also
        // notices changes made while System Settings stays frontmost. Stop the
        // timer completely when Barline has no visible UI.
        Publishers.CombineLatest4(
            navigationState.$isBarlineShelfPresented,
            navigationState.$isSearchPresented,
            navigationState.$isSettingsPresented,
            navigationState.$isWelcomePresented
        )
        .map { $0 || $1 || $2 || $3 }
        .removeDuplicates()
        .map { isVisible -> AnyPublisher<Void, Never> in
            guard isVisible else { return Empty().eraseToAnyPublisher() }
            return Timer.publish(every: 1, tolerance: 0.25, on: .main, in: .common)
                .autoconnect()
                .map { _ in () }
                .prepend(())
                .eraseToAnyPublisher()
        }
        .switchToLatest()
        .sink { [weak self] in
            self?.permissions.accessibility.refresh()
            self?.permissions.screenRecording.refresh()
        }
        .store(in: &c)

        Publishers.CombineLatest(
            navigationState.$isAppFrontmost,
            navigationState.$isSettingsPresented
        )
        .map { $0 && $1 }
        .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
        .merge(with: Just(true).delay(for: 1, scheduler: DispatchQueue.main))
        .sink { [weak self] shouldUpdate in
            guard let self, shouldUpdate else {
                return
            }
            Task {
                await self.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            }
        }
        .store(in: &c)

        menuBarManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        permissions.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        settings.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        updatesManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        profileManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Refreshes compatibility-owned state after a grant and immediately closes
    /// mutation UI after revocation. Cached item names remain available for
    /// read-only search while mutation entry points check the live permission.
    private func accessibilityPermissionDidChange(_ isGranted: Bool) async {
        guard reconciledAccessibilityPermission != isGranted else { return }
        reconciledAccessibilityPermission = isGranted
        guard isGranted else {
            logger.notice("Accessibility permission was revoked; continuing in degraded mode")
            hidEventManager.stopAll()
            menuBarManager.barlineShelfPanel.close()
            return
        }

        logger.notice("Accessibility permission was granted; refreshing menu bar state")
        hidEventManager.startAll()
        await BarlineMenuService.Connection.shared.start()
        do {
            _ = try await compatibilityCoordinator.refresh()
            await profileManager.reconcileActiveProfileAuthority()
        } catch {
            logger.warning("Compatibility snapshot unavailable after permission grant")
        }
        await itemManager.cacheItemsRegardless()
        await profileManager.processPendingBridgeCommands()
    }

    /// Returns a Boolean value indicating whether the app has been
    /// granted the permission associated with the given key.
    func hasPermission(_ key: AppPermissions.PermissionKey) -> Bool {
        switch key {
        case .accessibility:
            permissions.accessibility.refresh()
        case .screenRecording:
            permissions.screenRecording.refresh()
        }
    }

    /// Returns a publisher for the window with the given identifier.
    func publisherForWindow(_ id: BarlineWindowIdentifier) -> some Publisher<NSWindow?, Never> {
        NSApp.publisher(for: \.windows).mergeMap { window in
            window.publisher(for: \.identifier)
                .map { [weak window] identifier in
                    guard identifier?.rawValue == id.rawValue else {
                        return nil
                    }
                    return window
                }
                .first { $0 != nil }
                .replaceEmpty(with: nil)
        }
    }

    /// Opens the window with the given identifier.
    func openWindow(_ id: BarlineWindowIdentifier) {
        // Async prevents conflicts with SwiftUI.
        DispatchQueue.main.async {
            self.logger.debug("Opening window with id: \(id, privacy: .public)")
            EnvironmentValues().openWindow(id: id)
        }
    }

    /// Dismisses the window with the given identifier.
    func dismissWindow(_ id: BarlineWindowIdentifier) {
        // Async prevents conflicts with SwiftUI.
        DispatchQueue.main.async {
            self.logger.debug("Dismissing window with id: \(id, privacy: .public)")
            EnvironmentValues().dismissWindow(id: id)
        }
    }

    /// Activates the app and sets its activation policy.
    func activate(withPolicy policy: NSApplication.ActivationPolicy? = nil) {
        if let policy {
            NSApp.setActivationPolicy(resolvedActivationPolicy(for: policy))
        }
        // NSApplication.activate(ignoringOtherApps:) is deprecated, with
        // no suitable alternative for explicit activation, so we activate
        // through NSRunningApplication.current for now.
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            NSRunningApplication.current.activate()
            return
        }
        NSRunningApplication.current.activate(from: frontmost)
    }

    /// Deactivates the app and sets its activation policy.
    func deactivate(withPolicy policy: NSApplication.ActivationPolicy? = nil) {
        if let policy {
            NSApp.setActivationPolicy(resolvedActivationPolicy(for: policy))
        }
        NSApp.deactivate()
    }

    /// Applies the user's Dock preference without presenting or focusing UI.
    func applyDockIconPreference() {
        let hasVisibleAppWindow = NSApp.windows.contains {
            $0.isVisible && ($0.canBecomeKey || $0.canBecomeMain)
        }
        let requestedPolicy: NSApplication.ActivationPolicy = hasVisibleAppWindow ? .regular : .accessory
        NSApp.setActivationPolicy(resolvedActivationPolicy(for: requestedPolicy))
    }

    private func resolvedActivationPolicy(
        for requestedPolicy: NSApplication.ActivationPolicy
    ) -> NSApplication.ActivationPolicy {
        Self.activationPolicy(
            requested: requestedPolicy,
            hideDockIcon: settings.general.hideDockIcon
        )
    }

    static func activationPolicy(
        requested: NSApplication.ActivationPolicy,
        hideDockIcon: Bool
    ) -> NSApplication.ActivationPolicy {
        DockVisibilityPolicy.usesRegularActivationPolicy(
            requestedRegular: requested == .regular,
            hideDockIcon: hideDockIcon
        ) ? .regular : .accessory
    }
}
