import Foundation

/// Exact, non-localized identity for the macOS Focus menu extra. A title or
/// bundle prefix is never sufficient to recognize this platform surface.
public enum MenuBarPlatformPresenceIdentity {
    public static let focusItemID = MenuBarItemID(
        bundleIdentifier: "com.apple.MenuBarAgent",
        accessibilityIdentifier: "com.apple.menuextra.focusmode"
    )

    public static func isFocusItem(_ itemID: MenuBarItemID) -> Bool {
        // Pre-contract builds persisted title, occurrence alias, and fallback
        // fingerprint alongside this exact AX identity. Ignore those legacy
        // metadata fields only after both stable platform identity fields match.
        itemID.bundleIdentifier == focusItemID.bundleIdentifier &&
            itemID.accessibilityIdentifier == focusItemID.accessibilityIdentifier
    }
}

@_spi(BarlinePlatformPresence)
public struct MenuBarPlatformFocusItem: Equatable, Sendable {
    public let itemID: MenuBarItemID
    public let bounds: MenuBarRect
    public let displayID: MenuBarDisplayID
    public let ownerProcessIdentifier: Int32

    public init(
        itemID: MenuBarItemID,
        bounds: MenuBarRect,
        displayID: MenuBarDisplayID,
        ownerProcessIdentifier: Int32
    ) {
        self.itemID = itemID
        self.bounds = bounds
        self.displayID = displayID
        self.ownerProcessIdentifier = ownerProcessIdentifier
    }
}

@_spi(BarlinePlatformPresence)
public enum MenuBarPlatformFocusPresence: Equatable, Sendable {
    case present(MenuBarPlatformFocusItem)
    case absent
}

/// Runtime-only evidence from a closed, double-read MenuBarAgent tree. This
/// deliberately has no Codable conformance: process lifetime and signature
/// evidence must be reacquired after restart and can never come from a profile.
@_spi(BarlinePlatformPresence)
public struct MenuBarPlatformPresenceObservation: Equatable, Sendable {
    public let scanID: UUID
    public let startedAtUptimeNanoseconds: UInt64
    public let completedAtUptimeNanoseconds: UInt64
    public let publisherBundleIdentifier: String
    public let publisherProcessIdentifier: Int32
    public let publisherStartSeconds: UInt64
    public let publisherStartMicroseconds: UInt64
    public let publisherSealedIdentifier: String
    public let publisherCodeIdentityDigest: String
    public let scopeIsClosed: Bool
    public let clockAnchorIdentifier: String
    public let controlCenterAnchorIdentifier: String
    public let focusPresence: MenuBarPlatformFocusPresence

    public init(
        scanID: UUID,
        startedAtUptimeNanoseconds: UInt64,
        completedAtUptimeNanoseconds: UInt64,
        publisherBundleIdentifier: String,
        publisherProcessIdentifier: Int32,
        publisherStartSeconds: UInt64,
        publisherStartMicroseconds: UInt64,
        publisherSealedIdentifier: String,
        publisherCodeIdentityDigest: String,
        scopeIsClosed: Bool,
        clockAnchorIdentifier: String,
        controlCenterAnchorIdentifier: String,
        focusPresence: MenuBarPlatformFocusPresence
    ) {
        self.scanID = scanID
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        self.completedAtUptimeNanoseconds = completedAtUptimeNanoseconds
        self.publisherBundleIdentifier = publisherBundleIdentifier
        self.publisherProcessIdentifier = publisherProcessIdentifier
        self.publisherStartSeconds = publisherStartSeconds
        self.publisherStartMicroseconds = publisherStartMicroseconds
        self.publisherSealedIdentifier = publisherSealedIdentifier
        self.publisherCodeIdentityDigest = publisherCodeIdentityDigest
        self.scopeIsClosed = scopeIsClosed
        self.clockAnchorIdentifier = clockAnchorIdentifier
        self.controlCenterAnchorIdentifier = controlCenterAnchorIdentifier
        self.focusPresence = focusPresence
    }

    public var isStructurallyQualified: Bool {
        guard startedAtUptimeNanoseconds > 0,
              completedAtUptimeNanoseconds >= startedAtUptimeNanoseconds,
              publisherBundleIdentifier == "com.apple.MenuBarAgent",
              publisherProcessIdentifier > 0,
              publisherStartSeconds > 0,
              publisherStartMicroseconds < 1_000_000,
              publisherSealedIdentifier == "com.apple.MenuBarAgent",
              publisherCodeIdentityDigest.count == 64,
              publisherCodeIdentityDigest.allSatisfy(\.isHexDigit),
              scopeIsClosed,
              clockAnchorIdentifier == "com.apple.menuextra.clock",
              controlCenterAnchorIdentifier == "com.apple.menuextra.controlcenter"
        else { return false }

        switch focusPresence {
        case let .present(item):
            return MenuBarPlatformPresenceIdentity.isFocusItem(item.itemID) &&
                item.ownerProcessIdentifier == publisherProcessIdentifier &&
                !item.displayID.value.isEmpty &&
                item.bounds.width.isFinite && item.bounds.width > 0 &&
                item.bounds.height.isFinite && item.bounds.height > 0 &&
                item.bounds.x.isFinite && item.bounds.y.isFinite &&
                (item.bounds.x + item.bounds.width).isFinite &&
                (item.bounds.y + item.bounds.height).isFinite
        case .absent:
            return true
        }
    }

