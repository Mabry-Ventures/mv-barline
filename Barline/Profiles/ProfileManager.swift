//
//  ProfileManager.swift
//  Barline
//

import AppKit
import BarlineCore
import Combine
import Foundation
import OSLog

@MainActor
final class ProfileManager: ObservableObject {
    private enum PendingFocusRecoveryOutcome {
        case none
        case promoted
        case restored
        case failed
    }

    private struct WorkspaceLayoutItem: Hashable {
        let id: MenuBarItemID
        let displayID: MenuBarDisplayID?
        let section: BarlineCore.MenuBarSection
        let order: Int
    }

    @Published private(set) var profiles = [BarlineProfile]()
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var activeProfileActivatedAt: Date?
    @Published private(set) var activePresentation: ResolvedProfilePresentation?
    @Published private(set) var loadSource: ProfileStoreLoadSource = .notCreated
    @Published private(set) var pendingArchiveImport: ProfileArchiveImportPreview?
    @Published private(set) var pendingIceImports = [IceImportPreview]()
    @Published private(set) var isBusy = false
    @Published private(set) var interruptedFocusRecoveryToken: UUID?
    @Published var statusMessage: String?
    @Published private(set) var lastOperationErrorCode: String?

    var archivedFocusRecoveryToken: UUID? {
        manualRecoveryStore.load()?.token
    }

    func discardArchivedFocusRecovery(confirmedToken: UUID) {
        guard !isBusy, manualRecoveryStore.load()?.token == confirmedToken else { return }
        manualRecoveryStore.remove(ifMatching: confirmedToken)
        interruptedFocusRecoveryToken = recoverableFocusAuthority()?.token
        statusMessage = "Archived checkpoint discarded. The current arrangement and saved layouts were not changed."
    }

    /// This is authority from Barline's configured native Focus Filter, not a
    /// second Focus-mode catalog or inference from notification preferences.
    var configuredFocusIsActive: Bool? {
        guard bridgeDefaults != nil else { return nil }
        return isProcessingBridgeCommands ||
            processedDefaults.bool(forKey: Self.nativeFocusRequestedKey) ||
            processedDefaults.data(forKey: Self.workspaceBeforeFocusKey) != nil ||
            activationRequests[.focus] != nil
    }

    private static let profileCatalogKey = "intent.profileCatalog"
    private static let nativeFocusRequestedKey = "focus.nativeFilterRequested"
    private static let processedCommandIDsKey = "intent.processedCommandIDs"
    private static let profileBeforeFocusIDKey = "focus.profileBeforeFocusID"
    private static let presentationProfileIDKey = "focus.presentationProfileID"
    private static let activeFocusProfileIDKey = "focus.activeProfileID"
    private static let presentationFocusActiveKey = "focus.presentationModeIsActive"
    private static let workspaceBeforeFocusKey = "focus.workspaceBeforeFocus"
    private static let activeProfileAuthorityTokenKey = "profiles.activeAuthorityToken"
    private static let activeProfileAuthorityKey = "profiles.activeAuthority"
    private static let focusAuthorityTokenKey = "focus.presentationAuthorityToken"
    private static let profileBeforeFocusAuthorityTokenKey = "focus.profileBeforeFocusAuthorityToken"
    private static let maximumProcessedCommandCount = 256

