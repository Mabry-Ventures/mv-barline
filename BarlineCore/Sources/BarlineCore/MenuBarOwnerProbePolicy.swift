//
//  MenuBarOwnerProbePolicy.swift
//  Barline
//

import Foundation

/// Decides which running processes a macOS 27 menu bar inventory must ask
/// for status items.
///
/// Asking a process for its extras menu bar costs roughly ten milliseconds,
/// and a process that cannot answer holds the request for the full messaging
/// timeout. A working Mac runs well over a hundred processes while only a
/// dozen own menu bar items, so a scan of everything spends almost all of its
/// time on processes that have nothing to report — about two seconds on one
/// measured Mac, repeated for every inventory a single layout change takes.
///
/// Between full scans only known owners and recently launched processes are
/// asked. Applications usually create their status item a moment after they
/// launch, so a new process is asked on every pass for `launchGracePeriod`
/// rather than once; asking only once would file it as having no items and
/// miss them until the next full scan. A process that adds its first item
/// later still is found by the next full scan.
public struct MenuBarOwnerProbePolicy: Sendable {
    public let fullScanInterval: TimeInterval
    public let launchGracePeriod: TimeInterval
    public private(set) var knownOwners: Set<Int32> = []
    public private(set) var firstSeen: [Int32: Date] = [:]
    public private(set) var lastFullScan: Date?
    /// Processes already running at Barline's first inventory have long since
    /// created their items; only ones that appear afterwards get a grace period.
    public private(set) var hasCompletedInitialScan = false

    public var scannedProcesses: Set<Int32> {
        Set(firstSeen.keys)
    }

    public init(fullScanInterval: TimeInterval = 15, launchGracePeriod: TimeInterval = 30) {
        self.fullScanInterval = fullScanInterval
        self.launchGracePeriod = launchGracePeriod
    }

    /// Returns the processes to ask, and whether this pass is a full scan.
    public func processesToProbe(
        running: [Int32],
        now: Date
    ) -> (processes: [Int32], isFullScan: Bool) {
        guard let lastFullScan,
              now.timeIntervalSince(lastFullScan) < fullScanInterval
        else {
            return (running, true)
        }
        let selected = running.filter { process in
            if knownOwners.contains(process) {
                return true
            }
            guard let seen = firstSeen[process] else {
                return true
            }
            return now.timeIntervalSince(seen) < launchGracePeriod
        }
        return (selected, false)
    }

    /// Records which of the probed processes answered with menu bar items.
    /// Processes that were not probed keep their previous classification.
    public mutating func record(
        probed: [Int32],
        owners: Set<Int32>,
        running: [Int32],
        isFullScan: Bool,
        now: Date
    ) {
        let runningSet = Set(running)
        let probedSet = Set(probed)
        knownOwners = knownOwners
            .subtracting(probedSet)
            .union(owners)
            .intersection(runningSet)
        for process in probedSet where firstSeen[process] == nil {
            firstSeen[process] = hasCompletedInitialScan ? now : .distantPast
        }
        firstSeen = firstSeen.filter { runningSet.contains($0.key) }
        if isFullScan {
            lastFullScan = now
            hasCompletedInitialScan = true
        }
    }

    /// Forces the next inventory to ask every process.
    public mutating func invalidate() {
        lastFullScan = nil
    }
}
