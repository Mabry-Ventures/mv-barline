@testable import BarlineCore
import Foundation
import Testing

@Suite("Golden Gate retained inventory")
struct GoldenGateRetainedInventoryPolicyTests {
    private let displayID = MenuBarDisplayID("display")
    private let itemID = MenuBarItemID(
        bundleIdentifier: "com.example.single",
        title: "Item"
    )

    @Test("A committed hidden item survives disappearance from Accessibility")
    func retainsCommittedHiddenItem() {
        let result = merge(
            liveItems: [],
            retained: [descriptor(section: .visible)],
            assignment: GoldenGateLogicalAssignment(
                itemID: itemID,
                section: .hidden,
                rank: 0
            ),
            running: ["com.example.single"]
        )

        #expect(result.items.count == 1)
        #expect(result.items[0].id == itemID)
        #expect(result.items[0].section == .hidden)
        #expect(result.items[0].bounds == .zero)
        #expect(result.items[0].isOnScreen == false)
    }

    @Test("A missing visible item is not presented as a live phantom")
    func omitsMissingVisibleItem() {
        let result = merge(
            liveItems: [],
            retained: [descriptor(section: .visible)],
            assignment: GoldenGateLogicalAssignment(
                itemID: itemID,
                section: .visible,
                rank: 0
            ),
            running: ["com.example.single"]
        )

        #expect(result.items.isEmpty)
    }

    @Test("A stopped application's hidden item stays out of the live inventory")
    func omitsStoppedApplication() {
        let result = merge(
            liveItems: [],
            retained: [descriptor(section: .hidden)],
            assignment: GoldenGateLogicalAssignment(
                itemID: itemID,
                section: .hidden,
                rank: 0
            ),
            running: []
        )

        #expect(result.items.isEmpty)
    }

    @Test("A live observation replaces retained metadata without duplication")
    func liveObservationWins() {
        let live = descriptor(section: .hidden, displayName: "Current")
        let stale = descriptor(section: .hidden, displayName: "Stale")
        let result = merge(
            liveItems: [live],
            retained: [stale],
            assignment: GoldenGateLogicalAssignment(
                itemID: itemID,
                section: .hidden,
                rank: 0
            ),
            running: ["com.example.single"]
        )

        #expect(result.items.count == 1)
        #expect(result.items[0].displayName == "Current")
    }

    private func merge(
        liveItems: [MenuBarItemDescriptor],
        retained: [MenuBarItemDescriptor],
        assignment: GoldenGateLogicalAssignment,
        running: Set<String>
    ) -> MenuBarSnapshot {
        GoldenGateRetainedInventoryPolicy.merging(
            live: MenuBarSnapshot(
                generation: 1,
                capturedAt: Date(timeIntervalSince1970: 0),
                items: liveItems,
                displayIDs: [displayID],
                activeSpaceIsValid: true
            ),
            retainedDescriptors: Dictionary(uniqueKeysWithValues: retained.map {
                ($0.id, $0)
            }),
            assignments: [assignment.itemID: assignment],
            runningBundleIdentifiers: running
        )
    }

    private func descriptor(
        section: MenuBarSection,
        displayName: String = "Example"
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: itemID,
            section: section,
            order: 0,
            displayID: displayID,
            sourceOwnership: .application,
            displayName: displayName,
            bounds: MenuBarRect(x: 10, y: 0, width: 20, height: 20),
            isOnScreen: true
        )
    }
}
