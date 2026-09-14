import AppKit
import BarlineCore
import CoreGraphics
import CryptoKit
import Foundation
import os

/// The only shipping type that translates private WindowServer identifiers
/// into stable Barline domain identities.
final class WindowServerClient: @unchecked Sendable {
    typealias ConnectionID = Int32
    typealias SpaceID = Int

    private typealias MainConnectionFunction = @convention(c) () -> ConnectionID
    private typealias WindowCountFunction = @convention(c) (
        ConnectionID,
        ConnectionID,
        UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias WindowListFunction = @convention(c) (
        ConnectionID,
        ConnectionID,
        Int32,
        UnsafeMutablePointer<CGWindowID>,
        UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias WindowLevelFunction = @convention(c) (
        ConnectionID,
        CGWindowID,
        UnsafeMutablePointer<CGWindowLevel>
    ) -> Int32
    private typealias ActiveSpaceFunction = @convention(c) (ConnectionID) -> SpaceID
    private typealias WindowDisplayFunction = @convention(c) (
        ConnectionID, CGWindowID
    ) -> Unmanaged<CFString>?

    private struct GenerationState {
        var value: UInt64 = 0
    }

    private struct RevealObservation {
        let sourcePID: pid_t
        let preexistingWindowIDs: Set<CGWindowID>
        var interfaceWindowID: CGWindowID?
    }

    private struct IdentityRecord {
        let ownerPID: pid_t
        let id: MenuBarItemID
        var lastSeen: Date
    }

    private let resolver: DynamicSymbolResolver
    private let logger = Logger(category: "WindowServerClient")
    private let generation = OSAllocatedUnfairLock(initialState: GenerationState())
    // Window numbers are ephemeral helper-private lookup keys, never domain IDs.
    private let identities = OSAllocatedUnfairLock(initialState: [CGWindowID: IdentityRecord]())
    private let synthesisInProgress = OSAllocatedUnfairLock(initialState: false)
    private let revealObservations = OSAllocatedUnfairLock(
        initialState: [MenuBarRevealObservationToken: RevealObservation]()
    )

    init(resolver: DynamicSymbolResolver = DynamicSymbolResolver()) {
        self.resolver = resolver
    }

    var canEnumerate: Bool {
        Self.snapshotSymbols.allSatisfy(resolver.contains)
    }

    var canInterpretActiveSpace: Bool {
        resolver.contains("CGSMainConnectionID") && resolver.contains("CGSGetActiveSpace")
    }

    func behavioralProbe() -> Bool {
        guard canEnumerate else {
            return false
        }
        // A single composite menu-bar window is the macOS 27 compatibility
        // break, not a viable per-item inventory.
        return (enumerateMenuBarWindows()?.count ?? 0) > 1
    }

    @available(macOS 27.0, *)
    func goldenGateBehavioralProbe() -> Bool {
        guard let observations = try? GoldenGateAXInventory.collect() else {
            return false
        }
        return !observations.isEmpty
    }

    func eventSynthesisProbe() -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: .left
            ) != nil,
            CGEventField(rawValue: 0x33) != nil
        else {
            return false
        }
        return true
    }

    func snapshot() throws -> MenuBarSnapshot {
        guard let windows = enumerateMenuBarWindows() else {
            throw MenuBarBackendError.unavailableCapability("menu bar snapshot")
        }

        let displayIdentities = NSScreen.screens.compactMap { screen -> MenuBarDisplayIdentity? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return MenuBarDisplayIdentity(
                runtimeID: stableDisplayID(displayID),
                hardwareFingerprint: hardwareFingerprint(for: displayID)
            )
        }
        let displayIDs = Set(displayIdentities.map(\.runtimeID))

        let classified = classifiedWindows(windows)
        let identifiers = identifiedWindows(windows)
        let descriptors = windows.enumerated().map { index, window in
            let itemID = identifiers[index].id
            let sourcePID = sourcePID(for: window)
            let application = sourceApplication(for: window, sourcePID: sourcePID)
            let ownership: MenuBarSourceOwnership = if let bundleID = application?.bundleIdentifier {
                bundleID.hasPrefix("com.apple.") ? .system : .application
            } else {
                .unknown
            }
            let tagNamespace = tagNamespace(
                for: window,
                sourceApplication: application
            )
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isControlItem = tagNamespace.caseInsensitiveCompare(
                "com.mabryventures.Barline"
            ) == .orderedSame
            let semanticFlags = semanticFlags(
                namespace: tagNamespace,
                title: title ?? "",
                isControlItem: isControlItem
            )
            return MenuBarItemDescriptor(
                id: itemID,
                section: classified[index].section,
                order: index,
                displayID: displayID(for: window),
                isSystemItem: ownership == .system,
                sourceOwnership: ownership,
                isBarlineControlItem: isControlItem,
                tagNamespace: tagNamespace,
                title: title,
                displayName: displayName(
                    for: window,
                    application: application,
                    isControlItem: isControlItem
                ),
                ownerProcessIdentifier: window.ownerPID,
                sourceProcessIdentifier: sourcePID,
                bounds: MenuBarRect(
                    x: window.bounds.origin.x,
                    y: window.bounds.origin.y,
                    width: window.bounds.width,
                    height: window.bounds.height
                ),
                isOnScreen: window.isOnScreen,
                isMovable: semanticFlags.isMovable,
                canBeHidden: semanticFlags.canBeHidden,
                isBentoBox: semanticFlags.isBentoBox,
                isSystemClone: semanticFlags.isSystemClone,
                isResponsive: !Bridging.isProcessUnresponsive(
                    sourcePID ?? window.ownerPID
                )
            )
        }

        let nextGeneration = generation.withLock { state in
            state.value &+= 1
            return state.value
        }

        return MenuBarSnapshot(
            generation: nextGeneration,
            capturedAt: Date(),
            items: descriptors,
            displayIDs: displayIDs,
            displayIdentities: displayIdentities,
            activeSpaceIsValid: activeSpaceID() != nil,
            menuTrackingIsActive: menuTrackingIsActive(menuBarWindows: windows)
        )
    }

