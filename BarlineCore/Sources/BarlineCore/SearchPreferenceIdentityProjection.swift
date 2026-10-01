//
//  SearchPreferenceIdentityProjection.swift
//  Barline
//

import Foundation

/// Resolves live menu-item identities to the exact keys used by the local
/// search-preference archive without rewriting that archive during discovery.
public struct SearchPreferenceIdentityProjection: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case stored(MenuBarItemID)
        case new
        case ambiguous
    }

    private let resolutions: [MenuBarItemID: Resolution]

    public init(storedIDs: [MenuBarItemID], liveIDs: [MenuBarItemID]) {
        let storedBySemanticIdentity = Dictionary(
            grouping: storedIDs,
            by: GoldenGateIdentityMigration.semanticKey
        )
        let liveBySemanticIdentity = Dictionary(
            grouping: liveIDs,
            by: GoldenGateIdentityMigration.semanticKey
        )
        let migration = GoldenGateIdentityMigration(
            storedIDs: storedIDs,
            liveIDs: liveIDs
        )

        var projected = [MenuBarItemID: Resolution]()
        for liveID in Set(liveIDs) {
            let semanticIdentity = GoldenGateIdentityMigration.semanticKey(liveID)
            let storedFamily = storedBySemanticIdentity[semanticIdentity] ?? []
            let liveFamily = liveBySemanticIdentity[semanticIdentity] ?? []

            guard liveFamily.count == 1 else {
                projected[liveID] = .ambiguous
                continue
            }
            guard !storedFamily.isEmpty else {
                projected[liveID] = .new
                continue
            }
            guard storedFamily.count == 1,
                  migration.conflictingStoredIDs.isDisjoint(with: storedFamily),
                  let storedID = storedFamily.first
            else {
                projected[liveID] = .ambiguous
                continue
            }

            if storedID == liveID || migration.replacements[storedID] == liveID {
                projected[liveID] = .stored(storedID)
            } else {
                // A record in the same semantic family that cannot pass the
                // strong-AX occurrence migration must not be duplicated by a
                // point-of-use edit under a second exact key.
                projected[liveID] = .ambiguous
            }
        }
        resolutions = projected
    }

    public func resolution(for liveID: MenuBarItemID) -> Resolution {
        // A caller must refresh the projection from the current complete live
        // inventory before admitting an edit. Unknown/stale IDs fail closed.
        resolutions[liveID] ?? .ambiguous
    }
}
