import Foundation

public enum SnapshotRejectionReason: Error, Codable, Equatable, Sendable {
    case missingDisplayGeometry
    case invalidActiveSpace
    case staleSnapshot
    case futureDatedSnapshot
    case unknownItemDisplay(MenuBarDisplayID)
    case displayIdentitySetMismatch
    case duplicateDisplayIdentity(MenuBarDisplayID)
    case malformedDisplayFingerprint
    case duplicateItemIdentity(MenuBarItemID)
    case unstableItemIdentity(MenuBarItemID)
    case invalidItemGeometry(MenuBarItemID)
    case missingRequiredControlItem(MenuBarItemID)
    case implausibleItemCountCollapse(previous: Int, candidate: Int)
    case implausibleSystemItemCollapse(previous: Int, candidate: Int)
    case emptySnapshot
    case nonMonotonicGeneration(previous: UInt64, candidate: UInt64)
    case platformPresenceContractChanged
}

public struct SnapshotValidationPolicy: Sendable {
    public let requiredControlItemIDs: Set<MenuBarItemID>
    public let maximumAge: TimeInterval
    public let maximumFutureClockSkew: TimeInterval
    public let maximumCollapseRatio: Double
    public let maximumSystemItemCollapseRatio: Double
    public let allowsEmptySnapshot: Bool

    public init(
        requiredControlItemIDs: Set<MenuBarItemID> = [],
        maximumAge: TimeInterval = 10,
        maximumFutureClockSkew: TimeInterval = 1,
        maximumCollapseRatio: Double = 0.65,
        maximumSystemItemCollapseRatio: Double = 0.5,
        allowsEmptySnapshot: Bool = false
    ) {
        self.requiredControlItemIDs = requiredControlItemIDs
        self.maximumAge = maximumAge
        self.maximumFutureClockSkew = maximumFutureClockSkew
        self.maximumCollapseRatio = maximumCollapseRatio
        self.maximumSystemItemCollapseRatio = maximumSystemItemCollapseRatio
        self.allowsEmptySnapshot = allowsEmptySnapshot
    }
}

public struct SnapshotValidator: Sendable {
    public let policy: SnapshotValidationPolicy

    public init(policy: SnapshotValidationPolicy = SnapshotValidationPolicy()) {
        self.policy = policy
    }

    public func validate(
        _ candidate: MenuBarSnapshot,
        previous: MenuBarSnapshot?,
        now: Date = Date()
    ) -> Result<MenuBarSnapshot, SnapshotRejectionReason> {
        validate(candidate, previous: previous, now: now, excludingPlatformItems: [])
    }

    /// Runtime-only platform presence can remove exactly the attested Focus
    /// control from continuity denominators. All ordinary snapshot checks and
    /// every other item/system threshold remain unchanged. Persisted snapshots
    /// cannot reach this overload with reconstructed evidence.
    public func validate(
        _ observation: MenuBarAuthorityObservation,
        previous: MenuBarSnapshot?,
        now: Date = Date()
    ) -> Result<MenuBarSnapshot, SnapshotRejectionReason> {
        guard let contract = MenuBarPlatformPresenceContract.admitting(observation) else {
            return validate(observation.snapshot, previous: previous, now: now)
        }
        return validate(observation, previous: previous, platformContract: contract, now: now)
    }

    func validate(
        _ observation: MenuBarAuthorityObservation,
        previous: MenuBarSnapshot?,
        platformContract: MenuBarPlatformPresenceContract?,
        now: Date = Date()
    ) -> Result<MenuBarSnapshot, SnapshotRejectionReason> {
        guard let platformContract else {
            return validate(observation.snapshot, previous: previous, now: now)
        }
        guard platformContract.accepts(observation) else {
            return .failure(.platformPresenceContractChanged)
        }
        return validate(
            observation.snapshot,
            previous: previous,
            now: now,
            excludingPlatformItems: [MenuBarPlatformPresenceIdentity.focusItemID]
        )
    }

