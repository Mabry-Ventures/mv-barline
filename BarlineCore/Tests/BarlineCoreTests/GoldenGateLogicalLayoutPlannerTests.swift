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

    @Test("Cross-section assignment preserves native order regardless of synthetic drop index")
    func crossSectionAssignmentIgnoresDropIndex() throws {
        let before = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .hidden, order: 1),
            item(3, section: .hidden, order: 2),
        ])

        let after = try GoldenGateLogicalLayoutPlanner().applying(
            MenuBarMoveOperation(itemID: id(1), section: .hidden, index: 3),
            to: before
        )

        #expect(after.items.map(\.id) == [id(1), id(2), id(3)])
        #expect(after.items.allSatisfy { $0.section == .hidden })
    }

    @Test("Moves a hidden item back to its native visible-order position")
    func restoresVisibleItem() throws {
        let before = snapshot([
            item(1, section: .hidden, order: 0),
            item(2, section: .visible, order: 1),
            item(3, section: .visible, order: 2),
        ])

        let after = try GoldenGateLogicalLayoutPlanner().applying(
            MenuBarMoveOperation(itemID: id(1), section: .visible, index: 0),
            to: before
        )

        #expect(after.items.filter { $0.section == .hidden }.isEmpty)
        #expect(after.items.filter { $0.section == .visible }.map(\.id) == [id(1), id(2), id(3)])
    }

    @Test("Rejects a same-section reorder that native concealment cannot perform")
    func rejectsReorderWithinSection() {
        let before = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .visible, order: 1),
            item(3, section: .visible, order: 2),
        ])

        #expect(throws: MenuBarBackendError.self) {
            try GoldenGateLogicalLayoutPlanner().applying(
                MenuBarMoveOperation(itemID: id(1), section: .visible, index: 3),
                to: before
            )
        }
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

    @Test("Persisted shelf rank never cosmetically reorders the native menu bar")
    func appliesOnlyExplicitShelfRank() {
        let before = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .visible, order: 1),
            item(3, section: .hidden, order: 2),
            item(4, section: .hidden, order: 3),
        ])
        let assignments = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .visible, rank: 1),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .visible, rank: 0),
            id(3): GoldenGateLogicalAssignment(itemID: id(3), section: .hidden, rank: 1),
            id(4): GoldenGateLogicalAssignment(itemID: id(4), section: .hidden, rank: 0),
        ]

        let after = GoldenGateLogicalLayoutPlanner().applyingExplicitShelfOrder(
            to: before,
            assignments: assignments
        )

        #expect(after.items.filter { $0.section == .visible }.map(\.id) == [id(1), id(2)])
        #expect(after.items.filter { $0.section == .hidden }.map(\.id) == [id(4), id(3)])
    }

    @Test("Persistence retains absent apps and excludes Barline controls")
    func persistenceRetainsAbsentAssignments() {
        let absentID = id(9)
        let controlID = MenuBarItemID(
            bundleIdentifier: "com.mabryventures.Barline",
            accessibilityIdentifier: "barline-control",
            title: "Barline",
            alias: "occurrence-0"
        )
        let absentControlID = MenuBarItemID(
            bundleIdentifier: "COM.MABRYVENTURES.BARLINE",
            accessibilityIdentifier: "absent-barline-control",
            title: "Barline",
            alias: "occurrence-0"
        )
        let before = snapshot([
            item(1, section: .hidden, order: 0),
            item(
                controlID,
                section: .visible,
                order: 1,
                isBarlineControlItem: true
            ),
        ])
        let existing = [
            absentID: GoldenGateLogicalAssignment(itemID: absentID, section: .hidden, rank: 3),
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .visible, rank: 8),
            absentControlID: GoldenGateLogicalAssignment(
                itemID: absentControlID,
                section: .hidden,
                rank: 4
            ),
        ]

        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: before,
            preserving: existing,
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )

        #expect(assignments.map(\.itemID) == [id(1), absentID])
        #expect(assignments[0].section == .hidden)
        #expect(!assignments.contains(where: { $0.itemID == controlID }))
        #expect(!assignments.contains(where: { $0.itemID == absentControlID }))
    }

    @Test("Persistence is deterministically bounded")
    func persistenceIsBounded() {
        let before = snapshot([item(1, section: .visible, order: 0)])
        let existing = Dictionary(uniqueKeysWithValues: (2 ... 5).map { value in
            let itemID = id(value)
            return (
                itemID,
                GoldenGateLogicalAssignment(itemID: itemID, section: .hidden, rank: value)
            )
        })

        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: before,
            preserving: existing,
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 3
        )

        #expect(assignments.map(\.itemID) == [id(1), id(2), id(3)])
    }

    @Test("Restore applies target sections and advances generation")
    func restoresTargetSections() throws {
        let current = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .hidden, order: 1),
        ])
        let target = snapshot([
            item(2, section: .visible, order: 0),
            item(1, section: .hidden, order: 1),
        ])

        let restored = try GoldenGateLogicalLayoutPlanner().restoring(target, to: current)

        #expect(restored.generation == current.generation + 1)
        #expect(restored.items.map(\.id) == [id(1), id(2)])
        #expect(restored.items.map(\.section) == [.hidden, .visible])
    }

    @Test("Restore rejects moving an immovable item")
    func restoreRejectsImmovableItem() {
        let current = snapshot([
            item(1, section: .visible, order: 0, isMovable: false),
        ])
        let target = snapshot([
            item(1, section: .hidden, order: 0),
        ])

        #expect(throws: MenuBarBackendError.self) {
            try GoldenGateLogicalLayoutPlanner().restoring(target, to: current)
        }
    }

    @Test("Restore rejects hiding a non-hideable item")
    func restoreRejectsNonHideableItem() {
        let current = snapshot([
            item(1, section: .visible, order: 0, canBeHidden: false),
        ])
        let target = snapshot([
            item(1, section: .hidden, order: 0),
        ])

        #expect(throws: MenuBarBackendError.self) {
            try GoldenGateLogicalLayoutPlanner().restoring(target, to: current)
        }
    }

    @Test("Restore rejects duplicate item identities")
    func restoreRejectsDuplicates() {
        let current = snapshot([item(1, section: .visible, order: 0)])
        let target = snapshot([
            item(1, section: .visible, order: 0),
            item(1, section: .hidden, order: 1),
        ])

        #expect(throws: MenuBarBackendError.self) {
            try GoldenGateLogicalLayoutPlanner().restoring(target, to: current)
        }
    }

    @Test("Restore rejects an order that native concealment cannot perform")
    func restoreRejectsNativeReorder() {
        let current = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .visible, order: 1),
        ])
        let target = snapshot([
            item(2, section: .visible, order: 0),
            item(1, section: .visible, order: 1),
        ])

        #expect(throws: MenuBarBackendError.self) {
            try GoldenGateLogicalLayoutPlanner().restoring(target, to: current)
        }
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
        isMovable: Bool = true,
        canBeHidden: Bool = true
    ) -> MenuBarItemDescriptor {
        item(
            id(value),
            section: section,
            order: order,
            isMovable: isMovable,
            canBeHidden: canBeHidden
        )
    }

    private func item(
        _ itemID: MenuBarItemID,
        section: MenuBarSection,
        order: Int,
        isBarlineControlItem: Bool = false,
        isMovable: Bool = true,
        canBeHidden: Bool = true
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: itemID,
            section: section,
            order: order,
            displayID: MenuBarDisplayID("display"),
            isBarlineControlItem: isBarlineControlItem,
            displayName: itemID.title ?? "Menu Bar Item",
            isMovable: isMovable,
            canBeHidden: canBeHidden
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
