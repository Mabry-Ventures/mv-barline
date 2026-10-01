//
//  MenuBarAuthorityObservation.swift
//  BarlineCore
//

import Foundation

public enum MenuBarObservationFreshness: Sendable {
    case cachedAllowed
    case freshRequired
}

/// Scan provenance, not a platform-control exception or signature witness.
/// Only the live backend may supply it to the coordinator. Persisted snapshots
/// and callers' profile/checkpoint arguments never reconstruct this context.
public struct MenuBarObservationScan: Equatable, Sendable {
    public let scanID: UUID
    public let startedAtUptimeNanoseconds: UInt64
    public let completedAtUptimeNanoseconds: UInt64
    public let observedSnapshot: MenuBarSnapshot
    public let initialEnvironment: MenuBarEnvironmentSnapshot
    public let finalEnvironment: MenuBarEnvironmentSnapshot

    public init(
        scanID: UUID,
        startedAtUptimeNanoseconds: UInt64,
        completedAtUptimeNanoseconds: UInt64,
        observedSnapshot: MenuBarSnapshot,
        initialEnvironment: MenuBarEnvironmentSnapshot,
        finalEnvironment: MenuBarEnvironmentSnapshot
    ) {
        self.scanID = scanID
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        self.completedAtUptimeNanoseconds = completedAtUptimeNanoseconds
        self.observedSnapshot = observedSnapshot
        self.initialEnvironment = initialEnvironment
        self.finalEnvironment = finalEnvironment
    }

    /// A generation rebase is the only difference accepted here. Items,
    /// geometry, ordering, safety fields and observation time remain exact.
    public func isAssociated(with snapshot: MenuBarSnapshot) -> Bool {
        guard startedAtUptimeNanoseconds > 0,
              completedAtUptimeNanoseconds >= startedAtUptimeNanoseconds,
              initialEnvironment.hasSameValidScene(as: finalEnvironment),
              !initialEnvironment.activeSpaceIsFullscreen, !finalEnvironment.activeSpaceIsFullscreen,
              !initialEnvironment.menuTrackingIsActive, !finalEnvironment.menuTrackingIsActive,
              let receipt = initialEnvironment.nativeConcealmentReceipt, receipt.isStable,
              receipt == finalEnvironment.nativeConcealmentReceipt,
              let activeDisplay = finalEnvironment.activeStableDisplayID,
              observedSnapshot.displayIDs.contains(activeDisplay),
              observedSnapshot.activeSpaceIsValid, !observedSnapshot.menuTrackingIsActive else { return false }
        return observedSnapshot.capturedAt == snapshot.capturedAt &&
            observedSnapshot.items == snapshot.items &&
            observedSnapshot.displayIDs == snapshot.displayIDs &&
            observedSnapshot.displayIdentities == snapshot.displayIdentities &&
            observedSnapshot.activeSpaceIsValid == snapshot.activeSpaceIsValid &&
            observedSnapshot.menuTrackingIsActive == snapshot.menuTrackingIsActive
    }
}

/// An atomic runtime response. Deliberately not Codable: serialized snapshots
/// keep their existing schema and carry neither scan identity nor live trust.
public struct MenuBarAuthorityObservation: Equatable, Sendable {
    public let snapshot: MenuBarSnapshot
    public let scan: MenuBarObservationScan?

    public init(snapshot: MenuBarSnapshot, scan: MenuBarObservationScan? = nil) {
        self.snapshot = snapshot
        self.scan = scan?.isAssociated(with: snapshot) == true ? scan : nil
    }

    /// Cache and coordinator generation normalization retain actual scan ID
    /// and time. This must never be used to claim a new independent sample.
    public func rebasingGeneration(to generation: UInt64) -> Self {
        Self(
            snapshot: MenuBarSnapshot(
                generation: generation,
                capturedAt: snapshot.capturedAt,
                items: snapshot.items,
                displayIDs: snapshot.displayIDs,
                displayIdentities: snapshot.displayIdentities,
                activeSpaceIsValid: snapshot.activeSpaceIsValid,
                menuTrackingIsActive: snapshot.menuTrackingIsActive
            ),
            scan: scan
        )
    }
}
