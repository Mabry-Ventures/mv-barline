//
//  MenuBarItemImageCache.swift
//  Barline
//

import BarlineCore
import Cocoa
import Combine
import ImageIO
import OSLog

/// Cache for menu bar item images.
@MainActor
final class MenuBarItemImageCache: ObservableObject {
    /// A representation of a captured menu bar item image.
    struct CapturedImage: Hashable {
        /// The base image.
        let cgImage: CGImage

        /// The scale factor of the image at the time of capture.
        let scale: CGFloat

        /// The image's size, applying ``scale``.
        var scaledSize: CGSize {
            CGSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
        }

        /// The base image, converted to an `NSImage` and applying ``scale``.
        var nsImage: NSImage {
            NSImage(cgImage: cgImage, size: scaledSize)
        }
    }

    /// The result of an image capture operation.
    private struct CaptureResult {
        /// The successfully captured images.
        var images = [MenuBarItemID: CapturedImage]()

        /// The menu bar items excluded from the capture.
        var excluded = [MenuBarItem]()
    }

    /// Stable identities distinguish items that share a display title or legacy tag.
    @Published private(set) var images = [MenuBarItemID: CapturedImage]()

    /// Logger for the menu bar item image cache.
    private let logger = Logger(category: "MenuBarItemImageCache")

    /// Queue to run cache operations.
    private let queue = DispatchQueue(label: "MenuBarItemImageCache", qos: .background)

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// In-flight replies from an earlier permission epoch must not republish
    /// captured pixels after revocation (even when access was quickly restored).
    private var permissionGeneration: UInt64 = 0

    func permissionDidChange(_ isGranted: Bool) {
        permissionGeneration &+= 1
        images.removeAll()
        if isGranted {
            Task { await updateCache() }
        }
    }

    // MARK: Setup