    @available(macOS 27.0, *)
    func goldenGateSnapshot() throws -> MenuBarSnapshot {
        let observations = try GoldenGateAXInventory.collect()
        let activeDisplays = activeDisplayIDs()
        let displayIdentities = activeDisplays.map { displayID in
            MenuBarDisplayIdentity(
                runtimeID: stableDisplayID(displayID),
                hardwareFingerprint: hardwareFingerprint(for: displayID)
            )
        }
        let displayIDs = Set(displayIdentities.map(\.runtimeID))
        guard let activeDisplayID = Bridging.getActiveMenuBarDisplayID(),
              activeDisplays.contains(activeDisplayID)
        else {
            throw MenuBarBackendError.unavailableCapability("active menu bar display")
        }
        let activeStableDisplayID = stableDisplayID(activeDisplayID)
        let activeDisplayBounds = CGDisplayBounds(activeDisplayID)
        let appSigningIdentifier = Bundle.main.object(
            forInfoDictionaryKey: "BarlineAppSigningIdentifier"
        ) as? String ?? "com.mabryventures.Barline"

        var occurrenceBySemanticKey = [String: Int]()
        let preliminary = observations.enumerated().map { order, observation in
            let semanticKey = "\(observation.bundleIdentifier.lowercased())|\(observation.stableTitle.lowercased())"
            let occurrence = occurrenceBySemanticKey[semanticKey, default: 0]
            occurrenceBySemanticKey[semanticKey] = occurrence + 1
            let isControlItem = observation.bundleIdentifier.caseInsensitiveCompare(
                appSigningIdentifier
            ) == .orderedSame && observation.stableTitle.hasPrefix("Barline.ControlItem.")
            let ownership: MenuBarSourceOwnership = observation.bundleIdentifier.hasPrefix(
                "com.apple."
            ) ? .system : .application
            let semantics = semanticFlags(
                namespace: observation.bundleIdentifier,
                title: observation.stableTitle,
                isControlItem: isControlItem
            )
            let itemID = MenuBarItemID(
                bundleIdentifier: observation.bundleIdentifier,
                accessibilityIdentifier: observation.identifier,
                title: observation.stableTitle,
                alias: "occurrence-\(occurrence)",
                fallbackFingerprint: GoldenGateAXInventory.fallbackFingerprint(
                    bundleIdentifier: observation.bundleIdentifier,
                    stableTitle: observation.stableTitle
                )
            )
            return MenuBarItemDescriptor(
                id: itemID,
                section: .visible,
                order: order,
                // AXExtrasMenuBar describes the active menu bar. Hidden items
                // intentionally have off-screen geometry, so assigning them by
                // rectangle can attach them to the wrong adjacent display.
                // Bind the entire inventory to the display whose menu bar is
                // active for this atomic snapshot.
                displayID: activeStableDisplayID,
                isSystemItem: ownership == .system,
                sourceOwnership: ownership,
                isBarlineControlItem: isControlItem,
                tagNamespace: isControlItem
                    ? appSigningIdentifier
                    : observation.bundleIdentifier,
                title: observation.stableTitle,
                displayName: observation.localizedApplicationName
                    ?? observation.displayTitle,
                ownerProcessIdentifier: observation.ownerPID,
                sourceProcessIdentifier: observation.ownerPID,
                bounds: MenuBarRect(
                    x: observation.bounds.minX,
                    y: observation.bounds.minY,
                    width: observation.bounds.width,
                    height: observation.bounds.height
                ),
                isOnScreen: activeDisplayBounds.intersects(observation.bounds),
                // macOS 27 inventory is currently read-only. Keep the item's
                // semantic hideability so the app-side cache can classify it,
                // but do not enable drag-based mutations until they have an
                // auditable implementation with post-action verification and
                // rollback.
                isMovable: false,
                canBeHidden: semantics.canBeHidden,
                isBentoBox: semantics.isBentoBox,
                isSystemClone: semantics.isSystemClone,
                isResponsive: true
            )
        }

        let hiddenControl = preliminary.first {
            $0.isBarlineControlItem && $0.title == "Barline.ControlItem.Hidden"
        }
        let alwaysHiddenControl = preliminary.first {
            $0.isBarlineControlItem && $0.title == "Barline.ControlItem.AlwaysHidden"
        }
        logger.info(
            "Golden Gate snapshot inventory: items=\(preliminary.count, privacy: .public), controls=\(preliminary.count(where: \.isBarlineControlItem), privacy: .public)"
        )
        guard let hiddenControl else {
            // A sectionless inventory must never replace the last-known-good
            // snapshot. App-side discovery will retry this bounded failure and
            // retain its existing cache.
            throw MenuBarBackendError.unavailableCapability("Barline section controls")
        }
        let descriptors = try preliminary.map { descriptor in
            let section: MenuBarSection
            if descriptor.isBarlineControlItem {
                section = switch descriptor.title {
                case "Barline.ControlItem.AlwaysHidden": .alwaysHidden
                case "Barline.ControlItem.Hidden": .hidden
                default: .visible
                }
            } else {
                guard let classified = MenuBarDividerSectionClassifier.classify(
                    itemBounds: descriptor.bounds,
                    hiddenControlBounds: hiddenControl.bounds,
                    alwaysHiddenControlBounds: alwaysHiddenControl?.bounds
                ) else {
                    throw MenuBarBackendError.unavailableCapability(
                        "unambiguous Barline section geometry"
                    )
                }
                section = classified
            }
            return descriptor.replacingSection(section)
        }

        let nextGeneration = generation.withLock { state in
            state.value &+= 1
            return state.value
        }
        return MenuBarSnapshot(
            generation: nextGeneration,
            capturedAt: Date(),
            items: descriptors,
            displayIDs: displayIDs,
            displayIdentities: displayIdentities,
            activeSpaceIsValid: !displayIDs.isEmpty,
            menuTrackingIsActive: false
        )
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return []
        }
        return Array(displays.prefix(Int(count)))
    }

    func move(_ operation: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
        try beginMutation()
        defer { endMutation() }
        return try await moveWhileExclusive(operation)
    }

    private func moveWhileExclusive(_ operation: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
        let maximumAttempts = 8
        var lastOrigin: CGPoint?
        for attempt in 0 ..< maximumAttempts {
            try Task.checkCancellation()
            let windows = try currentWindows()
            let identified = identifiedWindows(windows)
            guard let sourceIndex = identified.firstIndex(where: { $0.id == operation.itemID }) else {
                throw MenuBarBackendError.staleItem(operation.itemID)
            }
            let item = identified[sourceIndex].window
            let classified = classifiedWindows(windows)
            let candidateIndices = classified.indices.filter {
                classified[$0].section == operation.section
            }
            guard !candidateIndices.isEmpty else {
                throw MenuBarBackendError.operationFailed("No destination item is available")
            }
            let requestedIndex = min(max(operation.index, 0), candidateIndices.count)
            let sourceDisplayID = displayID(for: item)
            var insertionIndex = requestedIndex
            let sourcePosition = candidateIndices.firstIndex(of: sourceIndex)
            if let sourcePosition,
               sourcePosition < insertionIndex
            {
                insertionIndex -= 1
            }
            let destinationIndices = candidateIndices.filter { $0 != sourceIndex }
            insertionIndex = min(max(insertionIndex, 0), destinationIndices.count)
            if classified[sourceIndex].section == operation.section,
               sourcePosition == insertionIndex,
               operation.destinationDisplayID.map({ sourceDisplayID == $0 }) != false
            {
                let updated = try snapshot()
                return MenuBarMutationResult(
                    generation: updated.generation,
                    changedItemIDs: []
                )
            }
            guard !destinationIndices.isEmpty else {
                throw MenuBarBackendError.operationFailed("No destination item is available")
            }
            let eligibleDestinations = destinationIndices.enumerated().filter { _, index in
                operation.destinationDisplayID.map {
                    displayID(for: classified[index].window) == $0
                } != false
            }
            guard !eligibleDestinations.isEmpty else {
                throw MenuBarBackendError.operationFailed(
                    "No destination item is available on the requested display"
                )
            }
            let targetIndex: Int
            let placement: MovePlacement
            if let following = eligibleDestinations.first(where: { offset, _ in
                offset >= insertionIndex
            }) {
                targetIndex = following.element
                placement = .left
            } else {
                targetIndex = eligibleDestinations[eligibleDestinations.count - 1].element
                placement = .right
            }
            let target = classified[targetIndex].window
            lastOrigin = item.bounds.origin
            try Task.checkCancellation()
            try await synthesizeMove(item: item, target: target, placement: placement)
            let delay = min(25 + (attempt * 20), 150)
            try await Task.sleep(for: .milliseconds(delay))
            let refreshed = try currentWindows()
            if let moved = identifiedWindows(refreshed)
                .first(where: { $0.id == operation.itemID })?.window,
                moved.bounds.origin != lastOrigin
            {
                break
            }
            if attempt == maximumAttempts - 1 {
                throw MenuBarBackendError.operationFailed("Menu bar item did not respond to move")
            }
        }
        let updated = try snapshot()
        return MenuBarMutationResult(generation: updated.generation, changedItemIDs: [operation.itemID])
    }

    func reveal(_ itemID: MenuBarItemID) async throws -> MenuBarMutationResult {
        let windows = try currentWindows()
        guard identifiedWindows(windows).contains(where: { $0.id == itemID }) else {
            throw MenuBarBackendError.staleItem(itemID)
        }
        let visibleCount = windows.count(where: \.isOnScreen)
        return try await move(MenuBarMoveOperation(itemID: itemID, section: .visible, index: visibleCount - 1))
    }

    func activate(_ itemID: MenuBarItemID, button: MenuBarMouseButton) async throws {
        try beginMutation()
        defer { endMutation() }
        let windows = try currentWindows()
        guard let item = identifiedWindows(windows).first(where: { $0.id == itemID })?.window else {
            throw MenuBarBackendError.staleItem(itemID)
        }
        guard item.isOnScreen else {
            throw MenuBarBackendError.operationFailed("Menu bar item must be revealed before activation")
        }
        try await synthesizeClick(item: item, pid: resolvedEventPID(for: item), button: button)
    }

    func capture(_ itemIDs: [MenuBarItemID]) throws -> [MenuBarCapturedImage] {
        guard !itemIDs.isEmpty, itemIDs.count <= 512 else {
            throw MenuBarBackendError.operationFailed("Invalid capture item count")
        }
        let windows = try currentWindows()
        let records = Dictionary(uniqueKeysWithValues: identifiedWindows(windows).map { ($0.id, $0.window) })
        return itemIDs.compactMap { itemID in
            guard
                let window = records[itemID],
                let data = WindowCaptureService.capturePNG(
                    windowIDs: [window.identifier],
                    screenBounds: nil,
                    options: CGWindowImageOption.boundsIgnoreFraming.rawValue |
                        CGWindowImageOption.bestResolution.rawValue
                )
            else {
                return nil
            }
            return MenuBarCapturedImage(
                itemID: itemID,
                pngData: data,
                bounds: MenuBarRect(
                    x: window.bounds.origin.x,
                    y: window.bounds.origin.y,
                    width: window.bounds.width,
                    height: window.bounds.height
                )
            )
        }
    }

    func captureBackground(
        displayID: UInt32,
        sampleHeight: Double?
    ) throws -> MenuBarBackgroundCapture {
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(displayID))
        guard
            let dictionaries = CGWindowListCopyWindowInfo(
                .optionOnScreenOnly,
                kCGNullWindowID
            ) as? [[CFString: Any]]
        else {
            throw MenuBarBackendError.unavailableCapability("window scene enumeration")
        }
        let windows = dictionaries.compactMap { WindowRecord($0) }
        guard let menuBar = windows.first(where: { window in
            window.ownerName == "Window Server" &&
                window.layer == kCGMainMenuWindowLevel &&
                window.title == "Menubar" &&
                displayBounds.contains(window.bounds)
        }) else {
            throw MenuBarBackendError.operationFailed("No validated menu bar scene")
        }
        let wallpaper = windows.first { window in
            let application = NSRunningApplication(processIdentifier: window.ownerPID)
            return application?.bundleIdentifier == "com.apple.dock" &&
                window.title?.hasPrefix("Wallpaper") == true &&
                displayBounds.contains(window.bounds)
        }
        var captureBounds = menuBar.bounds
        if let sampleHeight {
            guard sampleHeight.isFinite, sampleHeight > 0 else {
                throw MenuBarBackendError.operationFailed("Invalid background sample height")
            }
            captureBounds.size.height = min(CGFloat(sampleHeight), menuBar.bounds.height)
        }
        let identifiers = [menuBar.identifier, wallpaper?.identifier].compactMap(\.self)
        let data = WindowCaptureService.capturePNG(
            windowIDs: identifiers,
            screenBounds: captureBounds,
            options: CGWindowImageOption.nominalResolution.rawValue
        )
        return MenuBarBackgroundCapture(
            displayID: displayID,
            menuBarBounds: MenuBarRect(
                x: menuBar.bounds.origin.x,
                y: menuBar.bounds.origin.y,
                width: menuBar.bounds.width,
                height: menuBar.bounds.height
            ),
            pngData: data
        )
    }

    func environment() -> MenuBarEnvironmentSnapshot {
        let activeSpace = Bridging.getActiveSpaceID()
        let activeDisplayID = Bridging.getActiveMenuBarDisplayID()
        return MenuBarEnvironmentSnapshot(
            activeDisplayID: activeDisplayID,
            activeStableDisplayID: activeDisplayID.map(stableDisplayID),
            activeSpaceToken: activeSpace,
            activeSpaceIsFullscreen: Bridging.isSpaceFullscreen(activeSpace)
        )
    }

    func pointContext(_ point: MenuBarPoint) throws -> MenuBarPointContext {
        let location = CGPoint(x: point.x, y: point.y)
        let isInsideItem = try currentWindows().contains { window in
            window.isOnScreen && window.bounds.contains(location) &&
                !MenuBarClickArbitrationPolicy.isLayoutSeparator(title: window.title)
        }
        let window = WindowInfo.createWindows(option: .onScreen)
            .filter { $0.layer < CGWindowLevelForKey(.cursorWindow) }
            .first { $0.bounds.contains(location) && $0.title?.isEmpty == false }
        let application = window?.owningApplication
        return MenuBarPointContext(
            isInsideMenuBarItem: isInsideItem,
            applicationBundleIdentifier: application?.bundleIdentifier,
            applicationIsActive: application?.isActive ?? false,
            applicationUsesRegularActivationPolicy: application?.activationPolicy == .regular
        )
    }

    static func shelfPresentationObservation(
        _ probe: MenuBarShelfPresentationProbe
    ) -> MenuBarShelfPresentationObservation {
        let roleWindows = WindowInfo.createWindows(option: .onScreen)
            .filter { $0.title == "Barline Bar" && $0.isOnScreen }
        let ownerWindows = roleWindows.filter {
            $0.ownerPID == probe.ownerProcessIdentifier
        }
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(probe.targetDisplayID))
        return MenuBarShelfPresentationObservation(
            roleIsPresentOnscreen: !roleWindows.isEmpty,
            ownerMatches: !ownerWindows.isEmpty,
            intersectsTargetDisplay: ownerWindows.contains {
                $0.bounds.intersection(displayBounds).width > 0 &&
                    $0.bounds.intersection(displayBounds).height > 0
            }
        )
    }

    func beginRevealObservation(_ itemID: MenuBarItemID) throws -> MenuBarRevealObservationToken {
        let menuBarWindows = try currentWindows()
        guard let item = identifiedWindows(menuBarWindows).first(where: { $0.id == itemID })?.window else {
            throw MenuBarBackendError.staleItem(itemID)
        }
        let pid = try resolvedEventPID(for: item)
        let existing = Set(WindowInfo.createWindows(option: .onScreen).map(\.windowID))
        let token = MenuBarRevealObservationToken()
        revealObservations.withLock { observations in
            observations[token] = RevealObservation(
                sourcePID: pid,
                preexistingWindowIDs: existing,
                interfaceWindowID: nil
            )
        }
        return token
    }

    func revealObservationIsVisible(_ token: MenuBarRevealObservationToken) -> Bool {
        let windows = WindowInfo.createWindows(option: .onScreen)
        return revealObservations.withLock { observations in
            guard var observation = observations[token] else { return false }
            if let interfaceWindowID = observation.interfaceWindowID {
                return windows.contains { $0.windowID == interfaceWindowID && $0.isOnScreen }
            }
            guard let interface = windows.first(where: { window in
                window.ownerPID == observation.sourcePID &&
                    !observation.preexistingWindowIDs.contains(window.windowID)
            }) else {
                return false
            }
            observation.interfaceWindowID = interface.windowID
            observations[token] = observation
            return true
        }
    }

    func endRevealObservation(_ token: MenuBarRevealObservationToken) {
        revealObservations.withLock { $0[token] = nil }
    }

    func restore(_ priorSnapshot: MenuBarSnapshot) async throws -> MenuBarMutationResult {
        try beginMutation()
        defer { endMutation() }
        guard priorSnapshot.items.count <= 256 else {
            throw MenuBarBackendError.operationFailed("restore plan exceeds the safe operation limit")
        }
        let live = try snapshot()
        let plan = try WorkspaceRecoveryPlanner.exactPlan(saved: priorSnapshot, live: live)
        let operations = plan.operations
        guard operations.count <= 256 else {
            throw MenuBarBackendError.operationFailed("restore plan exceeds the safe operation limit")
        }
        var changed = [MenuBarItemID]()
        for operation in operations {
            try Task.checkCancellation()
            // A process can add/remove an item between drags. Never continue a
            // stale plan simply because the next source identity still exists.
            let current = try snapshot()
            guard current.displayIDs == live.displayIDs,
                  Set(current.items.map(\.id)) == Set(live.items.map(\.id))
            else {
                throw WorkspaceRecoveryPlanner.Failure.incompleteInventory
            }
            _ = try await moveWhileExclusive(operation)
            changed.append(operation.itemID)
        }
        try Task.checkCancellation()
        let updated = try snapshot()
        guard plan.matches(items: updated.items) else {
            throw WorkspaceRecoveryPlanner.Failure.exactTargetUnavailable
        }
        return MenuBarMutationResult(generation: updated.generation, changedItemIDs: changed)
    }

    private func enumerateMenuBarWindows() -> [WindowRecord]? {
        guard
            let mainConnection = resolver.resolve("CGSMainConnectionID", as: MainConnectionFunction.self),
            let getWindowCount = resolver.resolve("CGSGetWindowCount", as: WindowCountFunction.self),
            let getMenuBarList = resolver.resolve(
                "CGSGetProcessMenuBarWindowList",
                as: WindowListFunction.self
            )
        else {
            return nil
        }

        let connection = mainConnection()
        var count: Int32 = 0
        let maximumWindowCount: Int32 = 16384
        guard
            getWindowCount(connection, 0, &count) == 0,
            count > 0,
            count <= maximumWindowCount
        else {
            return []
        }

        let capacity = count
        var identifiers = [CGWindowID](repeating: 0, count: Int(capacity))
        guard
            getMenuBarList(connection, 0, capacity, &identifiers, &count) == 0,
            count >= 0,
            count <= capacity
        else {
            return nil
        }
        identifiers.removeSubrange(Int(count) ..< identifiers.count)
        if let activeSpaceID = activeSpaceID() {
            identifiers = identifiers.filter {
                Bridging.isWindowOnSpace($0, activeSpaceID)
            }
        }
        identifiers = identifiers.filter {
            windowLevel(for: $0) != kCGMainMenuWindowLevel
        }

        guard
            // CGS returns process menu bar windows from right to left. Ice
            // reverses the identifiers before assigning section-relative
            // indices; the typed move contract uses that left-to-right order.
            let array = Self.createWindowArray(Array(identifiers.reversed())),
            let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]]
        else {
            return []
        }

        guard let displayBounds = activeDisplayBounds() else { return nil }
        return descriptions.compactMap { WindowRecord($0, activeDisplayBounds: displayBounds) }
    }

    private func activeDisplayBounds() -> [MenuBarRect]? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &count) == .success,
              count > 0, count < displayIDs.count else { return nil }
        return displayIDs.prefix(Int(count)).map { identifier in
            let rect = CGDisplayBounds(identifier)
            return MenuBarRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
    }

    private func currentWindows() throws -> [WindowRecord] {
        guard let windows = enumerateMenuBarWindows() else {
            throw MenuBarBackendError.unavailableCapability("menu bar enumeration")
        }
        return windows
    }

    private func stableID(for window: WindowRecord) -> MenuBarItemID {
        let host = NSRunningApplication(processIdentifier: window.ownerPID)
        // A hosted window's semantic host/title identity must not change when
        // AX resolves its actual source later. Ownership is separate metadata.
        let bundleIdentifier: String = if Self.barlineControlTitles.contains(window.title ?? "") {
            "com.mabryventures.Barline"
        } else if isHosted(window) {
            "barline.hosted-menu-item"
        } else {
            host?.bundleIdentifier ?? window.ownerName ?? "unknown.window-owner"
        }
        let stableTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = [
            window.ownerName ?? "unknown",
            stableTitle ?? "untitled",
            String(window.layer),
        ].joined(separator: ":")
        return MenuBarItemID(
            bundleIdentifier: bundleIdentifier,
            title: stableTitle,
            fallbackFingerprint: fingerprint
        )
    }

    private func identifiedWindows(
        _ windows: [WindowRecord]
    ) -> [(window: WindowRecord, id: MenuBarItemID)] {
        let baseIDs = windows.map(stableID)
        let totals = Dictionary(grouping: baseIDs, by: { $0 }).mapValues(\.count)
        return identities.withLock { records in
            let now = Date()
            let liveIDs = Set(windows.map(\.identifier))
            // An empty/incomplete census is not proof that old windows died.
            // Retain aliases across transient omissions. Bound stale records
            // only after ten minutes without sighting and confirmed window loss.
            if !windows.isEmpty {
                records = records.filter { identifier, record in
                    liveIDs.contains(identifier) || now.timeIntervalSince(record.lastSeen) < 600 ||
                        WindowInfo(windowID: identifier) != nil
                }
            }
            // Reserve existing aliases first; reordering equal-title items must
            // not swap their identity, and one disappearing must not rename another.
            var reserved = Set(records.values.map(\.id))
            return zip(windows, baseIDs).map { window, baseID in
                if var record = records[window.identifier], record.ownerPID == window.ownerPID {
                    // Dynamic titles update descriptor metadata, not identity.
                    record.lastSeen = now
                    records[window.identifier] = record
                    return (window, record.id)
                }
                var identifier = baseID
                if totals[baseID, default: 0] > 1 || reserved.contains(identifier) {
                    var occurrence = 0
                    repeat {
                        identifier = MenuBarItemID(
                            bundleIdentifier: baseID.bundleIdentifier,
                            accessibilityIdentifier: baseID.accessibilityIdentifier,
                            title: baseID.title,
                            alias: "occurrence-\(occurrence)",
                            fallbackFingerprint: baseID.fallbackFingerprint
                        )
                        occurrence += 1
                    } while reserved.contains(identifier)
                }
                reserved.insert(identifier)
                records[window.identifier] = IdentityRecord(
                    ownerPID: window.ownerPID, id: identifier, lastSeen: now
                )
                return (window, identifier)
            }
        }
    }

    private func isHosted(_ window: WindowRecord) -> Bool {
        NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier?
            .caseInsensitiveCompare("com.apple.controlcenter") == .orderedSame
    }

    private func sourceApplication(for window: WindowRecord, sourcePID: pid_t?) -> NSRunningApplication? {
        if let sourcePID {
            return NSRunningApplication(processIdentifier: sourcePID)
        }
        return isHosted(window) ? nil : NSRunningApplication(processIdentifier: window.ownerPID)
    }

    private func beginMutation() throws {
        let acquired = synthesisInProgress.withLock { active in
            guard !active else { return false }
            active = true
            return true
        }
        guard acquired else {
            throw MenuBarBackendError.operationFailed("Another menu operation is in progress")
        }
    }

    private func endMutation() {
        synthesisInProgress.withLock { $0 = false }
    }

    /// Observe native menu windows, accessibility popover roles, and custom
    /// interfaces opened during a reveal. Barline's own shelf is not a menu.
    /// Unknown scene state defers work rather than closing the user's interface.
    private func menuTrackingIsActive(menuBarWindows: [WindowRecord]) -> Bool {
        guard let dictionaries = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return MenuBarTrackingPolicy.blocksMutation(
                sceneIsAvailable: false, nativeMenuIsVisible: false, sourceInterfaceIsVisible: false
            )
        }
        let windows = dictionaries.compactMap { WindowRecord($0) }
        let itemWindowIDs = Set(menuBarWindows.map(\.identifier))
        let interfaces = windows.filter { window in
            guard !itemWindowIDs.contains(window.identifier),
                  window.bounds.width > 0, window.bounds.height > 0
            else { return false }
            let bundleID = NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier
            // Only exempt our known presentation role, not our context menus.
            return !(bundleID?.caseInsensitiveCompare("com.mabryventures.Barline") == .orderedSame &&
                window.title == "Barline Bar")
        }
        let nativeMenu = interfaces.contains { $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
        let trackedInterface = revealObservations.withLock { observations in
            observations.values.contains { observation in
                interfaces.contains { window in
                    if let identifier = observation.interfaceWindowID {
                        return identifier == window.identifier
                    }
                    return window.ownerPID == observation.sourcePID &&
                        !observation.preexistingWindowIDs.contains(window.identifier)
                }
            }
        }
        return MenuBarTrackingPolicy.blocksMutation(
            sceneIsAvailable: true,
            nativeMenuIsVisible: nativeMenu,
            sourceInterfaceIsVisible: focusedTransientInterfaceIsVisible() || trackedInterface
        )
    }

    private func focusedTransientInterfaceIsVisible() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        var element = unsafeDowncast(focused, to: AXUIElement.self)
        for _ in 0 ..< 6 {
            AXUIElementSetMessagingTimeout(element, 0.05)
            var role: CFTypeRef?
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if MenuBarTrackingPolicy.isTransientInterface(role: role as? String, subrole: subrole as? String) {
                return true
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return false }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }

    private func requireSafeMenuTracking() throws {
        guard try !menuTrackingIsActive(menuBarWindows: currentWindows()) else {
            throw MenuBarBackendError.unsafeMenuTracking
        }
    }

    private func classifiedWindows(
        _ windows: [WindowRecord]
    ) -> [(window: WindowRecord, section: MenuBarSection)] {
        let hidden = windows.first { $0.title == "Barline.ControlItem.Hidden" }
        let alwaysHidden = windows.first { $0.title == "Barline.ControlItem.AlwaysHidden" }
        return windows.map { window in
            let section: MenuBarSection = switch window.title {
            case "Barline.ControlItem.AlwaysHidden": .alwaysHidden
            case "Barline.ControlItem.Hidden": .hidden
            case "Barline.ControlItem.Visible": .visible
            default:
                if let alwaysHidden, window.bounds.maxX <= alwaysHidden.bounds.minX {
                    .alwaysHidden
                } else if let hidden, window.bounds.maxX <= hidden.bounds.minX {
                    .hidden
                } else {
                    .visible
                }
            }
            return (window, section)
        }
    }

    private func sourcePID(for window: WindowRecord) -> pid_t? {
        WindowInfo(windowID: window.identifier)
            .flatMap { SourcePIDCache.shared.pid(for: $0) }
    }

    private func resolvedEventPID(for window: WindowRecord) throws -> pid_t {
        if let info = WindowInfo(windowID: window.identifier),
           let sourcePID = SourcePIDCache.shared.pid(for: info, retryFailedLookup: true)
        {
            return sourcePID
        }
        guard !isHosted(window) else {
            // Posting to Control Center when the real app is unknown can target
            // the wrong interface. A user retry may refresh the negative AX cache.
            throw MenuBarBackendError.unavailableCapability(
                MenuBarBackendCapabilityReason.sourceApplicationResolution
            )
        }
        return window.ownerPID
    }

    private func tagNamespace(
        for window: WindowRecord,
        sourceApplication: NSRunningApplication?
    ) -> String {
        if let title = window.title,
           Self.barlineControlTitles.contains(title)
        {
            return "com.mabryventures.Barline"
        }
        if let namespace = sourceApplication?.bundleIdentifier ?? sourceApplication?.localizedName {
            return namespace
        }
        return window.ownerName ?? "unknown.window-owner"
    }

    private func displayName(
        for window: WindowRecord,
        application: NSRunningApplication?,
        isControlItem: Bool
    ) -> String {
        if isControlItem {
            return "Barline"
        }
        let sourceName = application?.localizedName ?? application?.bundleIdentifier
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            return title
        }
        return sourceName ?? "Menu Bar Item"
    }

    private func semanticFlags(
        namespace: String,
        title: String,
        isControlItem _: Bool
    ) -> (isMovable: Bool, canBeHidden: Bool, isBentoBox: Bool, isSystemClone: Bool) {
        let normalizedNamespace = namespace.lowercased()
        let isControlCenter = normalizedNamespace == "com.apple.controlcenter"
        let isBentoBox = isControlCenter && title.hasPrefix("BentoBox")
        let isClock = isControlCenter && title == "Clock"
        let isSystemClone = title == "System Status Item Clone" &&
            !normalizedNamespace.hasPrefix("com.apple.")
        let isImmovable = isClock || isBentoBox
        let explicitlyNonHideable = isControlCenter && [
            "AudioVideoModule",
            "FaceTime",
        ].contains(title) || (
            title == "Item-0" && [
                "com.apple.controlcenter",
                "com.apple.screencaptureui",
            ].contains(normalizedNamespace)
        )
        return (
            isMovable: !isImmovable,
            canBeHidden: !isImmovable && !explicitlyNonHideable,
            isBentoBox: isBentoBox,
            isSystemClone: isSystemClone
        )
    }

    private func synthesizeClick(
        item: WindowRecord,
        pid: pid_t,
        button: MenuBarMouseButton
    ) async throws {
        try Task.checkCancellation()
        try requireSafeMenuTracking()
        let mouseButton: CGMouseButton = switch button {
        case .left: .left
        case .right: .right
        case .other: .center
        }
        let downType: CGEventType = switch button {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .other: .otherMouseDown
        }
        let upType: CGEventType = switch button {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .other: .otherMouseUp
        }
        // Re-read geometry after source-PID resolution. A hosted window can
        // retain kCGWindowIsOnscreen while physically outside every display.
        // Never synthesize a click there, even if an older snapshot allowed it.
        guard let bounds = WindowInfo(windowID: item.identifier)?.currentBounds(),
              let displays = activeDisplayBounds(),
              MenuBarVisibilityPolicy.isClickable(
                  reportedVisible: item.isOnScreen,
                  itemBounds: MenuBarRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                  displayBounds: displays
              )
        else {
            throw MenuBarBackendError.operationFailed("Menu bar item is outside the active displays")
        }
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton),
            let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton)
        else {
            throw MenuBarBackendError.unavailableCapability("menu bar event synthesis")
        }
        let cursorLocation = CGEvent(source: nil)?.location
        let cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        defer {
            if let cursorLocation {
                CGWarpMouseCursorPosition(cursorLocation)
            }
            if cursorHidden {
                CGDisplayShowCursor(CGMainDisplayID())
            }
        }
        permitLocalEvents()
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(item.identifier))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(item.identifier))
            event.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1 ... Int64.max))
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 0)
        do {
            try await deliverClick(down, to: pid)
            try await deliverClick(up, to: pid)
            // The compatibility baseline releases twice to clear hosted
            // status-item tracking state. This is the same up event, not a
            // second down/up gesture. Target receipts must still show exactly
            // one activation; transport acknowledgements cannot establish it.
            try await deliverClick(up, to: pid)
        } catch {
            // Release a partially delivered press even after cancellation. Do
            // not replay mouse-down: a second click could toggle the menu shut.
            up.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            throw error
        }
        try Task.checkCancellation()
    }

    /// Hosted status items need WindowServer's session routing. A direct PID
    /// post can reach a passive process tap without dispatching the status item.
    /// Post once per delivery through the session, never replay it to a PID.
    /// The caller deliberately delivers the release twice, as the baseline does.
    /// Receipt is transport evidence only; activation still needs observation.
    private func deliverClick(_ event: CGEvent, to pid: pid_t) async throws {
        let delivery = HelperEventDelivery()
        guard let entry = CGEvent(source: nil), let exit = CGEvent(source: nil) else {
            throw MenuBarBackendError.unavailableCapability("click ordering barrier")
        }
        entry.type = .null
        exit.type = .null
        let marker = Int64.random(in: 1 ..< Int64.max)
        entry.setIntegerValueField(.eventSourceUserData, value: marker)
        exit.setIntegerValueField(.eventSourceUserData, value: -marker)
        // Null signals order the source queue around session dispatch. They
        // are not clicks and never trigger another real mouse-down.
        let barrierTap = HelperEventTap(
            type: .null, location: .process(pid),
            placement: .headInsertEventTap, options: .defaultTap
        ) { _, received in
            switch received.getIntegerValueField(.eventSourceUserData) {
            case marker:
                delivery.dispatchOnceWhilePending { event.post(tap: .cgSessionEventTap) }
                return nil
            case -marker:
                delivery.finish()
                return nil
            default: break
            }
            return received
        }
        let sessionTap = HelperEventTap(
            type: event.type,
            location: .session,
            placement: .tailAppendEventTap,
            options: .listenOnly
        ) { tap, received in
            // Retain baseline source routing before acknowledging the session
            // event. An exit marker alone does not prove target consumption.
            if HelperClickRouting.restoreTarget(of: received, matching: event, to: pid) {
                tap.disable()
                exit.postToPid(pid)
            }
            return received
        }
        do {
            try await delivery.run(taps: [barrierTap, sessionTap], timeout: .milliseconds(500)) {
                entry.postToPid(pid)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MenuBarBackendError.operationFailed("Menu bar click delivery was not acknowledged")
        }
    }

    private enum MovePlacement {
        case left
        case right
    }

    private func synthesizeMove(
        item: WindowRecord,
        target: WindowRecord,
        placement: MovePlacement
    ) async throws {
        try Task.checkCancellation()
        try requireSafeMenuTracking()
        var start: CGPoint
        var end: CGPoint
        switch placement {
        case .left:
            start = CGPoint(x: target.bounds.minX, y: target.bounds.minY)
            end = start
            if item.bounds.maxX <= target.bounds.minX {
                end.x -= item.bounds.width
            } else {
                start.x -= 1
            }
        case .right:
            start = CGPoint(x: target.bounds.maxX, y: target.bounds.minY)
            end = start
            if item.bounds.minX <= target.bounds.maxX {
                end.x -= item.bounds.width
            } else {
                start.x += 1
            }
        }
        let pid = try resolvedEventPID(for: item)
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left),
            let windowField = CGEventField(rawValue: 0x33)
        else {
            throw MenuBarBackendError.unavailableCapability(MenuBarBackendCapabilityReason.dragSynthesis)
        }
        down.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1 ... Int64.max))
        up.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1 ... Int64.max))
        let cursorLocation = CGEvent(source: nil)?.location
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let cursorLocation {
                CGWarpMouseCursorPosition(cursorLocation)
            }
            CGDisplayShowCursor(CGMainDisplayID())
        }
        permitLocalEvents()
        for (event, identifier) in [(down, item.identifier), (up, target.identifier)] {
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(identifier))
            event.setIntegerValueField(
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                value: Int64(identifier)
            )
            event.setIntegerValueField(windowField, value: Int64(identifier))
        }

        let initialOrigin = item.bounds.origin
        do {
            try await deliver(down, to: pid)
            // Hosted items can commit their first geometry change only on
            // release. A missing intermediate transition is not a failed move.
            try await HelperMoveSettlement.releaseAndObserve(initialOrigin: initialOrigin) { [self] origin in
                try await waitForOriginChange(
                    of: item.identifier,
                    from: origin,
                    timeout: .milliseconds(200)
                )
            } release: { [self] in
                try await deliver(up, to: pid)
                try await deliver(up, to: pid)
            }
            // The outer move loop and coordinator verify final placement;
            // neither intermediate nor second geometry transitions prove it.
        } catch {
            // Always complete mouse-up after a successful or partially
            // successful mouse-down so the item cannot remain grabbed.
            let cleanup = Task.detached { [self] in
                try? await deliver(up, to: pid)
                try? await deliver(up, to: pid)
            }
            await cleanup.value
            throw error
        }
        try Task.checkCancellation()
    }

    private func waitForOriginChange(
        of identifier: CGWindowID,
        from origin: CGPoint,
        timeout: Duration
    ) async throws -> CGPoint? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let current = try currentWindows().first(where: { $0.identifier == identifier })?.bounds.origin,
               current != origin
            {
                return current
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    /// Routes a menu bar event through both the session and target-process
    /// event streams. A direct `postToPid` reaches the hosted status-item
    /// process on macOS 26 but does not trigger its movement behavior.
    private func deliver(_ event: CGEvent, to pid: pid_t) async throws {
        guard let entry = uniqueNullEvent(), let exit = uniqueNullEvent() else {
            throw MenuBarBackendError.unavailableCapability(MenuBarBackendCapabilityReason.eventDelivery)
        }
        let delivery = HelperEventDelivery()
        let fields: [CGEventField] = [
            .eventSourceUserData,
            .mouseEventWindowUnderMousePointer,
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            CGEventField(rawValue: 0x33)!, // swiftlint:disable:this force_unwrapping
        ]

        let processControlTap = HelperEventTap(
            type: .null,
            location: .process(pid),
            placement: .headInsertEventTap,
            // A passive control tap keeps the XPC service from needing its own
            // separate Accessibility grant. Null signals are harmless if they
            // continue through the target process's event stream.
            options: .listenOnly
        ) { _, received in
            if self.event(received, matches: entry, fields: [.eventSourceUserData]) {
                delivery.dispatchOnceWhilePending(stage: .session) {
                    event.post(tap: .cgSessionEventTap)
                }
                return nil
            }
            if self.event(received, matches: exit, fields: [.eventSourceUserData]) {
                delivery.finish()
                return nil
            }
            return received
        }
        let sessionTap = HelperEventTap(
            type: event.type,
            location: .session,
            placement: .tailAppendEventTap,
            options: .listenOnly
        ) { tap, received in
            guard self.event(received, matches: event, fields: fields) else {
                return received
            }
            tap.disable()
            delivery.dispatchOnceWhilePending(stage: .process) {
                event.postToPid(pid)
            }
            received.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            return received
        }
        let processEventTap = HelperEventTap(
            type: event.type,
            location: .process(pid),
            placement: .headInsertEventTap,
            options: .listenOnly
        ) { tap, received in
            guard self.event(received, matches: event, fields: fields) else {
                return received
            }
            tap.disable()
            exit.postToPid(pid)
            received.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            return received
        }

        do {
            try await delivery.run(
                taps: [processControlTap, sessionTap, processEventTap],
                timeout: .milliseconds(500)
            ) {
                entry.postToPid(pid)
            }
        } catch let HelperEventDelivery.DeliveryError.unavailable(stage) {
            let listenAllowed = CGPreflightListenEventAccess()
            let postAllowed = CGPreflightPostEventAccess()
            throw MenuBarBackendError.operationFailed(
                "Menu bar event delivery unavailable at stage \(stage) " +
                    "(listen: \(listenAllowed), post: \(postAllowed))"
            )
        } catch HelperEventDelivery.DeliveryError.timedOut {
            throw MenuBarBackendError.operationFailed("Menu bar event delivery timed out")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MenuBarBackendError.operationFailed("Menu bar event delivery failed")
        }
    }

    private func uniqueNullEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(
            .eventSourceUserData,
            value: Int64.random(in: 1 ... Int64.max)
        )
        return event
    }

    private func event(
        _ lhs: CGEvent,
        matches rhs: CGEvent,
        fields: [CGEventField]
    ) -> Bool {
        fields.allSatisfy {
            lhs.getIntegerValueField($0) == rhs.getIntegerValueField($0)
        }
    }

    private func permitLocalEvents() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let mask: CGEventFilterMask = [
            .permitLocalMouseEvents,
            .permitLocalKeyboardEvents,
            .permitSystemDefinedEvents,
        ]
        source.setLocalEventsFilterDuringSuppressionState(
            mask,
            state: .eventSuppressionStateRemoteMouseDrag
        )
        source.setLocalEventsFilterDuringSuppressionState(
            mask,
            state: .eventSuppressionStateSuppressionInterval
        )
        source.localEventsSuppressionInterval = 0
    }

    private func windowLevel(for identifier: CGWindowID) -> CGWindowLevel? {
        guard
            let mainConnection = resolver.resolve("CGSMainConnectionID", as: MainConnectionFunction.self),
            let getWindowLevel = resolver.resolve("CGSGetWindowLevel", as: WindowLevelFunction.self)
        else {
            return nil
        }
        var level: CGWindowLevel = 0
        guard getWindowLevel(mainConnection(), identifier, &level) == 0 else {
            return nil
        }
        return level
    }

    private func activeSpaceID() -> SpaceID? {
        guard
            let mainConnection = resolver.resolve("CGSMainConnectionID", as: MainConnectionFunction.self),
            let getActiveSpace = resolver.resolve("CGSGetActiveSpace", as: ActiveSpaceFunction.self)
        else {
            return nil
        }
        let value = getActiveSpace(mainConnection())
        return value > 0 ? value : nil
    }

    private func displayID(for window: WindowRecord) -> MenuBarDisplayID? {
        let displays = NSScreen.screens.compactMap { screen -> (MenuBarDisplayID, MenuBarRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(displayID)
            return (stableDisplayID(displayID), MenuBarRect(
                x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height
            ))
        }
        // Hidden status items live outside physical display bounds. Their
        // WindowServer-managed display is ownership; geometric visibility is not.
        let membership: Set<MenuBarDisplayID>? = if let connection = resolver.resolve("CGSMainConnectionID", as: MainConnectionFunction.self),
                                                    let copyDisplay = resolver.resolve("CGSCopyManagedDisplayForWindow", as: WindowDisplayFunction.self)
        {
            if let display = copyDisplay(connection(), window.identifier)?.takeRetainedValue() {
                [MenuBarDisplayID(display as String)]
            } else {
                []
            }
        } else {
            nil
        }
        return MenuBarDisplayOwnershipPolicy.resolve(
            itemBounds: MenuBarRect(
                x: window.bounds.minX, y: window.bounds.minY,
                width: window.bounds.width, height: window.bounds.height
            ),
            displays: Dictionary(uniqueKeysWithValues: displays),
            membershipDisplayIDs: membership
        )
    }

    private func stableDisplayID(_ displayID: CGDirectDisplayID) -> MenuBarDisplayID {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return MenuBarDisplayID("display-\(displayID)")
        }
        return MenuBarDisplayID(CFUUIDCreateString(nil, unmanagedUUID.takeRetainedValue()) as String)
    }

    private func hardwareFingerprint(
        for displayID: CGDirectDisplayID
    ) -> MenuBarDisplayHardwareFingerprint? {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let unknownVendor: UInt32 = 0x756E_6B6E // `unkn`
        let genericProduct: UInt32 = 0x0717
        guard vendor != 0,
              vendor != unknownVendor,
              model != 0,
              model != genericProduct,
              serial != 0
        else { return nil }

        var payload = Data("com.mabryventures.Barline.display-fingerprint.v1\0".utf8)
        for component in [vendor, model, serial] {
            var bigEndian = component.bigEndian
            withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return MenuBarDisplayHardwareFingerprint("v1:\(digest)")
    }

    private static func createWindowArray(_ identifiers: [CGWindowID]) -> CFArray? {
        var pointers: [UnsafeRawPointer?] = identifiers.compactMap {
            UnsafeRawPointer(bitPattern: UInt($0))
        }
        guard !pointers.isEmpty else {
            return nil
        }
        return CFArrayCreate(nil, &pointers, pointers.count, nil)
    }

    private static let snapshotSymbols = [
        "CGSMainConnectionID",
        "CGSGetWindowCount",
        "CGSGetProcessMenuBarWindowList",
        "CGSGetWindowLevel",
        "CGSGetActiveSpace",
        "CGSCopySpacesForWindows",
    ]

    private static let barlineControlTitles: Set<String> = [
        "Barline.ControlItem.Visible",
        "Barline.ControlItem.Hidden",
        "Barline.ControlItem.AlwaysHidden",
    ]
}

