//
//  MenuBarItemManager.swift
//  Barline
//

import BarlineCore
import Cocoa
import Combine
import OSLog

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// The current cache of menu bar items.
    @Published private(set) var itemCache = ItemCache(displayID: nil)
    @Published private(set) var itemDiscoveryState = MenuBarItemDiscoveryState.idle

    @Published private(set) var activationNotice: String?
    @Published private(set) var isActivatingItem = false
    @Published private(set) var temporarilyRevealedItemIDs = Set<MenuBarItemID>()
    @Published private(set) var hasPendingRestorations = false
    @Published private(set) var recoveryRecordsUnavailable = false

    var allowsPickerPresentation: Bool {
        MenuBarPresentationPolicy.allowsPresentation(activating: isActivatingItem, restoring: isRestoringItems)
    }

    private var isRestoringItems = false
    private var visibleInterfaceTasks = [MenuBarRevealObservationToken: Task<Void, Never>]()
    private var goldenGateConcealmentSyncTask: Task<Void, Never>?

    deinit {
        goldenGateConcealmentSyncTask?.cancel()
        for task in visibleInterfaceTasks.values {
            task.cancel()
        }
    }

    /// Logger for the menu bar item manager.
    private nonisolated let logger = Logger.menuBarItemManager

    /// Semaphore to prevent overlapping event operations.
    private nonisolated let eventSemaphore = AsyncSemaphore(value: 1)

    /// Actor for managing menu bar item cache operations.
    private let cacheActor = CacheActor()

    /// Monotonically increasing identifier for cache requests.
    private var cacheRequestSequence: UInt64 = 0

    /// Synchronously reserves discovery before any MainActor suspension and
    /// bounds a lifecycle burst to one current pass plus one trailing pass.
    private var itemDiscoveryRefreshGate = MenuBarDiscoveryRefreshGate()

    /// Payload-free evidence for diagnosing OS-specific lifecycle churn.
    private(set) var itemDiscoveryDiagnostics = MenuBarItemDiscoveryDiagnostics()

    /// Cold launches can briefly observe the menu bar before AppKit has
    /// published Barline's control items. Retry that bounded race without
    /// turning item discovery into a polling loop.
    private let itemDiscoveryRetryPolicy = RetryPolicy(
        maximumAttempts: 4,
        baseDelay: .milliseconds(150),
        maximumDelay: .milliseconds(750),
        maximumJitterPermille: 0
    )

    /// Contexts for temporarily shown menu bar items.
    private var temporarilyShownItemContexts = [TemporarilyShownItemContext]()

    /// A timer for rehiding temporarily shown menu bar items.
    private var rehideTimer: Timer?

    /// Timestamp of the most recent menu bar item move operation.
    private var lastMoveOperationTimestamp: ContinuousClock.Instant?

    /// Cached timeouts for move operations.
    private var moveOperationTimeouts = [MenuBarItemTag: Duration]()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Sets up the manager.
    func performSetup(with appState: AppState) async {
        self.appState = appState
        do {
            let entries = try await appState.temporaryRevealJournal.load()
            let authority = await appState.compatibilityCoordinator.layoutAuthorityGeneration
            temporarilyShownItemContexts = entries.map {
                TemporarilyShownItemContext(entry: $0, tag: nil, authority: authority, paused: true)
            }
            updateRestorationPresentation()
            if !entries.isEmpty {
                activationNotice = "An interrupted item reveal needs review. Retry its restoration in Layouts & Focus."
            }
        } catch {
            recoveryRecordsUnavailable = true
            updateRestorationPresentation()
            activationNotice = "Item recovery records could not be read. Existing records have been preserved."
        }
        await cacheItemsRegardless()
        configureCancellables(with: appState)
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables(with appState: AppState) {
        var c = Set<AnyCancellable>()

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .discardMerge(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didWakeNotification
                )
            )
            .discardMerge(
                NotificationCenter.default.publisher(
                    for: NSApplication.didChangeScreenParametersNotification
                )
            )
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .debounce(for: 1, scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                // Refresh the native running-application allowlist immediately.
                // Discovery may transiently fail while a new app is still
                // publishing its status item; failing visible is safer than
                // withholding that app until another lifecycle event arrives.
                scheduleGoldenGateConcealmentSync()
                Task {
                    await self.cacheItemsIfNeeded(intent: .automatic)
                }
            }
            .store(in: &c)

        appState.navigationState.$settingsNavigationIdentifier
            .sink { [weak self] identifier in
                guard let self, identifier == .menuBarLayout else {
                    return
                }
                Task {
                    await self.cacheItemsRegardless(intent: .automatic)
                }
            }
            .store(in: &c)

        let controlItemWindows = appState.menuBarManager.sections
            .map(\.controlItem.$window)
            .map { $0.eraseToAnyPublisher() }
        Publishers.MergeMany(controlItemWindows)
            .compactMap(\.self)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsRegardless(intent: .automatic)
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether the most recent
    /// menu bar item move operation occurred within the given duration.
    func lastMoveOperationOccurred(within duration: Duration) -> Bool {
        guard let timestamp = lastMoveOperationTimestamp else {
            return false
        }
        return timestamp.duration(to: .now) <= duration
    }
}

// MARK: - Item Cache

extension MenuBarItemManager {
    private func beginDiscoveryRequest(
        intent: MenuBarDiscoveryRefreshIntent
    ) -> UInt64? {
        guard itemDiscoveryRefreshGate.begin(
            intent: intent,
            terminalFailureWithoutSnapshot:
            itemDiscoveryState == .failed && !itemDiscoveryState.hasUsableSnapshot
        ) else {
            itemDiscoveryDiagnostics.recordCoalescedAutomaticRequest()
            logger.debug("Coalescing automatic menu bar discovery refresh")
            return nil
        }

        // Reserve synchronously on MainActor before the first suspension point.
        // This closes the check-then-await race during AppKit event storms.
        cacheRequestSequence += 1
        itemDiscoveryDiagnostics.recordStartedRequest(intent: intent)
        return cacheRequestSequence
    }

