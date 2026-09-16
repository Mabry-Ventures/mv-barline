//
//  GoldenGatePositionTableStore.swift
//  Barline
//
//  macOS 27 position-table behavior is verified against the live
//  com.apple.MenuBar CFPreferences domain.
//

@preconcurrency import AppKit
import BarlineCore
import CoreFoundation
import Darwin
import Foundation
import os

struct GoldenGatePositionCompanionState: Codable, Equatable, Sendable {
    let assignmentData: Data
    let descriptorData: Data
}

enum GoldenGatePositionRecoveryResult: Equatable, Sendable {
    case none
    case rolledBack
    case committed(GoldenGatePositionCompanionState)
    case externalStateWon
    case invalidJournalQuarantined
}

/// A narrowly scoped transaction boundary around macOS 27's menu-bar layout
/// preference. The preference daemon remains the primary writer; Barline never
/// replaces the backing plist during a normal transaction.
actor GoldenGatePositionTableStore {
    enum StoreError: Error {
        case accessNotGranted
        case unexpectedFile
        case invalidDocument
        case concurrentModification
        case externalStateWon
        case transactionPending
        case writeFailed
        case invalidJournal
    }

    private struct Journal: Codable, Equatable {
        let version: Int
        let phase: GoldenGatePositionRecoveryPhase
        let mutation: GoldenGatePositionMutation
        let companionState: GoldenGatePositionCompanionState?
    }

    private static let bookmarkKey = "GoldenGateMenuBarLayoutBookmark"
    private static let positionsKey = "TrailingItemPreferredPositions"
    private static let maximumJournalBytes = 256 * 1024
    private static let maximumPositionCount = 4096
    private static let quietWindow: Duration = .milliseconds(120)
    private let logger = Logger(category: "GoldenGatePositionTableStore")

    /// CFPreferences accepts a path without the `.plist` suffix as its
    /// application identifier. On macOS 27 this is the authoritative domain;
    /// `com.apple.MenuBarAgent.plist` is an adjacent, non-authoritative file.
    static var applicationID: String {
        expectedDirectoryURL
            .appending(path: "com.apple.MenuBar", directoryHint: .notDirectory)
            .path
    }

    static var expectedURL: URL {
        expectedDirectoryURL
            .appending(path: "com.apple.MenuBar.plist", directoryHint: .notDirectory)
    }

    static var expectedDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/com.apple.MenuBar", directoryHint: .isDirectory)
            .appending(path: "Library/Preferences", directoryHint: .isDirectory)
    }

    private static var journalURL: URL {
        get throws {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport
                .appending(path: "Barline", directoryHint: .isDirectory)
            try ensurePrivateDirectory(directory)
            return directory.appending(
                path: "GoldenGatePositionTransaction.json",
                directoryHint: .notDirectory
            )
        }
    }

    func readPositions(requestAccessIfNeeded: Bool) async throws -> [String: Int] {
        let scopedURL = try await authorizeAccess(requestAccessIfNeeded: requestAccessIfNeeded)
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        return try readPreferences()
    }

    func apply(_ mutation: GoldenGatePositionMutation) async throws {
        let scopedURL = try await authorizeAccess(requestAccessIfNeeded: true)
        defer { scopedURL?.stopAccessingSecurityScopedResource() }

        // The provider must reconcile any prior journal before planning a new
        // mutation so a verified companion state can be restored as well.
        let pendingJournal: Journal?
        do {
            pendingJournal = try loadJournal()
        } catch StoreError.invalidJournal {
            // Preserve the malformed evidence, but do not let one torn or
            // externally corrupted record permanently wedge every future
            // transaction. This attempt still fails closed; a later attempt
            // starts only after a fresh native-table read.
            try quarantineInvalidJournal()
            throw StoreError.invalidJournal
        }
        guard pendingJournal == nil else {
            // A successfully decoded journal is recovery authority, not corrupt
            // input. Leave it untouched so the provider's next recovery pass
            // can roll it back or commit its verified companion state.
            throw StoreError.transactionPending
        }

        // CFPreferences has no dictionary compare-and-swap. Refuse to write
        // while MenuBarAgent or another status item is actively changing the
        // table, then re-verify the touched keys after the same quiet window.
        let firstRead = try readPreferences()
        try await Task.sleep(for: Self.quietWindow)
        guard try readPreferences() == firstRead else {
            throw StoreError.concurrentModification
        }

        try saveJournal(Journal(
            version: 3,
            phase: .staged,
            mutation: mutation,
            companionState: nil
        ))
        do {
            try write(mutation)
            try saveJournal(Journal(
                version: 3,
                phase: .applied,
                mutation: mutation,
                companionState: nil
            ))
            try await Task.sleep(for: Self.quietWindow)
            let settled = try readPreferences()
            guard mutation.changes.allSatisfy({
                settled[$0.key] == $0.proposedValue
            }) else {
                throw StoreError.concurrentModification
            }
        } catch {
            let recovered: Bool
            do {
                recovered = try rollbackWithCurrentAccess(mutation)
            } catch {
                // The durable journal remains available for the next recovery
                // pass when rollback itself cannot be verified.
                throw StoreError.writeFailed
            }
            if recovered {
                // No Barline proposal remains. Tell the provider/coordinator
                // not to issue a second, stale compensating restore.
                throw StoreError.concurrentModification
            }
            // A third-party/native value replaced our proposal. The journal
            // has been cleared and the external state is authoritative.
            throw StoreError.externalStateWon
        }
        logger.notice(
            "Golden Gate position write verified: changes=\(mutation.changes.count, privacy: .public), summary=\(Self.numericSummary(mutation), privacy: .public)"
        )
    }

    /// Records the native AX postcondition durably before journal cleanup.
    func markVerified(
        _ mutation: GoldenGatePositionMutation,
        companionState: GoldenGatePositionCompanionState
    ) throws {
        guard let journal = try loadJournal(),
              journal.mutation == mutation,
              journal.phase == .applied
        else { throw StoreError.invalidJournal }
        try saveJournal(Journal(
            version: 3,
            phase: .verified,
            mutation: mutation,
            companionState: companionState
        ))
    }

    func finishTransaction() throws {
        guard let journal = try loadJournal() else { return }
        guard journal.phase == .verified else { throw StoreError.invalidJournal }
        try removeJournal()
    }

    /// Preserves a valid journal whose companion payload cannot be consumed.
    /// Native position state remains authoritative; moving the record aside
    /// prevents an unrecoverable companion from wedging every later snapshot.
    func quarantineRecoveryJournal() throws {
        guard try loadJournal() != nil else { return }
        try quarantineInvalidJournal()
        logger.fault("Quarantined an unusable Golden Gate recovery companion")
    }

    /// Resolves a durable transaction record on launch. Unverified proposals
    /// are rolled back only while every touched key still equals Barline's
    /// proposal. A later system/user write always wins.
    @discardableResult
    func recoverInterruptedTransaction() async throws -> GoldenGatePositionRecoveryResult {
        do {
            guard try loadJournal() != nil else { return .none }
            let scopedURL = try await authorizeAccess(requestAccessIfNeeded: false)
            defer { scopedURL?.stopAccessingSecurityScopedResource() }
            return try recoverInterruptedTransactionWithCurrentAccess()
        } catch StoreError.invalidJournal {
            try quarantineInvalidJournal()
            logger.fault("Quarantined an invalid Golden Gate transaction journal")
            return .invalidJournalQuarantined
        }
    }

    @discardableResult
    func rollback(_ mutation: GoldenGatePositionMutation) async throws -> Bool {
        let scopedURL = try await authorizeAccess(requestAccessIfNeeded: false)
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        return try rollbackWithCurrentAccess(mutation)
    }

    private func recoverInterruptedTransactionWithCurrentAccess() throws
        -> GoldenGatePositionRecoveryResult
    {
        guard let journal = try loadJournal() else { return .none }
        let positions = try readPreferences()
        switch GoldenGatePositionRecoveryPlanner.action(
            phase: journal.phase,
            mutation: journal.mutation,
            currentPositions: positions
        ) {
        case .clearOriginalJournal:
            try removeJournal()
            logger.notice("Resolved a Golden Gate transaction already at its original state")
            return .rolledBack
        case .commitVerifiedCompanion:
            guard let companionState = journal.companionState else {
                throw StoreError.invalidJournal
            }
            // Keep the verified journal until the provider has validated and
            // durably restored its companion state.
            return .committed(companionState)
        case let .rollback(rollback):
            try write(rollback)
            try removeJournal()
            logger.notice("Recovered one unverified Golden Gate position transaction")
            return .rolledBack
        case .preserveExternalStateAndClearJournal:
            try removeJournal()
            return .externalStateWon
        }
    }

    private func rollbackWithCurrentAccess(
        _ mutation: GoldenGatePositionMutation
    ) throws -> Bool {
        let positions = try readPreferences()
        if mutation.changes.allSatisfy({ positions[$0.key] == $0.originalValue }) {
            try removeJournalIfPresent()
            logger.notice("Golden Gate rollback was already reflected by CFPreferences")
            return true
        }
        guard let rollback = GoldenGatePositionTablePlanner.conditionalRollback(
            for: mutation,
            currentPositions: positions
        ) else {
            try removeJournalIfPresent()
            return false
        }
        try write(rollback)
        try removeJournalIfPresent()
        logger.notice(
            "Golden Gate position rollback verified: changes=\(rollback.changes.count, privacy: .public), summary=\(Self.numericSummary(rollback), privacy: .public)"
        )
        return true
    }

    private func authorizeAccess(
        requestAccessIfNeeded: Bool
    ) async throws -> URL? {
        // Do not use FileManager's POSIX readability flags as a TCC decision.
        // On macOS 27 they can be true for this Group Container plist even
        // though CFPreferences will later be denied. That false positive used
        // to bypass the scoped-file picker and turn an explicit move into an
        // opaque preflight failure. A security-scoped bookmark is the only
        // durable authorization path Barline relies on for this protected file.
        do {
            if let scopedURL = try resolvedBookmarkURL() {
                do {
                    return try beginAccessing(scopedURL)
                } catch StoreError.accessNotGranted {
                    // Releases before the scoped-bookmark migration saved a
                    // plain bookmark. It resolves to the right preference resource
                    // but cannot grant the Group Container access macOS 27 now
                    // requires. Retire it so this explicit move can present
                    // the picker and replace it with a security-scoped one.
                    UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
                }
            }
        } catch {
            // A bookmark is only a convenience for reacquiring this exact
            // system preference file. Retire corrupt, revoked, or wrong-target data
            // so an explicit user action can authorize it again. Passive
            // inventory remains noninteractive below.
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        }
        guard requestAccessIfNeeded else { throw StoreError.accessNotGranted }
        guard let bookmark = try await Self.requestBookmark() else {
            throw StoreError.accessNotGranted
        }
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        guard let scopedURL = try resolvedBookmarkURL() else {
            throw StoreError.accessNotGranted
        }
        return try beginAccessing(scopedURL)
    }

    private func beginAccessing(_ scopedURL: URL) throws -> URL {
        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw StoreError.accessNotGranted
        }
        return scopedURL
    }

    private func resolvedBookmarkURL() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            return nil
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard Self.isExpectedURL(url) else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            throw StoreError.unexpectedFile
        }
        if stale {
            let refreshed = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
        }
        return url
    }

    @MainActor
    private static func requestBookmark() throws -> Data? {
        let expected = expectedURL
        let panel = NSOpenPanel()
        panel.title = "Allow Barline to arrange menu bar items"
        panel.message = "Select the highlighted com.apple.MenuBar.plist file. Barline changes only this macOS menu bar position preference and verifies every change."
        panel.prompt = "Allow"
        panel.directoryURL = expected.deletingLastPathComponent()
        panel.nameFieldStringValue = expected.lastPathComponent
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard isExpectedURL(url) else { throw StoreError.unexpectedFile }
        return try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func isExpectedURL(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL ==
            expectedURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func readPreferences() throws -> [String: Int] {
        let applicationID = Self.applicationID as CFString
        guard CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { throw StoreError.writeFailed }
        guard let value = CFPreferencesCopyValue(
            Self.positionsKey as CFString,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { throw StoreError.invalidDocument }
        return try Self.validatedPositions(value)
    }

    /// Re-reads immediately before the preference-daemon write, rebases only
    /// Barline's named keys, synchronizes, and verifies both touched and
    /// untouched keys. Unknown/system entries are never intentionally changed.
    private func write(_ mutation: GoldenGatePositionMutation) throws {
        guard !mutation.changes.isEmpty else {
            throw StoreError.concurrentModification
        }
        let before = try readPreferences()
        guard let proposed = GoldenGatePositionTablePlanner.rebasedPositions(
            applying: mutation,
            to: before
        ) else { throw StoreError.concurrentModification }

        let applicationID = Self.applicationID as CFString
        CFPreferencesSetValue(
            Self.positionsKey as CFString,
            proposed as CFDictionary,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { throw StoreError.writeFailed }

        let after = try readPreferences()
        let touchedKeys = Set(mutation.changes.map(\.key))
        guard mutation.changes.allSatisfy({ after[$0.key] == $0.proposedValue }),
              before.allSatisfy({ key, value in
                  touchedKeys.contains(key) || after[key] == value
              }),
              after.allSatisfy({ key, value in
                  touchedKeys.contains(key) || before[key] == value
              })
        else { throw StoreError.concurrentModification }
        logger.notice("Golden Gate CFPreferences position mutation verified")
    }

    private static func validatedPositions(_ value: CFPropertyList) throws -> [String: Int] {
        guard let raw = value as? [String: Any],
              !raw.isEmpty,
              raw.count <= maximumPositionCount
        else { throw StoreError.invalidDocument }
        var result = [String: Int]()
        result.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard !key.isEmpty,
                  key.count <= 1024,
                  let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID()
            else { throw StoreError.invalidDocument }
            result[key] = number.intValue
        }
        return result
    }

    private func saveJournal(_ journal: Journal) throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= Self.maximumJournalBytes else {
            throw StoreError.invalidJournal
        }
        let url = try Self.journalURL
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
            throw StoreError.writeFailed
        }
    }

    private func loadJournal() throws -> Journal? {
        let url = try Self.journalURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumJournalBytes
        else { throw StoreError.invalidJournal }
        let data = try Data(contentsOf: url)
        guard let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.version == 3,
              !journal.mutation.changes.isEmpty
        else { throw StoreError.invalidJournal }
        return journal
    }

    private func removeJournalIfPresent() throws {
        guard let url = try? Self.journalURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try removeJournal()
    }

    private func removeJournal() throws {
        let url = try Self.journalURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func quarantineInvalidJournal() throws {
        let source = try Self.journalURL
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = source
            .deletingLastPathComponent()
            .appending(
                path: "GoldenGatePositionTransaction.invalid.json",
                directoryHint: .notDirectory
            )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                  (metadata.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK),
                  isDirectory.boolValue
            else { throw StoreError.invalidJournal }
        } else {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func numericSummary(_ mutation: GoldenGatePositionMutation) -> String {
        mutation.changes
            .map { "\($0.originalValue)>\($0.proposedValue)" }
            .joined(separator: ",")
    }
}
