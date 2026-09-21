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