    private func finishDiscoveryRequest(
        requestID: UInt64,
        allowsTrailingAutomaticRefresh: Bool
    ) {
        // A newer authoritative request owns the state after superseding this
        // one. Only the newest accepted request may clear or consume it.
        guard requestID == cacheRequestSequence else {
            return
        }

        let shouldRunTrailingRefresh = itemDiscoveryRefreshGate.finish(
            allowsTrailingAutomaticRefresh: allowsTrailingAutomaticRefresh,
            reachedUsableTerminalState: itemDiscoveryState != .failed
        )

        guard shouldRunTrailingRefresh else {
            return
        }
        Task { [weak self] in
            await self?.cacheItemsRegardless(
                intent: .automatic,
                allowsTrailingAutomaticRefresh: false
            )
        }
    }

    /// An actor that manages menu bar item cache operations.
    private final actor CacheActor {
        /// Stored task for the current cache operation.
        private var cacheTask: Task<Void, Never>?

        /// Identifier of the newest cache request accepted by this actor.
        private var currentRequestID: UInt64 = 0

        /// A list of the menu bar item window identifiers at the time
        /// of the previous cache.
        private(set) var cachedItemIDs = [MenuBarItemID]()

        /// Runs the given async closure as a task and waits for it to
        /// complete before returning.
        ///
        /// If a task from a previous call to this method is currently
        /// running, that task is cancelled and replaced.
        func runCacheTask(
            requestID: UInt64,
            operation: @escaping @MainActor @Sendable (UInt64) async -> Void
        ) async {
            // MainActor callers assign increasing IDs. Reject an older request
            // if actor scheduling ever delivers it after a newer one.
            guard requestID > currentRequestID else {
                return
            }
            currentRequestID = requestID
            cacheTask.take()?.cancel()
            let task = Task { @MainActor in
                await operation(requestID)
            }
            cacheTask = task
            await task.value
            if currentRequestID == requestID {
                cacheTask = nil
            }
        }

        /// Returns whether the given request still owns cache publication.
        func isCurrent(_ requestID: UInt64) -> Bool {
            requestID == currentRequestID && !Task.isCancelled
        }

        /// Updates the list of cached menu bar item window identifiers.
        @discardableResult
        func updateCachedItemIDs(
            _ itemIDs: [MenuBarItemID],
            for requestID: UInt64
        ) -> Bool {
            guard requestID == currentRequestID, !Task.isCancelled else {
                return false
            }
            cachedItemIDs = itemIDs
            return true
        }

        /// Clears the list of cached menu bar item window identifiers.
        @discardableResult
        func clearCachedItemIDs(for requestID: UInt64) -> Bool {
            guard requestID == currentRequestID, !Task.isCancelled else {
                return false
            }
            cachedItemIDs.removeAll()
            return true
        }
    }

    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// Hit testing includes system controls and clones that cannot be managed.
        fileprivate(set) var hitTestItems = [MenuBarItem]()
        /// Storage for cached menu bar items, keyed by section.
        private var storage = [MenuBarSection.Name: [MenuBarItem]]()

        /// The identifier of the display with the active menu bar at
        /// the time this cache was created.
        let displayID: CGDirectDisplayID?

