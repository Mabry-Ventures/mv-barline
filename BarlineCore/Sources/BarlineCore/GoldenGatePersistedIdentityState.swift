import Foundation

/// One bounded value is the authority for all macOS 27 identity documents.
/// Legacy per-document keys may remain as mirrors, but a partial mirror write
/// cannot split a migrated hidden assignment from its retained metadata.
public struct GoldenGatePersistedIdentityState: Codable, Equatable, Sendable {
    public static let maximumEntries = 512
    public static let maximumEncodedBytes = 1024 * 1024
    public static let maximumQuarantinedRecords = 4

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidDocument
        case tooLarge
    }

    public let version: Int
    public let assignments: [GoldenGateLogicalAssignment]
    public let remembered: [GoldenGateLogicalAssignment]
    public let descriptors: [MenuBarItemDescriptor]

    public init(
        assignments: [GoldenGateLogicalAssignment],
        remembered: [GoldenGateLogicalAssignment],
        descriptors: [MenuBarItemDescriptor]
    ) {
        version = 1
        self.assignments = assignments
        self.remembered = remembered
        self.descriptors = descriptors
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw ValidationError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw ValidationError.tooLarge }
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate()
        return document
    }

    /// Recover only from a previously validated complete authority, never from
    /// legacy mirrors. Corrupt bytes are preserved before a verified replay.
    public static func loadAuthority(
        from defaults: UserDefaults, key: String, backupKey: String, quarantineKey: String
    ) throws -> Self? {
        guard defaults.object(forKey: key) != nil else { return nil }
        guard Set([key, backupKey, quarantineKey]).count == 3,
              let current = defaults.data(forKey: key), current.count <= maximumEncodedBytes
        else { throw ValidationError.invalidDocument }
        if let valid = try? decode(current) {
            return valid
        }
        let quarantineKeys = (0 ..< maximumQuarantinedRecords).map { $0 == 0 ? quarantineKey : "\(quarantineKey).\($0)" }
        guard quarantineKeys.allSatisfy({ $0 != key && $0 != backupKey }),
              let backup = defaults.data(forKey: backupKey),
              let validBackup = try? decode(backup),
              let destination = quarantineKeys.first(where: { defaults.data(forKey: $0) == current }) ??
              quarantineKeys.first(where: { defaults.object(forKey: $0) == nil }),
              VerifiedUserDefaultsDataCommit.commit([destination: current], to: defaults),
              VerifiedUserDefaultsDataCommit.commit([key: backup], to: defaults)
        else { throw ValidationError.invalidDocument }
        return validBackup
    }

    /// Keep a complete last-known-good record before replacing one authority
    /// value. A crash can expose old or new complete authority, not split docs.
    public func commitAuthority(
        to defaults: UserDefaults, key: String, backupKey: String
    ) -> Bool {
        guard key != backupKey, let data = try? encoded() else { return false }
        if defaults.object(forKey: key) != nil {
            guard let previous = defaults.data(forKey: key), (try? Self.decode(previous)) != nil,
                  VerifiedUserDefaultsDataCommit.commit([backupKey: previous], to: defaults)
            else { return false }
        }
        return VerifiedUserDefaultsDataCommit.commit([key: data], to: defaults)
    }

    private func validate() throws {
        let descriptorIDs = Set(descriptors.map(\.id))
        guard version == 1,
              [assignments.count, remembered.count, descriptors.count].allSatisfy({ $0 <= Self.maximumEntries }),
              Set(assignments.map(\.itemID)).count == assignments.count,
              Set(remembered.map(\.itemID)).count == remembered.count,
              descriptorIDs.count == descriptors.count,
              (assignments + remembered).allSatisfy({ $0.rank >= 0 && Self.validIdentity($0.itemID) }),
              descriptors.allSatisfy({ Self.validIdentity($0.id) }),
              assignments.allSatisfy({ $0.section == .visible || descriptorIDs.contains($0.itemID) })
        else { throw ValidationError.invalidDocument }
    }

    private static func validIdentity(_ id: MenuBarItemID) -> Bool {
        id.isPlausiblyStable &&
            [id.bundleIdentifier, id.accessibilityIdentifier, id.title, id.alias, id.fallbackFingerprint]
            .compactMap(\.self).allSatisfy { $0.utf8.count <= 4096 }
    }
}