    /// Sets up the cache.
    @MainActor
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.Merge3(
                // Refresh when the app becomes active or the machine wakes.
                Publishers.Merge(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                )
                .replace(with: ()),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .replace(with: ()),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().replace(with: ()),
                    appState.itemManager.$itemCache.removeDuplicates().replace(with: ())
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.updateCache()
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    // MARK: Capturing Images

    /// Captures a composite image of the given items, then crops out an image
    /// for each item and returns the result.
    private func compositeCapture(_ items: [MenuBarItem], scale: CGFloat) async -> CaptureResult {
        await captureStableItems(items, scale: scale)
    }

    /// Captures an image of each of the given items individually, then
    /// returns the result.
    private func individualCapture(_ items: [MenuBarItem], scale: CGFloat) async -> CaptureResult {
        await captureStableItems(items, scale: scale)
    }

    private func captureStableItems(_ items: [MenuBarItem], scale: CGFloat) async -> CaptureResult {
        var result = CaptureResult()
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.stableID, $0) })
        let captures = await (try? BarlineMenuService.Connection.shared.capture(
            items.map(\.stableID)
        )) ?? []

        for capture in captures {
            guard
                let item = itemByID[capture.itemID],
                let source = CGImageSourceCreateWithData(capture.pngData as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                !image.isTransparent()
            else {
                continue
            }
            result.images[item.stableID] = CapturedImage(cgImage: image, scale: scale)
        }
        // A helper reply is not successful until its image decodes and passes
        // transparency validation. Invalid replies must remain retryable.
        result.excluded = items.filter { result.images[$0.stableID] == nil }
        return result
    }

    /// Captures the images of the given menu bar items and returns the result.
    private func captureImages(of items: [MenuBarItem], scale: CGFloat, appState: AppState) async -> CaptureResult {
        // Use individual capture after a move operation, since composite capture
        // doesn't account for overlapping items.
        if appState.itemManager.lastMoveOperationOccurred(within: .seconds(2)) {
            logger.debug("Capturing individually due to recent item movement")
            return await individualCapture(items, scale: scale)
        }

        let compositeResult = await compositeCapture(items, scale: scale)

        if compositeResult.excluded.isEmpty {
            return compositeResult // All items captured successfully.
        }

        logger.notice(
            """
            Some items were excluded from composite capture. Attempting to capture \
            excluded item count: \(compositeResult.excluded.count, privacy: .public)
            """
        )

        var individualResult = await individualCapture(compositeResult.excluded, scale: scale)

        // Merge the successfully captured images from each result. Keep excluded
        // items as part of the result, so they can be logged elsewhere.
        individualResult.images.merge(compositeResult.images) { _, new in new }

        return individualResult
    }

    // MARK: Update Cache

    /// Updates the cache for the given sections, without checking whether
    /// caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        // Golden Gate no longer guarantees per-status-item WindowServer
        // surfaces. Publishing partial or blank captures after the shelf is
        // already visible also changes its geometry underneath the pointer.
        // macOS 27 presentation uses stable application/SF Symbol artwork.
        if #available(macOS 27.0, *) {
            if !images.isEmpty {
                images.removeAll()
            }
            return
        }
        guard
            let appState,
            appState.hasPermission(.screenRecording)
        else {
            permissionDidChange(false)
            return
        }

        let capturePermissionGeneration = permissionGeneration
        guard let screenCaptureGeneration = ScreenCapture.grantedPermissionGeneration() else { return }

        guard
            let displayID = appState.itemManager.itemCache.displayID,
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else {
            return
        }

        let scale = screen.backingScaleFactor
        var newImages = [MenuBarItemID: CapturedImage]()

        for section in sections {
            let items = appState.itemManager.itemsForBarlineShelf(in: section, on: screen)
            guard !items.isEmpty else {
                continue
            }

            let captureResult = await captureImages(of: items, scale: scale, appState: appState)
            guard appState.hasPermission(.screenRecording),
                  ScreenCapture.canPublishCapture(from: screenCaptureGeneration),
                  capturePermissionGeneration == permissionGeneration
            else {
                return
            }
            if !captureResult.excluded.isEmpty {
                logger.error("Item capture failed count=\(captureResult.excluded.count, privacy: .public)")
            }
            let sectionImages = captureResult.images

            guard !sectionImages.isEmpty else {
                logger.warning("Failed item image cache for \(section.logString, privacy: .public)")
                continue
            }

            newImages.merge(sectionImages) { _, new in new }
        }

        let validIDs = Set(appState.itemManager.itemCache.managedItems.map(\.stableID))

        var updatedImages = images.filter { validIDs.contains($0.key) }
        updatedImages.merge(newImages) { _, new in new }
        guard appState.hasPermission(.screenRecording),
              ScreenCapture.canPublishCapture(from: screenCaptureGeneration),
              capturePermissionGeneration == permissionGeneration
        else {
            return
        }
        images = updatedImages
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        let isBarlineShelfPresented = appState.navigationState.isBarlineShelfPresented
        let isSearchPresented = appState.navigationState.isSearchPresented

        if !isBarlineShelfPresented, !isSearchPresented {
            guard
                appState.navigationState.isAppFrontmost,
                appState.navigationState.isSettingsPresented,
                appState.navigationState.settingsNavigationIdentifier == .menuBarLayout
            else {
                return
            }
        }

        guard !appState.itemManager.lastMoveOperationOccurred(within: .seconds(1)) else {
            logger.debug("Skipping item image cache due to recent item movement")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isBarlineShelfPresented = appState.navigationState.isBarlineShelfPresented
        let isSearchPresented = appState.navigationState.isSearchPresented
        let isSettingsPresented = appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()

        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isBarlineShelfPresented,
            let section = appState.menuBarManager.barlineShelfPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }

    // MARK: Cache Failed

    /// Returns a Boolean value that indicates whether caching menu bar items
    /// failed for the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        if #available(macOS 27.0, *) {
            return false
        }
        guard ScreenCapture.cachedCheckPermissions() else {
            return true
        }
        guard let appState else {
            return false
        }
        let items: [MenuBarItem] = if
            let displayID = appState.itemManager.itemCache.displayID,
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        {
            appState.itemManager.itemsForBarlineShelf(in: section, on: screen)
        } else {
            appState.itemManager.itemCache[section]
        }
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        return items.contains { !keys.contains($0.stableID) }
    }
}