    private func validate(
        _ candidate: MenuBarSnapshot,
        previous: MenuBarSnapshot?,
        now: Date,
        excludingPlatformItems excludedPlatformItems: Set<MenuBarItemID>
    ) -> Result<MenuBarSnapshot, SnapshotRejectionReason> {
        guard !candidate.displayIDs.isEmpty else {
            return .failure(.missingDisplayGeometry)
        }
        guard candidate.activeSpaceIsValid else {
            return .failure(.invalidActiveSpace)
        }
        let snapshotAge = now.timeIntervalSince(candidate.capturedAt)
        guard snapshotAge <= policy.maximumAge else {
            return .failure(.staleSnapshot)
        }
        guard snapshotAge >= -policy.maximumFutureClockSkew else {
            return .failure(.futureDatedSnapshot)
        }
        guard policy.allowsEmptySnapshot || !candidate.items.isEmpty else {
            return .failure(.emptySnapshot)
        }

        if let displayIdentities = candidate.displayIdentities {
            var identityIDs = Set<MenuBarDisplayID>()
            for identity in displayIdentities {
                guard !identity.runtimeID.value.isEmpty,
                      identityIDs.insert(identity.runtimeID).inserted
                else {
                    return .failure(.duplicateDisplayIdentity(identity.runtimeID))
                }
                if let fingerprint = identity.hardwareFingerprint,
                   !fingerprint.isWellFormed
                {
                    return .failure(.malformedDisplayFingerprint)
                }
            }
            guard identityIDs == candidate.displayIDs else {
                return .failure(.displayIdentitySetMismatch)
            }
        }

        var seen = Set<MenuBarItemID>()
        for item in candidate.items {
            if let displayID = item.displayID, !candidate.displayIDs.contains(displayID) {
                return .failure(.unknownItemDisplay(displayID))
            }
            guard item.id.isPlausiblyStable else {
                return .failure(.unstableItemIdentity(item.id))
            }
            guard item.bounds.isFiniteAndNonnegative else {
                return .failure(.invalidItemGeometry(item.id))
            }
            guard seen.insert(item.id).inserted else {
                return .failure(.duplicateItemIdentity(item.id))
            }
        }

        let presentControlIDs = Set(
            candidate.items.lazy.filter(\.isBarlineControlItem).map(\.id)
        )
        if let missingControlID = policy.requiredControlItemIDs.subtracting(presentControlIDs).first {
            return .failure(.missingRequiredControlItem(missingControlID))
        }

        if let previous,
           previous.items.contains(where: { MenuBarPlatformPresenceIdentity.isFocusItem($0.id) }),
           !candidate.items.contains(where: { MenuBarPlatformPresenceIdentity.isFocusItem($0.id) }),
           !excludedPlatformItems.contains(MenuBarPlatformPresenceIdentity.focusItemID)
        {
            // The exact MenuBarAgent/AX Focus identity exists only on Golden
            // Gate. The legacy WindowServer lane does not emit this identity.
            // Golden Gate must provide a closed native presence contract
            // before this platform-owned control may disappear.
            return .failure(.platformPresenceContractChanged)
        }

        if let previous {
            guard candidate.generation > previous.generation else {
                return .failure(
                    .nonMonotonicGeneration(
                        previous: previous.generation,
                        candidate: candidate.generation
                    )
                )
            }
            if !previous.items.isEmpty {
                let previousAuthorityItemCount = previous.items.count {
                    !isExcludedPlatformItem($0.id, by: excludedPlatformItems)
                }
                let candidateAuthorityItemCount = candidate.items.count {
                    !isExcludedPlatformItem($0.id, by: excludedPlatformItems)
                }
                let retainedRatio = previousAuthorityItemCount == 0
                    ? 1
                    : Double(candidateAuthorityItemCount) / Double(previousAuthorityItemCount)
                if retainedRatio < 1 - policy.maximumCollapseRatio {
                    return .failure(
                        .implausibleItemCountCollapse(
                            previous: previousAuthorityItemCount,
                            candidate: candidateAuthorityItemCount
                        )
                    )
                }
            }

            let previousSystemIDs = Set(previous.items.filter {
                $0.isConfirmedSystemItem &&
                    !isExcludedPlatformItem($0.id, by: excludedPlatformItems)
            }.map { continuityIdentity(for: $0.id) })
            let previousSystemItemCount = previousSystemIDs.count
            if previousSystemItemCount > 0 {
                // Continuity protects inventory, not a provisional ownership
                // classification. Retaining the same identity while its source
                // resolves must not freeze all later mutations. Conversely,
                // unrelated new system items cannot mask loss of known ones.
                let candidateSystemIDs = Set(candidate.items.map { continuityIdentity(for: $0.id) })
                let candidateSystemItemCount = previousSystemIDs.intersection(candidateSystemIDs).count
                let retainedRatio = Double(candidateSystemItemCount) / Double(previousSystemItemCount)
                if retainedRatio < 1 - policy.maximumSystemItemCollapseRatio {
                    return .failure(
                        .implausibleSystemItemCollapse(
                            previous: previousSystemItemCount,
                            candidate: candidateSystemItemCount
                        )
                    )
                }
            }
        }

        return .success(candidate)
    }

    private func isExcludedPlatformItem(
        _ itemID: MenuBarItemID,
        by excludedPlatformItems: Set<MenuBarItemID>
    ) -> Bool {
        excludedPlatformItems.contains(itemID) ||
            (excludedPlatformItems.contains(MenuBarPlatformPresenceIdentity.focusItemID) &&
                MenuBarPlatformPresenceIdentity.isFocusItem(itemID))
    }

    /// Older Golden Gate snapshots carry title/alias/fingerprint metadata for
    /// the same exact AX Focus identity. Continuity compares the semantic
    /// platform identity, not that non-authoritative presentation metadata.
    private func continuityIdentity(for itemID: MenuBarItemID) -> MenuBarItemID {
        MenuBarPlatformPresenceIdentity.isFocusItem(itemID)
            ? MenuBarPlatformPresenceIdentity.focusItemID
            : itemID
    }
}
