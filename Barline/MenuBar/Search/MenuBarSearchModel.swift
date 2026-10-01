//
//  MenuBarSearchModel.swift
//  Barline
//

import BarlineCore
import Cocoa
import Combine
import OSLog

@MainActor
final class MenuBarSearchModel: ObservableObject {
    enum ItemID: Hashable {
        case header(MenuBarSection.Name)
        case item(MenuBarItemID)
        case profileHeader
        case profile(UUID)
        case favoritesHeader
    }

    enum CommandInterpretationState: Equatable {
        case idle
        case deterministicOnly
        case interpreting
        case unavailable(SearchCapabilityUnavailableReason)
        case fallback
        case validated(ValidatedMenuBarCommand)
        case previewRequired(ValidatedMenuBarCommand)
        case nonRunnable(ValidatedMenuBarCommand, SearchCommandNonRunnableReason)
    }

    @Published var searchText = ""
    @Published var displayedItems = [SectionedListItem<ItemID>]()
    @Published var selection: ItemID?
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?
    @Published private(set) var commandInterpretationState: CommandInterpretationState = .idle
    @Published private(set) var personalization = SearchItemPersonalization.empty
    @Published private(set) var preferencesAvailable = false
    @Published private(set) var isSavingPreferences = false
    @Published private(set) var preferencesNotice: String?
    @Published var aliasEditorItemID: MenuBarItemID?
    @Published var aliasDraft = ""

    private var cancellables = Set<AnyCancellable>()
    private let commandInterpreter: any MenuBarCommandInterpreting
    private let commandRoutingPolicy = SearchCommandRoutingPolicy()
    private let commandValidator = MenuBarCommandValidator()
    private var commandInterpretationTask: Task<Void, Never>?
    private var commandInterpretationSequence: UInt64 = 0
    private var spotlightDocuments = [SearchDocument]()
    private var spotlightSynchronizationTask: Task<Void, Never>?
    private let searchService = CachedSearchService()
    private var rankingTask: Task<Void, Never>?
    private var rankingSequence: UInt64 = 0
    private let preferences = SearchItemPreferences()
    private var hasRequestedPreferences = false
    private var livePreferenceItemIDs = [MenuBarItemID]()
    private var preferenceIdentityProjection = SearchPreferenceIdentityProjection(
        storedIDs: [],
        liveIDs: []
    )
    private var aliasEditorStorageItemID: MenuBarItemID?

    init(commandInterpreter: any MenuBarCommandInterpreting = FoundationModelCommandInterpreter()) {
        self.commandInterpreter = commandInterpreter
    }

    var canSaveAlias: Bool {
        guard preferencesAvailable, !isSavingPreferences,
              let itemID = aliasEditorItemID,
              let storageID = aliasEditorStorageItemID,
              preferenceStorageID(for: itemID) == storageID
        else { return false }
        do {
            _ = try SearchItemPersonalization.validatedAlias(aliasDraft)
            return true
        } catch {
            return false
        }
    }

    func loadPreferences() async {
        guard !hasRequestedPreferences else { return }
        hasRequestedPreferences = true
        do {
            personalization = try await preferences.load()
            rebuildPreferenceIdentityProjection()
            preferencesAvailable = true
        } catch {
            preferencesNotice = "Saved favorites and aliases couldn’t be read. Existing data was left unchanged."
        }
    }

    func toggleFavorite(_ itemID: MenuBarItemID) {
        guard canEditPreferences(for: itemID),
              let storageID = preferenceStorageID(for: itemID)
        else { return }
        let desired = !personalization.isFavorite(storageID)
        isSavingPreferences = true
        preferencesNotice = nil
        Task {
            defer { isSavingPreferences = false }
            do {
                personalization = try await preferences.setFavorite(desired, for: storageID)
                rebuildPreferenceIdentityProjection()
            } catch {
                preferencesNotice = "Couldn’t save this favorite. Your saved preferences were not replaced."
            }
        }
    }

    func editAlias(for itemID: MenuBarItemID) {
        guard canEditPreferences(for: itemID),
              let storageID = preferenceStorageID(for: itemID)
        else { return }
        aliasDraft = personalization.alias(for: storageID) ?? ""
        aliasEditorItemID = itemID
        aliasEditorStorageItemID = storageID
        selection = nil
    }

