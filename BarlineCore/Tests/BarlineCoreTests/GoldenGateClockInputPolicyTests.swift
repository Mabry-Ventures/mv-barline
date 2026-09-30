@testable import BarlineCore
import Foundation
import Testing

@Suite("Golden Gate clock input policy")
struct GoldenGateClockInputPolicyTests {
    @Test("A delayed callback keeps the deadline of the original Quartz event")
    func delayedDeliveryDoesNotExtendClickBudget() {
        let event: UInt64 = 1_000_000_000
        let callback = event + 500_000_000
        let deadline = GoldenGateClockInputPolicy.deadline(eventUptimeNanoseconds: event)

        #expect(GoldenGateClockInputPolicy.clickBudgetNanoseconds == 600_000_000)
        #expect(deadline == event + 600_000_000)
        #expect(deadline - callback == 100_000_000)
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: callback,
            latestDownAgeNanoseconds: callback - event
        ))
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: deadline,
            latestDownAgeNanoseconds: deadline - event
        ) == false)
    }

    @Test("The original event expires exactly at its deadline", arguments: [
        UInt64(599_999_999), UInt64(600_000_000), UInt64(600_000_001),
    ])
    func expiryBoundary(_ elapsed: UInt64) {
        let event: UInt64 = 1_000_000_000
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: event + elapsed,
            latestDownAgeNanoseconds: elapsed
        ) == (elapsed < 600_000_000))
    }

    @Test("An event in the future is rejected even with the largest latest-down age")
    func futureEventIsRejected() {
        let event: UInt64 = 1_000_000_000
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: event - 1,
            latestDownAgeNanoseconds: UInt64.max
        ) == false)
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: event,
            latestDownAgeNanoseconds: 0
        ))
    }

    @Test("Deadline addition saturates rather than wrapping", arguments: [
        UInt64.max - 600_000_000,
        UInt64.max - 599_999_999,
        UInt64.max,
    ])
    func deadlineOverflow(_ event: UInt64) {
        #expect(GoldenGateClockInputPolicy.deadline(eventUptimeNanoseconds: event) == UInt64.max)
    }

    @Test("A saturated deadline keeps its strict expiry and future-event checks")
    func saturatedDeadlineAdmission() {
        let event = UInt64.max - 10
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: UInt64.max - 1,
            latestDownAgeNanoseconds: 9
        ))
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: UInt64.max,
            latestDownAgeNanoseconds: 10
        ) == false)
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: UInt64.max,
            now: UInt64.max - 1,
            latestDownAgeNanoseconds: UInt64.max
        ) == false)
    }

    @Test("Latest-down age rejects a newer click that arrived before the counters were sampled")
    func supersededBeforeCounterSample() {
        let event: UInt64 = 1_000_000_000
        let counterSample = event + 100_000_000
        let newerClick = counterSample - 20_000_000

        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: counterSample,
            latestDownAgeNanoseconds: counterSample - newerClick
        ) == false)
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: counterSample,
            latestDownAgeNanoseconds: counterSample - event
        ))
    }

    /// These fixtures model bracketed uptime-before-age reads. They verify the
    /// pure policy's response to supplied values, not real Quartz read ordering.
    @Test("A bounded uptime-before-age sample tolerates a delayed age read for the original click", arguments: [
        UInt64(0), UInt64(1_000_000), UInt64(2_000_000),
    ])
    func orderedSamplingToleratesDelayedAgeRead(_ readDelay: UInt64) {
        let event: UInt64 = 1_000_000_000
        let uptimeSample = event + 100_000_000
        let ageSample = uptimeSample + readDelay

        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            sampleStartedAt: uptimeSample,
            sampleCompletedAt: ageSample,
            latestDownAgeNanoseconds: ageSample - event
        ))
    }

    @Test("A delayed ordered age read rejects supersession before or between the reads", arguments: [
        UInt64(80_000_000), UInt64(100_500_000),
    ])
    func orderedSamplingRejectsSupersededInput(_ newerClickOffset: UInt64) {
        let event: UInt64 = 1_000_000_000
        let uptimeSample = event + 100_000_000
        let ageSample = uptimeSample + 1_000_000
        let newerClick = event + newerClickOffset

        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            sampleStartedAt: uptimeSample,
            sampleCompletedAt: ageSample,
            latestDownAgeNanoseconds: ageSample - newerClick
        ) == false)
    }

    @Test("A 150ms read stall is rejected even when its age would mask a newer click")
    func lateAgeReadCannotMaskSupersession() {
        let event: UInt64 = 1_000_000_000
        let uptimeSample = event + 100_000_000
        let newerClick = event + 90_000_000
        let ageSample = uptimeSample + 150_000_000
        let latestDownAge = ageSample - newerClick

        // Age arithmetic alone cannot identify the delayed sample. The
        // bracketed entry point must reject it before trusting that age.
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: uptimeSample,
            latestDownAgeNanoseconds: latestDownAge
        ))
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            sampleStartedAt: uptimeSample,
            sampleCompletedAt: ageSample,
            latestDownAgeNanoseconds: latestDownAge
        ) == false)
    }

    @Test("The sampling interval accepts exactly two milliseconds and rejects any excess", arguments: [
        UInt64(0), UInt64(1), UInt64(1_999_999), UInt64(2_000_000), UInt64(2_000_001),
    ])
    func samplingIntervalBoundary(_ interval: UInt64) {
        let event: UInt64 = 1_000_000_000
        let sampleStarted = event + 100_000_000
        let sampleCompleted = sampleStarted + interval

        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            sampleStartedAt: sampleStarted,
            sampleCompletedAt: sampleCompleted,
            latestDownAgeNanoseconds: sampleCompleted - event
        ) == (interval <= 2_000_000))
    }

    @Test("A sample whose completion precedes its start is rejected without subtraction underflow")
    func reversedSamplingInterval() {
        let event: UInt64 = 1_000_000_000
        let sampleStarted = event + 100_000_000

        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            sampleStartedAt: sampleStarted,
            sampleCompletedAt: sampleStarted - 1,
            latestDownAgeNanoseconds: UInt64.max
        ) == false)
    }

    @Test("A bounded sample must finish before the original deadline", arguments: [
        UInt64(599_999_999), UInt64(600_000_000), UInt64(600_000_001),
    ])
    func samplingCannotCrossOriginalDeadline(_ completionOffset: UInt64) {
        let event: UInt64 = 1_000_000_000
        let deadline = GoldenGateClockInputPolicy.deadline(eventUptimeNanoseconds: event)
        let sampleStarted = deadline - 1_000_000
        let sampleCompleted = event + completionOffset

        #expect(sampleCompleted - sampleStarted <= 2_000_000)
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            sampleStartedAt: sampleStarted,
            sampleCompletedAt: sampleCompleted,
            latestDownAgeNanoseconds: sampleCompleted - event
        ) == (sampleCompleted < deadline))
    }

    @Test("Delayed ordered reads retain the original deadline for the later press")
    func orderedSamplingCannotResetOriginalDeadline() {
        let event: UInt64 = 1_000_000_000
        let uptimeSample = event + 550_000_000
        let ageSample = uptimeSample + 1_000_000
        let deadline = GoldenGateClockInputPolicy.deadline(eventUptimeNanoseconds: event)

        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            sampleStartedAt: uptimeSample,
            sampleCompletedAt: ageSample,
            latestDownAgeNanoseconds: ageSample - event
        ))
        #expect(deadline == event + 600_000_000)

        let pressUptime = ageSample + GoldenGateTiming.clockLiftSettleNanoseconds
        #expect(pressUptime > deadline)
        #expect(GoldenGateTiming.admitsClockPress(
            now: pressUptime,
            deadline: deadline,
            beforeLift: false
        ) == false)
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: pressUptime,
            latestDownAgeNanoseconds: pressUptime - event
        ) == false)
    }

    @Test("The documented two-millisecond age-read tolerance has an inclusive lower bound")
    func ageReadToleranceBoundary() {
        let event: UInt64 = 1_000_000_000
        let now = event + 100_000_000

        #expect(GoldenGateClockInputPolicy.ageReadToleranceNanoseconds == 2_000_000)
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: now,
            latestDownAgeNanoseconds: 98_000_000
        ))
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: now,
            latestDownAgeNanoseconds: 97_999_999
        ) == false)
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: now,
            latestDownAgeNanoseconds: 100_000_001
        ))
    }

    @Test("The tolerance clamps young event ages at zero without underflow", arguments: [
        UInt64(0), UInt64(1), UInt64(1_999_999), UInt64(2_000_000), UInt64(2_000_001),
    ])
    func youngEventTolerance(_ elapsed: UInt64) {
        let event: UInt64 = 1_000_000_000
        #expect(GoldenGateClockInputPolicy.isCurrent(
            eventUptimeNanoseconds: event,
            now: event + elapsed,
            latestDownAgeNanoseconds: 0
        ) == (elapsed <= 2_000_000))
    }

    @Test("The foreground restore budget fits inside the helper cancellation grace")
    func restoreBudgetLeavesCancellationGrace() {
        #expect(GoldenGateTiming.clockRestoreBudget > .zero)
        #expect(GoldenGateTiming.clockRestoreBudget < .milliseconds(500))
    }
}
