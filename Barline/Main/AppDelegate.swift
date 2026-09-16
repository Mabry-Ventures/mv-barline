//
//  AppDelegate.swift
//  Barline
//

import BarlineCore
import OSLog
import SwiftUI

/// Keeps the nonactivating shelf in the application Accessibility root without
/// replacing AppKit's dynamic window list for Settings and other native UI.
@objc(BarlineApplication)
@MainActor
final class BarlineApplication: NSApplication {
    override func accessibilityWindows() -> [Any]? {
        let windows = super.accessibilityWindows() ?? []
        guard let appDelegate = delegate as? AppDelegate else { return windows }
        let shelf = appDelegate.appState.menuBarManager.barlineShelfPanel
        return Self.includingShelf(
            shelf,
            whenVisible: shelf.isVisible,
            in: windows
        )
    }

    static func includingShelf(
        _ shelf: AnyObject,
        whenVisible isVisible: Bool,
        in appKitWindows: [Any]
    ) -> [Any] {
        guard isVisible else { return appKitWindows }
        guard !appKitWindows.contains(where: { ($0 as AnyObject) === shelf }) else {
            return appKitWindows
        }
        return appKitWindows + [shelf]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let reopenRecoveryGenerationKey = "ReopenRecoveryGeneration"
    private static let reopenRecoveryFailureKey = "ReopenRecoveryFailure"
    private static let reopenRecoverySucceededKey = "ReopenRecoverySucceeded"
    private static let reopenProbeBaselineGenerationKey = "ReopenProbeBaselineGeneration"
    private static let reopenProbePresentationGenerationKey = "ReopenProbePresentationGeneration"
    private static let reopenProbePresentationProcessIdentifierKey = "ReopenProbePresentationProcessIdentifier"
    private static let notificationPrefix = Bundle.main.bundleIdentifier ?? "Barline"
    private static let reopenProbeHideSettingsNotification = Notification.Name(
        "\(notificationPrefix).reopen-probe.hide-settings"
    )
    /// Whether this install is still owed the first-run walkthrough. Declared
    /// before `appState` because stored properties initialize in declaration
    /// order and `AppState` may write preferences as it starts.
    private let isFreshInstall = AppDelegate.recordFreshInstall()

    /// The shared app state.
    let appState = AppState()

    /// Coalesces repeated requests to activate the settings window.
    private var settingsOpenTask: Task<Void, Never>?

    /// Avoids rapid accessory/regular policy churn while still releasing focus
    /// immediately when the final app window closes.
    private var accessoryDeactivationTask: Task<Void, Never>?

    /// Prevents bursts of reopen events from starting overlapping XPC refreshes.
    private var reopenRecoveryTask: Task<Void, Never>?

    /// Preserves one completion acknowledgement for every reopen event received
    /// while the serialized compatibility recovery task is still draining.
    private var pendingReopenRecoveryCount = 0

    #if DEBUG
        private static let runtimeSmokeToggleNotification = Notification.Name(
            "\(notificationPrefix).runtime-smoke.toggle-shelf"
        )
    #endif

    // MARK: NSApplicationDelegate Methods

    func applicationWillFinishLaunching(_: Notification) {
        // Initial chore work.
        NSSplitViewItem.swizzle()
        MigrationManager(appState: appState).migrateAll()
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Hide the main menu's items to add additional space to the
        // menu bar when we are the focused app.
        for item in NSApp.mainMenu?.items ?? [] {
            item.isHidden = true
        }

        if CommandLine.arguments.contains("--barline-reopen-probe") {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(hideSettingsForReopenProbe),
                name: Self.reopenProbeHideSettingsNotification,
                object: nil
            )
        }

        // Allow hiding the mouse while the app is in the background
        // to make menu bar item movement less jarring.
        Task {
            await BarlineMenuService.Connection.shared.configureCursorInBackground(true)
        }

        #if DEBUG
            // Don't perform setup if running as a preview.
            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                return
            }