    public func hasSamePublisherLifetime(as other: Self) -> Bool {
        publisherBundleIdentifier == other.publisherBundleIdentifier &&
            publisherProcessIdentifier == other.publisherProcessIdentifier &&
            publisherStartSeconds == other.publisherStartSeconds &&
            publisherStartMicroseconds == other.publisherStartMicroseconds &&
            publisherSealedIdentifier == other.publisherSealedIdentifier &&
            publisherCodeIdentityDigest == other.publisherCodeIdentityDigest
    }
}

/// Immutable admission for one live layout transaction. It can authorize only
/// the exact Focus identity observed under the same MenuBarAgent process/code
/// lifetime and helper session; a later publisher cannot enlarge the set.
@_spi(BarlinePlatformPresence)
public struct MenuBarPlatformPresenceContract: Equatable, Sendable {
    private let publisher: MenuBarPlatformPresenceObservation
    private let helperSessionID: UUID

    @_spi(BarlinePlatformPresence)
    public static func permitsCacheReuse(
        scan: MenuBarObservationScan?,
        snapshot: MenuBarSnapshot,
        requiresQualifiedPresence: Bool
    ) -> Bool {
        guard requiresQualifiedPresence else { return true }
        guard let scan,
              scan.platformPresenceObservation?.isStructurallyQualified == true
        else { return false }
        return scan.isAssociated(with: snapshot)
    }

    static func admitting(_ observation: MenuBarAuthorityObservation) -> Self? {
        guard let scan = observation.scan,
              scan.isAssociated(with: observation.snapshot),
              let presence = scan.platformPresenceObservation,
              presence.isStructurallyQualified,
              presence.scanID == scan.scanID,
              let receipt = scan.initialEnvironment.nativeConcealmentReceipt,
              receipt.isStable,
              receipt.helperSessionID == scan.finalEnvironment.nativeConcealmentReceipt?.helperSessionID
        else { return nil }
        return Self(publisher: presence, helperSessionID: receipt.helperSessionID)
    }

    func accepts(_ observation: MenuBarAuthorityObservation) -> Bool {
        guard let scan = observation.scan,
              scan.isAssociated(with: observation.snapshot),
              let presence = scan.platformPresenceObservation,
              presence.isStructurallyQualified,
              presence.scanID == scan.scanID,
              publisher.hasSamePublisherLifetime(as: presence),
              let initialReceipt = scan.initialEnvironment.nativeConcealmentReceipt,
              let finalReceipt = scan.finalEnvironment.nativeConcealmentReceipt,
              initialReceipt.isStable,
              finalReceipt.isStable,
              initialReceipt.helperSessionID == helperSessionID,
              finalReceipt.helperSessionID == helperSessionID
        else { return false }
        return true
    }

    func projecting(_ snapshot: MenuBarSnapshot) -> MenuBarSnapshot {
        let retained = snapshot.items
            .sorted { $0.order < $1.order }
            .filter { !MenuBarPlatformPresenceIdentity.isFocusItem($0.id) }
            .enumerated()
            .map { index, item in item.replacing(section: item.section, order: index) }
        return MenuBarSnapshot(
            generation: snapshot.generation,
            capturedAt: snapshot.capturedAt,
            items: retained,
            displayIDs: snapshot.displayIDs,
            displayIdentities: snapshot.displayIdentities,
            activeSpaceIsValid: snapshot.activeSpaceIsValid,
            menuTrackingIsActive: snapshot.menuTrackingIsActive
        )
    }

    func projecting(_ layout: ProfileLayout) -> ProfileLayout? {
        guard !layout.hidden.contains(where: MenuBarPlatformPresenceIdentity.isFocusItem),
              !layout.alwaysHidden.contains(where: MenuBarPlatformPresenceIdentity.isFocusItem)
        else { return nil }
        return ProfileLayout(
            visible: layout.visible.filter { !MenuBarPlatformPresenceIdentity.isFocusItem($0) },
            hidden: layout.hidden,
            alwaysHidden: layout.alwaysHidden
        )
    }

    func projecting(_ presentation: ResolvedProfilePresentation) -> ResolvedProfilePresentation? {
        guard let layout = projecting(presentation.layout) else { return nil }
        let groups = presentation.groups.compactMap { group -> ProfileGroup? in
            var projected = group
            projected.itemIDs.removeAll(where: MenuBarPlatformPresenceIdentity.isFocusItem)
            return projected.itemIDs.isEmpty ? nil : projected
        }
        let spacers = presentation.spacers.filter { spacer in
            guard case let .after(itemID) = spacer.placement else { return true }
            return !MenuBarPlatformPresenceIdentity.isFocusItem(itemID)
        }
        return ResolvedProfilePresentation(
            source: presentation.source,
            destinationDisplayID: presentation.destinationDisplayID,
            layout: layout,
            groups: groups,
            spacers: spacers
        )
    }
}
