import Foundation

/// Clock input expiry starts at Quartz event creation, never at delayed main
/// actor delivery. A last-down age rejects counters sampled after a newer
/// click; counters then detect supersession after that sample.
public enum GoldenGateClockInputPolicy {
    public static let clickBudgetNanoseconds: UInt64 = 600_000_000
    /// Accounts for the interval between uptime and Quartz age reads.
    public static let ageReadToleranceNanoseconds: UInt64 = 2_000_000

    public static func deadline(eventUptimeNanoseconds: UInt64) -> UInt64 {
        let (value, overflow) = eventUptimeNanoseconds.addingReportingOverflow(clickBudgetNanoseconds)
        return overflow ? .max : value
    }

    public static func isCurrent(
        eventUptimeNanoseconds: UInt64,
        sampleStartedAt: UInt64,
        sampleCompletedAt: UInt64,
        latestDownAgeNanoseconds: UInt64
    ) -> Bool {
        // Read uptime before Quartz age, but reject preempted samples: an old
        // age paired with a later uptime drops valid clicks; a much later age
        // paired with an old uptime can instead disguise a superseding click.
        guard sampleCompletedAt >= sampleStartedAt,
              sampleCompletedAt - sampleStartedAt <= ageReadToleranceNanoseconds,
              sampleCompletedAt < deadline(eventUptimeNanoseconds: eventUptimeNanoseconds)
        else { return false }
        return isCurrent(
            eventUptimeNanoseconds: eventUptimeNanoseconds,
            now: sampleStartedAt,
            latestDownAgeNanoseconds: latestDownAgeNanoseconds
        )
    }

    public static func isCurrent(
        eventUptimeNanoseconds: UInt64,
        now: UInt64,
        latestDownAgeNanoseconds: UInt64
    ) -> Bool {
        guard now >= eventUptimeNanoseconds, now < deadline(eventUptimeNanoseconds: eventUptimeNanoseconds)
        else { return false }
        let age = now - eventUptimeNanoseconds
        let lowerBound = age > ageReadToleranceNanoseconds ? age - ageReadToleranceNanoseconds : 0
        return latestDownAgeNanoseconds >= lowerBound
    }
}
