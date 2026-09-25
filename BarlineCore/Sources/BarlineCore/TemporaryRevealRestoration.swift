import Foundation

/// Stable compensation intent captured before temporarily revealing an item.
/// Neighbors are hints, not ownership: a neighbor that changes section or
/// display must never redirect restoration out of the original section.
public struct TemporaryRevealRestoration: Codable, Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case move(MenuBarMoveOperation)
        case itemAbsent
        case displayUnavailable
        case superseded
        case unavailable
    }

    public let itemID: MenuBarItemID
    public let originalSection: MenuBarSection
    public let originalDisplayID: MenuBarDisplayID
    /// The original ordinal within this section on this display, not a global index.
    public let originalIndex: Int
    public let precedingIDs: [MenuBarItemID]
    public let followingIDs: [MenuBarItemID]

    public init?(itemID: MenuBarItemID, in snapshot: MenuBarSnapshot) {
        guard Self.accepts(snapshot, now: Date()),
              let item = snapshot.items.first(where: { $0.id == itemID }),
              let displayID = item.displayID
        else { return nil }
        let neighbors = snapshot.items.filter {
            $0.section == item.section && $0.displayID == displayID
        }
        guard neighbors.count < 512,
              let index = neighbors.firstIndex(where: { $0.id == itemID })
        else { return nil }
        self.itemID = itemID
        originalSection = item.section
        originalDisplayID = displayID
        originalIndex = index
        precedingIDs = neighbors[..<index].reversed().map(\.id)
        followingIDs = neighbors[(index + 1)...].map(\.id)
        guard isValid else { return nil }
    }

    /// Persisted checkpoints are untrusted even when Codable decoding succeeds.
    public var isValid: Bool {
        let anchors = precedingIDs + followingIDs
        return !originalDisplayID.value.isEmpty && originalDisplayID.value.utf8.count <= 1024 &&
            originalIndex >= 0 && originalIndex < 512 &&
            precedingIDs.count == originalIndex && anchors.count < 512 &&
            Set(anchors).count == anchors.count && !anchors.contains(itemID) &&
            ([itemID] + anchors).allSatisfy(Self.acceptsIdentity)
    }

    public func resolve(in snapshot: MenuBarSnapshot, now: Date = Date()) -> Resolution {
        guard isValid, Self.accepts(snapshot, now: now) else { return .unavailable }
        guard snapshot.displayIDs.contains(originalDisplayID) else { return .displayUnavailable }
        guard let item = snapshot.items.first(where: { $0.id == itemID }) else { return .itemAbsent }
        guard item.displayID == originalDisplayID,
              item.section == .visible || item.section == originalSection
        else { return .superseded }

        // Operations use insertion offsets in the global, pre-removal section.
        // Keep the moving item in this array so an earlier source is not counted twice.
        let sectionItems = snapshot.items.filter { $0.section == originalSection }
        let eligibleIndices = sectionItems.indices.filter {
            sectionItems[$0].displayID == originalDisplayID && sectionItems[$0].id != itemID
        }
        for anchor in followingIDs {
            if let index = eligibleIndices.first(where: { sectionItems[$0].id == anchor }) {
                return move(to: index)
            }
        }
        for anchor in precedingIDs {
            if let index = eligibleIndices.first(where: { sectionItems[$0].id == anchor }) {
                return move(to: index + 1)
            }
        }

        let ordinal = min(originalIndex, eligibleIndices.count)
        if ordinal < eligibleIndices.count {
            return move(to: eligibleIndices[ordinal])
        }
        if let last = eligibleIndices.last {
            return move(to: last + 1)
        }
        // The helper requires a real same-display neighbor as a drag target.
        // Never substitute another display's item for an empty section.
        return .unavailable
    }

    private func move(to index: Int) -> Resolution {
        .move(MenuBarMoveOperation(
            itemID: itemID,
            section: originalSection,
            index: index,
            destinationDisplayID: originalDisplayID
        ))
    }

    private static func accepts(_ snapshot: MenuBarSnapshot, now: Date) -> Bool {
        guard !snapshot.menuTrackingIsActive,
              case .success = SnapshotValidator().validate(snapshot, previous: nil, now: now)
        else { return false }
        return true
    }

    private static func acceptsIdentity(_ id: MenuBarItemID) -> Bool {
        id.isPlausiblyStable &&
            [id.bundleIdentifier, id.accessibilityIdentifier, id.title, id.alias, id.fallbackFingerprint]
            .compactMap(\.self).allSatisfy { $0.utf8.count <= 4096 }
    }
}

/// Decides what to do when a temporarily revealed item is missing from a menu
/// bar census during restoration.
///
/// The menu bar can omit an item from one census while it compacts after a
/// reveal, so a single absence does not prove the item is gone. But an item
/// whose application has quit will never return to be restored, and a durable
/// obligation that can never be discharged blocks every later permanent layout
/// edit. Absence is therefore deferred only while the owning application is
/// running, and only for a bounded number of consecutive censuses.
public enum TemporaryRevealAbsencePolicy {
    public enum Decision: Equatable, Sendable {
        /// Keep the obligation and check again on a later census.
        case deferRestoration
        /// The item is gone; release the obligation.
        case release
    }

    public static let maximumDeferrals = 3

    public static func decision(
        ownerIsRunning: Bool?,
        consecutiveAbsences: Int
    ) -> Decision {
        if ownerIsRunning == false {
            return .release
        }
        return consecutiveAbsences < maximumDeferrals ? .deferRestoration : .release
    }
}