            // Runtime smoke tests exercise Barline's own UI without depending on
            // host-specific TCC grants. Release builds never include this path.
            if CommandLine.arguments.contains("--barline-runtime-smoke") {
                DistributedNotificationCenter.default().addObserver(
                    self,
                    selector: #selector(toggleShelfForRuntimeSmoke),
                    name: Self.runtimeSmokeToggleNotification,
                    object: nil
                )
                appState.performSetup()
                // Keep the probe in the same accessory-only, inactive state as
                // a production status-item click. It must not rely on opening
                // Settings to make the shelf visible.
                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
                return
            }
        #endif

        // Offer to move Barline into Applications before anything can request a
        // permission grant, because macOS ties grants to the app's location.
        // Development builds skip the offer and continue synchronously.
        ApplicationRelocator.offerIfNeeded { [appState, isFreshInstall] in
            // The settings, saved profiles, search metadata, and diagnostics remain
            // available without Accessibility. Features that manage other apps'
            // status items request that grant only when the user chooses them.
            appState.performSetup()
            // A fresh install gets the first-run walkthrough, which requests each
            // permission only when the user clicks to allow it. Upgrades and
            // development builds are not interrupted.
            WelcomePresenter.presentAtLaunchIfNeeded(
                appState: appState,
                isFreshInstall: isFreshInstall
            )
        }
        // Permission checks can transiently report missing while macOS is
        // reconnecting a newly installed signed build. Launch never shows a
        // system permission dialog on its own.
    }

    /// Marks a fresh install before anything else writes preferences, and
    /// reports whether the walkthrough is still owed. An empty preferences
    /// domain is only trustworthy on the very first launch: migrations and the
    /// move-to-Applications relaunch write values before the relocated copy
    /// starts. The marker survives that handoff and is cleared when the
    /// walkthrough ends. Upgrading users never receive it.
    private nonisolated static func recordFreshInstall() -> Bool {
        // Development builds share the installed app's preferences domain and
        // never present the walkthrough, so they must not write the marker, or
        // the next distributed copy would treat that domain as a fresh install.
        guard isDistributedBuild else {
            return false
        }
        let defaults = UserDefaults.standard
        let key = Defaults.Key.welcomePending.rawValue
        guard
            let identifier = Bundle.main.bundleIdentifier,
            let domain = defaults.persistentDomain(forName: identifier),
            !domain.isEmpty
        else {
            defaults.set(true, forKey: key)
            return true
        }
        return defaults.bool(forKey: key)
    }

    /// Copies distributed to users: not a development build, and signed with
    /// Barline's Developer ID, matching walkthrough eligibility.
    private nonisolated static var isDistributedBuild: Bool {
        #if DEBUG
            false
        #else
            DistributionIdentity.isDeveloperIDSigned
        #endif
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        Logger.default.notice("Application reopen received")
        // Keep every reopen responsive even if a prior compatibility recovery
        // is still in flight. The opener coalesces bursts independently.
        scheduleSettingsOpen(acknowledgeReopenProbe: true)
        // A reopen is also a safe recovery opportunity for the compatibility
        // backend. This keeps the app process alive while replacing an
        // interrupted XPC helper before the user performs another action.
        pendingReopenRecoveryCount += 1
        return true
    }

    private func startReopenRecoveryIfNeeded() {
        if reopenRecoveryTask == nil {
            reopenRecoveryTask = Task { [weak self] in
                guard let self else {
                    return
                }
                defer { reopenRecoveryTask = nil }
                while pendingReopenRecoveryCount > 0 {
                    pendingReopenRecoveryCount -= 1
                    await completeReopenRecovery()
                }
            }
        }
    }

    private func completeReopenRecovery() async {
        var succeeded = true
        var failureDescription: String?
        await appState.waitForSetup()
        do {
            do {
                _ = try await appState.compatibilityCoordinator.refresh()
            } catch let error as MenuBarBackendError {
                switch error {
                case .interrupted, .invalidSnapshot(.nonMonotonicGeneration):
                    // A replacement XPC helper can either interrupt the
                    // in-flight request or start a new raw generation epoch.
                    // In both cases, replace the session and rebase it.
                    _ = try await appState.compatibilityCoordinator.recover()
                default:
                    throw error
                }
            }
            await appState.profileManager.reconcileActiveProfileAuthority()
        } catch {
            succeeded = false
            failureDescription = recoveryFailureCategory(for: error)
            Logger.default.error(
                "Compatibility refresh on reopen failed: \(failureDescription ?? "unknown", privacy: .public)"
            )
        }
        let visibilityDeadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < visibilityDeadline,
              !NSApp.windows.contains(where: {
                  $0.identifier?.rawValue == BarlineWindowIdentifier.settings.rawValue && $0.isVisible
              })
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        succeeded = succeeded && NSApp.windows.contains(where: {
            $0.identifier?.rawValue == BarlineWindowIdentifier.settings.rawValue && $0.isVisible
        })
        let defaults = UserDefaults.standard
        defaults.set(succeeded, forKey: Self.reopenRecoverySucceededKey)
        defaults.set(failureDescription, forKey: Self.reopenRecoveryFailureKey)
        defaults.set(
            defaults.integer(forKey: Self.reopenRecoveryGenerationKey) + 1,
            forKey: Self.reopenRecoveryGenerationKey
        )
        defaults.synchronize()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if
            sender.isActive,
            sender.activationPolicy() != .accessory,
            appState.navigationState.isAppFrontmost
        {
            Logger.default.debug("All windows closed - deactivating with accessory activation policy")
            scheduleAccessoryDeactivation()
        }
        return false
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    // MARK: Other Methods

    /// Opens the settings window and activates the app.
    @objc func openSettingsWindow() {
        scheduleSettingsOpen(acknowledgeReopenProbe: false)
    }

    private func scheduleSettingsOpen(acknowledgeReopenProbe: Bool) {
        // Cancel the prior activation so a burst of requests cannot enqueue
        // unbounded main-actor work. Menu-driven settings requests retain the
        // compatibility delay. A production reopen is scheduled on the next
        // cooperative turn so activation and window presentation are not held
        // behind the longer menu-command delay or unrelated recovery work.
        accessoryDeactivationTask?.cancel()
        accessoryDeactivationTask = nil
        settingsOpenTask?.cancel()
        settingsOpenTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: acknowledgeReopenProbe ? .milliseconds(0) : .milliseconds(100)
                )
            } catch {
                return
            }
            guard let self else {
                return
            }
            settingsOpenTask = nil
            appState.activate(withPolicy: .regular)
            appState.openWindow(.settings)
            bringSettingsWindowForward()
            guard acknowledgeReopenProbe || pendingReopenRecoveryCount > 0 else {
                return
            }
            let visibilityDeadline = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < visibilityDeadline,
                  !isSettingsPresented()
            {
                bringSettingsWindowForward()
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  isSettingsPresented()
            else {
                startReopenRecoveryIfNeeded()
                return
            }
            if acknowledgeReopenProbe,
               CommandLine.arguments.contains("--barline-reopen-probe")
            {
                let defaults = UserDefaults.standard
                defaults.set(
                    ProcessInfo.processInfo.processIdentifier,
                    forKey: Self.reopenProbePresentationProcessIdentifierKey
                )
                defaults.set(
                    defaults.integer(forKey: Self.reopenProbePresentationGenerationKey) + 1,
                    forKey: Self.reopenProbePresentationGenerationKey
                )
                defaults.synchronize()
            }
            startReopenRecoveryIfNeeded()
        }
    }

    private func bringSettingsWindowForward() {
        guard let window = settingsWindow() else {
            return
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
    }

    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == BarlineWindowIdentifier.settings.rawValue
        }
    }

    private func isSettingsPresented() -> Bool {
        guard NSApp.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        else {
            return false
        }
        guard let window = settingsWindow() else {
            return false
        }
        return window.isVisible &&
            window.isOnActiveSpace &&
            (window.isKeyWindow || window.isMainWindow)
    }

    private func scheduleAccessoryDeactivation() {
        accessoryDeactivationTask?.cancel()
        NSApp.deactivate()
        accessoryDeactivationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  !NSApp.isActive,
                  !NSApp.windows.contains(where: {
                      $0.isVisible && ($0.canBecomeKey || $0.canBecomeMain)
                  })
            else {
                return
            }
            accessoryDeactivationTask = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Establishes a hidden-window baseline for the explicit local reopen probe.
    /// The launch argument keeps this test-only control unavailable in normal use.
    @objc private func hideSettingsForReopenProbe() {
        guard CommandLine.arguments.contains("--barline-reopen-probe") else {
            return
        }
        settingsOpenTask?.cancel()
        settingsOpenTask = nil
        for window in NSApp.windows where
            window.identifier?.rawValue == BarlineWindowIdentifier.settings.rawValue
        {
            window.orderOut(nil)
        }
        // The explicit probe is allowed to release focus immediately. Normal
        // last-window handling keeps the one-second policy deferral so a user
        // can reopen Settings without activation-policy churn.
        appState.deactivate(withPolicy: .accessory)
        let defaults = UserDefaults.standard
        defaults.set(
            defaults.integer(forKey: Self.reopenProbeBaselineGenerationKey) + 1,
            forKey: Self.reopenProbeBaselineGenerationKey
        )
        defaults.synchronize()
    }

    private func recoveryFailureCategory(for error: Error) -> String {
        guard let backendError = error as? MenuBarBackendError else {
            return "unexpected-error"
        }
        return switch backendError {
        case .unavailableCapability:
            "unavailable-capability"
        case .staleItem:
            "stale-item"
        case .unsafeMenuTracking:
            "unsafe-menu-tracking"
        case let .invalidSnapshot(reason):
            snapshotRejectionCategory(reason)
        case .interrupted:
            "interrupted"
        case .timedOut:
            "timed-out"
        case .mutationSuperseded:
            "mutation-superseded"
        case .mutationRecoveryRequired:
            "mutation-recovery-required"
        case .positionTableAccessNotGranted:
            "position-table-access-not-granted"
        case .mutationNotStarted:
            "mutation-not-started"
        case .mutationRecoveryFailed:
            "mutation-recovery-failed"
        case .operationFailed:
            "operation-failed"
        }
    }

    private func snapshotRejectionCategory(_ reason: SnapshotRejectionReason) -> String {
        switch reason {
        case .missingDisplayGeometry: "invalid-snapshot-missing-display-geometry"
        case .invalidActiveSpace: "invalid-snapshot-active-space"
        case .staleSnapshot: "invalid-snapshot-stale"
        case .futureDatedSnapshot: "invalid-snapshot-future-dated"
        case .unknownItemDisplay: "invalid-snapshot-unknown-item-display"
        case .displayIdentitySetMismatch: "invalid-snapshot-display-identity-set"
        case .duplicateDisplayIdentity: "invalid-snapshot-duplicate-display"
        case .malformedDisplayFingerprint: "invalid-snapshot-display-fingerprint"
        case .duplicateItemIdentity: "invalid-snapshot-duplicate-item"
        case .unstableItemIdentity: "invalid-snapshot-unstable-item"
        case .invalidItemGeometry: "invalid-snapshot-item-geometry"
        case .missingRequiredControlItem: "invalid-snapshot-missing-control"
        case .implausibleItemCountCollapse: "invalid-snapshot-item-collapse"
        case .implausibleSystemItemCollapse: "invalid-snapshot-system-item-collapse"
        case .emptySnapshot: "invalid-snapshot-empty"
        case .nonMonotonicGeneration: "invalid-snapshot-generation"
        }
    }

    #if DEBUG
        /// Gives a separate local probe a deterministic activation path without
        /// adding any behavior to Release builds.
        @objc private func toggleShelfForRuntimeSmoke() {
            // Exercise the production menu-bar-agent state: the status item
            // does not activate Barline, and hiding the Dock icon keeps the
            // application accessory-only while the shelf is presented.
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
            appState.menuBarManager.section(withName: .visible)?.toggle()
        }
    #endif
}
