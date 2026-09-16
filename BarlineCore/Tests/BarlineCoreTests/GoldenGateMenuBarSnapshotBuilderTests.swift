@testable import BarlineCore
import Foundation
import Testing

@Suite("Golden Gate menu bar snapshot builder")
struct GoldenGateMenuBarSnapshotBuilderTests {
    private let displayID = MenuBarDisplayID("display-a")
    private let displayBounds = MenuBarRect(x: 0, y: 0, width: 1800, height: 1200)
    private let appID = "com.mabryventures.Barline"

    @Test("Classifies items around Barline's section controls")
    func classifiesSections() throws {
        let snapshot = try build([
            observation(bundle: "com.example.always", title: "Always", x: 1400),
            observation(bundle: appID, title: "Barline.ControlItem.AlwaysHidden", x: 1450),
            observation(bundle: "com.example.hidden", title: "Hidden", x: 1500),
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
            observation(bundle: "com.example.visible", title: "Visible", x: 1600),
            observation(bundle: appID, title: "Barline.ControlItem.Visible", x: 1650),
        ])

        #expect(snapshot.items.map(\.section) == [
            .alwaysHidden, .alwaysHidden, .hidden, .hidden, .visible, .visible,
        ])
        #expect(snapshot.items.filter(\.isBarlineControlItem).count == 3)
        #expect(snapshot.items.allSatisfy { !$0.isMovable })
    }

    @Test("Fails closed without the hidden section control")
    func missingHiddenControl() {
        #expect(throws: MenuBarBackendError.self) {
            try build([
                observation(bundle: "com.example.item", title: "Item", x: 1600),
                observation(bundle: appID, title: "Barline.ControlItem.Visible", x: 1650),
            ])
        }
    }

    @Test("Creates stable occurrence aliases for duplicate semantic items")
    func duplicateAliases() throws {
        let snapshot = try build([
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1500),
            observation(bundle: "com.example.duplicate", title: "Duplicate", x: 1560),
            observation(bundle: "com.example.duplicate", title: "Duplicate", x: 1600),
        ])
        let duplicates = snapshot.items.filter {
            $0.id.bundleIdentifier == "com.example.duplicate"
        }
        #expect(duplicates.map(\.id.alias) == ["occurrence-0", "occurrence-1"])
    }

    @Test("Rebinds a uniquely identified item after its occurrence alias changes")
    func rebindsChangedOccurrenceAlias() {
        let requested = itemID(bundle: "com.example.item", title: "Status", alias: "occurrence-1")
        let current = itemID(bundle: "com.example.item", title: "Status", alias: "occurrence-0")

        #expect(GoldenGateMenuBarIdentityResolver.resolve(requested, among: [current]) == current)
    }

    @Test("Identity rebinding fails closed for ambiguous semantic duplicates")
    func ambiguousRebindingFailsClosed() {
        let requested = itemID(bundle: "com.example.item", title: "Status", alias: "occurrence-2")
        let candidates = [
            itemID(bundle: "com.example.item", title: "Status", alias: "occurrence-0"),
            itemID(bundle: "com.example.item", title: "Status", alias: "occurrence-1"),
        ]

        #expect(GoldenGateMenuBarIdentityResolver.resolve(requested, among: candidates) == nil)
    }

    @Test("Identity rebinding does not cross semantic identities")
    func semanticMismatchFailsClosed() {
        let requested = itemID(bundle: "com.example.item", title: "Status", alias: "occurrence-1")
        let candidate = itemID(bundle: "com.example.item", title: "Other", alias: "occurrence-0")

        #expect(GoldenGateMenuBarIdentityResolver.resolve(requested, among: [candidate]) == nil)
    }

    @Test("Uses remembered sections when the live divider is parked")
    func rememberedSections() throws {
        let item = observation(bundle: "com.example.hidden", title: "Hidden", x: 1600)
        let itemID = MenuBarItemID(
            bundleIdentifier: item.bundleIdentifier,
            accessibilityIdentifier: item.identifier,
            title: item.stableTitle,
            alias: "occurrence-0",
            fallbackFingerprint: item.fallbackFingerprint
        )
        let snapshot = try build([
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 10),
            item,
        ], rememberedSections: [itemID: .hidden])
        #expect(snapshot.items.first { !$0.isBarlineControlItem }?.section == .hidden)
    }

    @Test("Divider geometry remains authoritative for multiple application items")
    func mixedAssignmentsRetainGeometry() throws {
        let snapshot = try build([
            observation(bundle: "com.example.multiple", title: "Hidden", x: 1500),
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
            observation(bundle: "com.example.multiple", title: "Visible", x: 1600),
        ])
        #expect(snapshot.items.filter { !$0.isBarlineControlItem }.map(\.section) == [.hidden, .visible])
    }

    @Test("Explicit assignments override live divider geometry")
    func explicitAssignmentOverridesGeometry() throws {
        let item = observation(bundle: "com.example.utility", title: "Utility", x: 1600)
        let identifier = MenuBarItemID(
            bundleIdentifier: item.bundleIdentifier,
            accessibilityIdentifier: item.identifier,
            title: item.stableTitle,
            alias: "occurrence-0",
            fallbackFingerprint: item.fallbackFingerprint
        )
        let snapshot = try build([
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
            item,
        ], assignedSections: [identifier: .hidden])

        #expect(snapshot.items.first { $0.id == identifier }?.section == .hidden)
        #expect(snapshot.items.first { $0.id == identifier }?.isMovable == false)
    }

    @Test("Multiple items from one application cannot be assigned independently")
    func multipleApplicationItemsAreNotMovable() throws {
        let snapshot = try build([
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1500),
            observation(bundle: "com.example.multiple", title: "First", x: 1550),
            observation(bundle: "com.example.multiple", title: "Second", x: 1600),
        ])
        #expect(snapshot.items.filter {
            $0.id.bundleIdentifier == "com.example.multiple"
        }.allSatisfy { !$0.isMovable })
    }

    @Test("Meaningful item labels distinguish multiple controls from one application")
    func meaningfulItemLabels() throws {
        let snapshot = try build([
            observation(
                bundle: "com.example.multiple",
                title: "First Control",
                x: 1460,
                localizedApplicationName: "Example App"
            ),
            observation(
                bundle: "com.example.multiple",
                title: "Second Control",
                x: 1500,
                localizedApplicationName: "Example App"
            ),
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
        ])
        #expect(snapshot.items.filter { !$0.isBarlineControlItem }.map(\.displayName) == [
            "First Control", "Second Control",
        ])
    }

    @Test("Generated fallback labels use the localized application name")
    func unnamedItemLabel() throws {
        let snapshot = try build([
            observation(
                bundle: "com.example.unnamed",
                title: "Item-0",
                x: 1500,
                localizedApplicationName: "Example App"
            ),
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
        ])
        #expect(snapshot.items.first { !$0.isBarlineControlItem }?.displayName == "Example App")
    }

    private func build(
        _ observations: [GoldenGateMenuBarObservation],
        rememberedSections: [MenuBarItemID: MenuBarSection] = [:],
        assignedSections: [MenuBarItemID: MenuBarSection] = [:]
    ) throws -> MenuBarSnapshot {
        try GoldenGateMenuBarSnapshotBuilder.build(
            observations: observations,
            displayIdentities: [MenuBarDisplayIdentity(runtimeID: displayID)],
            activeDisplayID: displayID,
            activeDisplayBounds: displayBounds,
            appSigningIdentifier: appID,
            rememberedSections: rememberedSections,
            assignedSections: assignedSections,
            generation: 7
        )
    }

    private func observation(
        bundle: String,
        title: String,
        x: Double,
        localizedApplicationName: String? = nil
    ) -> GoldenGateMenuBarObservation {
        GoldenGateMenuBarObservation(
            bundleIdentifier: bundle,
            localizedApplicationName: localizedApplicationName,
            identifier: title,
            displayTitle: title,
            stableTitle: title,
            fallbackFingerprint: "fingerprint-\(bundle)-\(title)",
            bounds: MenuBarRect(x: x, y: 3, width: 30, height: 24),
            ownerProcessIdentifier: 42
        )
    }

    private func itemID(bundle: String, title: String, alias: String) -> MenuBarItemID {
        MenuBarItemID(
            bundleIdentifier: bundle,
            accessibilityIdentifier: title,
            title: title,
            alias: alias,
            fallbackFingerprint: "fingerprint-\(bundle)-\(title)"
        )
    }
}
