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

    @Test("Retained items preserve native slots before between and after live items")
    func preservesRetainedNativeSlots() {
        let first = id("first")
        let liveA = id("live-a")
        let middle = id("middle")
        let liveB = id("live-b")
        let last = id("last")
        let prior = [first, liveA, middle, liveB, last].enumerated().map { index, id in
            descriptor(id: id, section: id == liveA || id == liveB ? .visible : .hidden, order: index)
        }
        let assignments = Dictionary(uniqueKeysWithValues: prior.map { descriptor in
            (descriptor.id, GoldenGateLogicalAssignment(
                itemID: descriptor.id,
                section: descriptor.section,
                rank: 0
            ))
        })
        let result = GoldenGateRetainedInventoryPolicy.merging(
            live: snapshot([
                descriptor(id: liveA, section: .visible, order: 0),
                descriptor(id: liveB, section: .visible, order: 1),
            ]),
            retainedDescriptors: Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) }),
            assignments: assignments,
            runningBundleIdentifiers: Set(prior.map(\.id.bundleIdentifier)),
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(result.items.map(\.id) == [first, liveA, middle, liveB, last])
    }

    @Test("Current live order updates known slots without displacing retained items")
    func reconcilesLiveReorderAroundRetainedSlot() {
        let liveA = id("live-a")
        let retained = id("retained")
        let liveB = id("live-b")
        let prior = [
            descriptor(id: liveA, section: .visible, order: 0),
            descriptor(id: retained, section: .hidden, order: 1),
            descriptor(id: liveB, section: .visible, order: 2),
        ]
        let result = GoldenGateRetainedInventoryPolicy.merging(
            live: snapshot([
                descriptor(id: liveB, section: .visible, order: 0),
                descriptor(id: liveA, section: .visible, order: 1),
            ]),
            retainedDescriptors: Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) }),
            assignments: [retained: GoldenGateLogicalAssignment(
                itemID: retained,
                section: .hidden,
                rank: 0
            )],
            runningBundleIdentifiers: Set(prior.map(\.id.bundleIdentifier)),
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(result.items.map(\.id) == [liveB, retained, liveA])
    }

    @Test("Merge preserves physical sections and defers movability to the provider")
    func recomputesBundleEligibilityAfterMerge() {
        let retained = MenuBarItemID(bundleIdentifier: "com.example.multi", title: "First")
        let live = MenuBarItemID(bundleIdentifier: "com.example.multi", title: "Second")
        let retainedDescriptor = descriptor(id: retained, section: .hidden, order: 0)
        let result = GoldenGateRetainedInventoryPolicy.merging(
            live: snapshot([descriptor(id: live, section: .visible, order: 1)]),
            retainedDescriptors: [retained: retainedDescriptor],
            assignments: [retained: GoldenGateLogicalAssignment(
                itemID: retained,
                section: .hidden,
                rank: 0
            )],
            runningBundleIdentifiers: ["com.example.multi"],
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(result.items.map(\.section) == [.hidden, .visible])
        #expect(result.items.allSatisfy { !$0.isMovable })
    }

    @Test("An AX-absent retained item cannot be restored until its position key is rediscovered")
    func disappearanceFailsClosedUntilRediscovered() throws {
        let hidden = id("hidden")
        let visible = id("visible")
        let prior = [
            descriptor(id: hidden, section: .hidden, order: 0),
            descriptor(id: visible, section: .visible, order: 1),
        ]
        let refreshed = GoldenGateRetainedInventoryPolicy.merging(
            live: snapshot([descriptor(id: visible, section: .visible, order: 0)]),
            retainedDescriptors: Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) }),
            assignments: [hidden: GoldenGateLogicalAssignment(
                itemID: hidden,
                section: .hidden,
                rank: 0
            )],
            runningBundleIdentifiers: [hidden.bundleIdentifier, visible.bundleIdentifier],
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        let target = snapshot([
            descriptor(id: hidden, section: .visible, order: 0),
            descriptor(id: visible, section: .visible, order: 1),
        ])

        #expect(throws: MenuBarBackendError.self) {
            try GoldenGateLogicalLayoutPlanner().restoring(target, to: refreshed)
        }
    }

    @Test("Retained items preserve slots around live Barline control anchors")
    func preservesControlAnchors() {
        let leading = id("leading")
        let hiddenControl = MenuBarItemID(
            bundleIdentifier: "com.mabryventures.Barline",
            accessibilityIdentifier: "hidden-control"
        )
        let middle = id("middle")
        let visibleControl = MenuBarItemID(
            bundleIdentifier: "com.mabryventures.Barline",
            accessibilityIdentifier: "visible-control"
        )
        let trailing = id("trailing")
        let prior = [
            descriptor(id: leading, section: .hidden, order: 0),
            descriptor(id: hiddenControl, section: .hidden, order: 1, isControl: true),
            descriptor(id: middle, section: .hidden, order: 2),
            descriptor(id: visibleControl, section: .visible, order: 3, isControl: true),
            descriptor(id: trailing, section: .visible, order: 4),
        ]
        let assignments = [leading, middle].enumerated().reduce(into: [MenuBarItemID: GoldenGateLogicalAssignment]()) {
            $0[$1.element] = GoldenGateLogicalAssignment(
                itemID: $1.element,
                section: .hidden,
                rank: $1.offset
            )
        }
        let live = snapshot([
            descriptor(id: hiddenControl, section: .hidden, order: 0, isControl: true),
            descriptor(id: visibleControl, section: .visible, order: 1, isControl: true),
            descriptor(id: trailing, section: .visible, order: 2),
        ])

        let first = GoldenGateRetainedInventoryPolicy.merging(
            live: live,
            retainedDescriptors: Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) }),
            assignments: assignments,
            runningBundleIdentifiers: Set(prior.map(\.id.bundleIdentifier)),
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        let second = GoldenGateRetainedInventoryPolicy.merging(
            live: live,
            retainedDescriptors: Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) }),
            assignments: assignments,
            runningBundleIdentifiers: Set(prior.map(\.id.bundleIdentifier)),
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(first.items.map(\.id) == [leading, hiddenControl, middle, visibleControl, trailing])
        #expect(second.items.map(\.id) == first.items.map(\.id))
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
            runningBundleIdentifiers: running,
            barlineBundleIdentifier: "com.mabryventures.Barline"
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

    private func snapshot(_ items: [MenuBarItemDescriptor]) -> MenuBarSnapshot {
        MenuBarSnapshot(
            generation: 1,
            capturedAt: Date(timeIntervalSince1970: 0),
            items: items,
            displayIDs: [displayID],
            activeSpaceIsValid: true
        )
    }

    private func descriptor(
        id: MenuBarItemID,
        section: MenuBarSection,
        order: Int,
        isControl: Bool = false
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: id,
            section: section,
            order: order,
            displayID: displayID,
            sourceOwnership: .application,
            isBarlineControlItem: isControl,
            displayName: id.title ?? "Example",
            bounds: MenuBarRect(x: Double(order * 20), y: 0, width: 20, height: 20),
            isOnScreen: true
        )
    }

    private func id(_ suffix: String) -> MenuBarItemID {
        MenuBarItemID(bundleIdentifier: "com.example.\(suffix)", title: suffix)
    }
}
