import Foundation

/// Repairs only the order-derived aliases written by older macOS 27 builds.
/// Full-ID equality remains authoritative elsewhere. Planning is read-only;
/// callers must commit coordinated persistence before publishing the projection.
public struct GoldenGateIdentityMigration: Equatable, Sendable {
    public let replacements: [MenuBarItemID: MenuBarItemID]
    public let conflictingStoredIDs: Set<MenuBarItemID>

    public init(storedIDs: [MenuBarItemID], liveIDs: [MenuBarItemID]) {
        let stored = Dictionary(grouping: storedIDs, by: Self.semanticKey)
        let live = Dictionary(grouping: liveIDs, by: Self.semanticKey)
        var replacements = [MenuBarItemID: MenuBarItemID]()
        var conflicts = Set<MenuBarItemID>()
        for (key, sourceIDs) in stored where key.accessibilityIdentifier != nil {
            guard let candidates = live[key] else { continue }
            let changing = sourceIDs.filter { source in
                !candidates.contains(source) && Self.isOccurrenceAlias(source.alias) &&
                    candidates.contains { Self.isOccurrenceAlias($0.alias) }
            }
            guard !changing.isEmpty else { continue }
            // Include exact-current records in source cardinality: they must
            // not silently win over another saved section/rank for the same AX ID.
            guard sourceIDs.count == 1, candidates.count == 1,
                  let source = changing.first, let target = candidates.first,
                  Self.isOccurrenceAlias(target.alias)
            else {
                conflicts.formUnion(sourceIDs)
                continue
            }
            replacements[source] = target
        }
        self.replacements = replacements
        conflictingStoredIDs = conflicts
    }

    public func rebinding(
        _ assignments: [MenuBarItemID: GoldenGateLogicalAssignment],
        rejectingConflicts: Bool = true
    ) throws -> [MenuBarItemID: GoldenGateLogicalAssignment] {
        guard !rejectingConflicts || conflictingStoredIDs.isEmpty else {
            throw MenuBarBackendError.operationFailed("saved menu bar identities are ambiguous")
        }
        var result = [MenuBarItemID: GoldenGateLogicalAssignment]()
        for (id, assignment) in assignments {
            let resolved = replacements[id] ?? id
            guard result.updateValue(GoldenGateLogicalAssignment(
                itemID: resolved, section: assignment.section, rank: assignment.rank
            ), forKey: resolved) == nil else {
                throw MenuBarBackendError.operationFailed("saved menu bar identities are ambiguous")
            }
        }
        return result
    }

    public func rebinding(
        _ sections: [MenuBarItemID: MenuBarSection],
        rejectingConflicts: Bool = true
    ) throws -> [MenuBarItemID: MenuBarSection] {
        guard !rejectingConflicts || conflictingStoredIDs.isEmpty else {
            throw MenuBarBackendError.operationFailed("saved menu bar identities are ambiguous")
        }
        var result = [MenuBarItemID: MenuBarSection]()
        for (id, section) in sections {
            guard result.updateValue(section, forKey: replacements[id] ?? id) == nil else {
                throw MenuBarBackendError.operationFailed("saved menu bar identities are ambiguous")
            }
        }
        return result
    }

    /// Historical descriptors are metadata, not competing saved instructions.
    /// Discard an obsolete alias only if a unique *live* strong identity proves
    /// it and no unresolved saved instruction still requires that old full ID.
    /// Live metadata wins deterministically over every historical version.
    public static func reconcilingRetainedDescriptors(
        _ retained: [MenuBarItemID: MenuBarItemDescriptor],
        preserving storedIDs: Set<MenuBarItemID>,
        liveItems: [MenuBarItemDescriptor]
    ) -> [MenuBarItemID: MenuBarItemDescriptor] {
        let live = Dictionary(grouping: liveItems.map(\.id), by: semanticKey)
        var result = retained.filter { id, _ in
            guard !storedIDs.contains(id), id.accessibilityIdentifier != nil,
                  isOccurrenceAlias(id.alias),
                  let matches = live[semanticKey(id)], matches.count == 1,
                  let current = matches.first, isOccurrenceAlias(current.alias)
            else { return true }
            return id == current
        }
        for item in liveItems {
            result[item.id] = item
        }
        return result
    }

    public static func semanticKey(_ id: MenuBarItemID) -> MenuBarItemID {
        MenuBarItemID(
            bundleIdentifier: id.bundleIdentifier,
            accessibilityIdentifier: id.accessibilityIdentifier,
            title: id.title,
            fallbackFingerprint: id.fallbackFingerprint
        )
    }

    /// This is a read-only safety projection, not a proposed native mutation.
    /// Keep the observation's tracking state and provenance unchanged.
    public static func isolatingAmbiguousBundles(
        _ bundles: Set<String>, in snapshot: MenuBarSnapshot
    ) -> MenuBarSnapshot {
        MenuBarSnapshot(
            generation: snapshot.generation,
            capturedAt: snapshot.capturedAt,
            items: snapshot.items.map { item in
                bundles.contains(item.id.bundleIdentifier)
                    ? item.replacing(section: .visible, isMovable: false, canBeHidden: false)
                    : item
            },
            displayIDs: snapshot.displayIDs,
            displayIdentities: snapshot.displayIdentities,
            activeSpaceIsValid: snapshot.activeSpaceIsValid,
            menuTrackingIsActive: snapshot.menuTrackingIsActive
        )
    }

    private static func isOccurrenceAlias(_ alias: String?) -> Bool {
        guard let alias, alias.hasPrefix("occurrence-") else { return false }
        let ordinal = alias.dropFirst("occurrence-".count)
        return !ordinal.isEmpty && ordinal.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