    private let store: ProfileFileStore
    private let commandInbox: IntentCommandInbox?
    private let bridgeDefaults: UserDefaults?
    private let processedDefaults = UserDefaults.standard
    private lazy var authorityStore = ProfileAuthorityEnvelopeStore(
        defaults: processedDefaults,
        key: Self.activeProfileAuthorityKey
    )
    private lazy var manualRecoveryStore = ManualFocusRecoveryStore(
        defaults: processedDefaults, key: "profiles.manualFocusRecovery"
    )
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var profileBeforeFocusID: UUID?
    private var activationRequests = [ProfileActivationSource: ProfileActivationRequest]()
    private var bridgeObserver: DarwinNotificationObserver?
    private var bridgeRetryTask: Task<Void, Never>?
    private var bridgeRetryAttempt = 0
    private nonisolated let profileOperationSemaphore = AsyncSemaphore(value: 1)
    private var isProcessingBridgeCommands = false
    private var needsBridgeCommandRescan = false
    private var workspaceRevision: UInt64 = 0
    private var isApplyingWorkspaceSettings = false

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String? = Bundle.main.object(
            forInfoDictionaryKey: "BarlineAppGroupIdentifier"
        ) as? String
    ) {
        let resolvedAppGroupIdentifier = appGroupIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let validAppGroupIdentifier = resolvedAppGroupIdentifier.flatMap {
            !$0.isEmpty && !$0.contains("$(") ? $0 : nil
        }
        bridgeDefaults = validAppGroupIdentifier.flatMap(UserDefaults.init(suiteName:))
        let containerURL = validAppGroupIdentifier.flatMap {
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        let baseURL = containerURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Barline", isDirectory: true)
        store = ProfileFileStore(directoryURL: baseURL.appendingPathComponent("Profiles", isDirectory: true))
        commandInbox = containerURL.map(IntentCommandInbox.init(containerURL:))
        profileBeforeFocusID = processedDefaults.string(forKey: Self.profileBeforeFocusIDKey)
            .flatMap(UUID.init(uuidString:))
    }

    func performSetup(with appState: AppState) async {
        self.appState = appState
        await reload()
        await rehydrateActiveProfileAuthority()
        await reconcileDisplayConnections()
        configureWorkspaceAuthorityObservers()
        configureBridgeObservers()
        await processBridgeCommands()
    }

    func reload() async {
        await performOperation(successMessage: nil) { [store] in
            let result = try await store.load()
            return (result.profiles, result.source)
        } completion: { [weak self] result in
            self?.profiles = result.0
            self?.loadSource = result.1
            self?.publishCatalog()
        }
    }

    func captureCurrentProfile(named name: String) async {
        guard let appState else { return }
        await performOperation(successMessage: "Profile saved.") {
            let snapshot = try await appState.compatibilityCoordinator.refresh()
            let profile = self.profileFromCurrentWorkspace(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                snapshot: snapshot
            )
            let updated = self.profiles + [profile]
            try await self.store.save(updated)
            return updated
        } completion: { [weak self] updated in
            self?.profiles = updated
            self?.publishCatalog()
        }
    }

    func createPresentationProfile() async {
        guard let appState else { return }
        await performOperation(successMessage: "Presentation profile saved.") {
            guard self.processedDefaults.data(forKey: Self.workspaceBeforeFocusKey) == nil else {
                throw MenuBarBackendError.operationFailed(
                    "disable or recover Presentation mode before changing its profile"
                )
            }
            let presentationID = self.resolvedPresentationProfile()?.id
                ?? PresentationProfileTemplateBuilder.profileID
            try self.validateProfileDefinitionMutation(profileID: presentationID)
            let snapshot = try await appState.compatibilityCoordinator.refresh()
            let profile = PresentationProfileTemplateBuilder().makeTemplate(
                from: snapshot,
                id: presentationID
            ).profile
            let updated = self.profiles.filter { $0.id != presentationID } + [profile]
            try await self.store.save(updated)
            let clearedAuthority = await appState.compatibilityCoordinator.clearActiveProfileAuthority(
                ifMatches: presentationID
            )
            return (
                profiles: updated,
                presentationID: presentationID,
                clearedAuthority: clearedAuthority
            )
        } completion: { [weak self] result in
            guard let self else { return }
            profiles = result.profiles
            if activeProfileID == result.presentationID || result.clearedAuthority {
                activeProfileID = nil
                activeProfileActivatedAt = nil
                activePresentation = nil
                setActiveProfileAuthorityToken(nil)
            }
            activationRequests = activationRequests.filter {
                $0.value.profileID != result.presentationID
            }
            processedDefaults.set(
                result.presentationID.uuidString,
                forKey: Self.presentationProfileIDKey
            )
            publishCatalog()
        }
    }

    @discardableResult
    func activate(
        _ profile: BarlineProfile,
        source: ProfileActivationSource = .manual,
        expectedGeneration: UInt64? = nil,
        authorityToken: UUID? = nil,
        admission: (@Sendable () async throws -> Void)? = nil,
        prepareCheckpoint: (
            @Sendable (MenuBarWorkspaceCheckpoint, ResolvedProfilePresentation) async throws -> Void
        )? = nil,
        onFailure: ((any Error) -> Void)? = nil
    ) async -> Bool {
        guard let appState else { return false }
        if [.manual, .shortcut, .appIntent, .recovery].contains(source) {
            appState.contextualRules.pauseForManualChange()
        }
        let resolvedAuthorityToken = authorityToken ?? UUID()
        var didActivate = false
        await performOperation(successMessage: "Profile applied.", onFailure: onFailure) {
            let priorRequest = self.activationRequests[source]
            self.activationRequests[source] = ProfileActivationRequest(
                profileID: profile.id,
                source: source
            )
            let request = ProfileActivationResolver().resolve(self.activationRequests.values)
            if !source.retainsArbitrationRequestWhileActive {
                self.activationRequests.removeValue(forKey: source)
            }
            guard let request,
                  let resolvedProfile = self.profiles.first(where: {
                      $0.id == request.profileID
                  })
            else {
                throw MenuBarBackendError.operationFailed("requested profile is unavailable")
            }
            let priorAuthorityToken = self.activeProfileAuthorityToken()
            do {
                let snapshot = try await appState.compatibilityCoordinator.activate(
                    profile: resolvedProfile,
                    expectedGeneration: expectedGeneration,
                    workspaceTransaction: self.workspaceTransaction(),
                    admission: admission,
                    prepareCheckpoint: prepareCheckpoint
                )
                let reconciledProfiles = self.profilesReconcilingDisplayAliases(
                    after: snapshot,
                    activeProfileID: resolvedProfile.id
                )
                var publishedProfiles = self.profiles
                if reconciledProfiles != self.profiles {
                    do {
                        try await self.store.save(reconciledProfiles)
                        publishedProfiles = reconciledProfiles
                        self.alignActivePresentationSource(
                            in: reconciledProfiles,
                            activeProfileID: resolvedProfile.id
                        )
                    } catch {
                        Logger(category: "Profiles").error("Display alias persistence failed")
                    }
                }
                let coordinatorProfileID = await appState.compatibilityCoordinator.activeProfileID
                var expectedWorkspace = ProfileWorkspaceState(profile: resolvedProfile)
                expectedWorkspace.presentation = self.activePresentation
                guard coordinatorProfileID == resolvedProfile.id,
                      self.currentWorkspaceState() == expectedWorkspace
                else {
                    _ = await appState.compatibilityCoordinator.clearActiveProfileAuthority(
                        ifMatches: resolvedProfile.id
                    )
                    self.setActiveProfileAuthorityToken(nil)
                    throw MenuBarWorkspaceTransactionError.superseded
                }
                return (
                    profileID: resolvedProfile.id,
                    authorityToken: resolvedAuthorityToken,
                    profiles: publishedProfiles
                )
            } catch {
                if let priorRequest {
                    self.activationRequests[source] = priorRequest
                } else {
                    self.activationRequests.removeValue(forKey: source)
                }
                if self.pendingFocusAuthority(matching: resolvedAuthorityToken) != nil {
                    self.activeProfileID = nil
                    self.activeProfileActivatedAt = nil
                    // Keep the workspace presentation actually left by apply/rollback.
                    // Clearing profile authority must not fabricate a nil workspace:
                    // pending recovery compares this live state with its checkpoint.
                    self.processedDefaults.removeObject(
                        forKey: Self.activeProfileAuthorityTokenKey
                    )
                } else if await appState.compatibilityCoordinator.activeProfileID == nil {
                    self.activeProfileID = nil
                    self.activeProfileActivatedAt = nil
                    self.activePresentation = nil
                    self.setActiveProfileAuthorityToken(nil)
                } else {
                    self.setActiveProfileAuthorityToken(priorAuthorityToken)
                }
                throw error
            }
        } completion: { [weak self] result in
            guard let self else { return }
            profiles = result.profiles
            activeProfileID = result.profileID
            activeProfileActivatedAt = Date()
            setActiveProfileAuthorityToken(result.authorityToken)
            persistActiveProfileAuthority(
                profileID: result.profileID,
                token: result.authorityToken
            )
            didActivate = true
        }
        return didActivate
    }

    @discardableResult
    func update(
        _ profile: BarlineProfile,
        name: String,
        symbol: String?,
        groups: [ProfileGroup],
        spacers: [ProfileSpacer],
        displayOverrides: [DisplayProfileOverride]? = nil
    ) async -> Bool {
        var didSave = false
        appState?.contextualRules.pauseForManualChange()
        await performOperation(successMessage: "Profile updated.") {
            guard let index = self.profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw MenuBarBackendError.operationFailed("profile is unavailable")
            }
            let current = self.profiles[index]
            guard current == profile else {
                throw MenuBarBackendError.operationFailed("layout changed while editing; reopen the editor")
            }
            let variants = displayOverrides ?? current.displayOverrides
            if current.groups != groups || current.spacers != spacers || current.displayOverrides != variants {
                try self.validateProfileDefinitionMutation(profileID: current.id)
            }
            let updatedProfile = BarlineProfile(
                id: current.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                symbol: symbol,
                layout: current.layout,
                groups: groups,
                spacers: spacers,
                displayOverrides: variants,
                appearance: current.appearance,
                shelfBehavior: current.shelfBehavior,
                revealTriggers: current.revealTriggers,
                autoRehide: current.autoRehide,
                applicationMenuOverlapBehavior: current.applicationMenuOverlapBehavior,
                hotkey: current.hotkey,
                createdAt: current.createdAt,
                updatedAt: Date()
            )
            var updated = self.profiles
            updated[index] = updatedProfile
            try await self.store.save(updated)
            let presentationChanged = current.groups != groups || current.spacers != spacers || current.displayOverrides != variants
            let shouldInvalidatePublishedAuthority = presentationChanged
                && self.activeProfileID == current.id
            let invalidatedCoordinatorAuthority = if presentationChanged,
                                                     let appState = self.appState
            {
                await appState.compatibilityCoordinator.clearActiveProfileAuthority(
                    ifMatches: current.id
                )
            } else {
                false
            }
            return (
                profiles: updated,
                invalidatedAuthority: shouldInvalidatePublishedAuthority
                    || invalidatedCoordinatorAuthority
            )
        } completion: { [weak self] saved in
            didSave = true
            self?.profiles = saved.profiles
            if saved.invalidatedAuthority {
                self?.activeProfileID = nil
                self?.activeProfileActivatedAt = nil
                self?.activePresentation = nil
                self?.setActiveProfileAuthorityToken(nil)
            }
            if profile.name == "Presentation"
                || profile.id == PresentationProfileTemplateBuilder.profileID
            {
                self?.processedDefaults.set(
                    profile.id.uuidString,
                    forKey: Self.presentationProfileIDKey
                )
            }
            self?.publishCatalog()
        }
        return didSave
    }

    func resetFromCurrentWorkspace(_ profile: BarlineProfile) async {
        appState?.contextualRules.pauseForManualChange()
        guard let appState else { return }
        await performOperation(successMessage: "Profile reset from the current workspace.") {
            guard let index = self.profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw MenuBarBackendError.operationFailed("profile is unavailable")
            }
            let current = self.profiles[index]
            try self.validateProfileDefinitionMutation(profileID: current.id)
            let snapshot = try await appState.compatibilityCoordinator.refresh()
            let reset = self.profileFromCurrentWorkspace(
                id: current.id,
                name: current.name,
                symbol: current.symbol,
                snapshot: snapshot,
                createdAt: current.createdAt,
                groups: [],
                spacers: []
            )
            var updated = self.profiles
            updated[index] = reset
            try await self.store.save(updated)
            let clearedAuthority = await appState.compatibilityCoordinator.clearActiveProfileAuthority(
                ifMatches: current.id
            )
            return (
                profiles: updated,
                profileID: current.id,
                clearedAuthority: clearedAuthority
            )
        } completion: { [weak self] updated in
            guard let self else { return }
            profiles = updated.profiles
            if activeProfileID == updated.profileID || updated.clearedAuthority {
                activeProfileID = nil
                activeProfileActivatedAt = nil
                activePresentation = nil
                setActiveProfileAuthorityToken(nil)
            }
            activationRequests = activationRequests.filter {
                $0.value.profileID != updated.profileID
            }
            publishCatalog()
        }
    }

    func restoreLastKnownGoodLayout() async {
        appState?.contextualRules.pauseForManualChange()
        guard let appState else { return }
        await performOperation(successMessage: "Last-known-good layout restored.") {
            _ = try await appState.compatibilityCoordinator.perform(.restoreLastKnownGood)
            return await appState.compatibilityCoordinator.activeProfileID
        } completion: { [weak self] profileID in
            guard let self else { return }
            activeProfileID = profileID
            activeProfileActivatedAt = profileID == nil ? nil : Date()
            if profileID == nil {
                activePresentation = nil
                activationRequests.removeAll()
                setActiveProfileAuthorityToken(nil)
            }
        }
    }

    /// A user-confirmed restore, not an automatic claim of Focus ownership.
    /// Bind confirmation to the exact transaction so a newer journal cannot be restored.
    func restoreInterruptedFocusLayout(confirmedToken: UUID) async {
        guard let appState else { return }
        appState.contextualRules.pauseForManualChange()
        await performOperation(successMessage: "Pre-Focus layout restored.") {
            guard let pending = self.recoverableFocusAuthority(matching: confirmedToken),
                  let checkpoint = pending.checkpoint,
                  let encoded = try? JSONEncoder().encode(checkpoint),
                  self.decodeFocusCheckpoint(encoded) != nil
            else {
                throw MenuBarWorkspaceTransactionError.superseded
            }
            do {
                _ = try await appState.compatibilityCoordinator.restoreWorkspaceCheckpoint(
                    checkpoint,
                    workspaceTransaction: self.workspaceTransaction()
                )
            } catch {
                Logger(category: "Profiles").error("Focus recovery transaction failed: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
                throw error
            }
            guard self.recoverableFocusAuthority(matching: confirmedToken) == pending,
                  await self.currentWorkspaceMatches(checkpoint)
            else {
                Logger(category: "Profiles").error("Focus recovery final verification failed")
                throw MenuBarWorkspaceTransactionError.superseded
            }
            return checkpoint
        } completion: { [weak self] checkpoint in
            guard let self else { return }
            restorePriorAuthorityAfterVerifiedRollback(checkpoint: checkpoint)
            activationRequests.removeValue(forKey: .focus)
            clearProfileBeforeFocus()
            manualRecoveryStore.remove(ifMatching: confirmedToken)
        }
    }

    func previewAvailableFocusRecovery(confirmedToken: UUID) async -> MenuBarPreparedWorkspaceRecovery? {
        await profileOperationSemaphore.wait()
        defer { profileOperationSemaphore.signal() }
        guard let appState, let pending = recoverableFocusAuthority(matching: confirmedToken),
              let checkpoint = pending.checkpoint else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let prepared = try await appState.compatibilityCoordinator.prepareAvailableWorkspaceRecovery(
                checkpoint, workspaceTransaction: workspaceTransaction()
            )
            guard recoverableFocusAuthority(matching: confirmedToken) == pending else {
                throw MenuBarWorkspaceTransactionError.superseded
            }
            return prepared
        } catch {
            statusMessage = "Recovery cannot be previewed safely. Leave the menu bar idle and check that the original displays are connected."
            return nil
        }
    }

    func restoreAvailableFocusLayout(confirmedToken: UUID, prepared: MenuBarPreparedWorkspaceRecovery) async {
        guard let appState else { return }
        appState.contextualRules.pauseForManualChange()
        await performOperation(successMessage: "Available items restored. The original checkpoint is retained because this is not an exact full restoration.") {
            guard let pending = self.recoverableFocusAuthority(matching: confirmedToken),
                  pending.checkpoint == prepared.checkpoint
            else {
                throw MenuBarWorkspaceTransactionError.superseded
            }
            try self.manualRecoveryStore.validateArchiving(pending)
            let restored = try await appState.compatibilityCoordinator.restoreAvailableWorkspaceRecovery(
                prepared, workspaceTransaction: self.workspaceTransaction()
            )
            guard self.recoverableFocusAuthority(matching: confirmedToken) == pending,
                  await self.currentWorkspaceMatches(restored)
            else {
                throw MenuBarWorkspaceTransactionError.superseded
            }
            try self.manualRecoveryStore.archive(pending)
            try self.finishArchivedFocusRecovery(pending)
            return restored
        } completion: { [weak self] restored in
            guard let self else { return }
            activeProfileID = nil
            activeProfileActivatedAt = nil
            activePresentation = restored.workspace.presentation
            activationRequests.removeValue(forKey: .focus)
        }
    }

    func undoLayoutChange() async {
        appState?.contextualRules.pauseForManualChange()
        await performHistoryChange(isUndo: true)
    }

    func redoLayoutChange() async {
        appState?.contextualRules.pauseForManualChange()
        await performHistoryChange(isUndo: false)
    }

    func archiveData() async -> Data? {
        guard !profiles.isEmpty else {
            statusMessage = "Create a profile before exporting an archive."
            return nil
        }
        isBusy = true
        defer { isBusy = false }
        let profiles = profiles
        do {
            let data = try await Task.detached {
                try ProfileCodec().export(profiles)
            }.value
            statusMessage = "Profile archive ready to save."
            return data
        } catch {
            statusMessage = "The profile archive could not be created."
            Logger(category: "Profiles").error("Profile archive export failed")
            return nil
        }
    }

    func previewArchiveImport(from url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let archive = try await Task.detached {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let limit = ProfileCodec.maximumArchiveByteCount
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else {
                    throw ProfileValidationError.archiveTooLarge(data.count)
                }
                return try ProfileCodec().importArchive(data)
            }.value
            let existingIDs = Set(profiles.map(\.id))
            pendingArchiveImport = ProfileArchiveImportPreview(
                profiles: archive.profiles,
                conflictingProfileIDs: Set(archive.profiles.map(\.id)).intersection(existingIDs)
            )
            statusMessage = "Review the validated archive before importing."
        } catch {
            pendingArchiveImport = nil
            statusMessage = "This profile archive is invalid or unreadable."
            Logger(category: "Profiles").error("Profile archive import validation failed")
        }
    }

    func cancelArchiveImport() {
        pendingArchiveImport = nil
        statusMessage = "Profile import cancelled."
    }

    func commitArchiveImport(replacingExisting: Bool) async {
        guard let preview = pendingArchiveImport else { return }
        await performOperation(successMessage: "Profile archive imported.") {
            let importedIDs = Set(preview.profiles.map(\.id))
            if replacingExisting {
                for profileID in importedIDs where self.profiles.contains(where: { $0.id == profileID }) {
                    try self.validateProfileDefinitionMutation(profileID: profileID)
                }
            }
            let importedProfiles = replacingExisting
                ? preview.profiles
                : preview.profiles.filter { imported in
                    !self.profiles.contains(where: { $0.id == imported.id })
                }
            guard !importedProfiles.isEmpty else {
                throw MenuBarBackendError.operationFailed("every imported profile already exists")
            }
            let retained = self.profiles.filter {
                !replacingExisting || !importedIDs.contains($0.id)
            }
            let updated = retained + importedProfiles
            try await self.store.save(updated)
            let invalidatedAuthority: Bool = if replacingExisting,
                                                let appState = self.appState,
                                                let coordinatorProfileID = await appState.compatibilityCoordinator.activeProfileID,
                                                importedIDs.contains(coordinatorProfileID)
            {
                await appState.compatibilityCoordinator
                    .clearActiveProfileAuthority(ifMatches: coordinatorProfileID)
            } else {
                false
            }
            return (
                profiles: updated,
                invalidatedAuthority: invalidatedAuthority,
                importedIDs: importedIDs
            )
        } completion: { [weak self] result in
            if result.invalidatedAuthority {
                self?.activationRequests = self?.activationRequests.filter {
                    !result.importedIDs.contains($0.value.profileID)
                } ?? [:]
                self?.activeProfileID = nil
                self?.activeProfileActivatedAt = nil
                self?.activePresentation = nil
                self?.setActiveProfileAuthorityToken(nil)
            }
            self?.profiles = result.profiles
            self?.pendingArchiveImport = nil
            self?.publishCatalog()
        }
    }

    func discoverIceImports() async {
        guard let appState else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let snapshot = try await appState.compatibilityCoordinator.refresh()
            let preferences = await IceDefaultsDomainReader().discover()
            let previews = try preferences.map {
                try IceProfileImporter().preview(preferences: $0, currentSnapshot: snapshot)
            }
            pendingIceImports = previews
            statusMessage = previews.isEmpty
                ? "No supported Ice preferences were found."
                : "Review the Ice import before saving it as a Barline profile."
        } catch {
            pendingIceImports = []
            statusMessage = "Ice preferences could not be previewed from the current layout."
            Logger(category: "Profiles").error("Ice profile import preview failed")
        }
    }

    func cancelIceImports() {
        pendingIceImports = []
        statusMessage = "Ice import cancelled."
    }

    func commitIceImport(_ preview: IceImportPreview, replacingExisting: Bool) async {
        await performOperation(successMessage: "Ice settings imported as a Barline profile.") {
            if replacingExisting,
               self.profiles.contains(where: { $0.id == preview.profile.id })
            {
                try self.validateProfileDefinitionMutation(profileID: preview.profile.id)
            }
            let updated = try await self.store.commit(
                preview,
                confirmed: true,
                replacingExisting: replacingExisting
            )
            let invalidatedAuthority: Bool = if replacingExisting, let appState = self.appState {
                await appState.compatibilityCoordinator
                    .clearActiveProfileAuthority(ifMatches: preview.profile.id)
            } else {
                false
            }
            return (profiles: updated, invalidatedAuthority: invalidatedAuthority)
        } completion: { [weak self] result in
            if result.invalidatedAuthority {
                self?.activationRequests = self?.activationRequests.filter {
                    $0.value.profileID != preview.profile.id
                } ?? [:]
                self?.activeProfileID = nil
                self?.activeProfileActivatedAt = nil
                self?.activePresentation = nil
                self?.setActiveProfileAuthorityToken(nil)
            }
            self?.profiles = result.profiles
            self?.pendingIceImports.removeAll { $0.source == preview.source }
            self?.publishCatalog()
        }
    }

    func delete(_ profile: BarlineProfile) async {
        appState?.contextualRules.pauseForManualChange()
        await performOperation(successMessage: "Profile deleted.") {
            try self.validateProfileDefinitionMutation(profileID: profile.id)
            let remaining = self.profiles.filter { $0.id != profile.id }
            try await self.store.save(remaining)
            let invalidatedAuthority = await self.appState?.compatibilityCoordinator
                .clearActiveProfileAuthority(ifMatches: profile.id) == true
            return (profiles: remaining, invalidatedAuthority: invalidatedAuthority)
        } completion: { [weak self] result in
            self?.activationRequests = self?.activationRequests.filter { $0.value.profileID != profile.id } ?? [:]
            self?.profiles = result.profiles
            if result.invalidatedAuthority {
                self?.activeProfileID = nil
                self?.activeProfileActivatedAt = nil
                self?.activePresentation = nil
                self?.setActiveProfileAuthorityToken(nil)
            }
            self?.publishCatalog()
        }
    }

    private func profileFromCurrentWorkspace(
        id: UUID = UUID(),
        name: String,
        symbol: String? = nil,
        snapshot: MenuBarSnapshot,
        createdAt: Date = Date(),
        groups: [ProfileGroup]? = nil,
        spacers: [ProfileSpacer]? = nil
    ) -> BarlineProfile {
        let ordered = snapshot.items.sorted { lhs, rhs in
            lhs.section == rhs.section
                ? lhs.order < rhs.order
                : lhs.section.rawValue < rhs.section.rawValue
        }
        guard let appState else {
            return BarlineProfile(id: id, name: name, symbol: symbol, createdAt: createdAt)
        }
        let general = appState.settings.general
        let advanced = appState.settings.advanced
        let appearanceConfiguration = appState.appearanceManager.configuration
        return BarlineProfile(
            id: id,
            name: name,
            symbol: symbol,
            layout: ProfileLayout(
                visible: ordered.filter { $0.section == .visible }.map(\.id),
                hidden: ordered.filter { $0.section == .hidden }.map(\.id),
                alwaysHidden: ordered.filter { $0.section == .alwaysHidden }.map(\.id)
            ),
            groups: groups ?? activePresentation?.groups ?? [],
            spacers: spacers ?? activePresentation?.spacers ?? [],
            appearance: ProfileAppearance(
                tintHex: profileTintHex(from: appearanceConfiguration.staticConfiguration),
                gradientHex: profileGradientHex(from: appearanceConfiguration.staticConfiguration),
                gradientStops: profileGradientStops(from: appearanceConfiguration.staticConfiguration),
                showsBorder: appearanceConfiguration.staticConfiguration.hasBorder,
                borderHex: hexString(from: appearanceConfiguration.staticConfiguration.borderColor) ?? "#000000",
                borderWidth: appearanceConfiguration.staticConfiguration.borderWidth,
                showsShadow: appearanceConfiguration.staticConfiguration.hasShadow,
                shape: profileShape(from: appearanceConfiguration.shapeKind),
                shapeDetails: profileShapeDetails(from: appearanceConfiguration),
                itemSpacing: min(
                    max(general.itemSpacingOffset, ProfileAppearance.itemSpacingRange.lowerBound),
                    ProfileAppearance.itemSpacingRange.upperBound
                ),
                dynamicAppearance: dynamicProfileAppearance(from: appearanceConfiguration),
                isDynamic: appearanceConfiguration.isDynamic
            ),
            shelfBehavior: ProfileShelfBehavior(isEnabled: general.useBarlineShelf),
            revealTriggers: ProfileRevealTriggers(
                click: general.showOnClick,
                hover: general.showOnHover,
                scroll: general.showOnScroll
            ),
            autoRehide: ProfileAutoRehide(
                isEnabled: general.autoRehide,
                strategy: profileRehideStrategy(from: general.rehideStrategy),
                delaySeconds: max(0, general.rehideInterval)
            ),
            applicationMenuOverlapBehavior:
            advanced.hideApplicationMenus ? .hideWhenNeeded : .leaveVisible,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }

    private func applyWorkspaceSettings(_ workspace: ProfileWorkspaceState) {
        isApplyingWorkspaceSettings = true
        defer { isApplyingWorkspaceSettings = false }
        guard let appState else { return }
        let general = appState.settings.general
        general.useBarlineShelf = workspace.shelfBehavior.isEnabled
        general.showOnClick = workspace.revealTriggers.click
        general.showOnHover = workspace.revealTriggers.hover
        general.showOnScroll = workspace.revealTriggers.scroll
        general.itemSpacingOffset = workspace.appearance.itemSpacing
        general.autoRehide = workspace.autoRehide.isEnabled
        general.rehideStrategy = rehideStrategy(from: workspace.autoRehide.strategy)
        general.rehideInterval = workspace.autoRehide.delaySeconds
        appState.settings.advanced.hideApplicationMenus =
            workspace.applicationMenuOverlapBehavior == .hideWhenNeeded
    }

    private func currentWorkspaceState() -> ProfileWorkspaceState {
        guard let appState else {
            return ProfileWorkspaceState(profile: BarlineProfile(name: "Unavailable workspace"))
        }
        let general = appState.settings.general
        let appearanceConfiguration = appState.appearanceManager.configuration
        return ProfileWorkspaceState(
            appearance: ProfileAppearance(
                tintHex: profileTintHex(from: appearanceConfiguration.staticConfiguration),
                gradientHex: profileGradientHex(from: appearanceConfiguration.staticConfiguration),
                gradientStops: profileGradientStops(from: appearanceConfiguration.staticConfiguration),
                showsBorder: appearanceConfiguration.staticConfiguration.hasBorder,
                borderHex: hexString(from: appearanceConfiguration.staticConfiguration.borderColor) ?? "#000000",
                borderWidth: appearanceConfiguration.staticConfiguration.borderWidth,
                showsShadow: appearanceConfiguration.staticConfiguration.hasShadow,
                shape: profileShape(from: appearanceConfiguration.shapeKind),
                shapeDetails: profileShapeDetails(from: appearanceConfiguration),
                itemSpacing: general.itemSpacingOffset,
                dynamicAppearance: dynamicProfileAppearance(from: appearanceConfiguration),
                isDynamic: appearanceConfiguration.isDynamic
            ),
            shelfBehavior: ProfileShelfBehavior(isEnabled: general.useBarlineShelf),
            revealTriggers: ProfileRevealTriggers(
                click: general.showOnClick,
                hover: general.showOnHover,
                scroll: general.showOnScroll
            ),
            autoRehide: ProfileAutoRehide(
                isEnabled: general.autoRehide,
                strategy: profileRehideStrategy(from: general.rehideStrategy),
                delaySeconds: general.rehideInterval
            ),
            applicationMenuOverlapBehavior:
            appState.settings.advanced.hideApplicationMenus ? .hideWhenNeeded : .leaveVisible,
            presentation: activePresentation
        )
    }

    @discardableResult
    private func applyWorkspaceState(
        _ workspace: ProfileWorkspaceState,
        expectedRevision: UInt64? = nil
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        guard let appState else {
            throw MenuBarBackendError.operationFailed("app state unavailable")
        }
        try ProfileValidator().validate(workspace)
        let revision = expectedRevision ?? workspaceRevision
        guard workspaceRevision == revision else {
            throw MenuBarWorkspaceTransactionError.superseded
        }
        let workspaceBeforeSpacing = currentWorkspaceState()
        let spacing = Int(workspace.appearance.itemSpacing)
        if Double(spacing) != appState.settings.general.itemSpacingOffset {
            appState.spacingManager.offset = spacing
            do {
                try await appState.spacingManager.applyOffset()
            } catch {
                do {
                    try await restoreCurrentModeledSpacing()
                } catch {
                    throw MenuBarWorkspaceTransactionError.sideEffectRecoveryFailed
                }
                throw MenuBarWorkspaceTransactionError.superseded
            }
        }
        guard workspaceRevision == revision,
              currentWorkspaceState() == workspaceBeforeSpacing
        else {
            do {
                try await restoreCurrentModeledSpacing()
            } catch {
                throw MenuBarWorkspaceTransactionError.sideEffectRecoveryFailed
            }
            throw MenuBarWorkspaceTransactionError.superseded
        }
        isApplyingWorkspaceSettings = true
        defer { isApplyingWorkspaceSettings = false }
        appState.appearanceManager.configuration = try appearanceConfiguration(
            applying: workspace.appearance,
            to: appState.appearanceManager.configuration
        )
        applyWorkspaceSettings(workspace)
        let presentationChanged = activePresentation != workspace.presentation
        activePresentation = workspace.presentation
        if presentationChanged {
            workspaceRevision &+= 1
        }
        return workspaceRevision
    }

    /// A spacing write reaches macOS before the rest of the modeled workspace
    /// is committed. If an edit supersedes the transaction while that write is
    /// awaiting completion, put the physical default back in sync with the
    /// newest authoritative setting before reporting a side-effect-free abort.
    private func restoreCurrentModeledSpacing() async throws {
        guard let appState else {
            throw MenuBarBackendError.operationFailed("app state unavailable")
        }
        for _ in 0 ..< 3 {
            let expectedSpacing = appState.settings.general.itemSpacingOffset
            appState.spacingManager.offset = Int(expectedSpacing)
            try await appState.spacingManager.applyOffset()
            if appState.settings.general.itemSpacingOffset == expectedSpacing {
                return
            }
        }
        throw MenuBarBackendError.operationFailed(
            "item spacing changed repeatedly during profile rollback"
        )
    }

    private func profileRehideStrategy(from strategy: RehideStrategy) -> ProfileAutoRehideStrategy {
        switch strategy {
        case .smart: .smart
        case .timed: .timed
        case .focusedApp: .focusedApp
        }
    }

    private func rehideStrategy(from strategy: ProfileAutoRehideStrategy) -> RehideStrategy {
        switch strategy {
        case .smart: .smart
        case .timed: .timed
        case .focusedApp: .focusedApp
        }
    }

    private func profileShape(from shape: MenuBarShapeKind) -> ProfileAppearance.Shape {
        switch shape {
        case .noShape: .standard
        case .full: .rounded
        case .split: .split
        }
    }

    private func profileTintHex(from configuration: MenuBarAppearancePartialConfiguration) -> String? {
        guard configuration.tintKind == .solid else { return nil }
        return hexString(from: configuration.tintColor)
    }

    private func profileGradientHex(from configuration: MenuBarAppearancePartialConfiguration) -> [String] {
        guard configuration.tintKind == .gradient else { return [] }
        return configuration.tintGradient.stops.compactMap { hexString(from: $0.color) }
    }

    private func profileGradientStops(
        from configuration: MenuBarAppearancePartialConfiguration
    ) -> [ProfileGradientStop] {
        guard configuration.tintKind == .gradient else { return [] }
        return configuration.tintGradient.stops.compactMap { stop in
            hexString(from: stop.color).map {
                ProfileGradientStop(colorHex: $0, location: Double(stop.location))
            }
        }
    }

    private func profileEndCap(from endCap: MenuBarEndCap) -> ProfileEndCap {
        switch endCap {
        case .square: .square
        case .round: .round
        }
    }

    private func menuBarEndCap(from endCap: ProfileEndCap) -> MenuBarEndCap {
        switch endCap {
        case .square: .square
        case .round: .round
        }
    }

    private func profileFullShape(from shape: MenuBarFullShapeInfo) -> ProfileFullShape {
        ProfileFullShape(
            leading: profileEndCap(from: shape.leadingEndCap),
            trailing: profileEndCap(from: shape.trailingEndCap)
        )
    }

    private func menuBarFullShape(from shape: ProfileFullShape) -> MenuBarFullShapeInfo {
        MenuBarFullShapeInfo(
            leadingEndCap: menuBarEndCap(from: shape.leading),
            trailingEndCap: menuBarEndCap(from: shape.trailing)
        )
    }

    private func profileShapeDetails(
        from configuration: MenuBarAppearanceConfigurationV2
    ) -> ProfileShapeDetails {
        ProfileShapeDetails(
            full: profileFullShape(from: configuration.fullShapeInfo),
            splitLeading: profileFullShape(from: configuration.splitShapeInfo.leading),
            splitTrailing: profileFullShape(from: configuration.splitShapeInfo.trailing),
            isInset: configuration.isInset
        )
    }

    private func profileAppearanceMode(
        from configuration: MenuBarAppearancePartialConfiguration
    ) -> ProfileAppearanceMode {
        ProfileAppearanceMode(
            tintHex: profileTintHex(from: configuration),
            gradientHex: profileGradientHex(from: configuration),
            gradientStops: profileGradientStops(from: configuration),
            showsBorder: configuration.hasBorder,
            borderHex: hexString(from: configuration.borderColor) ?? "#000000",
            borderWidth: configuration.borderWidth,
            showsShadow: configuration.hasShadow
        )
    }

    private func dynamicProfileAppearance(
        from configuration: MenuBarAppearanceConfigurationV2
    ) -> ProfileDynamicAppearance {
        ProfileDynamicAppearance(
            light: profileAppearanceMode(from: configuration.lightModeConfiguration),
            dark: profileAppearanceMode(from: configuration.darkModeConfiguration)
        )
    }

    private func appearanceConfiguration(
        applying appearance: ProfileAppearance,
        to existing: MenuBarAppearanceConfigurationV2
    ) throws -> MenuBarAppearanceConfigurationV2 {
        var configuration = existing
        var partial = configuration.current
        partial.hasBorder = appearance.showsBorder
        partial.borderColor = try color(from: appearance.borderHex)
        partial.borderWidth = appearance.borderWidth
        partial.hasShadow = appearance.showsShadow
        if !appearance.gradientStops.isEmpty {
            partial.tintKind = .gradient
            partial.tintGradient = try BarlineGradient(
                stops: appearance.gradientStops.map { stop in
                    try .stop(color(from: stop.colorHex), location: CGFloat(stop.location))
                }
            )
        } else if let tintHex = appearance.tintHex {
            partial.tintKind = .solid
            partial.tintColor = try color(from: tintHex)
        } else {
            partial.tintKind = .noTint
        }
        configuration.staticConfiguration = partial
        if let dynamicAppearance = appearance.dynamicAppearance {
            configuration.lightModeConfiguration = try appearancePartialConfiguration(
                applying: dynamicAppearance.light,
                to: configuration.lightModeConfiguration
            )
            configuration.darkModeConfiguration = try appearancePartialConfiguration(
                applying: dynamicAppearance.dark,
                to: configuration.darkModeConfiguration
            )
            configuration.isDynamic = appearance.isDynamic
        } else {
            configuration.lightModeConfiguration = partial
            configuration.darkModeConfiguration = partial
            configuration.isDynamic = false
        }
        configuration.shapeKind = switch appearance.shape {
        case .standard: .noShape
        case .rounded: .full
        case .split: .split
        }
        configuration.fullShapeInfo = menuBarFullShape(from: appearance.shapeDetails.full)
        configuration.splitShapeInfo = MenuBarSplitShapeInfo(
            leading: menuBarFullShape(from: appearance.shapeDetails.splitLeading),
            trailing: menuBarFullShape(from: appearance.shapeDetails.splitTrailing)
        )
        configuration.isInset = appearance.shapeDetails.isInset
        return configuration
    }

    private func appearancePartialConfiguration(
        applying appearance: ProfileAppearanceMode,
        to existing: MenuBarAppearancePartialConfiguration
    ) throws -> MenuBarAppearancePartialConfiguration {
        var partial = existing
        partial.hasBorder = appearance.showsBorder
        partial.borderColor = try color(from: appearance.borderHex)
        partial.borderWidth = appearance.borderWidth
        partial.hasShadow = appearance.showsShadow
        if !appearance.gradientStops.isEmpty {
            partial.tintKind = .gradient
            partial.tintGradient = try BarlineGradient(
                stops: appearance.gradientStops.map { stop in
                    try .stop(color(from: stop.colorHex), location: CGFloat(stop.location))
                }
            )
        } else if let tintHex = appearance.tintHex {
            partial.tintKind = .solid
            partial.tintColor = try color(from: tintHex)
        } else {
            partial.tintKind = .noTint
        }
        return partial
    }

    private func color(from hex: String) throws -> CGColor {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6 || value.count == 8,
              let raw = UInt64(value, radix: 16)
        else {
            throw ProfileValidationError.invalidAppearance
        }
        let hasAlpha = value.count == 8
        let red = CGFloat((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(raw & 0xFF) / 255 : 1
        return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func hexString(from color: CGColor) -> String? {
        guard let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        let alpha = Int((converted.alphaComponent * 255).rounded())
        if alpha == 255 {
            return String(format: "#%02X%02X%02X", red, green, blue)
        }
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    private func workspaceTransaction() -> MenuBarWorkspaceTransaction {
        MenuBarWorkspaceTransaction(
            capture: { @MainActor [weak self] in
                guard let self else {
                    throw MenuBarBackendError.operationFailed("profile manager unavailable")
                }
                return currentWorkspaceState()
            },
            apply: { @MainActor [weak self] workspace in
                guard let self else {
                    throw MenuBarBackendError.operationFailed("profile manager unavailable")
                }
                try await applyWorkspaceState(workspace)
            },
            currentRevision: { @MainActor [weak self] in
                self?.workspaceRevision ?? 0
            },
            applyIfCurrent: { @MainActor [weak self] workspace, expectedRevision in
                guard let self, workspaceRevision == expectedRevision else { return nil }
                return try await applyWorkspaceState(
                    workspace,
                    expectedRevision: expectedRevision
                )
            },
            rollbackSuperseded: { @MainActor [weak self] target, original in
                guard let self else { return nil }
                let revision = workspaceRevision
                let current = currentWorkspaceState()
                guard workspaceRevision == revision else { return nil }
                let merged = current.rollingBackUnchangedFields(
                    applied: target,
                    to: original
                )
                do {
                    return try await applyWorkspaceState(
                        merged,
                        expectedRevision: revision
                    )
                } catch MenuBarWorkspaceTransactionError.superseded {
                    return nil
                }
            }
        )
    }

    private func configureBridgeObservers() {
        bridgeObserver = DarwinNotificationObserver(name: IntentCommandInbox.notificationName) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.processBridgeCommands()
            }
        }

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { await self?.processBridgeCommands() }
            }
            .store(in: &cancellables)
    }

    private func configureWorkspaceAuthorityObservers() {
        guard let appState else { return }
        let general = appState.settings.general
        let advanced = appState.settings.advanced
        let changes: [AnyPublisher<Void, Never>] = [
            appState.appearanceManager.$configuration.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            general.$useBarlineShelf.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            general.$showOnClick.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            general.$showOnHover.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            general.$showOnScroll.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            general.$itemSpacingOffset.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            general.$autoRehide.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            general.$rehideStrategy.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            general.$rehideInterval.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            advanced.$hideApplicationMenus.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(changes)
            .sink { [weak self] in
                self?.workspaceRevision &+= 1
                if self?.isApplyingWorkspaceSettings == false {
                    self?.appState?.contextualRules.pauseForManualChange()
                }
            }
            .store(in: &cancellables)

        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.reconcileActiveProfileAuthority()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.reconcileDisplayConnections()
                }
            }
            .store(in: &cancellables)
    }

    private func reconcileDisplayConnections() async {
        await profileOperationSemaphore.wait()
        defer { profileOperationSemaphore.signal() }
        guard let appState else { return }
        do {
            let snapshot = try await appState.compatibilityCoordinator.refresh()
            var reconciled = profilesReconcilingDisplayAliases(
                after: snapshot,
                activeProfileID: activeProfileID
            )
            let coordinatorProfileID = await appState.compatibilityCoordinator.activeProfileID
            if let activeProfileID,
               coordinatorProfileID == nil,
               let profile = reconciled.first(where: { $0.id == activeProfileID }),
               let reconnectDisplayID = reconnectDisplayID(
                   for: profile,
                   snapshot: snapshot
               )
            {
                let reactivated = try await appState.compatibilityCoordinator.activate(
                    profile: profile,
                    on: reconnectDisplayID,
                    workspaceTransaction: workspaceTransaction()
                )
                reconciled = profilesReconcilingDisplayAliases(
                    after: reactivated,
                    activeProfileID: activeProfileID
                )
                activeProfileActivatedAt = Date()
            } else if activeProfileID != nil, coordinatorProfileID == nil {
                activeProfileID = nil
                activeProfileActivatedAt = nil
                activePresentation = nil
                activationRequests.removeAll()
            }
            if reconciled != profiles {
                try await store.save(reconciled)
                profiles = reconciled
                alignActivePresentationSource(
                    in: reconciled,
                    activeProfileID: activeProfileID
                )
                publishCatalog()
            }
            if activeProfileID != nil {
                _ = try await synchronizeProfileAuthority(clearsActivationRequests: false)
            }
        } catch {
            Logger(category: "Profiles").error("Display reconciliation failed")
        }
    }

    private func reconnectDisplayID(
        for profile: BarlineProfile,
        snapshot: MenuBarSnapshot
    ) -> MenuBarDisplayID? {
        guard let activePresentation,
              case let .displayOverride(storedID) = activePresentation.source
        else {
            return nil
        }
        guard !snapshot.displayIDs.contains(storedID) else { return nil }
        let matches = snapshot.displayIDs.compactMap { liveID in
            DisplayProfileOverrideResolver().resolve(
                profile: profile,
                requestedDisplayID: liveID,
                snapshot: snapshot
            )
        }.filter {
            $0.override.displayID == storedID
                && $0.liveDisplayID != storedID
                && $0.method == .uniqueHardwareFingerprint
        }
        guard matches.count == 1 else { return nil }
        return matches[0].liveDisplayID
    }

    private func alignActivePresentationSource(
        in profiles: [BarlineProfile],
        activeProfileID: UUID?
    ) {
        guard let activeProfileID,
              let destinationDisplayID = activePresentation?.destinationDisplayID,
              profiles.first(where: { $0.id == activeProfileID })?.displayOverrides.contains(
                  where: { $0.displayID == destinationDisplayID }
              ) == true
        else {
            return
        }
        activePresentation?.source = .displayOverride(destinationDisplayID)
    }

    private func profilesReconcilingDisplayAliases(
        after snapshot: MenuBarSnapshot,
        activeProfileID: UUID?
    ) -> [BarlineProfile] {
        var updated = profiles
        let identities = snapshot.displayIdentities ?? []
        for profileIndex in updated.indices {
            for overrideIndex in updated[profileIndex].displayOverrides.indices {
                let storedID = updated[profileIndex].displayOverrides[overrideIndex].displayID
                if let fingerprint = snapshot.displayIdentity(for: storedID)?.hardwareFingerprint,
                   updated[profileIndex].displayOverrides[overrideIndex].displayFingerprint == nil,
                   identities.count(where: { $0.hardwareFingerprint == fingerprint }) == 1,
                   !updated[profileIndex].displayOverrides.enumerated().contains(where: {
                       $0.offset != overrideIndex && $0.element.displayFingerprint == fingerprint
                   })
                {
                    updated[profileIndex].displayOverrides[overrideIndex].displayFingerprint = fingerprint
                }
            }
        }

        guard let activeProfileID,
              let profileIndex = updated.firstIndex(where: { $0.id == activeProfileID }),
              let activePresentation,
              case let .displayOverride(storedID) = activePresentation.source,
              let liveID = activePresentation.destinationDisplayID,
              let overrideIndex = updated[profileIndex].displayOverrides.firstIndex(where: {
                  $0.displayID == storedID
              })
        else {
            return updated
        }
        updated[profileIndex].displayOverrides[overrideIndex].displayID = liveID
        if updated[profileIndex].displayOverrides[overrideIndex].displayFingerprint == nil,
           let fingerprint = snapshot.displayIdentity(for: liveID)?.hardwareFingerprint,
           identities.count(where: { $0.hardwareFingerprint == fingerprint }) == 1,
           !updated[profileIndex].displayOverrides.enumerated().contains(where: {
               $0.offset != overrideIndex && $0.element.displayFingerprint == fingerprint
           })
        {
            updated[profileIndex].displayOverrides[overrideIndex].displayFingerprint = fingerprint
        }
        return updated
    }

    func reconcileActiveProfileAuthority() async {
        await profileOperationSemaphore.wait()
        defer { profileOperationSemaphore.signal() }
        guard activeProfileID != nil else { return }

        do {
            let retainedProfileID = try await synchronizeProfileAuthority(
                clearsActivationRequests: false
            )
            if retainedProfileID != activeProfileID {
                activeProfileActivatedAt = retainedProfileID == nil ? nil : Date()
            }
            activeProfileID = retainedProfileID
            if retainedProfileID == nil {
                activePresentation = nil
                activationRequests.removeAll()
            }
        } catch {
            if let appState, let activeProfileID {
                _ = await appState.compatibilityCoordinator.clearActiveProfileAuthority(
                    ifMatches: activeProfileID
                )
            }
            activeProfileID = nil
            activeProfileActivatedAt = nil
            activePresentation = nil
            activationRequests.removeAll()
        }
    }

    func processPendingBridgeCommands() async {
        await processBridgeCommands()
    }

    private func processBridgeCommands() async {
        guard let appState, let commandInbox else { return }
        guard !isProcessingBridgeCommands else {
            needsBridgeCommandRescan = true
            return
        }

        isProcessingBridgeCommands = true
        appState.contextualRules.contextDidChange()
        defer {
            isProcessingBridgeCommands = false
            appState.contextualRules.contextDidChange()
        }

        repeat {
            needsBridgeCommandRescan = false
            let commands: [BarlineIntentCommand]
            do {
                commands = try await commandInbox.pendingCommands()
            } catch {
                Logger(category: "Profiles").error("Intent command inbox could not be read")
                scheduleBridgeRetry()
                return
            }

            for (index, command) in commands.enumerated() {
                if hasProcessed(command.id) {
                    try? await commandInbox.acknowledge(command.id)
                    continue
                }
                if command.kind != .openDestination,
                   !appState.permissions.accessibility.hasPermission
                {
                    statusMessage = "Accessibility is required before applying this pending command."
                    scheduleBridgeRetry()
                    continue
                }
                var requiresReview = false
                guard await handle(command, onFailure: {
                    requiresReview = IntentCommandFailurePolicy.requiresUserReview($0)
                }) else {
                    if requiresReview {
                        // Consume this rejected delivery, not the saved layout or
                        // recovery journal. A fresh user command can try again.
                        recordProcessed(command.id)
                        try? await commandInbox.acknowledge(command.id)
                        bridgeRetryAttempt = 0
                        continue
                    }
                    if command.kind == .setFocusProfile || command.kind == .setPresentationMode,
                       commands.dropFirst(index + 1).contains(where: {
                           $0.kind == .setFocusProfile || $0.kind == .setPresentationMode
                       })
                    {
                        recordProcessed(command.id)
                        try? await commandInbox.acknowledge(command.id)
                        continue
                    }
                    scheduleBridgeRetry()
                    break
                }
                bridgeRetryAttempt = 0
                recordProcessed(command.id)
                do {
                    try await commandInbox.acknowledge(command.id)
                } catch {
                    Logger(category: "Profiles").error("Processed intent command could not be acknowledged")
                }
            }
        } while needsBridgeCommandRescan
    }

    private func scheduleBridgeRetry() {
        guard bridgeRetryTask == nil else { return }
        bridgeRetryAttempt = min(bridgeRetryAttempt + 1, 6)
        let delaySeconds = min(1 << (bridgeRetryAttempt - 1), 30)
        bridgeRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self, !Task.isCancelled else { return }
            bridgeRetryTask = nil
            await processBridgeCommands()
        }
    }

    private func handle(
        _ command: BarlineIntentCommand,
        onFailure: ((any Error) -> Void)? = nil
    ) async -> Bool {
        guard let appState else { return false }

        if let requested = IntentCommandFailurePolicy.requestedFocusState(for: command) {
            processedDefaults.set(requested, forKey: Self.nativeFocusRequestedKey)
        }
        switch command.kind {
        case .openDestination:
            guard let destination = command.destination else { return true }
            switch destination {
            case .search:
                appState.menuBarManager.searchPanel.show()
            case .profiles:
                appState.navigationState.settingsNavigationIdentifier = .profiles
                appState.activate(withPolicy: .regular)
                appState.openWindow(.settings)
            case .settings:
                appState.activate(withPolicy: .regular)
                appState.openWindow(.settings)
            }
            return true

        case .activateProfile:
            guard let profileID = command.profileID,
                  let profile = profiles.first(where: { $0.id == profileID })
            else {
                statusMessage = "The profile requested by Shortcuts is no longer available."
                return true
            }
            return await activate(profile, source: .appIntent, onFailure: onFailure)

        case .setFocusProfile:
            return await applyFocusProfile(command.profileID, onFailure: onFailure)

        case .setPresentationMode:
            guard let isEnabled = command.presentationModeEnabled else { return true }
            return await applyFocusProfile(isEnabled ? resolvedPresentationProfile()?.id : nil, onFailure: onFailure)
        }
    }

    private func applyFocusProfile(_ profileID: UUID?, onFailure: ((any Error) -> Void)? = nil) async -> Bool {
        switch await recoverPendingFocusAuthority() {
        case .promoted:
            if let profileID, activeFocusProfile()?.id == profileID {
                return true
            }
        case .restored:
            if profileID == nil {
                return true
            }
        case .failed:
            return false
        case .none:
            break
        }
        if let profileID,
           processedDefaults.data(forKey: Self.workspaceBeforeFocusKey) != nil,
           let currentFocusProfile = activeFocusProfile(),
           currentFocusProfile.id != profileID
        {
            guard await applyFocusProfile(nil, onFailure: onFailure) else { return false }
            return await applyFocusProfile(profileID, onFailure: onFailure)
        }

        if let profileID {
            guard let presentation = profiles.first(where: { $0.id == profileID }) else {
                statusMessage = "The profile selected by this Focus is no longer available."
                return true
            }
            // A persisted workspace journal is the durable source of truth. It is
            // written before activation so a crash at any later point cannot cause
            // a retry to overwrite the user's original pre-Presentation workspace.
            let existingJournal = processedDefaults.data(forKey: Self.workspaceBeforeFocusKey)
            if let existingJournal {
                guard let checkpoint = decodeFocusCheckpoint(existingJournal) else {
                    statusMessage = "The pre-Presentation workspace checkpoint is invalid."
                    return false
                }
                if activeProfileID == presentation.id,
                   persistedProfileAuthority()?.activeAuthority?.profileID == presentation.id
                {
                    processedDefaults.set(true, forKey: Self.presentationFocusActiveKey)
                    processedDefaults.set(
                        presentation.id.uuidString,
                        forKey: Self.activeFocusProfileIDKey
                    )
                    return true
                }
                guard await currentWorkspaceMatches(checkpoint) else {
                    statusMessage = "Focus profile recovery evidence is incomplete."
                    return false
                }
                clearProfileBeforeFocus()
            }
            let priorAuthorityToken = activeProfileAuthorityToken()
            let priorPersistedAuthority = persistedProfileAuthority()?.activeAuthority.flatMap {
                $0.token == priorAuthorityToken ? $0 : nil
            }
            let focusAuthorityToken = processedDefaults.string(forKey: Self.focusAuthorityTokenKey)
                .flatMap(UUID.init(uuidString:)) ?? UUID()
            let journal: @Sendable (
                MenuBarWorkspaceCheckpoint,
                ResolvedProfilePresentation
            ) async throws -> Void = { @MainActor [weak self] checkpoint, resolvedPresentation in
                guard let self else {
                    throw MenuBarBackendError.operationFailed("profile manager unavailable")
                }
                let data = try JSONEncoder().encode(checkpoint)
                guard data.count <= ProfileCodec.maximumArchiveByteCount else {
                    throw ProfileValidationError.archiveTooLarge(data.count)
                }
                try persistPendingFocusAuthority(
                    profile: presentation,
                    token: focusAuthorityToken,
                    presentation: resolvedPresentation,
                    checkpoint: checkpoint,
                    priorAuthority: priorPersistedAuthority
                )
                processedDefaults.set(data, forKey: Self.workspaceBeforeFocusKey)
                guard processedDefaults.data(forKey: Self.workspaceBeforeFocusKey) == data else {
                    throw MenuBarBackendError.operationFailed("workspace journal persistence failed")
                }
                profileBeforeFocusID = checkpoint.activeProfileID
                processedDefaults.set(
                    checkpoint.activeProfileID?.uuidString,
                    forKey: Self.profileBeforeFocusIDKey
                )
                processedDefaults.set(
                    focusAuthorityToken.uuidString,
                    forKey: Self.focusAuthorityTokenKey
                )
                processedDefaults.set(
                    priorAuthorityToken?.uuidString,
                    forKey: Self.profileBeforeFocusAuthorityTokenKey
                )
            }
            guard await activate(
                presentation,
                source: .focus,
                authorityToken: focusAuthorityToken,
                prepareCheckpoint: journal,
                onFailure: onFailure
            ) else {
                activationRequests.removeValue(forKey: .focus)
                if let data = processedDefaults.data(forKey: Self.workspaceBeforeFocusKey),
                   let checkpoint = decodeFocusCheckpoint(data),
                   await currentWorkspaceMatches(checkpoint)
                {
                    restorePriorAuthorityAfterVerifiedRollback(checkpoint: checkpoint)
                    clearProfileBeforeFocus()
                }
                return false
            }
            processedDefaults.set(true, forKey: Self.presentationFocusActiveKey)
            processedDefaults.set(presentation.id.uuidString, forKey: Self.activeFocusProfileIDKey)
            return true
        }

        guard let appState else { return false }
        guard let data = processedDefaults.data(forKey: Self.workspaceBeforeFocusKey) else {
            if !processedDefaults.bool(forKey: Self.presentationFocusActiveKey) {
                activationRequests.removeValue(forKey: .focus)
                return true
            }
            statusMessage = "The pre-Focus workspace checkpoint is unavailable."
            return false
        }
        guard let checkpoint = decodeFocusCheckpoint(data) else {
            statusMessage = "The pre-Focus workspace checkpoint is unavailable."
            return false
        }
        if !processedDefaults.bool(forKey: Self.presentationFocusActiveKey),
           await currentWorkspaceMatches(checkpoint)
        {
            activationRequests.removeValue(forKey: .focus)
            clearProfileBeforeFocus()
            return true
        }
        guard let presentation = activeFocusProfile() else {
            activationRequests.removeValue(forKey: .focus)
            clearProfileBeforeFocus()
            return true
        }
        let focusAuthorityToken = processedDefaults.string(forKey: Self.focusAuthorityTokenKey)
            .flatMap(UUID.init(uuidString:))
        let authorityIsCurrent = focusAuthorityToken != nil
            && activeProfileAuthorityToken() == focusAuthorityToken
        var didFinish = false
        await performOperation(successMessage: nil, onFailure: onFailure) {
            let result = try await appState.compatibilityCoordinator.restoreWorkspaceCheckpoint(
                checkpoint,
                ifCurrentMatches: presentation,
                authorityIsCurrent: authorityIsCurrent,
                workspaceTransaction: self.workspaceTransaction()
            )
            guard case .restored = result else {
                let profileID = try await self.synchronizeProfileAuthority(
                    clearsActivationRequests: false
                )
                return (restored: false, profileID: profileID, authorityToken: self.activeProfileAuthorityToken())
            }
            let retainedProfileID = try await self.synchronizeProfileAuthority(
                clearsActivationRequests: false
            )
            let priorAuthorityToken = self.processedDefaults
                .string(forKey: Self.profileBeforeFocusAuthorityTokenKey)
                .flatMap(UUID.init(uuidString:))
            return (
                restored: true,
                profileID: retainedProfileID,
                authorityToken: retainedProfileID == checkpoint.activeProfileID
                    ? priorAuthorityToken
                    : nil
            )
        } completion: { [weak self] result in
            guard let self else { return }
            activeProfileID = result.profileID
            activeProfileActivatedAt = result.profileID == nil ? nil : Date()
            setActiveProfileAuthorityToken(result.profileID == nil ? nil : result.authorityToken)
            if let profileID = result.profileID, let token = result.authorityToken {
                persistActiveProfileAuthority(profileID: profileID, token: token)
            }
            didFinish = true
        }
        guard didFinish else {
            statusMessage = "Barline could not restore the pre-Focus workspace."
            return false
        }
        activationRequests.removeValue(forKey: .focus)
        clearProfileBeforeFocus()
        return true
    }

    private func profileMatchesCheckpoint(
        _ profile: BarlineProfile,
        checkpoint: MenuBarWorkspaceCheckpoint
    ) async -> Bool {
        guard let appState else { return false }
        let destinationSupport = await appState.compatibilityCoordinator.capabilities
            .moveDestinationSupport ?? .existingItemRequired
        return ProfileAuthorityMatcher.matches(
            profile: profile,
            checkpoint: checkpoint,
            destinationSupport: destinationSupport
        )
    }

    private func decodeFocusCheckpoint(_ data: Data) -> MenuBarWorkspaceCheckpoint? {
        guard data.count <= ProfileCodec.maximumArchiveByteCount,
              let checkpoint = try? JSONDecoder().decode(
                  MenuBarWorkspaceCheckpoint.self,
                  from: data
              ),
              (try? ProfileValidator().validate(checkpoint.workspace)) != nil
        else {
            return nil
        }
        switch SnapshotValidator().validate(
            checkpoint.snapshot,
            previous: nil,
            now: checkpoint.snapshot.capturedAt
        ) {
        case .success:
            return checkpoint
        case .failure:
            return nil
        }
    }

    private func currentWorkspaceMatches(_ expected: MenuBarWorkspaceCheckpoint) async -> Bool {
        guard let appState,
              let current = try? await appState.compatibilityCoordinator.captureWorkspaceCheckpoint(
                  workspaceTransaction: workspaceTransaction()
              )
        else {
            return false
        }
        return checkpointsHaveSameState(current, expected)
    }

    private func checkpointsHaveSameState(
        _ lhs: MenuBarWorkspaceCheckpoint,
        _ rhs: MenuBarWorkspaceCheckpoint
    ) -> Bool {
        guard lhs.activeProfileID == rhs.activeProfileID,
              lhs.activeDisplayID == rhs.activeDisplayID,
              lhs.workspace == rhs.workspace,
              lhs.snapshot.displayIDs == rhs.snapshot.displayIDs
        else {
            return false
        }
        let lhsLayout = Set(lhs.snapshot.items.map {
            WorkspaceLayoutItem(
                id: $0.id,
                displayID: $0.displayID,
                section: $0.section,
                order: $0.order
            )
        })
        let rhsLayout = Set(rhs.snapshot.items.map {
            WorkspaceLayoutItem(
                id: $0.id,
                displayID: $0.displayID,
                section: $0.section,
                order: $0.order
            )
        })
        return lhsLayout == rhsLayout
    }

    private func performHistoryChange(isUndo: Bool) async {
        guard let appState else { return }
        let successMessage = isUndo ? "Layout change undone." : "Layout change redone."
        await performOperation(successMessage: successMessage) {
            if isUndo {
                _ = try await appState.compatibilityCoordinator.undo(
                    workspaceTransaction: self.workspaceTransaction()
                )
            } else {
                _ = try await appState.compatibilityCoordinator.redo(
                    workspaceTransaction: self.workspaceTransaction()
                )
            }
            return try await self.synchronizeProfileAuthority()
        } completion: { [weak self] profileID in
            self?.activeProfileID = profileID
            self?.activeProfileActivatedAt = profileID == nil ? nil : Date()
        }
    }

    private func synchronizeProfileAuthority(
        clearsActivationRequests: Bool = true
    ) async throws -> UUID? {
        guard let appState else { return nil }
        if clearsActivationRequests {
            activationRequests.removeAll()
        }
        let checkpoint = try await appState.compatibilityCoordinator.captureWorkspaceCheckpoint(
            workspaceTransaction: workspaceTransaction()
        )
        let profileID = checkpoint.activeProfileID
        guard currentWorkspaceState() == checkpoint.workspace else {
            if let profileID {
                _ = await appState.compatibilityCoordinator.clearActiveProfileAuthority(
                    ifMatches: profileID
                )
            }
            activeProfileID = nil
            activeProfileActivatedAt = nil
            activePresentation = nil
            setActiveProfileAuthorityToken(nil)
            return nil
        }
        guard let profileID,
              let profile = profiles.first(where: { $0.id == profileID })
        else {
            activeProfileID = nil
            activeProfileActivatedAt = nil
            activePresentation = nil
            setActiveProfileAuthorityToken(nil)
            return nil
        }
        guard await profileMatchesCheckpoint(profile, checkpoint: checkpoint) else {
            _ = await appState.compatibilityCoordinator.clearActiveProfileAuthority(
                ifMatches: profileID
            )
            activeProfileID = nil
            activeProfileActivatedAt = nil
            activePresentation = nil
            setActiveProfileAuthorityToken(nil)
            return nil
        }
        if let token = activeProfileAuthorityToken() {
            persistActiveProfileAuthority(profileID: profileID, token: token)
        }
        return profileID
    }

    private func clearProfileBeforeFocus() {
        processedDefaults.set(false, forKey: Self.presentationFocusActiveKey)
        guard !processedDefaults.bool(forKey: Self.presentationFocusActiveKey) else {
            statusMessage = "Focus profile state could not be cleared."
            return
        }
        profileBeforeFocusID = nil
        processedDefaults.removeObject(forKey: Self.profileBeforeFocusIDKey)
        processedDefaults.removeObject(forKey: Self.workspaceBeforeFocusKey)
        processedDefaults.removeObject(forKey: Self.activeFocusProfileIDKey)
        processedDefaults.removeObject(forKey: Self.focusAuthorityTokenKey)
        processedDefaults.removeObject(forKey: Self.profileBeforeFocusAuthorityTokenKey)
    }

    private func activeProfileAuthorityToken() -> UUID? {
        processedDefaults.string(forKey: Self.activeProfileAuthorityTokenKey)
            .flatMap(UUID.init(uuidString:))
    }

    private func setActiveProfileAuthorityToken(_ token: UUID?) {
        if let token {
            processedDefaults.set(token.uuidString, forKey: Self.activeProfileAuthorityTokenKey)
        } else {
            processedDefaults.removeObject(forKey: Self.activeProfileAuthorityTokenKey)
            processedDefaults.removeObject(forKey: Self.activeProfileAuthorityKey)
        }
    }

    private func persistedProfileAuthority() -> ProfileAuthorityEnvelope? {
        authorityStore.load()
    }

    private func persistProfileAuthority(_ authority: ProfileAuthorityEnvelope) throws {
        try authorityStore.save(authority)
    }

    private func recoverableFocusAuthority(matching token: UUID? = nil) -> ProfileAuthorityEnvelope? {
        // A newer active transaction takes priority over an older manual receipt.
        let value = pendingFocusAuthority() ?? manualRecoveryStore.load()
        guard token == nil || value?.token == token else { return nil }
        return value
    }

    private func pendingFocusAuthority(matching token: UUID? = nil) -> ProfileAuthorityEnvelope? {
        guard let authority = persistedProfileAuthority(), authority.phase == .pendingFocus else {
            return nil
        }
        guard token == nil || authority.token == token else { return nil }
        return authority
    }

    private func persistPendingFocusAuthority(
        profile: BarlineProfile,
        token: UUID,
        presentation: ResolvedProfilePresentation,
        checkpoint: MenuBarWorkspaceCheckpoint,
        priorAuthority: ProfileActiveAuthority?
    ) throws {
        try persistProfileAuthority(ProfileAuthorityEnvelope(
            pendingFocusProfile: profile,
            token: token,
            presentation: presentation,
            checkpoint: checkpoint,
            priorAuthority: priorAuthority
        ))
    }

    private func persistActiveProfileAuthority(profileID: UUID, token: UUID) {
        guard let activePresentation else {
            setActiveProfileAuthorityToken(nil)
            return
        }
        do {
            try persistProfileAuthority(ProfileAuthorityEnvelope(active: ProfileActiveAuthority(
                profileID: profileID,
                token: token,
                presentation: activePresentation
            )))
        } catch {
            setActiveProfileAuthorityToken(nil)
        }
    }

    private func restorePriorAuthorityAfterVerifiedRollback(
        checkpoint: MenuBarWorkspaceCheckpoint
    ) {
        let priorAuthority = pendingFocusAuthority()?.priorAuthority
        activeProfileID = checkpoint.activeProfileID
        activeProfileActivatedAt = checkpoint.activeProfileID == nil ? nil : Date()
        activePresentation = checkpoint.workspace.presentation
        guard let priorAuthority,
              priorAuthority.profileID == checkpoint.activeProfileID,
              priorAuthority.presentation == checkpoint.workspace.presentation
        else {
            setActiveProfileAuthorityToken(nil)
            return
        }
        setActiveProfileAuthorityToken(priorAuthority.token)
        do {
            try persistProfileAuthority(ProfileAuthorityEnvelope(active: priorAuthority))
        } catch {
            setActiveProfileAuthorityToken(nil)
        }
    }

    private func finishArchivedFocusRecovery(_ pending: ProfileAuthorityEnvelope) throws {
        guard manualRecoveryStore.load() == pending else { throw MenuBarWorkspaceTransactionError.superseded }
        // Clear the journal first. A crash before removing pending authority is
        // recognized by the matching manual receipt and resumes only cleanup.
        clearProfileBeforeFocus()
        guard processedDefaults.data(forKey: Self.workspaceBeforeFocusKey) == nil,
              processedDefaults.string(forKey: Self.activeFocusProfileIDKey) == nil,
              !processedDefaults.bool(forKey: Self.presentationFocusActiveKey)
        else {
            throw MenuBarBackendError.operationFailed("partial recovery lifecycle cleanup failed")
        }
        setActiveProfileAuthorityToken(nil)
    }

    private func recoverPendingFocusAuthority() async -> PendingFocusRecoveryOutcome {
        defer { interruptedFocusRecoveryToken = recoverableFocusAuthority()?.token }
        guard let appState, let pending = pendingFocusAuthority() else { return .none }
        // Crash after writing the manual receipt but before clearing active keys:
        // finish cleanup, never replay the already-completed partial transaction.
        if manualRecoveryStore.load() == pending {
            activeProfileID = nil
            activeProfileActivatedAt = nil
            do {
                try finishArchivedFocusRecovery(pending)
                return .none
            } catch { return .failed }
        }
        guard let checkpoint = pending.checkpoint,
              let encodedCheckpoint = try? JSONEncoder().encode(checkpoint),
              decodeFocusCheckpoint(encodedCheckpoint) != nil,
              let profile = pending.pendingProfile,
              profile.id == pending.profileID,
              pending.priorAuthority?.profileID == checkpoint.activeProfileID
              || pending.priorAuthority == nil
        else {
            processedDefaults.removeObject(forKey: Self.activeProfileAuthorityTokenKey)
            statusMessage = "Focus profile recovery evidence is inconsistent."
            return .failed
        }
        if let currentToken = activeProfileAuthorityToken(),
           currentToken != pending.token,
           currentToken != pending.priorAuthority?.token
        {
            processedDefaults.removeObject(forKey: Self.activeProfileAuthorityTokenKey)
            statusMessage = "Focus profile recovery authority is inconsistent."
            return .failed
        }
        do {
            let result = try await appState.compatibilityCoordinator
                .recoverPendingProfileActivation(
                    profile: profile,
                    persistedPresentation: pending.presentation,
                    checkpoint: checkpoint,
                    workspaceTransaction: workspaceTransaction()
                )
            switch result {
            case let .promoted(presentation):
                let journalData = try JSONEncoder().encode(checkpoint)
                guard journalData.count <= ProfileCodec.maximumArchiveByteCount else {
                    throw ProfileValidationError.archiveTooLarge(journalData.count)
                }
                processedDefaults.set(journalData, forKey: Self.workspaceBeforeFocusKey)
                guard processedDefaults.data(forKey: Self.workspaceBeforeFocusKey) == journalData else {
                    throw MenuBarBackendError.operationFailed("workspace journal persistence failed")
                }
                profileBeforeFocusID = checkpoint.activeProfileID
                processedDefaults.set(
                    checkpoint.activeProfileID?.uuidString,
                    forKey: Self.profileBeforeFocusIDKey
                )
                processedDefaults.set(
                    pending.token.uuidString,
                    forKey: Self.focusAuthorityTokenKey
                )
                processedDefaults.set(
                    pending.priorAuthority?.token.uuidString,
                    forKey: Self.profileBeforeFocusAuthorityTokenKey
                )
                activePresentation = presentation
                activeProfileID = profile.id
                activeProfileActivatedAt = Date()
                setActiveProfileAuthorityToken(pending.token)
                try persistProfileAuthority(ProfileAuthorityEnvelope(active: ProfileActiveAuthority(
                    profileID: profile.id,
                    token: pending.token,
                    presentation: presentation
                )))
                processedDefaults.set(true, forKey: Self.presentationFocusActiveKey)
                processedDefaults.set(profile.id.uuidString, forKey: Self.activeFocusProfileIDKey)
                return .promoted
            case .restored:
                restorePriorAuthorityAfterVerifiedRollback(checkpoint: checkpoint)
                clearProfileBeforeFocus()
                return .restored
            case .unchanged:
                restorePriorAuthorityAfterVerifiedRollback(checkpoint: checkpoint)
                clearProfileBeforeFocus()
                return .restored
            case .inconclusive:
                activeProfileID = nil
                activeProfileActivatedAt = nil
                // Inconclusive is not a workspace mutation. Retain its observed
                // presentation so a later verified recovery can still compare it.
                processedDefaults.removeObject(forKey: Self.activeProfileAuthorityTokenKey)
                statusMessage = "Barline preserved an interrupted Focus profile recovery for review."
                return .failed
            }
        } catch {
            activeProfileID = nil
            activeProfileActivatedAt = nil
            // Recovery failure cannot author a replacement workspace either.
            processedDefaults.removeObject(forKey: Self.activeProfileAuthorityTokenKey)
            statusMessage = "Barline could not recover an interrupted Focus profile activation."
            return .failed
        }
    }

    private func rehydrateActiveProfileAuthority() async {
        await profileOperationSemaphore.wait()
        defer { profileOperationSemaphore.signal() }
        if pendingFocusAuthority() != nil {
            _ = await recoverPendingFocusAuthority()
            return
        }
        guard let appState,
              let authority = persistedProfileAuthority()?.activeAuthority,
              activeProfileAuthorityToken() == authority.token,
              let profile = profiles.first(where: { $0.id == authority.profileID })
        else {
            setActiveProfileAuthorityToken(nil)
            return
        }
        do {
            activePresentation = authority.presentation
            guard let normalizedPresentation = try await appState.compatibilityCoordinator
                .rehydrateActiveProfileAuthority(
                    profile: profile,
                    persistedPresentation: authority.presentation,
                    workspaceTransaction: workspaceTransaction()
                )
            else {
                activePresentation = nil
                setActiveProfileAuthorityToken(nil)
                return
            }
            activePresentation = normalizedPresentation
            activeProfileID = profile.id
            activeProfileActivatedAt = Date()
            persistActiveProfileAuthority(profileID: profile.id, token: authority.token)
        } catch {
            activeProfileID = nil
            activeProfileActivatedAt = nil
            activePresentation = nil
            setActiveProfileAuthorityToken(nil)
        }
    }

    func clearActiveProfileAuthority(ifMatches expectedProfileID: UUID?) async {
        await profileOperationSemaphore.wait()
        defer { profileOperationSemaphore.signal() }
        guard let appState else { return }
        if let expectedProfileID {
            _ = await appState.compatibilityCoordinator.clearActiveProfileAuthority(
                ifMatches: expectedProfileID
            )
        }
        do {
            let retainedProfileID = try await synchronizeProfileAuthority(
                clearsActivationRequests: false
            )
            if retainedProfileID != activeProfileID {
                activeProfileActivatedAt = retainedProfileID == nil ? nil : Date()
            }
            activeProfileID = retainedProfileID
            if retainedProfileID == nil {
                activePresentation = nil
                activationRequests.removeAll()
            }
        } catch {
            activeProfileID = nil
            activeProfileActivatedAt = nil
            activePresentation = nil
            Logger(category: "Profiles").error("Profile authority reconciliation failed")
        }
    }

    private func resolvedPresentationProfile() -> BarlineProfile? {
        if let storedID = processedDefaults.string(forKey: Self.presentationProfileIDKey)
            .flatMap(UUID.init(uuidString:)),
            let profile = profiles.first(where: { $0.id == storedID })
        {
            return profile
        }
        if let stable = profiles.first(where: { $0.id == PresentationProfileTemplateBuilder.profileID }) {
            processedDefaults.set(stable.id.uuidString, forKey: Self.presentationProfileIDKey)
            return stable
        }
        if let legacy = profiles.first(where: { $0.name == "Presentation" }) {
            processedDefaults.set(legacy.id.uuidString, forKey: Self.presentationProfileIDKey)
            return legacy
        }
        return nil
    }

    private func activeFocusProfile() -> BarlineProfile? {
        if let profileID = processedDefaults.string(forKey: Self.activeFocusProfileIDKey)
            .flatMap(UUID.init(uuidString:))
        {
            return profiles.first(where: { $0.id == profileID })
        }
        return pendingFocusAuthority()?.pendingProfile ?? resolvedPresentationProfile()
    }

    private func validateProfileDefinitionMutation(profileID: UUID) throws {
        guard processedDefaults.data(forKey: Self.workspaceBeforeFocusKey) != nil else {
            return
        }
        let protectedProfileID = processedDefaults.string(forKey: Self.activeFocusProfileIDKey)
            .flatMap(UUID.init(uuidString:))
            ?? pendingFocusAuthority()?.profileID
        if profileID == protectedProfileID {
            throw MenuBarBackendError.operationFailed(
                "disable or recover the active Focus before changing its profile"
            )
        }
    }

    private func hasProcessed(_ commandID: UUID) -> Bool {
        (processedDefaults.stringArray(forKey: Self.processedCommandIDsKey) ?? [])
            .contains(commandID.uuidString)
    }

    private func recordProcessed(_ commandID: UUID) {
        var identifiers = processedDefaults.stringArray(forKey: Self.processedCommandIDsKey) ?? []
        identifiers.removeAll { $0 == commandID.uuidString }
        identifiers.append(commandID.uuidString)
        if identifiers.count > Self.maximumProcessedCommandCount {
            identifiers.removeFirst(identifiers.count - Self.maximumProcessedCommandCount)
        }
        processedDefaults.set(identifiers, forKey: Self.processedCommandIDsKey)
    }

    private func publishCatalog() {
        struct Entry: Codable { let id: UUID; let name: String }
        let entries = profiles.map { Entry(id: $0.id, name: $0.name) }
        guard let data = try? JSONEncoder().encode(entries),
              let encoded = String(data: data, encoding: .utf8)
        else { return }
        bridgeDefaults?.set(encoded, forKey: Self.profileCatalogKey)
    }

    private func performOperation<Value: Sendable>(
        successMessage: String?,
        onFailure: ((any Error) -> Void)? = nil,
        operation: () async throws -> Value,
        completion: (Value) -> Void
    ) async {
        await profileOperationSemaphore.wait()
        defer { profileOperationSemaphore.signal() }
        isBusy = true
        defer {
            isBusy = false
            interruptedFocusRecoveryToken = recoverableFocusAuthority()?.token
        }
        do {
            let value = try await operation()
            completion(value)
            lastOperationErrorCode = nil
            statusMessage = successMessage
        } catch {
            onFailure?(error)
            lastOperationErrorCode = PrivacySafeDiagnostics.errorCode(error)
            statusMessage = IntentCommandFailurePolicy.requiresUserReview(error)
                ? "A saved menu bar item is unavailable. Open its app or update the saved layout, then try again. Automatic retries stopped; any recovery checkpoint is retained."
                : error is WorkspaceRecoveryPlanner.Failure
                ? "The saved layout no longer matches the available items or displays. Restoration could not be verified; the recovery checkpoint is retained."
                : appState?.itemManager.hasPendingRestorations == true
                ? "Finish item restoration in Recovery, then apply the layout again."
                : "The profile operation could not be completed."
            Logger(category: "Profiles").error("Profile operation failed: \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
        }
    }
}
