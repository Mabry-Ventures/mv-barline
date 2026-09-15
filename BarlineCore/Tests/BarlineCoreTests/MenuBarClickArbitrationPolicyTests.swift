//
//  MenuBarClickArbitrationPolicyTests.swift
//  Barline
//

@testable import BarlineCore
import Testing

@Suite("Menu-bar click arbitration")
struct MenuBarClickArbitrationPolicyTests {
    @Test("Only layout separators leave empty-space clicks available")
    func separatorHitTesting() {
        #expect(MenuBarClickArbitrationPolicy.isLayoutSeparator(title: "Barline.ControlItem.Hidden"))
        #expect(MenuBarClickArbitrationPolicy.isLayoutSeparator(title: "Barline.ControlItem.AlwaysHidden"))
        for title in [nil, "Clock", "BentoBox", "Barline.ControlItem.Visible", "Other"] {
            #expect(!MenuBarClickArbitrationPolicy.isLayoutSeparator(title: title))
        }
    }

    @Test("An unavailable hit-test snapshot is not evidence of empty menu-bar space")
    func missingHitTestSnapshot() {
        #expect(!MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
            isInsideMenuBar: true,
            isInsideApplicationMenu: false,
            isInsidePrimaryControlItem: false,
            isInsideCachedMenuBarItem: false,
            isInsideNotch: false,
            hasHitTestSnapshot: false
        ))
    }

    @Test("A windowless hosted control click cannot schedule rehide with stale bar geometry")
    func windowlessPrimaryClickDoesNotRehide() {
        #expect(!MenuBarClickArbitrationPolicy.shouldScheduleSmartRehide(
            hasVisibleSection: true,
            eventTargetsPrimaryControlItem: false,
            isInsidePrimaryControlItem: true,
            isInsideShelf: false,
            isInsideMenuBar: false
        ))
    }

    @Test("Smart rehide accepts only genuine outside clicks", arguments: 0 ..< 5)
    func smartRehideOwnership(exclusion: Int) {
        #expect(!MenuBarClickArbitrationPolicy.shouldScheduleSmartRehide(
            hasVisibleSection: exclusion != 0,
            eventTargetsPrimaryControlItem: exclusion == 1,
            isInsidePrimaryControlItem: exclusion == 2,
            isInsideShelf: exclusion == 3,
            isInsideMenuBar: exclusion == 4
        ))
        #expect(MenuBarClickArbitrationPolicy.shouldScheduleSmartRehide(
            hasVisibleSection: true,
            eventTargetsPrimaryControlItem: false,
            isInsidePrimaryControlItem: false,
            isInsideShelf: false,
            isInsideMenuBar: false
        ))
    }

    @Test("Target-action ownership wins even if every geometry cache describes a gap")
    func primaryWindowOwnsClickDespiteStaleGeometry() {
        #expect(
            !MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
                isInsideMenuBar: true,
                isInsideApplicationMenu: false,
                isInsidePrimaryControlItem: false,
                isInsideCachedMenuBarItem: false,
                isInsideNotch: false,
                eventTargetsPrimaryControlItem: true
            )
        )
    }

    @Test("A shelf item owns its click even where the shelf overlaps the menu bar")
    func shelfOwnsOverlappingClick() {
        #expect(
            !MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
                isInsideMenuBar: true,
                isInsideApplicationMenu: false,
                isInsidePrimaryControlItem: false,
                eventTargetsShelf: true,
                isInsideCachedMenuBarItem: false,
                isInsideNotch: false
            )
        )
    }

    @Test("A cold cache cannot classify the primary control item as empty space")
    func primaryControlItemWinsOverColdCache() {
        #expect(
            !MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
                isInsideMenuBar: true,
                isInsideApplicationMenu: false,
                isInsidePrimaryControlItem: true,
                isInsideCachedMenuBarItem: false,
                isInsideNotch: false
            )
        )
    }

    @Test("A genuine menu-bar gap remains eligible for global click handling")
    func genuineEmptySpace() {
        #expect(
            MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
                isInsideMenuBar: true,
                isInsideApplicationMenu: false,
                isInsidePrimaryControlItem: false,
                isInsideCachedMenuBarItem: false,
                isInsideNotch: false
            )
        )
    }

    @Test("Known occupied menu-bar regions are never empty")
    func occupiedRegions() {
        #expect(
            !MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
                isInsideMenuBar: true,
                isInsideApplicationMenu: true,
                isInsidePrimaryControlItem: false,
                isInsideCachedMenuBarItem: false,
                isInsideNotch: false
            )
        )
        #expect(
            !MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
                isInsideMenuBar: true,
                isInsideApplicationMenu: false,
                isInsidePrimaryControlItem: false,
                isInsideCachedMenuBarItem: true,
                isInsideNotch: false
            )
        )
        #expect(
            !MenuBarClickArbitrationPolicy.isEmptyMenuBarSpace(
                isInsideMenuBar: true,
                isInsideApplicationMenu: false,
                isInsidePrimaryControlItem: false,
                isInsideCachedMenuBarItem: false,
                isInsideNotch: true
            )
        )
    }
}