        /// The cached menu bar items as an array.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                guard let items = storage[section] else {
                    return
                }
                result.append(contentsOf: items)
            }
        }

        /// Creates a cache with the given display identifier.
        init(displayID: CGDirectDisplayID?) {
            self.displayID = displayID
        }

        // TODO: This is redundant now, so remove it.
        /// Returns the managed menu bar items for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section]
        }

        /// Returns the address for the menu bar item with the given tag,
        /// if it exists in the cache.
        func address(for tag: MenuBarItemTag) -> (section: MenuBarSection.Name, index: Int)? {
            for (section, items) in storage {
                guard let index = items.firstIndex(matching: tag) else {
                    continue
                }
                return (section, index)
            }
            return nil
        }

        /// Inserts the given menu bar item into the cache at the specified
        /// destination.
        mutating func insert(_ item: MenuBarItem, at destination: MoveDestination) {
            let targetTag = destination.targetItem.tag

            if targetTag == .hiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.hidden].append(item)
                case .rightOfItem:
                    self[.visible].insert(item, at: 0)
                }
                return
            }

            if targetTag == .alwaysHiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.alwaysHidden].append(item)
                case .rightOfItem:
                    self[.hidden].insert(item, at: 0)
                }
                return
            }

            guard case (let section, var index)? = address(for: targetTag) else {
                return
            }

            if case .rightOfItem = destination {
                let range = self[section].startIndex ... self[section].endIndex
                index = (index + 1).clamped(to: range)
            }

            self[section].insert(item, at: index)
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { storage[section, default: []] }
            set { storage[section] = newValue }
        }
    }

    /// Returns the items to display for an Barline Bar section on the given screen.
    ///
    /// The system keeps items pushed behind a display notch in Barline's visible
    /// section, even though the user cannot see or click them. Include those
    /// items in the hidden Barline Bar without permanently changing their layout.
    func itemsForBarlineShelf(in section: MenuBarSection.Name, on screen: NSScreen) -> [MenuBarItem] {
        let allowedIDs = Set(MenuBarPresentationPolicy.shelfItemIDs(
            itemCache[section].map(\.stableID), temporarilyRevealed: temporarilyRevealedItemIDs
        ))
        let sectionItems = itemCache[section].filter { allowedIDs.contains($0.stableID) }

        guard section == .hidden else {
            return sectionItems
        }

        let visibleItems = itemCache[.visible]
        let excludedIndices = Set(visibleItems.indices.filter { visibleItems[$0].isControlItem })
        let itemBounds = visibleItems.map { Optional($0.bounds) }
        let obscuredIndices = NotchOverflowResolver.obscuredIndices(
            itemBounds: itemBounds,
            excluding: excludedIndices,
            screenBounds: CGDisplayBounds(screen.displayID),
            rightSafeArea: screen.auxiliaryTopRightArea
        )
        let existingItemIDs = Set(sectionItems.map(\.stableID))
        let obscuredItems = obscuredIndices
            .map { visibleItems[$0] }
            .filter { !existingItemIDs.contains($0.stableID) && !temporarilyRevealedItemIDs.contains($0.stableID) }

        return sectionItems + obscuredItems
    }

    /// A pair of control items, taken from a list of menu bar items
    /// during a menu bar item cache operation.
    private struct ControlItemPair {
        let hidden: MenuBarItem
        let alwaysHidden: MenuBarItem?

        init?(items: inout [MenuBarItem]) {
            guard let hidden = items.removeFirst(matching: .hiddenControlItem) else {
                return nil
            }
            self.hidden = hidden
            alwaysHidden = items.removeFirst(matching: .alwaysHiddenControlItem)
        }
    }

    /// Context maintained during a menu bar item cache operation.
    private struct CacheContext {
        let controlItems: ControlItemPair

        var cache: ItemCache
        var temporarilyShownItems = [(MenuBarItem, TemporaryRevealRestoration)]()
        var shouldClearCachedItemWindowIDs = false

        private(set) var hiddenControlItemBounds: CGRect
        private(set) var alwaysHiddenControlItemBounds: CGRect?

        init(controlItems: ControlItemPair, displayID: CGDirectDisplayID?) {
            self.controlItems = controlItems
            cache = ItemCache(displayID: displayID)
            hiddenControlItemBounds = Self.bestBounds(for: controlItems.hidden)
            alwaysHiddenControlItemBounds = controlItems.alwaysHidden.map(Self.bestBounds)
        }

        static func bestBounds(for item: MenuBarItem) -> CGRect {
            item.bounds
        }

        func isValidForCaching(_ item: MenuBarItem) -> Bool {
            if !item.canBeHidden {
                return false
            }
            if item.isSystemClone {
                return false
            }
            if item.isControlItem, item.tag != .visibleControlItem {
                return false
            }
            return true
        }

        mutating func findSection(for item: MenuBarItem) -> MenuBarSection.Name? {
            if #available(macOS 27.0, *) {
                return switch item.section {
                case .visible: .visible
                case .hidden: .hidden
                case .alwaysHidden: .alwaysHidden
                }
            }
            lazy var itemBounds = Self.bestBounds(for: item)
            return MenuBarSection.Name.allCases.first { section in
                switch section {
                case .visible:
                    itemBounds.minX >= hiddenControlItemBounds.maxX
                case .hidden:
                    if let alwaysHiddenControlItemBounds {
                        itemBounds.maxX <= hiddenControlItemBounds.minX &&
                            itemBounds.minX >= alwaysHiddenControlItemBounds.maxX
                    } else {
                        itemBounds.maxX <= hiddenControlItemBounds.minX
                    }
                case .alwaysHidden:
                    if let alwaysHiddenControlItemBounds {
                        itemBounds.maxX <= alwaysHiddenControlItemBounds.minX
                    } else {
                        false
                    }
                }
            }
        }
    }

    private enum CacheAttemptResult {
        case success
        case retryableFailure(MenuBarItemDiscoveryFailureCode)
        case cancelled
    }

    /// Caches the given menu bar items, without ensuring that the provided
    /// control items are correctly ordered.
    private func uncheckedCacheItems(
        items: [MenuBarItem],
        controlItems: ControlItemPair,
        displayID: CGDirectDisplayID?,
        requestID: UInt64
    ) async {
        guard
            await cacheActor.isCurrent(requestID),
            requestID == cacheRequestSequence
        else {
            return
        }

        var context = CacheContext(controlItems: controlItems, displayID: displayID)
        context.cache.hitTestItems = items

        for item in items where context.isValidForCaching(item) {
            if item.sourcePID == nil {
                logger.warning("Missing sourcePID for menu bar item")
                // A few status items do not expose an extras menu bar through
                // Accessibility and can never be mapped back to a source PID.
                // Invalidating the window-ID cache here creates a feedback
                // loop that repeats the expensive lookup on every refresh.
                // Keep the UUID-tagged item stable instead; SourcePIDCache
                // throttles negative lookups and retries after its TTL.
            }

            if let temp = temporarilyShownItemContexts.first(where: { $0.itemID == item.stableID }) {
                // Cache temporarily shown items as if they were in their original locations.
                // Keep track of them separately and use their return destinations to insert
                // them into the cache once all other items have been handled.
                context.temporarilyShownItems.append((item, temp.entry.checkpoint))
                continue
            }

            if let section = context.findSection(for: item) {
                context.cache[section].append(item)
                continue
            }

            logger.warning("Couldn't find section for caching menu bar item")
            context.shouldClearCachedItemWindowIDs = true
        }

        for (item, checkpoint) in context.temporarilyShownItems {
            let section: MenuBarSection.Name = switch checkpoint.originalSection {
            case .visible: .visible
            case .hidden: .hidden
            case .alwaysHidden: .alwaysHidden
            }
            let index = min(checkpoint.originalIndex, context.cache[section].count)
            context.cache[section].insert(item, at: index)
        }

        if context.shouldClearCachedItemWindowIDs {
            logger.info("Clearing cached menu bar item windowIDs")
            guard
                await cacheActor.clearCachedItemIDs(for: requestID),
                requestID == cacheRequestSequence
            else {
                return
            }
        }

        guard itemCache != context.cache else {
            logger.debug("Not updating menu bar item cache, as items haven't changed")
            scheduleGoldenGateConcealmentSync()
            return
        }

        itemCache = context.cache
        scheduleGoldenGateConcealmentSync()
        logger.debug("Updated menu bar item cache")
    }

    func scheduleGoldenGateConcealmentSync() {
        guard #available(macOS 27.0, *) else { return }
        goldenGateConcealmentSyncTask?.cancel()
        goldenGateConcealmentSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self, let appState else { return }

            var visible = [MenuBarItemID]()
            var concealed = [MenuBarItemID]()
            for sectionName in MenuBarSection.Name.allCases {
                let itemIDs = itemCache[sectionName]
                    .filter { !$0.isControlItem }
                    .map(\.stableID)
                let shelfOwnsPresentation = MenuBarPresentationPolicy.usesShelf(
                    requestedShelf: appState.settings.general.useBarlineShelf,
                    systemAutoHideEnabled: appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults
                )
                // The shelf is a separate presentation surface. Opening it
                // must never reveal a second native copy in the system bar.
                let shouldConceal = sectionName != .visible && (
                    shelfOwnsPresentation ||
                        appState.menuBarManager.section(withName: sectionName)?.isHidden == true
                )
                if shouldConceal {
                    concealed.append(contentsOf: itemIDs)
                } else {
                    visible.append(contentsOf: itemIDs)
                }
            }
            do {
                try await BarlineMenuService.Connection.shared.configureConcealment(
                    MenuBarConcealmentConfiguration(
                        visibleItemIDs: visible,
                        concealedItemIDs: concealed
                    )
                )
            } catch {
                logger.error(
                    "Golden Gate concealment sync failed: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)"
                )
            }
        }
    }

    /// Caches the current menu bar items, regardless of whether the
    /// items have changed since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsRegardless(
        _ currentItemIDs: [MenuBarItemID]? = nil,
        intent: MenuBarDiscoveryRefreshIntent = .authoritative,
        allowsTrailingAutomaticRefresh: Bool = true
    ) async {
        guard let requestID = beginDiscoveryRequest(intent: intent) else {
            return
        }
        defer {
            finishDiscoveryRequest(
                requestID: requestID,
                allowsTrailingAutomaticRefresh: allowsTrailingAutomaticRefresh
            )
        }
        await discardSupersededRestorations()

        await runCacheDiscovery(currentItemIDs: currentItemIDs, requestID: requestID)
    }

    private func runCacheDiscovery(
        currentItemIDs: [MenuBarItemID]?,
        requestID: UInt64
    ) async {
        await cacheActor.runCacheTask(requestID: requestID) { [weak self] requestID in
            guard let self else {
                return
            }
            let hadUsableSnapshot = itemDiscoveryState.hasUsableSnapshot
            if !hadUsableSnapshot, itemDiscoveryState != .failed {
                itemDiscoveryState = .loading
            }

            for attempt in 0 ..< itemDiscoveryRetryPolicy.maximumAttempts {
                if attempt > 0 {
                    do {
                        try await Task.sleep(
                            for: itemDiscoveryRetryPolicy.delay(forAttempt: attempt - 1)
                        )
                    } catch {
                        return
                    }
                }

                let result = await cacheItemsAttempt(
                    currentItemIDs: attempt == 0 ? currentItemIDs : nil,
                    requestID: requestID
                )
                switch result {
                case .success:
                    itemDiscoveryState = .completed(
                        managedItemCount: itemCache.managedItems.count
                    )
                    itemDiscoveryDiagnostics.recordCompletion(
                        attemptCount: attempt + 1,
                        managedItemCount: itemCache.managedItems.count
                    )
                    return
                case .cancelled:
                    return
                case let .retryableFailure(failure):
                    itemDiscoveryDiagnostics.recordAttemptFailure(code: failure)
                    continue
                }
            }

            guard
                await cacheActor.isCurrent(requestID),
                requestID == cacheRequestSequence
            else {
                return
            }
            itemDiscoveryState = hadUsableSnapshot
                ? itemDiscoveryState.preservingUsableSnapshotOrFailure()
                : .failed
            itemDiscoveryDiagnostics.recordFailure(
                attemptCount: itemDiscoveryRetryPolicy.maximumAttempts
            )
            logger.error("Menu bar item discovery exhausted its bounded retry budget")
        }
    }

    private func cacheItemsAttempt(
        currentItemIDs: [MenuBarItemID]?,
        requestID: UInt64
    ) async -> CacheAttemptResult {
        guard
            let settings = appState?.settings,
            await cacheActor.isCurrent(requestID),
            requestID == cacheRequestSequence
        else {
            return .cancelled
        }

        guard !lastMoveOperationOccurred(within: .seconds(1)) else {
            logger.debug("Deferring menu bar item cache due to recent item movement")
            return .retryableFailure(.recentMovement)
        }

        let environment = try? await BarlineMenuService.Connection.shared.environment()
        let displayID = environment?.activeDisplayID.map { CGDirectDisplayID($0) } ??
            NSScreen.main?.displayID
        let loadedItems: [MenuBarItem]
        do {
            loadedItems = try await MenuBarItem.loadMenuBarItems(option: .activeSpace)
        } catch {
            logger.warning(
                "Menu bar snapshot failed: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)"
            )
            return .retryableFailure(.snapshotUnavailable)
        }
        var items = loadedItems
        let reportedItemIDs = currentItemIDs ?? items.reversed().map(\.stableID)

        guard
            await cacheActor.isCurrent(requestID),
            requestID == cacheRequestSequence
        else {
            return .cancelled
        }

        let resolvedItemIDs = items.reversed().map(\.stableID)
        guard MenuBarRecoveryPolicy.snapshotIsComplete(
            reportedIDs: reportedItemIDs,
            resolvedIDs: resolvedItemIDs
        ) else {
            logger.warning(
                "Incomplete menu bar snapshot (reported: \(reportedItemIDs.count, privacy: .public), resolved: \(resolvedItemIDs.count, privacy: .public)); keeping previous cache"
            )
            _ = await cacheActor.clearCachedItemIDs(for: requestID)
            return .retryableFailure(.incompleteSnapshot)
        }

        let hasVisibleControlItem = items.contains { $0.tag == .visibleControlItem }
        guard let controlItems = ControlItemPair(items: &items) else {
            logger.warning("Missing control item for hidden section, keeping previous menu bar item cache")
            _ = await cacheActor.clearCachedItemIDs(for: requestID)
            return .retryableFailure(.missingControlItems)
        }

        guard MenuBarRecoveryPolicy.hasRequiredControlItems(
            hasVisibleControlItem: hasVisibleControlItem,
            hasAlwaysHiddenControlItem: controlItems.alwaysHidden != nil,
            requiresVisibleControlItem: settings.general.showBarlineIcon,
            requiresAlwaysHiddenControlItem: settings.advanced.enableAlwaysHiddenSection
        ) else {
            logger.warning("Missing required control item, keeping previous menu bar item cache")
            _ = await cacheActor.clearCachedItemIDs(for: requestID)
            return .retryableFailure(.missingRequiredControlItems)
        }

        guard
            await cacheActor.updateCachedItemIDs(reportedItemIDs, for: requestID),
            requestID == cacheRequestSequence
        else {
            return .cancelled
        }

        await enforceControlItemOrder(controlItems: controlItems)

        guard
            await cacheActor.isCurrent(requestID),
            requestID == cacheRequestSequence
        else {
            return .cancelled
        }

        await uncheckedCacheItems(
            items: items,
            controlItems: controlItems,
            displayID: displayID,
            requestID: requestID
        )
        return .success
    }

    /// Caches the current menu bar items, if the items have changed
    /// since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsIfNeeded(
        intent: MenuBarDiscoveryRefreshIntent = .automatic
    ) async {
        guard let requestID = beginDiscoveryRequest(intent: intent) else {
            return
        }
        defer {
            finishDiscoveryRequest(
                requestID: requestID,
                allowsTrailingAutomaticRefresh: true
            )
        }

        let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        let itemIDs = items.reversed().map(\.stableID)
        let environment = try? await BarlineMenuService.Connection.shared.environment()
        let displayID = environment?.activeDisplayID.map { CGDirectDisplayID($0) } ??
            NSScreen.main?.displayID

        // The inventory and environment calls suspend. An authoritative
        // request may have superseded this automatic request while either was
        // in flight, so never let stale work enter discovery or discard newer
        // restoration state.
        guard requestID == cacheRequestSequence else {
            return
        }

        let cachedItemIDs = await cacheActor.cachedItemIDs
        guard requestID == cacheRequestSequence else {
            return
        }

        if MenuBarDiscoveryRefreshPolicy.shouldRunDiscovery(
            inventoryChanged: cachedItemIDs != itemIDs,
            displayChanged: itemCache.displayID != displayID,
            hasUsableSnapshot: itemDiscoveryState.hasUsableSnapshot
        ) {
            await discardSupersededRestorations()
            await runCacheDiscovery(currentItemIDs: itemIDs, requestID: requestID)
        }
    }
}

