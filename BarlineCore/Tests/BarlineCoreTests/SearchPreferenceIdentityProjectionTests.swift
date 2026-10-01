//
//  SearchPreferenceIdentityProjectionTests.swift
//  Barline
//

@testable import BarlineCore
import Testing

@Suite("Search preference identity projection")
struct SearchPreferenceIdentityProjectionTests {
    @Test("Unique strong AX occurrence change preserves the exact archive key")
    func uniqueStrongIdentity() throws {
        let stored = id(axID: "battery", alias: "occurrence-3")
        let live = id(axID: "battery", alias: "occurrence-0")
        let preferences = try SearchItemPersonalization.empty
            .settingFavorite(true, for: stored)
            .settingAlias("Desk Battery", for: stored)
        let projection = SearchPreferenceIdentityProjection(
            storedIDs: preferences.entries.map(\.itemID),
            liveIDs: [live]
        )

        #expect(projection.resolution(for: live) == .stored(stored))
        let storageID = try #require(projection.storageID(for: live))
        #expect(preferences.isFavorite(storageID))
        #expect(preferences.alias(for: storageID) == "Desk Battery")

        let edited = try preferences.settingAlias("Travel Battery", for: storageID)
        #expect(edited.entries.count == 1)
        #expect(edited.entries[0].itemID == stored)
        #expect(edited.isFavorite(stored))
        #expect(edited.alias(for: stored) == "Travel Battery")
        #expect(try SearchItemPersonalization.decode(edited.encoded()) == edited)
    }

    @Test("Same-title items with distinct AX identifiers project independently")
    func distinctStrongIdentities() {
        let firstStored = id(axID: "first", alias: "occurrence-1")
        let secondStored = id(axID: "second", alias: "occurrence-2")
        let firstLive = id(axID: "first", alias: "occurrence-0")
        let secondLive = id(axID: "second", alias: "occurrence-0")
        let projection = SearchPreferenceIdentityProjection(
            storedIDs: [firstStored, secondStored],
            liveIDs: [firstLive, secondLive]
        )

        #expect(projection.resolution(for: firstLive) == .stored(firstStored))
        #expect(projection.resolution(for: secondLive) == .stored(secondStored))
    }

    @Test("Exact plus legacy records block the entire semantic family")
    func exactLegacyCollision() {
        let legacy = id(axID: "battery", alias: "occurrence-4")
        let live = id(axID: "battery", alias: "occurrence-0")
        let projection = SearchPreferenceIdentityProjection(
            storedIDs: [legacy, live],
            liveIDs: [live]
        )

        #expect(projection.resolution(for: live) == .ambiguous)
    }

    @Test("Weak, custom-alias, duplicate, changed, and stale identities fail safely")
    func boundaries() {
        let live = id(axID: "battery", alias: "occurrence-0")
        let weakStored = id(axID: nil, alias: "occurrence-2")
        let weakLive = id(axID: nil, alias: "occurrence-0")
        let customStored = id(axID: "battery", alias: "custom")
        let duplicateLive = id(axID: "duplicate", alias: "occurrence-0")

        #expect(SearchPreferenceIdentityProjection(
            storedIDs: [weakStored], liveIDs: [weakLive]
        ).resolution(for: weakLive) == .ambiguous)
        #expect(SearchPreferenceIdentityProjection(
            storedIDs: [customStored], liveIDs: [live]
        ).resolution(for: live) == .ambiguous)
        #expect(SearchPreferenceIdentityProjection(
            storedIDs: [], liveIDs: [duplicateLive, duplicateLive]
        ).resolution(for: duplicateLive) == .ambiguous)

        let changed = id(axID: "changed", alias: "occurrence-0")
        let projection = SearchPreferenceIdentityProjection(
            storedIDs: [live], liveIDs: [changed]
        )
        #expect(projection.resolution(for: changed) == .new)
        #expect(projection.resolution(for: live) == .ambiguous)
    }

    private func id(axID: String?, alias: String) -> MenuBarItemID {
        MenuBarItemID(
            bundleIdentifier: "com.example.status",
            accessibilityIdentifier: axID,
            title: "Battery",
            alias: alias,
            fallbackFingerprint: "battery-fingerprint"
        )
    }
}

private extension SearchPreferenceIdentityProjection {
    func storageID(for liveID: MenuBarItemID) -> MenuBarItemID? {
        guard case let .stored(storageID) = resolution(for: liveID) else { return nil }
        return storageID
    }
}