    func cancelAliasEditing() {
        aliasEditorItemID = nil
        aliasEditorStorageItemID = nil
        aliasDraft = ""
        selection = displayedItems.first { $0.isSelectable }?.id
    }

    func saveAlias() {
        guard canSaveAlias,
              let itemID = aliasEditorItemID,
              let storageID = aliasEditorStorageItemID
        else { return }
        let draft = aliasDraft
        isSavingPreferences = true
        preferencesNotice = nil
        Task {
            defer { isSavingPreferences = false }
            do {
                personalization = try await preferences.setAlias(draft, for: storageID)
                rebuildPreferenceIdentityProjection()
                if aliasEditorItemID == itemID,
                   aliasEditorStorageItemID == storageID
                {
                    cancelAliasEditing()
                }
            } catch {
                preferencesNotice = "Couldn’t save this alias. Your saved preferences were not replaced."
            }
        }
    }

    func updatePreferenceIdentityProjection(liveItemIDs: [MenuBarItemID]) {
        livePreferenceItemIDs = liveItemIDs
        rebuildPreferenceIdentityProjection()
    }

    func isFavorite(_ itemID: MenuBarItemID) -> Bool {
        guard case let .stored(storageID) = preferenceIdentityProjection.resolution(for: itemID) else {
            return false
        }
        return personalization.isFavorite(storageID)
    }

    func alias(for itemID: MenuBarItemID) -> String? {
        guard case let .stored(storageID) = preferenceIdentityProjection.resolution(for: itemID) else {
            return nil
        }
        return personalization.alias(for: storageID)
    }

    func canEditPreferences(for itemID: MenuBarItemID) -> Bool {
        preferencesAvailable && !isSavingPreferences && preferenceStorageID(for: itemID) != nil
    }

    private func preferenceStorageID(for itemID: MenuBarItemID) -> MenuBarItemID? {
        switch preferenceIdentityProjection.resolution(for: itemID) {
        case let .stored(storageID): storageID
        case .new: itemID
        case .ambiguous: nil
        }
    }

    private func rebuildPreferenceIdentityProjection() {
        preferenceIdentityProjection = SearchPreferenceIdentityProjection(
            storedIDs: personalization.entries.map(\.itemID),
            liveIDs: livePreferenceItemIDs
        )
    }

    func rankResults(
        for query: String,
        documents: [SearchDocument],
        publish: @escaping @MainActor ([SearchResult]) -> Void
    ) {
        cancelRanking()
        resetCommandInterpretation()
        displayedItems = []
        selection = nil
        let sequence = rankingSequence
        let service = searchService
        synchronizeSpotlightIfNeeded(with: documents)
        rankingTask = Task { [weak self] in
            do {
                // Coalesce rapid input without delaying unrelated UI events.
                try await Task.sleep(for: .milliseconds(60))
                let results = try await service.search(query, documents: documents)
                guard let self, !Task.isCancelled,
                      sequence == rankingSequence, searchText == query
                else { return }
                publish(results)
            } catch is CancellationError {
                return
            } catch {
                guard let self, sequence == rankingSequence, searchText == query else { return }
                Logger(category: "Search").error("Search index synchronization failed")
                publish([])
            }
        }
    }

    func cancelRanking() {
        rankingSequence &+= 1
        rankingTask?.cancel()
        rankingTask = nil
    }