// MARK: - Typed Item Operations

extension MenuBarItemManager {
    enum EventError: CustomStringConvertible, LocalizedError {
        case cannotComplete
        case itemNotMovable(MenuBarItem)
        case missingItemBounds(MenuBarItem)

        var description: String {
            switch self {
            case .cannotComplete:
                "\(Self.self).cannotComplete"
            case let .itemNotMovable(item):
                "\(Self.self).itemNotMovable(item: \(item.tag))"
            case let .missingItemBounds(item):
                "\(Self.self).missingItemBounds(item: \(item.tag))"
            }
        }

        var errorDescription: String? {
            switch self {
            case .cannotComplete:
                "Operation could not be completed"
            case let .itemNotMovable(item):
                "\"\(item.displayName)\" is not movable"
            case let .missingItemBounds(item):
                "Missing bounds rectangle for \"\(item.displayName)\""
            }
        }

        var recoverySuggestion: String? {
            if case .itemNotMovable = self {
                return nil
            }
            return "Please try again. If the error persists, please file a bug report."
        }
    }

    enum MoveDestination {
        case leftOfItem(MenuBarItem)
        case rightOfItem(MenuBarItem)

        var targetItem: MenuBarItem {
            switch self {
            case let .leftOfItem(item), let .rightOfItem(item): item
            }
        }

