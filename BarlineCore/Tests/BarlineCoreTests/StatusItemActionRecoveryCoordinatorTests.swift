@testable import BarlineCore
import Testing

@Suite("Status item action recovery")
struct StatusItemActionRecoveryCoordinatorTests {
    @Test("shelf events are never eligible for control-action recovery")
    func shelfEventIsExcluded() {
        #expect(!StatusItemActionRecoveryCoordinator.shouldSchedulePrimaryRecovery(
            eventTargetsShelf: true,
            eventLocationIsInsideExactButtonFrame: true
        ))
    }

    @Test("only the exact control button is eligible for recovery")
    func exactButtonFrameIsRequired() {
        #expect(StatusItemActionRecoveryCoordinator.shouldSchedulePrimaryRecovery(
            eventTargetsShelf: false,
            eventLocationIsInsideExactButtonFrame: true
        ))
        #expect(!StatusItemActionRecoveryCoordinator.shouldSchedulePrimaryRecovery(
            eventTargetsShelf: false,
            eventLocationIsInsideExactButtonFrame: false
        ))
    }

    @Test("an overlapping menu cannot be mistaken for the status control")
    func overlappingMenuIsExcluded() {
        #expect(!StatusItemActionRecoveryCoordinator.shouldSchedulePrimaryRecovery(
            eventTargetsShelf: false,
            eventLocationIsInsideExactButtonFrame: true,
            eventTargetsAccessibleControl: false
        ))
        #expect(StatusItemActionRecoveryCoordinator.shouldSchedulePrimaryRecovery(
            eventTargetsShelf: false,
            eventLocationIsInsideExactButtonFrame: true,
            eventTargetsAccessibleControl: true
        ))
    }

    @Test("scene-sized and invalid frames are rejected")
    func onlyStatusItemSizedFramesArePlausible() {
        #expect(StatusItemActionRecoveryCoordinator.isPlausibleExactButtonFrame(
            width: 24,
            height: 24
        ))
        #expect(!StatusItemActionRecoveryCoordinator.isPlausibleExactButtonFrame(
            width: 1920,
            height: 24
        ))
        #expect(!StatusItemActionRecoveryCoordinator.isPlausibleExactButtonFrame(
            width: 24,
            height: .nan
        ))
    }

    @Test("native action cancels the pending fallback")
    func nativeActionWins() {
        var coordinator = StatusItemActionRecoveryCoordinator()
        let scheduled = coordinator.observeMouseDown(sequence: 1, eventTimestamp: 10)
        let nativeClaimed = coordinator.claimNativeAction(eventTimestamp: 10.04)
        let fallbackClaimed = coordinator.claimFallback(sequence: 1)
        #expect(scheduled)
        #expect(nativeClaimed)
        #expect(!fallbackClaimed)
    }

    @Test("fallback handles a missing native action once")
    func fallbackWins() {
        var coordinator = StatusItemActionRecoveryCoordinator()
        let scheduled = coordinator.observeMouseDown(sequence: 1, eventTimestamp: 10)
        let fallbackClaimed = coordinator.claimFallback(sequence: 1)
        let fallbackClaimedAgain = coordinator.claimFallback(sequence: 1)
        let lateNativeClaimed = coordinator.claimNativeAction(eventTimestamp: 10.08)
        #expect(scheduled)
        #expect(fallbackClaimed)
        #expect(!fallbackClaimedAgain)
        #expect(!lateNativeClaimed)
    }

    @Test("native action observed before the global monitor suppresses fallback")
    func nativeActionArrivesFirst() {
        var coordinator = StatusItemActionRecoveryCoordinator()
        let nativeClaimed = coordinator.claimNativeAction(eventTimestamp: 10)
        let scheduled = coordinator.observeMouseDown(sequence: 1, eventTimestamp: 10)
        let fallbackClaimed = coordinator.claimFallback(sequence: 1)
        #expect(nativeClaimed)
        #expect(!scheduled)
        #expect(!fallbackClaimed)
    }

    @Test("a later physical click remains independent")
    func laterClickIsIndependent() {
        var coordinator = StatusItemActionRecoveryCoordinator()
        let firstScheduled = coordinator.observeMouseDown(sequence: 1, eventTimestamp: 10)
        let firstFallbackClaimed = coordinator.claimFallback(sequence: 1)
        let secondScheduled = coordinator.observeMouseDown(sequence: 2, eventTimestamp: 10.2)
        let secondNativeClaimed = coordinator.claimNativeAction(eventTimestamp: 10.25)
        let secondFallbackClaimed = coordinator.claimFallback(sequence: 2)
        #expect(firstScheduled)
        #expect(firstFallbackClaimed)
        #expect(secondScheduled)
        #expect(secondNativeClaimed)
        #expect(!secondFallbackClaimed)
    }

    @Test("stale fallback cannot claim a newer click")
    func staleFallbackCannotClaimNewerClick() {
        var coordinator = StatusItemActionRecoveryCoordinator()
        let firstScheduled = coordinator.observeMouseDown(sequence: 1, eventTimestamp: 10)
        let secondScheduled = coordinator.observeMouseDown(sequence: 2, eventTimestamp: 11)
        let staleFallbackClaimed = coordinator.claimFallback(sequence: 1)
        let currentFallbackClaimed = coordinator.claimFallback(sequence: 2)
        #expect(firstScheduled)
        #expect(secondScheduled)
        #expect(!staleFallbackClaimed)
        #expect(currentFallbackClaimed)
    }
}