private struct WindowRecord {
    let identifier: CGWindowID
    let ownerPID: pid_t
    let bounds: CGRect
    let layer: Int
    let title: String?
    let ownerName: String?
    let isOnScreen: Bool

    init?(_ dictionary: [CFString: Any], activeDisplayBounds: [MenuBarRect]? = nil) {
        guard
            let identifier = dictionary[kCGWindowNumber] as? CGWindowID,
            let ownerPID = dictionary[kCGWindowOwnerPID] as? pid_t,
            let boundsDictionary = dictionary[kCGWindowBounds] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
            let layer = dictionary[kCGWindowLayer] as? Int
        else {
            return nil
        }
        self.identifier = identifier
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        title = dictionary[kCGWindowName] as? String
        ownerName = dictionary[kCGWindowOwnerName] as? String
        let reportedVisible = dictionary[kCGWindowIsOnscreen] as? Bool ?? false
        if let activeDisplayBounds {
            // Only menu-item enumeration supplies geometry. Generic interface
            // observation retains its existing raw visibility semantics.
            isOnScreen = MenuBarVisibilityPolicy.isClickable(
                reportedVisible: reportedVisible,
                itemBounds: MenuBarRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                displayBounds: activeDisplayBounds
            )
        } else {
            isOnScreen = reportedVisible
        }
    }
}