        var logString: String {
            switch self {
            case let .leftOfItem(item): "left of \(item.logString)"
            case let .rightOfItem(item): "right of \(item.logString)"
            }
        }
    }

    private nonisolated func hasUserPausedInput(for duration: Duration) -> Bool {
        NSEvent.modifierFlags.isEmpty &&
            !MouseHelpers.lastMovementOccurred(within: duration) &&
            !MouseHelpers.lastScrollWheelOccurred(within: duration) &&
            !MouseHelpers.isButtonPressed()
    }

    private nonisolated func waitForUserToPauseInput() async throws {
        for _ in 0 ..< 40 {
            try Task.checkCancellation()
            if hasUserPausedInput(for: .milliseconds(50)) {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        logger.error("Item input idle wait expired")
        throw MenuBarInputIdleTimeoutError()
    }

    private nonisolated func eventSleep(for duration: Duration = .milliseconds(25)) async {
        let task = Task {
            try? await Task.sleep(for: duration)
        }
        await task.value
    }

    private nonisolated func getCurrentBounds(for item: MenuBarItem) async throws -> CGRect {
        let snapshot = try await MenuBarItem.snapshotCoordinator.refreshOnce()
        guard let descriptor = snapshot.items.first(where: { $0.id == item.stableID }) else {
            throw EventError.missingItemBounds(item)
        }
        return CGRect(
            x: descriptor.bounds.x,
            y: descriptor.bounds.y,
            width: descriptor.bounds.width,
            height: descriptor.bounds.height
        )
    }

    private func operation(
        for item: MenuBarItem,
        destination: MoveDestination,
        in snapshot: MenuBarSnapshot
    ) -> MenuBarMoveOperation? {
        let target = destination.targetItem
        guard let targetDescriptor = snapshot.items.first(where: {
            $0.id == target.stableID
        }) else {
            return nil
        }

        let address: (section: MenuBarSection.Name, index: Int)
        if target.tag == .hiddenControlItem {
            let hiddenItems = snapshot.items.filter { $0.section == .hidden }
            guard let controlIndex = hiddenItems.firstIndex(where: {
                $0.id == targetDescriptor.id
            }) else {
                return nil
            }
            address = switch destination {
            case .leftOfItem: (.hidden, controlIndex)
            case .rightOfItem: (.visible, 0)
            }
        } else if target.tag == .alwaysHiddenControlItem {
            let alwaysHiddenItems = snapshot.items.filter { $0.section == .alwaysHidden }
            guard let controlIndex = alwaysHiddenItems.firstIndex(where: {
                $0.id == targetDescriptor.id
            }) else {
                return nil
            }
            address = switch destination {
            case .leftOfItem: (.alwaysHidden, controlIndex)
            case .rightOfItem: (.hidden, 0)
            }
        } else {
            let candidates = snapshot.items.filter {
                $0.section == targetDescriptor.section
            }
            guard var targetIndex = candidates.firstIndex(where: {
                $0.id == targetDescriptor.id
            }) else {
                return nil
            }
            if case .rightOfItem = destination {
                targetIndex += 1
            }
            let section: MenuBarSection.Name = switch targetDescriptor.section {
            case .visible: .visible
            case .hidden: .hidden
            case .alwaysHidden: .alwaysHidden
            }
            address = (section, targetIndex)
        }

        let section = switch address.section {
        case .visible: BarlineCore.MenuBarSection.visible
        case .hidden: BarlineCore.MenuBarSection.hidden
        case .alwaysHidden: BarlineCore.MenuBarSection.alwaysHidden
        }
        return MenuBarMoveOperation(
            itemID: item.stableID,
            section: section,
            index: address.index,
            destinationDisplayID: targetDescriptor.displayID
        )
    }

    func move(
        item: MenuBarItem,
        to destination: MoveDestination,
        recordsHistory: Bool = true,
        interactionID: UUID? = nil
    ) async throws {
        if recordsHistory {
            appState?.contextualRules.pauseForManualChange()
        }
        guard appState?.permissions.accessibility.hasPermission == true else {
            throw EventError.cannotComplete
        }
        guard item.isMovable else {
            throw EventError.itemNotMovable(item)
        }
        if recordsHistory, hasPendingRestorations {
            await retryPendingRestorations()
            guard !hasPendingRestorations else { throw EventError.cannotComplete }
        }
        try await waitForUserToPauseInput()
        guard let appState,
              appState.permissions.accessibility.hasPermission == true
        else {
            throw EventError.cannotComplete
        }
        logger.log("Moving menu bar item to requested destination")
        lastMoveOperationTimestamp = .now
        defer { lastMoveOperationTimestamp = .now }
        do {
            let snapshot = try await appState.compatibilityCoordinator.refresh(interactionID: interactionID)
            guard let operation = operation(
                for: item,
                destination: destination,
                in: snapshot
            ) else {
                throw EventError.cannotComplete
            }
            let priorProfileID = await appState.compatibilityCoordinator.activeProfileID
            let mutation: BarlineCore.MenuBarMutation = recordsHistory
                ? .move(operation)
                : .transientMove(operation)
            _ = try await appState.compatibilityCoordinator.perform(
                mutation,
                expectedGeneration: snapshot.generation,
                interactionID: interactionID
            )
            if recordsHistory {
                await appState.profileManager.clearActiveProfileAuthority(
                    ifMatches: priorProfileID
                )
            }
            if interactionID == nil {
                await cacheItemsRegardless()
            }
        } catch {
            logger.error("Typed helper move failed: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
            throw EventError.cannotComplete
        }
    }

    func click(
        item: MenuBarItem,
        with mouseButton: CGMouseButton,
        interactionID: UUID
    ) async throws {
        try await waitForUserToPauseInput()
        let button: MenuBarMouseButton = switch mouseButton {
        case .left: .left
        case .right: .right
        default: .other
        }
        guard let appState else {
            throw EventError.cannotComplete
        }
        do {
            let snapshot = try await appState.compatibilityCoordinator.refresh(
                interactionID: interactionID
            )
            guard snapshot.items.contains(where: { $0.id == item.stableID }) else {
                throw MenuBarBackendError.staleItem(item.stableID)
            }
            _ = try await appState.compatibilityCoordinator.perform(
                .activate(item.stableID, button),
                expectedGeneration: snapshot.generation,
                interactionID: interactionID
            )
        } catch {
            logger.error("Typed activation failed: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
            throw EventError.cannotComplete
        }
    }
}

// MARK: - Temporarily Showing Items

extension MenuBarItemManager {
    /// Cached views supply identity only; visibility and mutation authority are fresh.
    @discardableResult
    func activateItem(_ itemID: MenuBarItemID, with button: CGMouseButton) async -> MenuBarItemActivationOutcome {
        guard !isActivatingItem, !isRestoringItems, let appState else { return .failed }
        isActivatingItem = true
        activationNotice = nil
        defer { isActivatingItem = false }
        do {
            return try await appState.compatibilityCoordinator.withItemInteraction { [self] token in
                try await activateAssumingInteraction(itemID, with: button, interactionID: token)
            }
        } catch {
            activationNotice = "Couldn’t open this item. Close any open menu and try again."
            logger.error("Item activation did not complete: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
            return .failed
        }
    }

    private func activateAssumingInteraction(
        _ itemID: MenuBarItemID,
        with button: CGMouseButton,
        interactionID: UUID
    ) async throws -> MenuBarItemActivationOutcome {
        guard let appState else { throw EventError.cannotComplete }
        let snapshot = try await appState.compatibilityCoordinator.refresh(interactionID: interactionID)
        guard !snapshot.menuTrackingIsActive else {
            throw MenuBarBackendError.unsafeMenuTracking
        }
        guard let descriptor = snapshot.items.first(where: { $0.id == itemID }) else {
            throw MenuBarBackendError.staleItem(itemID)
        }
        let item = MenuBarItem(descriptor: descriptor)
        guard item.isResponsive else {
            throw EventError.cannotComplete
        }
        let interfaceObserved: Bool
        if item.isOnScreen {
            let token = try await BarlineMenuService.Connection.shared.beginRevealObservation(for: itemID)
            do {
                try await click(item: item, with: button, interactionID: interactionID)
                interfaceObserved = try await waitForInterface(token)
                if interfaceObserved {
                    observeVisibleInterfaceUntilClosed(token)
                } else {
                    await BarlineMenuService.Connection.shared.endRevealObservation(token)
                }
            } catch {
                await BarlineMenuService.Connection.shared.endRevealObservation(token)
                throw error
            }
        } else {
            interfaceObserved = try await temporarilyShow(item: item, clickingWith: button, interactionID: interactionID)
        }
        guard interfaceObserved else {
            activationNotice = "Couldn’t confirm this item opened. It may have performed an action without showing a menu."
            logger.notice("Activation completed without an observed interface")
            // No observed menu is inconclusive (some items perform a direct
            // action). Do not reopen a picker over a delayed target interface.
            return .interfaceNotObserved
        }
        logger.notice("Activation target interface observed")
        return .interfaceObserved
    }

    /// Keep custom normal-layer interfaces protected after the click lease ends.
    /// This owns observation only, never a mutation-authority token.
    private func observeVisibleInterfaceUntilClosed(_ token: MenuBarRevealObservationToken) {
        visibleInterfaceTasks[token] = Task { [weak self] in
            do {
                while try await BarlineMenuService.Connection.shared.revealObservationIsVisible(token) {
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch {
                // Cancellation or helper loss ends this helper-owned observation.
            }
            await BarlineMenuService.Connection.shared.endRevealObservation(token)
            self?.visibleInterfaceTasks[token] = nil
        }
    }

    private func waitForInterface(_ token: MenuBarRevealObservationToken) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if try await BarlineMenuService.Connection.shared.revealObservationIsVisible(token) {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Context for a temporarily shown menu bar item.
    private final class TemporarilyShownItemContext {
        let entry: TemporaryRevealJournal.Entry
        let tag: MenuBarItemTag?
        let authority: UInt64
        var itemID: MenuBarItemID {
            entry.checkpoint.itemID
        }

        var revealObservation: MenuBarRevealObservationToken?
        var rehideAttempts = 0
        var paused: Bool

        init(entry: TemporaryRevealJournal.Entry, tag: MenuBarItemTag?, authority: UInt64, paused: Bool = false) {
            self.entry = entry
            self.tag = tag
            self.authority = authority
            self.paused = paused
        }
    }

    private func updateRestorationPresentation() {
        temporarilyRevealedItemIDs = Set(temporarilyShownItemContexts.map(\.itemID))
        hasPendingRestorations = recoveryRecordsUnavailable || !temporarilyShownItemContexts.isEmpty
    }

    private func discardSupersededRestorations() async {
        guard let appState, !temporarilyShownItemContexts.isEmpty else { return }
        let authority = await appState.compatibilityCoordinator.layoutAuthorityGeneration
        let superseded = temporarilyShownItemContexts.filter { $0.authority != authority }
        temporarilyShownItemContexts.removeAll { $0.authority != authority }
        updateRestorationPresentation()
        for context in superseded {
            if let token = context.revealObservation {
                await BarlineMenuService.Connection.shared.endRevealObservation(token)
            }
        }
    }

    /// User-triggered recovery also handles entries loaded after app restart.
    func retryPendingRestorations() async {
        await discardSupersededRestorations()
        for context in temporarilyShownItemContexts {
            context.paused = false
            context.rehideAttempts = 0
        }
        await rehideTemporarilyShownItems()
        await cacheItemsRegardless()
    }

    /// Called only after the user confirms retaining today's physical layout.
    /// Preserve the old journal for recovery, including unreadable records.
    func keepCurrentItemPositions() async {
        guard allowsPickerPresentation, let appState else { return }
        isRestoringItems = true
        defer { isRestoringItems = false }
        do {
            try await appState.compatibilityCoordinator.withItemInteraction { [self] _ in
                try await keepCurrentPositionsAssumingInteraction()
            }
            await cacheItemsRegardless()
        } catch {
            activationNotice = "Recovery records could not be archived. No item positions were changed."
        }
    }

    private func keepCurrentPositionsAssumingInteraction() async throws {
        guard let appState else { throw EventError.cannotComplete }
        try await appState.temporaryRevealJournal.discardPreservingBackup()
        let prior = temporarilyShownItemContexts
        temporarilyShownItemContexts.removeAll()
        recoveryRecordsUnavailable = false
        updateRestorationPresentation()
        activationNotice = nil
        for context in prior {
            if let token = context.revealObservation {
                await BarlineMenuService.Connection.shared.endRevealObservation(token)
            }
        }
    }

    /// Schedules a timer for the given interval that rehides the
    /// temporarily shown items when fired.
    private func runRehideTimer(for interval: TimeInterval? = nil) {
        guard let appState else {
            return
        }
        let interval = interval ?? appState.settings.advanced.tempShowInterval
        logger.debug("Running rehide timer for interval: \(interval, format: .fixed, privacy: .public)")
        rehideTimer?.invalidate()
        rehideTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            logger.debug("Rehide timer fired")
            Task {
                await self.rehideTemporarilyShownItems()
            }
        }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached and returned to its original location after the
    /// time interval specified by ``AdvancedSettings/tempShowInterval``.
    ///
    /// - Parameters:
    ///   - item: The item to temporarily show.
    ///   - mouseButton: The mouse button to click the item with.
    private func temporarilyShow(
        item: MenuBarItem,
        clickingWith mouseButton: CGMouseButton,
        interactionID: UUID
    ) async throws -> Bool {
        guard let appState else {
            logger.error("Missing AppState, so not showing menu bar item")
            throw EventError.cannotComplete
        }
        guard let screen = NSScreen.screenWithActiveMenuBar else {
            logger.error("No active menu bar screen, so not showing menu bar item")
            throw EventError.cannotComplete
        }

        guard let applicationMenuFrame = screen.getApplicationMenuFrame() else {
            logger.error("No application menu frame, so not showing menu bar item")
            throw EventError.cannotComplete
        }

        var items = await MenuBarItem.getMenuBarItems(option: .activeSpace, interactionID: interactionID)

        let snapshot = try await appState.compatibilityCoordinator.refresh(interactionID: interactionID)
        guard let checkpoint = TemporaryRevealRestoration(itemID: item.stableID, in: snapshot) else {
            logger.error("No return destination for menu bar item")
            throw EventError.cannotComplete
        }

        // Remove all items up to and including the hidden control item.
        if let index = items.firstIndex(matching: .hiddenControlItem) {
            items.removeSubrange(...index)
        }

        let maxX: CGFloat = {
            var maxX = applicationMenuFrame.maxX
            if let frameOfNotch = screen.frameOfNotch {
                maxX = max(maxX, frameOfNotch.maxX + 30)
            }
            return maxX + item.bounds.width
        }()

        // Remove items until we have enough room to show this item.
        items.trimPrefix { item in
            if item.isOnScreen, item.canBeHidden {
                return item.bounds.minX <= maxX
            }
            return true
        }

        guard let targetItem = items.first else {
            logger.warning("Not enough room to show menu bar item")
            throw EventError.cannotComplete
        }

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        logger.debug("Temporarily showing menu bar item")

        // Register compensation before the first mutation: cancellation can
        // arrive after the helper moves but before coordinator verification.
        await discardSupersededRestorations()
        guard !temporarilyShownItemContexts.contains(where: { $0.itemID == item.stableID }) else {
            throw EventError.cannotComplete
        }
        let context = await TemporarilyShownItemContext(
            entry: TemporaryRevealJournal.Entry(checkpoint: checkpoint),
            tag: item.tag,
            authority: appState.compatibilityCoordinator.layoutAuthorityGeneration
        )
        // A failed durable write must prevent the native reveal.
        try await appState.temporaryRevealJournal.replace(
            temporarilyShownItemContexts.map(\.entry) + [context.entry]
        )
        temporarilyShownItemContexts.append(context)
        updateRestorationPresentation()
        rehideTimer?.invalidate()
        defer { runRehideTimer() }

        do {
            try await move(
                item: item,
                to: .leftOfItem(targetItem),
                recordsHistory: false,
                interactionID: interactionID
            )
        } catch {
            logger.error("Error showing item: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
            throw error
        }

        await eventSleep(for: .milliseconds(100))
        let observation = try await BarlineMenuService.Connection.shared
            .beginRevealObservation(for: item.stableID)
        context.revealObservation = observation

        do {
            try await click(item: item, with: mouseButton, interactionID: interactionID)
        } catch {
            logger.error("Error clicking item: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
            throw error
        }

        return try await waitForInterface(observation)
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits
    /// for the interface to close before hiding the items.
    func rehideTemporarilyShownItems() async {
        guard !isRestoringItems else { return }
        await discardSupersededRestorations()
        guard !isActivatingItem else {
            runRehideTimer(for: 1)
            return
        }
        guard let appState else {
            logger.error("Missing AppState, so not rehiding")
            return
        }
        guard !temporarilyShownItemContexts.isEmpty else {
            return
        }
        isRestoringItems = true
        defer { isRestoringItems = false }
        do {
            try await appState.compatibilityCoordinator.withItemInteraction { [self] token in
                await rehideAssumingInteraction(interactionID: token)
            }
        } catch {
            logger.warning("Restoration deferred: another menu bar transaction is active")
            runRehideTimer(for: 3)
        }
    }

    private func rehideAssumingInteraction(interactionID: UUID) async {
        guard let appState else { return }
        for context in temporarilyShownItemContexts {
            if let token = context.revealObservation,
               await (try? BarlineMenuService.Connection.shared.revealObservationIsVisible(token)) == true
            {
                logger.debug("Menu bar item interface is shown, so waiting to rehide")
                runRehideTimer(for: 3)
                return
            }
        }
        guard hasUserPausedInput(for: .milliseconds(250)) else {
            logger.debug("Found recent user input, so waiting to rehide")
            runRehideTimer(for: 1)
            return
        }

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }
        // Do not remove obligations from memory while an await can reenter
        // caching. Each one stays durable until verified restoration/absence.
        for context in temporarilyShownItemContexts.reversed() where !context.paused {
            do {
                let snapshot = try await appState.compatibilityCoordinator.refresh(interactionID: interactionID)
                // Tracking is a safe deferral, not a failed movement attempt.
                if snapshot.menuTrackingIsActive {
                    runRehideTimer(for: 1)
                    return
                }
                switch context.entry.checkpoint.resolve(in: snapshot) {
                case let .move(operation):
                    try await waitForUserToPauseInput()
                    let restored = try await appState.compatibilityCoordinator.perform(
                        .transientMove(operation),
                        expectedGeneration: snapshot.generation,
                        interactionID: interactionID
                    )
                    guard let item = restored.items.first(where: { $0.id == context.itemID }),
                          item.section == context.entry.checkpoint.originalSection,
                          item.displayID == context.entry.checkpoint.originalDisplayID
                    else { throw EventError.cannotComplete }
                case .itemAbsent, .superseded:
                    // A validated census or explicit external relocation owns
                    // the current state; don't chase a replacement identity.
                    break
                case .displayUnavailable, .unavailable:
                    context.paused = true
                    activationNotice = "Item restoration needs review. Use Retry Item Restoration in Layouts & Focus."
                    continue
                }
                try await finishRestoration(context)
            } catch {
                context.rehideAttempts += 1
                if context.rehideAttempts >= 3 {
                    context.paused = true
                    activationNotice = "Item restoration paused after three attempts. Retry in Layouts & Focus."
                }
                logger.warning("Item restoration deferred: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
            }
        }
        updateRestorationPresentation()
        if temporarilyShownItemContexts.contains(where: { !$0.paused }) {
            runRehideTimer(for: 3)
        }
    }

    private func finishRestoration(_ context: TemporarilyShownItemContext) async throws {
        guard let appState else { throw EventError.cannotComplete }
        let remaining = temporarilyShownItemContexts.filter { $0.entry.id != context.entry.id }
        try await appState.temporaryRevealJournal.replace(remaining.map(\.entry))
        temporarilyShownItemContexts = remaining
        updateRestorationPresentation()
        if let token = context.revealObservation {
            await BarlineMenuService.Connection.shared.endRevealObservation(token)
        }
        if remaining.isEmpty {
            activationNotice = nil
        }
    }

    /// Removes a temporarily shown item from the cache, ensuring that
    /// the item is _not_ returned to its original location.
    func removeTemporarilyShownItemFromCache(with tag: MenuBarItemTag) {
        // Layout editing must wait for durable compensation, rather than
        // silently deleting an obligation before an edit that may fail.
        guard temporarilyShownItemContexts.contains(where: { $0.tag == tag }) else { return }
        activationNotice = "Finish item restoration before editing its layout."
        Task { await retryPendingRestorations() }
    }
}

// MARK: - Control Item Order

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the
    /// control item for the always-hidden section is positioned to the
    /// left of control item for the hidden section.
    private func enforceControlItemOrder(controlItems: ControlItemPair) async {
        guard appState?.permissions.accessibility.hasPermission == true else {
            return
        }
        let hidden = controlItems.hidden

        guard
            let alwaysHidden = controlItems.alwaysHidden,
            hidden.bounds.maxX <= alwaysHidden.bounds.minX
        else {
            return
        }

        do {
            logger.debug("Control items have incorrect order")
            try await move(item: alwaysHidden, to: .leftOfItem(hidden))
        } catch {
            logger.error("Error enforcing control item order: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
        }
    }
}

// MARK: - Logger Helpers

private extension Logger {
    /// Logger for the menu bar item manager.
    static let menuBarItemManager = Logger(category: "MenuBarItemManager")
}
