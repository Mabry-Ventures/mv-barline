@testable import BarlineCore
import Foundation
import Testing

@Suite("Menu bar owner probing")
struct MenuBarOwnerProbePolicyTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("The first inventory asks every process")
    func firstPassIsFull() {
        let policy = MenuBarOwnerProbePolicy()
        let plan = policy.processesToProbe(running: [1, 2, 3], now: start)

        #expect(plan.isFullScan)
        #expect(plan.processes == [1, 2, 3])
    }

    @Test("Between full scans only known owners are asked")
    func laterPassesAskOwners() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 15)
        policy.record(probed: [1, 2, 3], owners: [2], running: [1, 2, 3], isFullScan: true, now: start)

        let plan = policy.processesToProbe(running: [1, 2, 3], now: start.addingTimeInterval(5))

        #expect(!plan.isFullScan)
        #expect(plan.processes == [2])
    }

    @Test("A newly launched process is asked immediately")
    func newProcessesAreAsked() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 15)
        policy.record(probed: [1, 2], owners: [2], running: [1, 2], isFullScan: true, now: start)

        let plan = policy.processesToProbe(running: [1, 2, 9], now: start.addingTimeInterval(5))

        #expect(plan.processes == [2, 9])
    }

    @Test("A process that has no item yet keeps being asked through its launch grace period")
    func lateStatusItemIsFoundDuringGrace() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 15, launchGracePeriod: 30)
        policy.record(probed: [1, 2], owners: [2], running: [1, 2], isFullScan: true, now: start)
        // Process 9 launches; its first probe happens before it creates its item.
        policy.record(probed: [2, 9], owners: [2], running: [1, 2, 9], isFullScan: false, now: start.addingTimeInterval(1))

        let plan = policy.processesToProbe(running: [1, 2, 9], now: start.addingTimeInterval(4))

        #expect(plan.processes.contains(9))
        #expect(!plan.processes.contains(1))
    }

    @Test("Once the grace period ends, a process without items waits for the next full scan")
    func graceExpires() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 1_000, launchGracePeriod: 30)
        policy.record(probed: [1], owners: [], running: [1], isFullScan: true, now: start)
        policy.record(probed: [9], owners: [], running: [1, 9], isFullScan: false, now: start.addingTimeInterval(1))

        let plan = policy.processesToProbe(running: [1, 9], now: start.addingTimeInterval(40))

        #expect(plan.processes.isEmpty)
    }

    @Test("Processes already running at the first inventory get no grace period")
    func initialProcessesAreNotInGrace() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 15, launchGracePeriod: 30)
        policy.record(probed: [1, 2, 3], owners: [2], running: [1, 2, 3], isFullScan: true, now: start)

        let plan = policy.processesToProbe(running: [1, 2, 3], now: start.addingTimeInterval(1))

        #expect(plan.processes == [2])
    }

    @Test("The full scan interval brings every process back")
    func intervalForcesFullScan() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 15)
        policy.record(probed: [1, 2], owners: [2], running: [1, 2], isFullScan: true, now: start)

        let plan = policy.processesToProbe(running: [1, 2], now: start.addingTimeInterval(15))

        #expect(plan.isFullScan)
        #expect(plan.processes == [1, 2])
    }

    @Test("An owner that stops answering is dropped, unprobed processes keep their class")
    func ownersAreReclassifiedOnlyWhenProbed() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 15)
        policy.record(probed: [1, 2, 3], owners: [2, 3], running: [1, 2, 3], isFullScan: true, now: start)
        policy.record(probed: [2], owners: [], running: [1, 2, 3], isFullScan: false, now: start.addingTimeInterval(2))

        #expect(policy.knownOwners == [3])
    }

    @Test("Terminated processes are forgotten")
    func terminatedProcessesAreForgotten() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 15)
        policy.record(probed: [1, 2], owners: [1, 2], running: [1, 2], isFullScan: true, now: start)
        policy.record(probed: [1], owners: [1], running: [1], isFullScan: false, now: start.addingTimeInterval(1))

        #expect(policy.knownOwners == [1])
        #expect(policy.scannedProcesses == [1])
    }

    @Test("Invalidation forces the next pass to be full")
    func invalidationForcesFullScan() {
        var policy = MenuBarOwnerProbePolicy(fullScanInterval: 15)
        policy.record(probed: [1, 2], owners: [2], running: [1, 2], isFullScan: true, now: start)
        policy.invalidate()

        #expect(policy.processesToProbe(running: [1, 2], now: start.addingTimeInterval(1)).isFullScan)
    }
}
