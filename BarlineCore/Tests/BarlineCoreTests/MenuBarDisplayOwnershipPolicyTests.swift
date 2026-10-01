@testable import BarlineCore
import Foundation
import Testing

@Suite("Menu bar display ownership")
struct MenuBarDisplayOwnershipPolicyTests {
    @Test("Inventory completion rejects changed geometry with unchanged display IDs")
    func stableInventoryGeometry() {
        let id = MenuBarDisplayID("a")
        let initial = [id: MenuBarRect(x: 0, y: 0, width: 1920, height: 1080)]
        #expect(MenuBarDisplayOwnershipPolicy.hasStableGeometry(before: initial, after: initial))
        #expect(!MenuBarDisplayOwnershipPolicy.hasStableGeometry(before: initial, after: [
            id: MenuBarRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]))
        #expect(!MenuBarDisplayOwnershipPolicy.hasStableGeometry(before: initial, after: [
            id: MenuBarRect(x: 0, y: 0, width: 960, height: 540),
        ]))
        #expect(!MenuBarDisplayOwnershipPolicy.hasStableGeometry(before: initial, after: [:]))
    }

    @Test("Logical moves reject transfers and unknown source ownership")
    func logicalMoveDestination() {
        let first = MenuBarDisplayID("a")
        let second = MenuBarDisplayID("b")
        #expect(MenuBarDisplayOwnershipPolicy.permitsLogicalMove(sourceDisplayID: first, destinationDisplayID: nil))
        #expect(MenuBarDisplayOwnershipPolicy.permitsLogicalMove(sourceDisplayID: nil, destinationDisplayID: nil))
        #expect(MenuBarDisplayOwnershipPolicy.permitsLogicalMove(sourceDisplayID: first, destinationDisplayID: first))
        #expect(!MenuBarDisplayOwnershipPolicy.permitsLogicalMove(sourceDisplayID: first, destinationDisplayID: second))
        #expect(!MenuBarDisplayOwnershipPolicy.permitsLogicalMove(sourceDisplayID: nil, destinationDisplayID: first))
    }

    private let primary = MenuBarDisplayID("primary")
    private let secondary = MenuBarDisplayID("secondary")
    private let mainBounds = MenuBarRect(x: 0, y: 0, width: 1728, height: 1117)
    private let leftBounds = MenuBarRect(x: -1728, y: 0, width: 1728, height: 1117)
    private let hidden = MenuBarRect(x: -4283, y: 0, width: 90, height: 33)
    private let visible = MenuBarRect(x: 800, y: 0, width: 90, height: 33)

    @Test("Authoritative ownership survives hidden coordinates outside every display")
    func offscreenHidden() {
        #expect(resolve(hidden, membership: [primary]) == primary)
        #expect(resolve(hidden, membership: [secondary]) == secondary)
        #expect(resolve(hidden, membership: nil) == nil)
    }

    @Test("Hidden layout coordinates inside another monitor cannot override unique ownership")
    func membershipPrecedesGeometry() {
        let overLeftDisplay = MenuBarRect(x: -1200, y: 0, width: 90, height: 33)
        #expect(resolve(overLeftDisplay, membership: [primary]) == primary)
        #expect(resolve(overLeftDisplay, membership: nil) == secondary)
    }

    @Test("Unavailable membership and a successful query without an owner differ")
    func unavailableAndEmpty() {
        #expect(resolve(visible, membership: nil) == primary)
        #expect(resolve(visible, membership: []) == nil)
        #expect(resolve(visible, membership: [MenuBarDisplayID("disconnected")]) == nil)
        #expect(resolve(visible, membership: [primary, MenuBarDisplayID("disconnected")]) == nil)
    }

    @Test("Multiple memberships require exactly one physically containing member")
    func ambiguousMembership() {
        #expect(resolve(visible, membership: [primary, secondary]) == primary)
        #expect(resolve(hidden, membership: [primary, secondary]) == nil)
        #expect(MenuBarDisplayOwnershipPolicy.resolve(
            itemBounds: visible,
            displays: [primary: mainBounds, secondary: mainBounds],
            membershipDisplayIDs: [primary, secondary]
        ) == nil)
        #expect(MenuBarDisplayOwnershipPolicy.resolve(
            itemBounds: visible,
            displays: [primary: mainBounds, secondary: mainBounds],
            membershipDisplayIDs: nil
        ) == nil)
    }

    @Test("Fallback uses the click center with half-open display edges, not rectangle overlap")
    func physicalGeometry() {
        #expect(resolve(MenuBarRect(x: -45, y: 0, width: 90, height: 33), membership: nil) == primary)
        #expect(resolve(MenuBarRect(x: -46, y: 0, width: 90, height: 33), membership: nil) == secondary)
        #expect(resolve(MenuBarRect(x: 1700, y: 0, width: 90, height: 33), membership: nil) == nil)
        #expect(MenuBarDisplayOwnershipPolicy.resolve(
            itemBounds: MenuBarRect(x: 1800, y: 0, width: 90, height: 33),
            displays: [primary: mainBounds, secondary: MenuBarRect(x: 2000, y: 0, width: 1728, height: 1117)],
            membershipDisplayIDs: nil
        ) == nil)
    }

    @Test("Malformed geometry or display identity fails closed even with a reported owner")
    func invalidGeometry() {
        for rect in [MenuBarRect.zero, MenuBarRect(x: .nan, y: 0, width: 90, height: 33),
                     MenuBarRect(x: .greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 33)]
        {
            #expect(resolve(rect, membership: [primary]) == nil)
            #expect(MenuBarDisplayOwnershipPolicy.resolve(
                itemBounds: visible, displays: [primary: rect], membershipDisplayIDs: [primary]
            ) == nil)
        }
        #expect(MenuBarDisplayOwnershipPolicy.resolve(
            itemBounds: visible, displays: [MenuBarDisplayID(""): mainBounds], membershipDisplayIDs: nil
        ) == nil)
        #expect(MenuBarDisplayOwnershipPolicy.resolve(
            itemBounds: visible, displays: [:], membershipDisplayIDs: [primary]
        ) == nil)
    }

    @Test("Resolved ownership keeps hidden-to-visible-to-hidden compensation on its original display")
    func restorationRoundTrip() throws {
        let target = MenuBarItemID(bundleIdentifier: "test.ownership", accessibilityIdentifier: "target")
        let anchor = MenuBarItemID(bundleIdentifier: "test.ownership", accessibilityIdentifier: "anchor")
        func snapshot(_ section: MenuBarSection, bounds: MenuBarRect) -> MenuBarSnapshot {
            MenuBarSnapshot(
                generation: 1, capturedAt: Date(), items: [
                    MenuBarItemDescriptor(id: target, section: section, order: 0,
                                          displayID: resolve(bounds, membership: [primary]), bounds: bounds),
                    MenuBarItemDescriptor(id: anchor, section: .hidden, order: 1,
                                          displayID: resolve(hidden, membership: [primary]), bounds: hidden),
                ], displayIDs: [primary, secondary], activeSpaceIsValid: true
            )
        }
        let before = snapshot(.hidden, bounds: hidden)
        let checkpoint = try #require(TemporaryRevealRestoration(itemID: target, in: before))
        let revealed = snapshot(.visible, bounds: visible)
        let expected = MenuBarMoveOperation(itemID: target, section: .hidden, index: 0, destinationDisplayID: primary)
        #expect(checkpoint.resolve(in: revealed) == .move(expected))
        let restored = snapshot(.hidden, bounds: hidden)
        #expect(MenuBarMovePlanner().resultMatches(expected, in: restored, from: revealed))
        #expect(checkpoint.resolve(in: restored) == .move(MenuBarMoveOperation(
            itemID: target, section: .hidden, index: 1, destinationDisplayID: primary
        )))
    }

    private func resolve(_ bounds: MenuBarRect, membership: Set<MenuBarDisplayID>?) -> MenuBarDisplayID? {
        MenuBarDisplayOwnershipPolicy.resolve(
            itemBounds: bounds, displays: [primary: mainBounds, secondary: leftBounds], membershipDisplayIDs: membership
        )
    }
}
