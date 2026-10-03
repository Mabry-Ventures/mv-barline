@testable import BarlineCore
import Foundation
import Testing

@Suite("Golden Gate menu bar snapshot builder")
struct GoldenGateMenuBarSnapshotBuilderTests {
    private let displayID = MenuBarDisplayID("display-a")
    private let displayBounds = MenuBarRect(x: 0, y: 0, width: 1800, height: 1200)
    private let appID = "com.mabryventures.Barline"

    @Test("Visible ownership and divider classification are independent per display")
    func perDisplayDividerGeometry() throws {
        let secondDisplay = MenuBarDisplayID("display-b")
        let observations = [
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
            observation(bundle: "com.example.a", title: "A", x: 1500),
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 2150),
            observation(bundle: "com.example.b", title: "B", x: 1900),
        ]
        let snapshot = try GoldenGateMenuBarSnapshotBuilder.build(
            observations: observations,
            displayIdentities: [MenuBarDisplayIdentity(runtimeID: displayID), MenuBarDisplayIdentity(runtimeID: secondDisplay)],
            activeDisplayID: displayID,
            displayBounds: [displayID: displayBounds, secondDisplay: MenuBarRect(x: 1800, y: 0, width: 1800, height: 1200)],
            activeSpaceIsValid: false, menuTrackingIsActive: true,
            appSigningIdentifier: appID, generation: 8
        )
        #expect(snapshot.items[1].displayID == displayID)
        #expect(snapshot.items[3].displayID == secondDisplay)
        #expect(snapshot.items[1].section == .hidden)
        #expect(snapshot.items[3].section == .hidden)
        #expect(!snapshot.activeSpaceIsValid)
        #expect(snapshot.menuTrackingIsActive)
    }

    @Test("A divider on one display cannot erase another display's remembered section")
    func missingDividerOnSecondDisplay() throws {
        let secondDisplay = MenuBarDisplayID("display-b")
        let observations = [
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
            observation(bundle: "com.example.a", title: "A", x: 1600),
            observation(bundle: "com.example.b", title: "B", x: 1900),
            observation(bundle: "com.example.unknown", title: "Unknown", x: 2000),
            observation(bundle: "com.example.offscreen", title: "Offscreen", x: -10000),
        ]
        let identifiers = GoldenGateMenuBarSnapshotBuilder.identifiers(for: observations)
        let snapshot = try GoldenGateMenuBarSnapshotBuilder.build(
            observations: observations,
            displayIdentities: [MenuBarDisplayIdentity(runtimeID: displayID), MenuBarDisplayIdentity(runtimeID: secondDisplay)],
            activeDisplayID: displayID,
            displayBounds: [displayID: displayBounds, secondDisplay: MenuBarRect(x: 1800, y: 0, width: 1800, height: 1200)],
            activeSpaceIsValid: true, menuTrackingIsActive: false,
            appSigningIdentifier: appID, rememberedSections: [identifiers[2]: .hidden], generation: 8
        )
        #expect(snapshot.items[1].section == .visible)
        #expect(snapshot.items[2].section == .hidden)
        #expect(snapshot.items[3].section == .visible)
        #expect(!snapshot.items[3].canBeHidden)
        #expect(snapshot.items[4].displayID == nil)
        #expect(!snapshot.items[4].isOnScreen)
    }

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

    @Test("An ambiguous divider overlap preserves the rest of the inventory")
    func ambiguousDividerOverlapIsVisibleAndNonHideable() throws {
        let snapshot = try build([
            observation(bundle: "com.example.hidden", title: "Hidden", x: 1480),
            observation(
                bundle: "com.example.ambiguous",
                title: "Ambiguous",
                x: 1538,
                width: 20
            ),
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
            observation(bundle: "com.example.visible", title: "Visible", x: 1600),
        ])

        #expect(snapshot.items.count == 4)
        let ambiguous = snapshot.items.first {
            $0.id.bundleIdentifier == "com.example.ambiguous"
        }
        #expect(ambiguous?.section == .visible)
        #expect(ambiguous?.isMovable == false)
        #expect(ambiguous?.canBeHidden == false)
        #expect(snapshot.items.first {
            $0.id.bundleIdentifier == "com.example.hidden"
        }?.section == .hidden)
        #expect(snapshot.items.first {
            $0.id.bundleIdentifier == "com.example.visible"
        }?.section == .visible)
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

    @Test("Distinct numeric AX identifiers keep their identities through reorder and sibling changes")
    func distinctNumericIdentifiersAreOrderIndependent() {
        let observations = (0 ..< 3).map { index in
            GoldenGateMenuBarObservation(
                bundleIdentifier: "com.example.multiple",
                localizedApplicationName: "Example",
                identifier: "status-item-\(index)",
                displayTitle: "Status",
                stableTitle: "status-item-<n>",
                fallbackFingerprint: "same-semantic-fingerprint",
                bounds: MenuBarRect(x: Double(1500 + index * 30), y: 3, width: 24, height: 24),
                ownerProcessIdentifier: 42
            )
        }
        let ids = GoldenGateMenuBarSnapshotBuilder.identifiers(for: observations)
        #expect(GoldenGateMenuBarSnapshotBuilder.identifiers(for: observations.reversed()) == ids.reversed())
        #expect(GoldenGateMenuBarSnapshotBuilder.identifiers(for: [observations[1]]) == [ids[1]])
        #expect(GoldenGateMenuBarSnapshotBuilder.identifiers(for: [observations[2], observations[0]]) == [ids[2], ids[0]])
        #expect(ids.allSatisfy { $0.alias == "occurrence-0" })
    }

    @Test("Occurrence buckets use normalized structured identities including fingerprints")
    func structuredIdentityBuckets() {
        func observed(_ bundle: String, _ identifier: String?, _ title: String, _ fingerprint: String) -> GoldenGateMenuBarObservation {
            GoldenGateMenuBarObservation(
                bundleIdentifier: bundle, localizedApplicationName: nil,
                identifier: identifier, displayTitle: title, stableTitle: title,
                fallbackFingerprint: fingerprint, bounds: .zero, ownerProcessIdentifier: 42
            )
        }
        let ids = GoldenGateMenuBarSnapshotBuilder.identifiers(for: [
            observed(" COM.EXAMPLE.APP ", " AX-ID ", " Status ", " One "),
            observed("com.example.app", "ax-id", "status", "one"),
            observed("com.example.app", "ax-id", "status", "two"),
            observed("com.example|app", nil, "status", "one"),
            observed("com.example", nil, "app|status", "one"),
            observed("com.example.nil", nil, "status", "one"),
            observed("com.example.nil", "  ", "status", "one"),
        ])
        #expect(ids.map(\.alias) == ["occurrence-0", "occurrence-1", "occurrence-0", "occurrence-0", "occurrence-0", "occurrence-0", "occurrence-1"])
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
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: -10000),
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

    @Test("Native new items remain assignable with an off-screen divider")
    func nativeParkedDivider() throws {
        let snapshot = try build([
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 2500),
            observation(bundle: "com.example.fixture", title: "Native", x: 1400),
            observation(bundle: "com.example.fixture", title: "Popover", x: 1450),
        ], sectionPolicy: .nativeVisibilityAssignments)
        let items = snapshot.items.filter { !$0.isBarlineControlItem }
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.section == .visible && $0.canBeHidden && !$0.isMovable })
        #expect(items.allSatisfy { $0.displayID == displayID })
    }

    @Test("Native unassigned items default visible regardless of divider geometry")
    func nativeDoesNotInferHiddenFromGeometry() throws {
        for dividerX in [1450.0, 1550, 2500] {
            let snapshot = try build([
                observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: dividerX),
                observation(bundle: "com.example.new", title: "New", x: 1500),
            ], sectionPolicy: .nativeVisibilityAssignments)
            #expect(snapshot.items[1].section == .visible)
            #expect(snapshot.items[1].canBeHidden)
            #expect(!snapshot.items[1].isMovable)
        }
    }

    @Test("Native saved assignments precede remembered sections and geometry")
    func nativeAssignmentPrecedence() throws {
        let observations = [
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1400),
            observation(bundle: "com.example.saved", title: "Saved", x: 1500),
        ]
        let identifier = GoldenGateMenuBarSnapshotBuilder.identifiers(for: observations)[1]
        let remembered = try build(observations, rememberedSections: [identifier: .hidden],
                                   sectionPolicy: .nativeVisibilityAssignments)
        #expect(remembered.items[1].section == .hidden)
        let explicit = try build(observations, rememberedSections: [identifier: .hidden],
                                 assignedSections: [identifier: .visible],
                                 sectionPolicy: .nativeVisibilityAssignments)
        #expect(explicit.items[1].section == .visible)
        #expect(remembered.items[1].canBeHidden && explicit.items[1].canBeHidden)
    }

    @Test("Native policy does not guess unresolved display ownership")
    func nativeUnknownDisplayFailsVisible() throws {
        let snapshot = try build([
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 2500),
            observation(bundle: "com.example.offscreen", title: "Offscreen", x: -10000),
        ], sectionPolicy: .nativeVisibilityAssignments)
        #expect(snapshot.items[1].section == .visible)
        #expect(snapshot.items[1].displayID == nil)
        #expect(!snapshot.items[1].canBeHidden && !snapshot.items[1].isMovable)
    }

    @Test("Native policy retains control-presence and Focus safeguards")
    func nativeControlSafeguards() throws {
        #expect(throws: MenuBarBackendError.self) {
            try build([observation(bundle: "com.example.new", title: "New", x: 1500)],
                      sectionPolicy: .nativeVisibilityAssignments)
        }
        let observations = [
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 2500),
            observation(bundle: "com.apple.MenuBarAgent", title: "com.apple.menuextra.focusmode", x: 1500),
            observation(bundle: "com.apple.controlcenter", title: "Clock", x: 1650),
        ]
        let snapshot = try build(observations,
                                 assignedSections: [MenuBarPlatformPresenceIdentity.focusItemID: .hidden],
                                 sectionPolicy: .nativeVisibilityAssignments)
        #expect(snapshot.items[1].section == .visible)
        #expect(!snapshot.items[1].canBeHidden && !snapshot.items[1].isMovable)
        #expect(!snapshot.items[2].canBeHidden && !snapshot.items[2].isMovable)
    }

    @Test("Default geometry policy still rejects a parked divider's new items")
    func defaultParkedDividerRemainsStrict() throws {
        let snapshot = try build([
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 2500),
            observation(bundle: "com.example.new", title: "New", x: 1500),
        ])
        #expect(snapshot.items[1].section == .visible)
        #expect(!snapshot.items[1].canBeHidden && !snapshot.items[1].isMovable)
    }

    @Test("Native policy does not resolve ownership across overlapping displays")
    func nativeAmbiguousDisplayRemainsStrict() throws {
        let secondDisplay = MenuBarDisplayID("display-b")
        let snapshot = try GoldenGateMenuBarSnapshotBuilder.build(
            observations: [
                observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 2500),
                observation(bundle: "com.example.ambiguous", title: "Ambiguous", x: 1500),
            ],
            displayIdentities: [MenuBarDisplayIdentity(runtimeID: displayID), MenuBarDisplayIdentity(runtimeID: secondDisplay)],
            activeDisplayID: displayID,
            displayBounds: [displayID: displayBounds, secondDisplay: displayBounds],
            activeSpaceIsValid: true, menuTrackingIsActive: false,
            appSigningIdentifier: appID, sectionPolicy: .nativeVisibilityAssignments, generation: 8
        )
        #expect(snapshot.items[1].section == .visible)
        #expect(snapshot.items[1].displayID == nil)
        #expect(!snapshot.items[1].canBeHidden && !snapshot.items[1].isMovable)
    }

    @Test("Native policy preserves existing saved off-screen state without granting movability")
    func nativeSavedOffscreenStateIsNotNewAuthority() throws {
        let observations = [
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 2500),
            observation(bundle: "com.example.saved", title: "Saved", x: -10000),
        ]
        let identifier = GoldenGateMenuBarSnapshotBuilder.identifiers(for: observations)[1]
        for remembered in [false, true] {
            let snapshot = try build(
                observations,
                rememberedSections: remembered ? [identifier: .hidden] : [:],
                assignedSections: remembered ? [:] : [identifier: .hidden],
                sectionPolicy: .nativeVisibilityAssignments
            )
            #expect(snapshot.items[1].section == .hidden)
            #expect(snapshot.items[1].displayID == nil)
            #expect(!snapshot.items[1].isMovable && !snapshot.items[1].isOnScreen)
            // This preserves the pre-existing saved-intent path, not permission
            // to guess a display or to mutate on an unqualified observation.
            #expect(!MenuBarDisplayOwnershipPolicy.permitsLogicalMove(
                sourceDisplayID: snapshot.items[1].displayID, destinationDisplayID: displayID
            ))
        }
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
        assignedSections: [MenuBarItemID: MenuBarSection] = [:],
        sectionPolicy: GoldenGateMenuBarSnapshotBuilder.SectionPolicy = .dividerGeometry
    ) throws -> MenuBarSnapshot {
        try GoldenGateMenuBarSnapshotBuilder.build(
            observations: observations,
            displayIdentities: [MenuBarDisplayIdentity(runtimeID: displayID)],
            activeDisplayID: displayID,
            displayBounds: [displayID: displayBounds],
            activeSpaceIsValid: true,
            menuTrackingIsActive: false,
            appSigningIdentifier: appID,
            rememberedSections: rememberedSections,
            assignedSections: assignedSections,
            sectionPolicy: sectionPolicy,
            generation: 7
        )
    }

    private func observation(
        bundle: String,
        title: String,
        x: Double,
        width: Double = 30,
        localizedApplicationName: String? = nil
    ) -> GoldenGateMenuBarObservation {
        GoldenGateMenuBarObservation(
            bundleIdentifier: bundle,
            localizedApplicationName: localizedApplicationName,
            identifier: title,
            displayTitle: title,
            stableTitle: title,
            fallbackFingerprint: "fingerprint-\(bundle)-\(title)",
            bounds: MenuBarRect(x: x, y: 3, width: width, height: 24),
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
