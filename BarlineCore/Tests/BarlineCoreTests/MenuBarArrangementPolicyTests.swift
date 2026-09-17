@testable import BarlineCore
import Foundation
import Testing

@Suite("Menu bar arrangement policy")
struct MenuBarArrangementPolicyTests {
    @Test("macOS 27 preserves native order while applying shelf and visibility")
    func goldenGatePlanSeparatesStateOwners() throws {
        let first = item(bundle: "com.example.first", title: "First", order: 0)
        let second = item(bundle: "com.example.second", title: "Second", order: 1)
        let snapshot = snapshot(items: [first, second])
        let plan = try MenuBarArrangementPolicy().plan(
            layout: ProfileLayout(visible: [first.id], hidden: [second.id]),
            snapshot: snapshot,
            capabilities: MenuBarArrangementCapabilities(
                canReorderNativeItems: true,
                visibilityAssignmentGranularity: .applicationGroupAndKnownSystemItem,
                canReorderShelfItems: true,
                canApplySavedNativeOrder: false
            ),
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(plan.nativeOrder == .preserveCurrentOrder)
        #expect(plan.shelfOrder == .applySavedOrder)
        #expect(plan.concealment?.concealedItemIDs == [second.id])
    }

    @Test("mixed assignment in a multi-item app fails closed")
    func mixedApplicationAssignmentIsRejected() {
        let first = item(bundle: "com.example.multi", title: "First", order: 0)
        let second = item(bundle: "com.example.multi", title: "Second", order: 1)

        #expect(throws: MenuBarArrangementPolicyError.unsupportedVisibilityAssignment) {
            _ = try MenuBarArrangementPolicy().plan(
                layout: ProfileLayout(visible: [first.id], hidden: [second.id]),
                snapshot: snapshot(items: [first, second]),
                capabilities: goldenGateCapabilities,
                barlineBundleIdentifier: "com.mabryventures.Barline"
            )
        }
    }

    @Test("whole multi-item applications are admitted")
    func completeApplicationGroupIsAdmitted() throws {
        let first = item(bundle: "com.example.multi", title: "First", order: 0)
        let second = item(bundle: "com.example.multi", title: "Second", order: 1)
        let plan = try MenuBarArrangementPolicy().plan(
            layout: ProfileLayout(hidden: [first.id, second.id]),
            snapshot: snapshot(items: [first, second]),
            capabilities: goldenGateCapabilities,
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(Set(plan.concealment?.concealedItemIDs ?? []) == Set([first.id, second.id]))
    }

    @Test("Unavailable visibility accepts an already-matching partial layout")
    func unavailableVisibilityIgnoresUnchangedAndOmittedItems() throws {
        let visible = item(bundle: "com.example.visible", title: "Visible", order: 0)
        let hidden = item(
            bundle: "com.example.hidden",
            title: "Hidden",
            order: 1,
            section: .hidden
        )
        let omitted = item(bundle: "com.example.omitted", title: "Omitted", order: 2)

        let plan = try MenuBarArrangementPolicy().plan(
            layout: ProfileLayout(visible: [visible.id], hidden: [hidden.id]),
            snapshot: snapshot(items: [visible, hidden, omitted]),
            capabilities: MenuBarArrangementCapabilities(
                canReorderNativeItems: true,
                visibilityAssignmentGranularity: .unavailable,
                canReorderShelfItems: true,
                canApplySavedNativeOrder: false
            ),
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(plan.concealment == nil)
    }

    private var goldenGateCapabilities: MenuBarArrangementCapabilities {
        MenuBarArrangementCapabilities(
            canReorderNativeItems: true,
            visibilityAssignmentGranularity: .applicationGroupAndKnownSystemItem,
            canReorderShelfItems: true,
            canApplySavedNativeOrder: false
        )
    }

    private func item(
        bundle: String,
        title: String,
        order: Int,
        section: MenuBarSection = .visible
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: MenuBarItemID(bundleIdentifier: bundle, title: title),
            section: section,
            order: order,
            displayName: title,
            isOnScreen: true
        )
    }

    private func snapshot(items: [MenuBarItemDescriptor]) -> MenuBarSnapshot {
        MenuBarSnapshot(
            generation: 1,
            capturedAt: Date(),
            items: items,
            displayIDs: [],
            activeSpaceIsValid: true
        )
    }
}