    func considerCommandInterpretation(
        query: String,
        documents: [SearchDocument],
        deterministicResults: [SearchResult],
        coordinator: MenuBarStateCoordinator,
        availableProfileIDs: Set<ProfileID>
    ) {
        commandInterpretationSequence += 1
        let requestSequence = commandInterpretationSequence
        commandInterpretationTask?.cancel()
        guard commandRoutingPolicy.shouldInterpret(
            query: query,
            deterministicResults: deterministicResults
        ) else {
            commandInterpretationState = .deterministicOnly
            return
        }

        let availability = SearchRuntimeAvailability.current()
        let plan = availability.plan(for: .ambiguousNaturalLanguage)
        guard plan.useFoundationModels else {
            if case let .unavailable(reason) = availability.foundationModels {
                commandInterpretationState = .unavailable(reason)
            } else {
                commandInterpretationState = .fallback
            }
            return
        }

        let context = boundedModelContext(documents: documents, results: deterministicResults)
        let interpreter = commandInterpreter
        let validator = commandValidator
        commandInterpretationState = .interpreting
        commandInterpretationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard self?.commandRequestIsCurrent(requestSequence, query: query) == true else {
                    return
                }
                let command = try await interpreter.interpret(query: query, documents: context)
                guard self?.commandRequestIsCurrent(requestSequence, query: query) == true else {
                    return
                }

                // Model inference can outlive the snapshot it started with. Refresh
                // before creating authority so validation never relies on that stale state.
                _ = try await coordinator.refresh()
                guard self?.commandRequestIsCurrent(requestSequence, query: query) == true else {
                    return
                }
                let authority = try await MenuBarCommandAuthority.current(
                    from: coordinator,
                    availableProfileIDs: availableProfileIDs
                )
                let validated = try validator.validate(command, authority: authority).get()
                guard self?.commandRequestIsCurrent(requestSequence, query: query) == true else {
                    return
                }
                let disposition = SearchCommandExecutionPolicy().disposition(
                    for: validated,
                    in: authority.validatedSnapshot
                )
                if case let .nonRunnable(reason) = disposition {
                    self?.commandInterpretationState = .nonRunnable(validated, reason)
                    return
                }
                switch validated.confirmation {
                case .immediate:
                    self?.commandInterpretationState = .validated(validated)
                case .previewRequired:
                    self?.commandInterpretationState = .previewRequired(validated)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self?.commandRequestIsCurrent(requestSequence, query: query) == true else {
                    return
                }
                self?.commandInterpretationState = .fallback
            }
        }
    }

    func resetCommandInterpretation() {
        commandInterpretationSequence += 1
        commandInterpretationTask?.cancel()
        commandInterpretationTask = nil
        commandInterpretationState = .idle
    }

    func markCommandNonRunnable(
        _ command: ValidatedMenuBarCommand,
        reason: SearchCommandNonRunnableReason
    ) {
        commandInterpretationState = .nonRunnable(command, reason)
    }

    private func commandRequestIsCurrent(_ sequence: UInt64, query: String) -> Bool {
        !Task.isCancelled
            && sequence == commandInterpretationSequence
            && searchText == query
    }

    private func boundedModelContext(
        documents: [SearchDocument],
        results: [SearchResult]
    ) -> [SearchDocument] {
        var seen = Set<SearchDocumentID>()
        return (results.map(\.document) + documents)
            .filter { seen.insert($0.id).inserted }
            .prefix(30)
            .map(\.self)
    }

    func synchronizeSpotlightIfNeeded(with documents: [SearchDocument]) {
        guard documents != spotlightDocuments else { return }
        spotlightDocuments = documents
        spotlightSynchronizationTask?.cancel()
        spotlightSynchronizationTask = Task {
            do {
                try await CoreSpotlightIndexer.shared.replaceAll(with: documents)
            } catch is CancellationError {
                return
            } catch CoreSpotlightIndexingError.unavailable {
                // Search remains fully available through the in-process index.
            } catch {
                Logger(category: "Search").error("Spotlight synchronization failed")
            }
        }
    }

    func performSetup(with panel: MenuBarSearchPanel) {
        configureCancellables(with: panel)
    }

    private func configureCancellables(with panel: MenuBarSearchPanel) {
        var c = Set<AnyCancellable>()

        Publishers.CombineLatest(
            panel.publisher(for: \.screen),
            panel.publisher(for: \.isVisible)
        )
        .compactMap { screen, isVisible in
            isVisible ? screen : nil
        }
        .sink { [weak self] screen in
            self?.updateAverageColorInfo(for: screen)
        }
        .store(in: &c)

        cancellables = c
    }

    private func updateAverageColorInfo(for screen: NSScreen) {
        Task { [weak self] in
            guard
                let self,
                let capture = await ScreenCapture.captureMenuBarBackground(
                    displayID: screen.displayID,
                    sampleHeight: 1
                ),
                let image = capture.image,
                let color = image.averageColor(option: .ignoreAlpha)
            else {
                return
            }
            let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)
            if averageColorInfo != info {
                averageColorInfo = info
            }
        }
    }
}
