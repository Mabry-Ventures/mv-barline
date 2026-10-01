//
//  ProfileAuthorityPersistence.swift
//  BarlineCore
//

import Foundation

/// Persistence rejection after a layout transaction requires a new user
/// decision. Replaying the layout cannot repair an unverified authority write.
public enum ProfileAuthorityPersistenceError: Error, Equatable, Sendable {
    case encodingFailed
    case archiveTooLarge
    case writeNotVerified
    case rollbackNotVerified
}

public struct ProfileActiveAuthority: Codable, Hashable, Sendable {
    public let profileID: UUID
    public let token: UUID
    public let presentation: ResolvedProfilePresentation

    public init(profileID: UUID, token: UUID, presentation: ResolvedProfilePresentation) {
        self.profileID = profileID
        self.token = token
        self.presentation = presentation
    }
}

public struct ProfileAuthorityEnvelope: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case active
        case pendingFocus
    }

    public let phase: Phase
    public let profileID: UUID
    public let token: UUID
    public let presentation: ResolvedProfilePresentation
    public let priorAuthority: ProfileActiveAuthority?
    public let pendingProfile: BarlineProfile?
    public let checkpoint: MenuBarWorkspaceCheckpoint?

    public init(active authority: ProfileActiveAuthority) {
        phase = .active
        profileID = authority.profileID
        token = authority.token
        presentation = authority.presentation
        priorAuthority = nil
        pendingProfile = nil
        checkpoint = nil
    }

    public init(
        pendingFocusProfile: BarlineProfile,
        token: UUID,
        presentation: ResolvedProfilePresentation,
        checkpoint: MenuBarWorkspaceCheckpoint,
        priorAuthority: ProfileActiveAuthority?
    ) {
        phase = .pendingFocus
        profileID = pendingFocusProfile.id
        self.token = token
        self.presentation = presentation
        self.priorAuthority = priorAuthority
        pendingProfile = pendingFocusProfile
        self.checkpoint = checkpoint
    }

    public var activeAuthority: ProfileActiveAuthority? {
        guard phase == .active else { return nil }
        return ProfileActiveAuthority(
            profileID: profileID,
            token: token,
            presentation: presentation
        )
    }
}

public final class ProfileAuthorityEnvelopeStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> ProfileAuthorityEnvelope? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let envelope = try? JSONDecoder().decode(ProfileAuthorityEnvelope.self, from: data) {
            return envelope
        }
        guard let legacy = try? JSONDecoder().decode(ProfileActiveAuthority.self, from: data) else {
            return nil
        }
        return ProfileAuthorityEnvelope(active: legacy)
    }

    /// This storage transaction restores its previous values on rejection. A
    /// caller whose physical workspace has already changed must separately
    /// withdraw active publication, including the token mirror, while retaining
    /// the restored envelope as recovery evidence. Storage rollback is not
    /// permission to reactivate the previous physical workspace.
    public func save(_ envelope: ProfileAuthorityEnvelope, activeTokenKey: String? = nil) throws {
        guard activeTokenKey == nil || (envelope.phase == .active && activeTokenKey != key) else {
            throw ProfileAuthorityPersistenceError.writeNotVerified
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            throw ProfileAuthorityPersistenceError.encodingFailed
        }
        guard data.count <= ProfileCodec.maximumArchiveByteCount else {
            throw ProfileAuthorityPersistenceError.archiveTooLarge
        }
        let previous = defaults.object(forKey: key)
        let previousToken = activeTokenKey.flatMap { defaults.object(forKey: $0) }
        // Publish the mirror first. An interruption between writes must leave
        // the pending Focus envelope available to startup recovery, not replace
        // it with an active envelope whose token cannot yet be verified.
        if let activeTokenKey {
            defaults.set(envelope.token.uuidString, forKey: activeTokenKey)
        }
        defaults.set(data, forKey: key)
        let tokenVerified = activeTokenKey.map {
            defaults.string(forKey: $0) == envelope.token.uuidString
        } ?? true
        guard defaults.data(forKey: key) == data, tokenVerified else {
            // Failed promotion must not consume a pending Focus checkpoint.
            // Restore exactly the value this writer replaced, including an
            // unreadable old value retained for manual recovery.
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            if let activeTokenKey {
                if let previousToken {
                    defaults.set(previousToken, forKey: activeTokenKey)
                } else {
                    defaults.removeObject(forKey: activeTokenKey)
                }
            }
            let restored = defaults.object(forKey: key)
            let tokenRestored = activeTokenKey.map {
                Self.samePreferenceValue(previousToken, defaults.object(forKey: $0))
            } ?? true
            guard Self.samePreferenceValue(previous, restored), tokenRestored else {
                throw ProfileAuthorityPersistenceError.rollbackNotVerified
            }
            throw ProfileAuthorityPersistenceError.writeNotVerified
        }
    }

    private static func samePreferenceValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs as NSObject, rhs as NSObject): lhs.isEqual(rhs)
        default: false
        }
    }

    public func remove() {
        defaults.removeObject(forKey: key)
    }
}
