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
            editing: [id(1)],
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
            editing: [id(1)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 3
        )

        #expect(assignments.map(\.itemID) == [id(1), id(2), id(3)])
    }

    @Test("Unrelated visibility edit cannot save transient fail-visible state")
    func persistenceEditsOnlyRequestedIdentity() {
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 0),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .hidden, rank: 1),
            id(3): GoldenGateLogicalAssignment(itemID: id(3), section: .visible, rank: 0),
        ]
        let runtime = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .visible, order: 1),
            item(4, section: .visible, order: 2), // temporary, unsaved sibling
            item(3, section: .hidden, order: 3), // unrelated explicit edit
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(3)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect(byID[id(1)]?.section == .hidden)
        #expect(byID[id(2)]?.section == .hidden)
        #expect(byID[id(3)]?.section == .hidden)
        #expect(byID[id(4)] == nil)
    }

    @Test("Shelf reorder preserves unrelated hidden intent")
    func shelfReorderEditsOnlyItsSection() {
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 0),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .hidden, rank: 0),
            id(3): GoldenGateLogicalAssignment(itemID: id(3), section: .hidden, rank: 1),
        ]
        let runtime = snapshot([
            item(1, section: .visible, order: 0), // temporarily fail-visible
            item(3, section: .hidden, order: 1),
            item(2, section: .hidden, order: 2),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(2), id(3)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect(byID[id(1)] == saved[id(1)])
        #expect(byID[id(3)]?.rank == 1)
        #expect(byID[id(2)]?.rank == 2)
    }

    @Test("An edited item joins the saved order instead of a separate rank space")
    func editedItemRankIsConsistentWithSavedRanks() {
        // Saved ranks come from an older numbering (5, 9); the live menu bar
        // shows the newly hidden item 3 between them.
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 5),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .hidden, rank: 9),
        ]
        let runtime = snapshot([
            item(1, section: .hidden, order: 0),
            item(3, section: .hidden, order: 1),
            item(2, section: .hidden, order: 2),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(3)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        // Before this fix item 3 got live index 1, which sorted it ahead of both.
        #expect(byID[id(1)]?.rank == 0)
        #expect(byID[id(3)]?.rank == 1)
        #expect(byID[id(2)]?.rank == 2)
        #expect(assignments.allSatisfy { $0.section == .hidden })
    }

    @Test("An edited item follows its nearest live neighbour, not the last saved one")
    func editedItemFollowsNearestLivePredecessor() {
        // Saved order A(1), B(2); the live bar shows B, A, then the edited X.
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 0),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .hidden, rank: 1),
        ]
        let runtime = snapshot([
            item(2, section: .hidden, order: 0),
            item(1, section: .hidden, order: 1),
            item(3, section: .hidden, order: 2),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(3)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect(byID[id(1)]?.rank == 0)
        #expect(byID[id(3)]?.rank == 1)
        #expect(byID[id(2)]?.rank == 2)
    }

    @Test("Physical position wins over a display-ordered snapshot")
    func physicalPositionOrdersEditedItem() {
        // Device case on macOS 27: 1Password (id 1) is already hidden, so the
        // display snapshot lists it after every visible item, but physically it
        // sits left of Stats (id 2), which is being hidden now.
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 0),
        ]
        func framed(_ value: Int, _ section: MenuBarSection, order: Int, x: Double) -> MenuBarItemDescriptor {
            MenuBarItemDescriptor(
                id: id(value),
                section: section,
                order: order,
                displayID: MenuBarDisplayID("display"),
                displayName: "Item \(value)",
                bounds: MenuBarRect(x: x, y: 0, width: 30, height: 24),
                isMovable: true,
                canBeHidden: true
            )
        }
        let runtime = snapshot([
            framed(2, .hidden, order: 0, x: 1462),
            framed(3, .visible, order: 1, x: 1700),
            framed(1, .hidden, order: 2, x: 1384),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(2)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect(byID[id(1)]?.rank == 0)
        #expect(byID[id(2)]?.rank == 1)
    }

    @Test("Re-hiding an item left of already hidden items keeps physical order")
    func rehidingLeftItemPrecedesHiddenNeighbours() {
        // Device case: the absent fixture (ids 8, 9) and Stats (id 2) are saved
        // hidden; 1Password (id 1), physically left of Stats, is hidden again.
        let saved = [
            id(8): GoldenGateLogicalAssignment(itemID: id(8), section: .hidden, rank: 0),
            id(9): GoldenGateLogicalAssignment(itemID: id(9), section: .hidden, rank: 1),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .hidden, rank: 2),
        ]
        func framed(_ value: Int, _ section: MenuBarSection, order: Int, x: Double) -> MenuBarItemDescriptor {
            MenuBarItemDescriptor(
                id: id(value),
                section: section,
                order: order,
                displayID: MenuBarDisplayID("display"),
                displayName: "Item \(value)",
                bounds: MenuBarRect(x: x, y: 0, width: 30, height: 24),
                isMovable: true,
                canBeHidden: true
            )
        }
        let runtime = snapshot([
            framed(3, .visible, order: 0, x: 1700),
            framed(1, .hidden, order: 1, x: 1384),
            framed(2, .hidden, order: 2, x: 1462),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(1)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect((byID[id(1)]?.rank ?? 99) < (byID[id(2)]?.rank ?? -1))
    }

    @Test("One frameless retained item does not discard physical positions")
    func framelessItemKeepsOthersPhysical() {
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 0),
            id(7): GoldenGateLogicalAssignment(itemID: id(7), section: .hidden, rank: 1),
        ]
        func framed(_ value: Int, _ section: MenuBarSection, order: Int, x: Double) -> MenuBarItemDescriptor {
            MenuBarItemDescriptor(
                id: id(value), section: section, order: order,
                displayID: MenuBarDisplayID("display"), displayName: "Item \(value)",
                bounds: MenuBarRect(x: x, y: 0, width: x > 0 ? 30 : 0, height: 24),
                isMovable: true, canBeHidden: true
            )
        }
        // Display order puts hidden 1Password (1) and the frameless retained
        // item (7) after Stats (2); physically 1Password is left of Stats.
        let runtime = snapshot([
            framed(2, .hidden, order: 0, x: 1462),
            framed(1, .hidden, order: 1, x: 1384),
            framed(7, .hidden, order: 2, x: 0),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime, preserving: saved, editing: [id(2)],
            barlineBundleIdentifier: "com.mabryventures.Barline", maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect((byID[id(1)]?.rank ?? 99) < (byID[id(2)]?.rank ?? -1))
    }

    @Test("An explicit shelf reorder keeps the requested order")
    func shelfReorderKeepsRequestedOrder() {
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 0),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .hidden, rank: 1),
        ]
        func framed(_ value: Int, order: Int, x: Double) -> MenuBarItemDescriptor {
            MenuBarItemDescriptor(
                id: id(value), section: .hidden, order: order,
                displayID: MenuBarDisplayID("display"), displayName: "Item \(value)",
                bounds: MenuBarRect(x: x, y: 0, width: 30, height: 24),
                isMovable: true, canBeHidden: true
            )
        }
        // The user dragged 2 before 1, although 1 is physically to the left.
        let candidate = snapshot([framed(2, order: 0, x: 1462), framed(1, order: 1, x: 1384)])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: candidate, preserving: saved, editing: [id(1), id(2)],
            barlineBundleIdentifier: "com.mabryventures.Barline", maximumCount: 10,
            rankOrder: .snapshot
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect(byID[id(2)]?.rank == 0)
        #expect(byID[id(1)]?.rank == 1)
    }

    @Test("With no live neighbour, an edited item follows saved items")
    func editedItemFollowsConcealedSavedItems() {
        // 1Password (id 1) was hidden earlier and is concealed, so it is absent
        // from the live snapshot. Hiding Stats (id 2) must not jump ahead of it.
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 0),
        ]
        let runtime = snapshot([
            item(2, section: .hidden, order: 0),
            item(3, section: .visible, order: 1),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(2)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect(byID[id(1)]?.rank == 0)
        #expect(byID[id(2)]?.rank == 1)
    }

    @Test("Edited items with no untouched predecessor lead the section in live order")
    func editedItemsWithoutPredecessorLead() {
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 4),
        ]
        let runtime = snapshot([
            item(3, section: .hidden, order: 0),
            item(2, section: .hidden, order: 1),
            item(1, section: .hidden, order: 2),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(2), id(3)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.itemID, $0) })

        #expect(byID[id(3)]?.rank == 0)
        #expect(byID[id(2)]?.rank == 1)
        #expect(byID[id(1)]?.rank == 2)
    }

    @Test("Editing the previously hidden group intentionally replaces its intent")
    func explicitGroupEditCanMakeItemsVisible() {
        let saved = [
            id(1): GoldenGateLogicalAssignment(itemID: id(1), section: .hidden, rank: 0),
            id(2): GoldenGateLogicalAssignment(itemID: id(2), section: .hidden, rank: 1),
        ]
        let runtime = snapshot([
            item(1, section: .visible, order: 0),
            item(2, section: .visible, order: 1),
        ])
        let assignments = GoldenGateLogicalLayoutPlanner().assignmentsForPersistence(
            from: runtime,
            preserving: saved,
            editing: [id(1), id(2)],
            barlineBundleIdentifier: "com.mabryventures.Barline",
            maximumCount: 10
        )

        #expect(assignments.allSatisfy { $0.section == .visible })
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
