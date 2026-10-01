@testable import BarlineCore
import Foundation
import Testing

@Suite("Golden Gate saved identity compatibility")
struct GoldenGateIdentityMigrationTests {
    private let displayID = MenuBarDisplayID("display")

    @Test("Legacy swapped aliases preserve hidden assignments and ranks without ghosts")
    func swappedAliasesWithHistoricalMetadata() throws {
        let oldA = id(0, alias: 1), oldB = id(1, alias: 0)
        let currentA = id(0, alias: 0), currentB = id(1, alias: 0)
        let absent = id(99, alias: 3)
        let saved = [
            oldA: assignment(oldA, rank: 8), oldB: assignment(oldB, rank: 2),
            absent: assignment(absent, rank: 12),
        ]
        let liveItems = [descriptor(currentA, order: 0), descriptor(currentB, order: 1)]
        let plan = GoldenGateIdentityMigration(storedIDs: Array(saved.keys), liveIDs: liveItems.map(\.id))
        let migrated = try plan.rebinding(saved)
        #expect(plan.conflictingStoredIDs.isEmpty)
        #expect(migrated[currentA]?.section == .hidden)
        #expect(migrated[currentA]?.rank == 8)
        #expect(migrated[currentB]?.rank == 2)
        #expect(migrated[absent] == saved[absent])
        #expect(migrated[oldA] == nil)

        let historical = [oldA, oldB, currentA, id(1, alias: 1), absent].enumerated().map {
            descriptor($1, order: $0)
        }
        let inventory = GoldenGateIdentityMigration.reconcilingRetainedDescriptors(
            Dictionary(uniqueKeysWithValues: historical.map { ($0.id, $0) }),
            preserving: Set(migrated.keys), liveItems: liveItems
        )
        #expect(Set(inventory.keys) == [currentA, currentB, absent])
        let projected = liveItems.map { $0.replacingSection(migrated[$0.id]!.section) }
        let merged = GoldenGateRetainedInventoryPolicy.merging(
            live: snapshot(projected), retainedDescriptors: inventory,
            assignments: migrated, runningBundleIdentifiers: ["com.example.app"],
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        #expect(merged.items.count == 3)
        #expect(merged.items.allSatisfy { $0.section == .hidden })
        let native = GoldenGateConcealmentPolicy.resolve(
            MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: merged.items.map(\.id)),
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        #expect(native.concealedBundleIdentifiers == ["com.example.app"])
        let ordered = GoldenGateLogicalLayoutPlanner().applyingExplicitShelfOrder(to: merged, assignments: migrated)
        #expect(ordered.items.map(\.id) == [currentB, currentA, absent])
        let second = GoldenGateIdentityMigration(storedIDs: Array(migrated.keys), liveIDs: liveItems.map(\.id))
        #expect(second.replacements.isEmpty)
        #expect(try second.rebinding(migrated) == migrated)
    }

    @Test("Competing saved aliases including an exact match cannot choose hidden versus visible")
    func conflictingSavedRecords() {
        let old = id(0, alias: 1), current = id(0, alias: 0)
        let saved = [old: assignment(old, rank: 2), current: assignment(current, section: .visible, rank: 0)]
        let plan = GoldenGateIdentityMigration(storedIDs: Array(saved.keys), liveIDs: [current])
        #expect(plan.replacements.isEmpty)
        #expect(plan.conflictingStoredIDs == [old, current])
        #expect(throws: MenuBarBackendError.self) { try plan.rebinding(saved) }
        #expect(saved[old]?.section == .hidden)
        #expect(saved[current]?.section == .visible)
    }

    @Test("Ambiguous live duplicates cannot receive a legacy assignment")
    func ambiguousLiveRecords() {
        let old = id(0, alias: 2)
        let plan = GoldenGateIdentityMigration(storedIDs: [old], liveIDs: [id(0, alias: 0), id(0, alias: 1)])
        #expect(plan.replacements.isEmpty)
        #expect(plan.conflictingStoredIDs == [old])
    }

    @Test("Missing identifiers changed semantics and user aliases are not migration evidence")
    func strongIdentityBoundaries() {
        let cases: [(MenuBarItemID, MenuBarItemID)] = [
            (id(0, alias: 1, axID: nil), id(0, alias: 0, axID: nil)),
            (id(0, alias: 1), id(1, alias: 0)),
            (id(0, alias: 1), id(0, alias: 0, bundle: "com.other.app")),
            (id(0, alias: 1), id(0, alias: 0, fingerprint: "changed")),
            (id(0, alias: 1), MenuBarItemID(bundleIdentifier: "com.example.app", accessibilityIdentifier: "item-0", title: "changed", alias: "occurrence-0", fallbackFingerprint: "fingerprint")),
            (MenuBarItemID(bundleIdentifier: "com.example.app", accessibilityIdentifier: "item-0", title: "item-<n>", alias: "user-alias", fallbackFingerprint: "fingerprint"), id(0, alias: 0)),
        ]
        for (old, current) in cases {
            #expect(GoldenGateIdentityMigration(storedIDs: [old], liveIDs: [current]).replacements.isEmpty)
        }
    }

    @Test("Base and display presentations preserve groups and spacer anchors without rewriting archives")
    func profilePresentations() throws {
        let old = id(0, alias: 2), current = id(0, alias: 0)
        for source in [ResolvedProfilePresentation.Source.base, .displayOverride(displayID)] {
            let saved = ResolvedProfilePresentation(
                source: source, destinationDisplayID: source == .base ? nil : displayID,
                layout: ProfileLayout(hidden: [old]),
                groups: [ProfileGroup(name: "Example", itemIDs: [old])],
                spacers: [ProfileSpacer(placement: .after(old), width: 12)]
            )
            let resolved = try saved.resolvingItemIdentities(in: snapshot([descriptor(current)]))
            #expect(resolved.layout.hidden == [current])
            #expect(resolved.groups[0].itemIDs == [current])
            #expect(resolved.spacers[0].placement == .after(current))
            #expect(resolved.source == saved.source)
            #expect(resolved.destinationDisplayID == saved.destinationDisplayID)
            #expect(saved.layout.hidden == [old])
        }
    }

    @Test("Profiles reject many saved identities targeting one live identity")
    func ambiguousProfile() {
        let old = id(0, alias: 1), current = id(0, alias: 0)
        let saved = ResolvedProfilePresentation(
            source: .base, destinationDisplayID: nil,
            layout: ProfileLayout(visible: [current], hidden: [old]), groups: [], spacers: []
        )
        #expect(throws: MenuBarBackendError.self) {
            try saved.resolvingItemIdentities(in: snapshot([descriptor(current)]))
        }
    }

