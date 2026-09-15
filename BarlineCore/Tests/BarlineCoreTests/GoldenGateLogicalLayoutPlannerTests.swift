@testable import BarlineCore
import Foundation
import Testing

@Suite("Golden Gate logical layout planner")
struct GoldenGateLogicalLayoutPlannerTests {
    @Test("Moves a supported visible item into an empty hidden section")
    func movesIntoEmptyHiddenSection() throws {
        let before = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .visible, order: 1),
        ])

        let after = try GoldenGateLogicalLayoutPlanner().applying(
            MenuBarMoveOperation(itemID: id(1), section: .hidden, index: 0),
            to: before
        )

        #expect(after.generation == before.generation + 1)
        #expect(after.items.filter { $0.section == .hidden }.map(\.id) == [id(1)])
        #expect(after.items.filter { $0.section == .visible }.map(\.id) == [id(2)])
    }

    @Test("Moves a hidden item back to visible at the requested insertion point")
    func restoresVisibleItem() throws {
        let before = snapshot([
            item(1, section: .hidden, order: 0),
            item(2, section: .visible, order: 1),
            item(3, section: .visible, order: 2),
        ])

        let after = try GoldenGateLogicalLayoutPlanner().applying(
            MenuBarMoveOperation(itemID: id(1), section: .visible, index: 1),
            to: before
        )

        #expect(after.items.filter { $0.section == .hidden }.isEmpty)
        #expect(after.items.filter { $0.section == .visible }.map(\.id) == [id(2), id(1), id(3)])
    }

    @Test("Reorders an item in its current section without duplicating it")
    func reordersWithinSection() throws {
        let before = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .visible, order: 1),
            item(3, section: .visible, order: 2),
        ])

        let after = try GoldenGateLogicalLayoutPlanner().applying(
            MenuBarMoveOperation(itemID: id(1), section: .visible, index: 3),
            to: before
        )

        #expect(after.items.map(\.id) == [id(2), id(3), id(1)])
        #expect(Set(after.items.map(\.id)).count == before.items.count)
    }

    @Test("Rejects unsupported independent assignments")
    func rejectsImmovableItem() {
        let before = snapshot([item(1, section: .visible, order: 0, isMovable: false)])

        #expect(throws: MenuBarBackendError.self) {
            try GoldenGateLogicalLayoutPlanner().applying(
                MenuBarMoveOperation(itemID: id(1), section: .hidden, index: 0),
                to: before
            )
        }
    }

    @Test("Restores persisted rank without losing newly discovered items")
    func appliesExplicitRank() {
        let before = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .visible, order: 1),
            item(3, section: .visible, order: 2),
        ])
        let assignments = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .visible, rank: 1),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .visible, rank: 0),
        ]

        let after = GoldenGateLogicalLayoutPlanner().applyingExplicitOrder(
            to: before,
            assignments: assignments
        )

        #expect(after.items.map(\.id) == [id(2), id(1), id(3)])
    }

    private func snapshot(_ items: [MenuBarItemDescriptor]) -> MenuBarSnapshot {
        MenuBarSnapshot(
            generation: 10,
            capturedAt: Date(timeIntervalSince1970: 1),
            items: items,
            displayIDs: [MenuBarDisplayID("display")],
            activeSpaceIsValid: true
        )
    }

    private func item(
        _ value: Int,
        section: MenuBarSection,
        order: Int,
        isMovable: Bool = true
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: id(value),
            section: section,
            order: order,
            displayID: MenuBarDisplayID("display"),
            displayName: "Item \(value)",
            isMovable: isMovable
        )
    }

    private func id(_ value: Int) -> MenuBarItemID {
        MenuBarItemID(
            bundleIdentifier: "com.example.item\(value)",
            accessibilityIdentifier: "item-\(value)",
            title: "Item \(value)",
            alias: "occurrence-0"
        )
    }
}
