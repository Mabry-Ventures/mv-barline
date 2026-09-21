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
/// Between full scans only known owners, and processes launched since the
/// last full scan, are asked. A process that adds its first item later
/// without relaunching is found by the next full scan.
public struct MenuBarOwnerProbePolicy: Sendable {
    public let fullScanInterval: TimeInterval
    public private(set) var knownOwners: Set<Int32> = []
    public private(set) var scannedProcesses: Set<Int32> = []
    public private(set) var lastFullScan: Date?

    public init(fullScanInterval: TimeInterval = 15) {
        self.fullScanInterval = fullScanInterval
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
        let selected = running.filter {
            knownOwners.contains($0) || !scannedProcesses.contains($0)
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
        scannedProcesses = scannedProcesses.union(probedSet).intersection(runningSet)
        if isFullScan {
            lastFullScan = now
        }
    }

    /// Forces the next inventory to ask every process.
    public mutating func invalidate() {
        lastFullScan = nil
    }
}