    @Test("Logical restoration rebinds aliases but cannot grant cross-display authority")
    func logicalRestoration() throws {
        let old = id(0, alias: 1), current = id(0, alias: 0)
        let target = snapshot([descriptor(old, section: .hidden)])
        let result = try GoldenGateLogicalLayoutPlanner().restoring(target, to: snapshot([descriptor(current)]))
        #expect(result.items[0].id == current)
        #expect(result.items[0].section == .hidden)
        let otherDisplay = MenuBarDisplayID("other")
        let moved = snapshot([MenuBarItemDescriptor(id: current, section: .visible, order: 0, displayID: otherDisplay)])
        #expect(throws: MenuBarBackendError.self) { try GoldenGateLogicalLayoutPlanner().restoring(target, to: moved) }
    }

    @Test("One authority envelope survives every partial legacy mirror combination with AX-absent hidden items")
    func partialMirrorWritesCannotSplitIdentity() throws {
        let old = id(0, alias: 1), current = id(0, alias: 0)
        let state = GoldenGatePersistedIdentityState(
            assignments: [assignment(current, rank: 9)],
            remembered: [assignment(current, rank: 0)],
            descriptors: [descriptor(current, section: .hidden)]
        )
        let oldState = GoldenGatePersistedIdentityState(
            assignments: [assignment(old, rank: 9)], remembered: [assignment(old, rank: 0)],
            descriptors: [descriptor(old, section: .hidden)]
        )
        let suite = "BarlineTests.IdentityEnvelope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(try VerifiedUserDefaultsDataCommit.commit(["authority": state.encoded()], to: defaults))
        for prefix in 0 ..< 8 {
            try defaults.set(JSONEncoder().encode(prefix & 1 == 0 ? oldState.assignments : state.assignments), forKey: "layout")
            try defaults.set(JSONEncoder().encode(prefix & 2 == 0 ? oldState.remembered : state.remembered), forKey: "remembered")
            try defaults.set(JSONEncoder().encode(prefix & 4 == 0 ? oldState.descriptors : state.descriptors), forKey: "inventory")
            let loaded = try GoldenGatePersistedIdentityState.loadAuthority(
                from: defaults, key: "authority", backupKey: "backup", quarantineKey: "quarantine"
            )
            let restored = try #require(loaded)
            let merged = GoldenGateRetainedInventoryPolicy.merging(
                live: snapshot([]),
                retainedDescriptors: Dictionary(uniqueKeysWithValues: restored.descriptors.map { ($0.id, $0) }),
                assignments: Dictionary(uniqueKeysWithValues: restored.assignments.map { ($0.itemID, $0) }),
                runningBundleIdentifiers: ["com.example.app"], barlineBundleIdentifier: "com.mabryventures.Barline"
            )
            #expect(merged.items.map(\.id) == [current])
            #expect(merged.items[0].section == .hidden)
            #expect(restored.assignments[0].rank == 9)
        }
    }

