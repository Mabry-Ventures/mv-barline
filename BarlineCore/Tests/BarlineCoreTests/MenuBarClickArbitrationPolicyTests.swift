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

    @Test("A fresh deferred gap click commits against the same positive window", arguments: [0.0, 0.125, 0.5])
    func freshDeferredGapClick(_ eventAge: Double) {
        #expect(canCommitDeferredGapClick(eventAge: eventAge))
    }

    @Test("Deferred gap clicks reject expired, negative, and nonfinite ages", arguments: [
        -Double.leastNonzeroMagnitude,
        -1.0,
        Double(0.5).nextUp,
        Double.infinity,
        -Double.infinity,
        Double.nan,
    ])
    func invalidDeferredClickAge(_ eventAge: Double) {
        #expect(canCommitDeferredGapClick(eventAge: eventAge) == false)
    }

    @Test("A replaced or absent hit window cannot commit a deferred gap click")
    func deferredGapClickRequiresSamePositiveWindow() {
        for (mouseDownWindow, commitWindow) in [
            (41, 42), (0, 41), (41, 0), (0, 0), (-1, 41), (41, -1), (-1, -1),
        ] {
            #expect(canCommitDeferredGapClick(
                hitWindowAtMouseDown: mouseDownWindow,
                hitWindowAtCommit: commitWindow
            ) == false)
        }
    }

    @Test("A superseded click cannot commit a previously observed gap")
    func supersededDeferredGapClick() {
        #expect(canCommitDeferredGapClick(isCurrentInput: false) == false)
    }

    @Test("A presentation epoch change invalidates a deferred gap click")
    func changedPresentationInvalidatesDeferredGapClick() {
        #expect(canCommitDeferredGapClick(isCurrentPresentation: false) == false)
    }

    @Test("Disabling monitoring or the feature invalidates a deferred gap click")
    func disabledDeferredGapClick() {
        #expect(canCommitDeferredGapClick(monitoringEnabled: false) == false)
        #expect(canCommitDeferredGapClick(featureEnabled: false) == false)
    }

    @Test("An active native interface prevents a deferred gap click from committing")
    func nativeInterfaceOwnsDeferredGapClick() {
        #expect(canCommitDeferredGapClick(nativeInterfaceActive: true) == false)
    }

    private func canCommitDeferredGapClick(
        eventAge: Double = 0.125,
        isCurrentInput: Bool = true,
        isCurrentPresentation: Bool = true,
        monitoringEnabled: Bool = true,
        featureEnabled: Bool = true,
        nativeInterfaceActive: Bool = false,
        hitWindowAtMouseDown: Int = 41,
        hitWindowAtCommit: Int = 41
    ) -> Bool {
        MenuBarClickArbitrationPolicy.canCommitDeferredEmptySpaceClick(
            eventAge: eventAge,
            isCurrentInput: isCurrentInput,
            isCurrentPresentation: isCurrentPresentation,
            monitoringEnabled: monitoringEnabled,
            featureEnabled: featureEnabled,
            nativeInterfaceActive: nativeInterfaceActive,
            hitWindowAtMouseDown: hitWindowAtMouseDown,
            hitWindowAtCommit: hitWindowAtCommit
        )
    }
}
