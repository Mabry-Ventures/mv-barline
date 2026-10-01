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

    @Test("new visible members do not invalidate an unchanged visible application group")
    func omittedVisibleGroupMembersRemainVisible() throws {
        let saved = item(bundle: "com.example.multi", title: "Saved", order: 0)
        let newlyObserved = item(bundle: "com.example.multi", title: "New", order: 1)
        let hidden = item(bundle: "com.example.hidden", title: "Hidden", order: 2)
        let plan = try MenuBarArrangementPolicy().plan(
            layout: ProfileLayout(visible: [saved.id], hidden: [hidden.id]),
            snapshot: snapshot(items: [saved, newlyObserved, hidden]),
            capabilities: goldenGateCapabilities,
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        #expect(plan.concealment?.visibleItemIDs == [saved.id, newlyObserved.id])
        #expect(plan.concealment?.concealedItemIDs == [hidden.id])
    }

    @Test("omitted items retain their current visibility in the complete native assertion")
    func omittedHiddenGroupMembersRemainHidden() throws {
        let saved = item(bundle: "com.example.multi", title: "Saved", order: 0, section: .hidden)
        let omitted = item(bundle: "com.example.multi", title: "Omitted", order: 1, section: .hidden)
        let newVisible = item(bundle: "com.example.new", title: "New", order: 2)
        let plan = try MenuBarArrangementPolicy().plan(
            layout: ProfileLayout(hidden: [saved.id]),
            snapshot: snapshot(items: [saved, omitted, newVisible]),
            capabilities: goldenGateCapabilities,
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        #expect(plan.concealment?.visibleItemIDs == [newVisible.id])
        #expect(plan.concealment?.concealedItemIDs == [saved.id, omitted.id])
    }

    @Test("an omitted visible member still blocks concealing part of an application")
    func omittedVisibleMemberPreventsPartialConcealment() {
        let saved = item(bundle: "com.example.multi", title: "Saved", order: 0)
        let newlyObserved = item(bundle: "com.example.multi", title: "New", order: 1)
        #expect(throws: MenuBarArrangementPolicyError.unsupportedVisibilityAssignment) {
            _ = try MenuBarArrangementPolicy().plan(
                layout: ProfileLayout(hidden: [saved.id]),
                snapshot: snapshot(items: [saved, newlyObserved]),
                capabilities: goldenGateCapabilities,
                barlineBundleIdentifier: "com.mabryventures.Barline"
            )
        }
    }

    @Test("an omitted invalid mixed application is rejected rather than silently normalized")
    func omittedMixedApplicationFailsClosed() {
        let visible = item(bundle: "com.example.multi", title: "Visible", order: 0)
        let hidden = item(bundle: "com.example.multi", title: "Hidden", order: 1, section: .hidden)
        let target = item(bundle: "com.example.target", title: "Target", order: 2)
        #expect(throws: MenuBarArrangementPolicyError.unsupportedVisibilityAssignment) {
            _ = try MenuBarArrangementPolicy().plan(
                layout: ProfileLayout(hidden: [target.id]),
                snapshot: snapshot(items: [visible, hidden, target]),
                capabilities: goldenGateCapabilities,
                barlineBundleIdentifier: "com.mabryventures.Barline"
            )
        }
    }

    @Test("overlapping explicit visibility assignments remain rejected")
    func overlappingAssignmentsFailClosed() {
        let target = item(bundle: "com.example.target", title: "Target", order: 0)
        #expect(throws: MenuBarArrangementPolicyError.unsupportedVisibilityAssignment) {
            _ = try MenuBarArrangementPolicy().plan(
                layout: ProfileLayout(visible: [target.id], hidden: [target.id]),
                snapshot: snapshot(items: [target]),
                capabilities: goldenGateCapabilities,
                barlineBundleIdentifier: "com.mabryventures.Barline"
            )
        }
    }

    @Test("Barline controls are excluded from Golden Gate concealment validation")
    func barlineControlsAreExcludedFromConcealment() throws {
        let visibleItem = item(bundle: "com.example.visible", title: "Visible", order: 0)
        let control = item(
            bundle: "com.mabryventures.Barline",
            title: "Barline.ControlItem.Hidden",
            order: 1,
            isBarlineControlItem: true
        )

        let plan = try MenuBarArrangementPolicy().plan(
            layout: ProfileLayout(visible: [visibleItem.id]),
            snapshot: snapshot(items: [visibleItem, control]),
            capabilities: goldenGateCapabilities,
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(plan.concealment?.visibleItemIDs == [visibleItem.id])
        #expect(plan.concealment?.concealedItemIDs.isEmpty == true)
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
        section: MenuBarSection = .visible,
        isBarlineControlItem: Bool = false
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: MenuBarItemID(bundleIdentifier: bundle, title: title),
            section: section,
            order: order,
            isBarlineControlItem: isBarlineControlItem,
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