    @Test("Rejected envelope write retains original complete authority")
    func failedEnvelopeCommit() throws {
        let suite = "BarlineTests.IdentityFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = id(0, alias: 1), current = id(0, alias: 0)
        let oldData = try GoldenGatePersistedIdentityState(assignments: [assignment(old, rank: 4)], remembered: [], descriptors: [descriptor(old)]).encoded()
        let newData = try GoldenGatePersistedIdentityState(assignments: [assignment(current, rank: 4)], remembered: [], descriptors: [descriptor(current)]).encoded()
        defaults.set(oldData, forKey: "authority")
        var synchronizations = 0
        let committed = VerifiedUserDefaultsDataCommit.commit(["authority": newData], to: defaults) {
            synchronizations += 1
            if synchronizations == 1 {
                defaults.removeObject(forKey: "authority")
            }
            return false
        }
        #expect(!committed)
        #expect(defaults.data(forKey: "authority") == oldData)
        #expect(try GoldenGatePersistedIdentityState.decode(#require(defaults.data(forKey: "authority"))).assignments[0].itemID == old)
    }

    @Test("Malformed authority cannot fall back to incomplete hidden metadata")
    func malformedEnvelope() {
        let current = id(0, alias: 0)
        #expect(throws: GoldenGatePersistedIdentityState.ValidationError.self) {
            try GoldenGatePersistedIdentityState(assignments: [assignment(current, rank: 0)], remembered: [], descriptors: []).encoded()
        }
        #expect(throws: GoldenGatePersistedIdentityState.ValidationError.self) {
            try GoldenGatePersistedIdentityState(assignments: [], remembered: [], descriptors: [descriptor(current), descriptor(current)]).encoded()
        }
    }

    @Test("Corrupt authority recovers only a complete verified backup and preserves corrupt bytes")
    func recoversCorruptAuthority() throws {
        let suite = "BarlineTests.IdentityRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = id(0, alias: 0)
        let original = GoldenGatePersistedIdentityState(assignments: [assignment(current, rank: 4)], remembered: [], descriptors: [descriptor(current)])
        let replacement = GoldenGatePersistedIdentityState(assignments: [assignment(current, section: .visible, rank: 0)], remembered: [], descriptors: [descriptor(current)])
        #expect(original.commitAuthority(to: defaults, key: "authority", backupKey: "backup"))
        #expect(replacement.commitAuthority(to: defaults, key: "authority", backupKey: "backup"))
        let corrupt = Data("invalid-record".utf8)
        defaults.set(corrupt, forKey: "authority")
        #expect(try GoldenGatePersistedIdentityState.loadAuthority(from: defaults, key: "authority", backupKey: "backup", quarantineKey: "quarantine") == original)
        #expect(defaults.data(forKey: "quarantine") == corrupt)
        #expect(try GoldenGatePersistedIdentityState.decode(#require(defaults.data(forKey: "authority"))) == original)
    }

    @Test("Invalid authority with no valid backup remains intact rather than trusting legacy mirrors")
    func invalidAuthorityPreserved() throws {
        let suite = "BarlineTests.InvalidIdentity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("invalid-authority".utf8)
        defaults.set(corrupt, forKey: "authority")
        defaults.set(Data("legacy-data".utf8), forKey: "inventory")
        #expect(throws: GoldenGatePersistedIdentityState.ValidationError.self) {
            try GoldenGatePersistedIdentityState.loadAuthority(from: defaults, key: "authority", backupKey: "backup", quarantineKey: "quarantine")
        }
        #expect(defaults.data(forKey: "authority") == corrupt)
        #expect(defaults.object(forKey: "quarantine") == nil)
    }

    @Test("Repeated corruption preserves each damaged record within a bounded quarantine")
    func boundedRepeatedRecovery() throws {
        let suite = "BarlineTests.RepeatedIdentityRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = id(0, alias: 0)
        let state = GoldenGatePersistedIdentityState(assignments: [assignment(current, rank: 4)], remembered: [], descriptors: [descriptor(current)])
        #expect(state.commitAuthority(to: defaults, key: "authority", backupKey: "backup"))
        #expect(state.commitAuthority(to: defaults, key: "authority", backupKey: "backup"))
        for index in 0 ..< GoldenGatePersistedIdentityState.maximumQuarantinedRecords {
            let corrupt = Data("corrupt-\(index)".utf8)
            defaults.set(corrupt, forKey: "authority")
            #expect(try GoldenGatePersistedIdentityState.loadAuthority(from: defaults, key: "authority", backupKey: "backup", quarantineKey: "quarantine") == state)
            #expect(defaults.data(forKey: index == 0 ? "quarantine" : "quarantine.\(index)") == corrupt)
        }
        let finalCorrupt = Data("quarantine-full".utf8)
        defaults.set(finalCorrupt, forKey: "authority")
        #expect(throws: GoldenGatePersistedIdentityState.ValidationError.self) {
            try GoldenGatePersistedIdentityState.loadAuthority(from: defaults, key: "authority", backupKey: "backup", quarantineKey: "quarantine")
        }
        #expect(defaults.data(forKey: "authority") == finalCorrupt)
        #expect(defaults.data(forKey: "quarantine") == Data("corrupt-0".utf8))
        #expect(try GoldenGatePersistedIdentityState.decode(#require(defaults.data(forKey: "backup"))) == state)
    }

    @Test("Conflicting families preserve intent while unrelated unique identities can be repaired")
    func isolatedConflict() throws {
        let old = id(0, alias: 2), current = id(0, alias: 0)
        let otherOld = id(1, alias: 3, bundle: "com.other.app"), otherCurrent = id(1, alias: 0, bundle: "com.other.app")
        let saved = [old: assignment(old, rank: 2), current: assignment(current, section: .visible, rank: 0), otherOld: assignment(otherOld, rank: 5)]
        let plan = GoldenGateIdentityMigration(storedIDs: Array(saved.keys), liveIDs: [current, otherCurrent])
        let repaired = try plan.rebinding(saved, rejectingConflicts: false)
        #expect(repaired[old] == saved[old])
        #expect(repaired[current] == saved[current])
        #expect(repaired[otherCurrent]?.section == .hidden)
        #expect(repaired[otherCurrent]?.rank == 5)
    }

    @Test("Retention pressure protects saved hidden intent even when its descriptor failed visible")
    func hiddenIntentUnderRetentionPressure() throws {
        let hidden = id(99, alias: 0)
        let candidates = (0 ..< 5).map { descriptor(id($0, alias: 0), order: $0) } + [descriptor(hidden, order: 5)]
        let assignments = [assignment(hidden, rank: 7)]
        let requiredIDs = Set(assignments.filter { $0.section != .visible }.map(\.itemID))
        let selected = try BoundedPersistenceSelection.select(
            from: candidates,
            requiredIndices: Set(candidates.indices.filter { requiredIDs.contains(candidates[$0].id) }),
            maximumCount: 3, maximumBytes: 16 * 1024,
            encode: { try JSONEncoder().encode($0) }
        )
        #expect(selected.elements.count == 3)
        #expect(selected.elements.contains { $0.id == hidden && $0.section == .visible })
        let restored = try GoldenGatePersistedIdentityState.decode(
            GoldenGatePersistedIdentityState(assignments: assignments, remembered: [], descriptors: selected.elements).encoded()
        )
        let merged = GoldenGateRetainedInventoryPolicy.merging(
            live: snapshot([]), retainedDescriptors: Dictionary(uniqueKeysWithValues: restored.descriptors.map { ($0.id, $0) }),
            assignments: [hidden: assignments[0]], runningBundleIdentifiers: ["com.example.app"],
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        #expect(merged.items.map(\.id) == [hidden])
        #expect(merged.items[0].section == .hidden)
    }

    @Test("Ambiguity isolation preserves menu tracking and observation provenance")
    func isolationKeepsTracking() {
        let ambiguous = descriptor(id(0, alias: 0), section: .hidden, order: 7)
        let other = descriptor(id(1, alias: 0, bundle: "com.other.app"), section: .hidden, order: 3)
        let observed = MenuBarSnapshot(
            generation: 42, capturedAt: Date(timeIntervalSince1970: 1234),
            items: [ambiguous, other], displayIDs: [displayID],
            activeSpaceIsValid: false, menuTrackingIsActive: true
        )
        let projected = GoldenGateIdentityMigration.isolatingAmbiguousBundles(["com.example.app"], in: observed)
        #expect(projected.generation == observed.generation)
        #expect(projected.capturedAt == observed.capturedAt)
        #expect(projected.displayIDs == observed.displayIDs)
        #expect(projected.displayIdentities == observed.displayIdentities)
        #expect(!projected.activeSpaceIsValid)
        #expect(projected.menuTrackingIsActive)
        #expect(projected.items[0].section == .visible)
        #expect(!projected.items[0].isMovable && !projected.items[0].canBeHidden)
        #expect(projected.items[0].order == 7)
        #expect(projected.items[1] == other)
    }

    @Test("Mixed legacy conflict canonicalization retains the open-menu guard through the full projection")
    func mixedConflictKeepsTracking() {
        let old = id(0, alias: 2), current = id(0, alias: 0)
        let plan = GoldenGateIdentityMigration(storedIDs: [old, current], liveIDs: [current])
        let observed = MenuBarSnapshot(
            generation: 43, capturedAt: Date(timeIntervalSince1970: 1235),
            items: [descriptor(old, section: .hidden, order: 7), descriptor(current, order: 3)],
            displayIDs: [displayID], activeSpaceIsValid: true, menuTrackingIsActive: true
        )
        let ordered = GoldenGateLogicalLayoutPlanner().applyingExplicitShelfOrder(to: observed, assignments: [old: assignment(old, rank: 7)])
        #expect(ordered.menuTrackingIsActive && ordered.capturedAt == observed.capturedAt)
        let canonical = GoldenGateConcealmentPolicy.canonicalizingSnapshot(ordered, barlineBundleIdentifier: "com.mabryventures.Barline")
        #expect(canonical.repairedItemIDs == [old])
        let projected = GoldenGateIdentityMigration.isolatingAmbiguousBundles(Set(plan.conflictingStoredIDs.map(\.bundleIdentifier)), in: canonical.snapshot)
        #expect(projected.menuTrackingIsActive)
        #expect(projected.generation == observed.generation)
        #expect(projected.capturedAt == observed.capturedAt)
        #expect(projected.items.map(\.order) == ordered.items.map(\.order))
        #expect(projected.items.allSatisfy { $0.section == .visible && !$0.isMovable })
    }

    @Test("Profile and group search membership follows only unique live identity repair")
    func profileSearchMembership() throws {
        let old = id(0, alias: 2), current = id(0, alias: 0)
        var profile = BarlineProfile(name: "Synthetic Profile", layout: ProfileLayout(hidden: [old]), groups: [ProfileGroup(name: "Synthetic Group", itemIDs: [old])])
        let original = profile
        let projection = profile.searchableItemIdentityMap(liveIDs: [current])
        let archived = try #require(projection[current])
        #expect(profile.searchableItemIDs.contains(archived))
        #expect(profile.searchableGroupNames(containing: archived) == ["Synthetic Group"])
        #expect(profile == original)
        profile.layout.visible = [current]
        #expect(profile.searchableItemIdentityMap(liveIDs: [current]).isEmpty)
        #expect(original.searchableItemIdentityMap(liveIDs: [current, id(0, alias: 1)]).isEmpty)
    }

    private func id(_ index: Int, alias: Int, axID: String? = "default", bundle: String = "com.example.app", fingerprint: String = "fingerprint") -> MenuBarItemID {
        MenuBarItemID(bundleIdentifier: bundle, accessibilityIdentifier: axID == "default" ? "item-\(index)" : axID, title: "item-<n>", alias: "occurrence-\(alias)", fallbackFingerprint: fingerprint)
    }

    private func assignment(_ id: MenuBarItemID, section: MenuBarSection = .hidden, rank: Int) -> GoldenGateLogicalAssignment {
        GoldenGateLogicalAssignment(itemID: id, section: section, rank: rank)
    }

    private func descriptor(_ id: MenuBarItemID, section: MenuBarSection = .visible, order: Int = 0) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(id: id, section: section, order: order, displayID: displayID, displayName: "Synthetic", isMovable: true)
    }

    private func snapshot(_ items: [MenuBarItemDescriptor]) -> MenuBarSnapshot {
        MenuBarSnapshot(generation: 1, capturedAt: Date(), items: items, displayIDs: [displayID], activeSpaceIsValid: true)
    }
}
