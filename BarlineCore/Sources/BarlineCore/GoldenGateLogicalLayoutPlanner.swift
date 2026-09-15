import Foundation

public struct GoldenGateLogicalAssignment: Codable, Equatable, Sendable {
    public let itemID: MenuBarItemID
    public let section: MenuBarSection
    public let rank: Int

    public init(itemID: MenuBarItemID, section: MenuBarSection, rank: Int) {
        self.itemID = itemID
        self.section = section
        self.rank = rank
    }
}

/// Applies macOS 27 visibility assignments without synthesizing pointer input.
/// The caller remains responsible for committing the resulting complete state
/// through the native concealment controller before persisting it.
public struct GoldenGateLogicalLayoutPlanner: Sendable {
    public init() {}

    public func applying(
        _ operation: MenuBarMoveOperation,
        to snapshot: MenuBarSnapshot
    ) throws -> MenuBarSnapshot {
        guard let source = snapshot.items.first(where: { $0.id == operation.itemID }) else {
            throw MenuBarBackendError.staleItem(operation.itemID)
        }
        guard source.isMovable else {
            throw MenuBarBackendError.operationFailed("menu bar item cannot be assigned independently")
        }
        if operation.section != .visible, !source.canBeHidden {
            throw MenuBarBackendError.operationFailed("menu bar item cannot be hidden")
        }

        // Native concealment changes visibility only; macOS retains physical
        // status-item order. Preserve that order and reject any operation whose
        // requested insertion slot would require an unperformed native reorder.
        let ordered = snapshot.items.map { item in
            item.id == operation.itemID
                ? item.replacingSection(operation.section)
                : item
        }
        let candidate = replacingItems(
            ordered,
            in: snapshot,
            generation: snapshot.generation &+ 1
        )
        guard MenuBarMovePlanner().resultMatches(operation, in: candidate, from: snapshot) else {
            throw MenuBarBackendError.operationFailed(
                "menu bar assignment would require changing native item order"
            )
        }
        return candidate
    }

    public func applyingExplicitOrder(
        to snapshot: MenuBarSnapshot,
        assignments: [MenuBarItemID: GoldenGateLogicalAssignment],
        fallbackRank: Int = 512
    ) -> MenuBarSnapshot {
        guard !assignments.isEmpty else { return snapshot }
        var ordered = [MenuBarItemDescriptor]()
        for section in MenuBarSection.allCases {
            let sectionItems = snapshot.items.filter { $0.section == section }.sorted { lhs, rhs in
                let lhsRank = assignments[lhs.id]?.rank ?? (fallbackRank + lhs.order)
                let rhsRank = assignments[rhs.id]?.rank ?? (fallbackRank + rhs.order)
                return lhsRank == rhsRank ? lhs.order < rhs.order : lhsRank < rhsRank
            }
            ordered.append(contentsOf: sectionItems)
        }
        return replacingItems(ordered, in: snapshot)
    }

    /// Produces a bounded, deterministic persistence document. Assignments for
    /// temporarily absent applications are retained, while control items and
    /// identities currently observed as invalid are removed.
    public func assignmentsForPersistence(
        from snapshot: MenuBarSnapshot,
        preserving existing: [MenuBarItemID: GoldenGateLogicalAssignment],
        barlineBundleIdentifier: String,
        maximumCount: Int
    ) -> [GoldenGateLogicalAssignment] {
        guard maximumCount > 0 else { return [] }
        let observedIDs = Set(snapshot.items.map(\.id))
        let current = MenuBarSection.allCases.flatMap { section in
            snapshot.items
                .filter {
                    $0.section == section &&
                        !$0.isBarlineControlItem &&
                        $0.id.isPlausiblyStable
                }
                .enumerated()
                .map { rank, item in
                    GoldenGateLogicalAssignment(
                        itemID: item.id,
                        section: section,
                        rank: rank
                    )
                }
        }
        let retained = existing.values
            .filter {
                !observedIDs.contains($0.itemID) &&
                    $0.itemID.isPlausiblyStable &&
                    $0.itemID.bundleIdentifier.caseInsensitiveCompare(barlineBundleIdentifier) != .orderedSame &&
                    $0.rank >= 0
            }
            .sorted {
                if $0.section != $1.section {
                    return $0.section.rawValue < $1.section.rawValue
                }
                if $0.rank != $1.rank {
                    return $0.rank < $1.rank
                }
                return $0.itemID.description < $1.itemID.description
            }
        return Array((current + retained).prefix(maximumCount))
    }

    /// Reconciles a saved target with the current inventory while enforcing
    /// the same independent-assignment policy as a direct move.
    public func restoring(
        _ target: MenuBarSnapshot,
        to current: MenuBarSnapshot
    ) throws -> MenuBarSnapshot {
        guard Set(target.items.map(\.id)).count == target.items.count,
              Set(current.items.map(\.id)).count == current.items.count
        else {
            throw MenuBarBackendError.operationFailed("saved layout contains duplicate menu bar items")
        }
        let targetByID = Dictionary(uniqueKeysWithValues: target.items.map { ($0.id, $0) })
        guard current.items.allSatisfy({ targetByID[$0.id] != nil }) else {
            throw MenuBarBackendError.operationFailed("saved layout no longer matches the menu bar")
        }
        let ordered: [MenuBarItemDescriptor] = try current.items.enumerated().map { index, currentItem in
            guard let targetItem = targetByID[currentItem.id] else {
                throw MenuBarBackendError.operationFailed("saved layout no longer matches the menu bar")
            }
            if currentItem.section != targetItem.section {
                guard currentItem.isMovable else {
                    throw MenuBarBackendError.operationFailed(
                        "saved layout contains an item that cannot be assigned independently"
                    )
                }
                if targetItem.section != .visible, !currentItem.canBeHidden {
                    throw MenuBarBackendError.operationFailed(
                        "saved layout contains an item that cannot be hidden"
                    )
                }
            }
            return currentItem.replacing(section: targetItem.section, order: index)
        }
        let currentIDs = Set(current.items.map(\.id))
        for section in MenuBarSection.allCases {
            let requestedOrder = target.items
                .filter { $0.section == section && currentIDs.contains($0.id) }
                .map(\.id)
            let nativeOrder = ordered.filter { $0.section == section }.map(\.id)
            guard requestedOrder == nativeOrder else {
                throw MenuBarBackendError.operationFailed(
                    "saved layout would require changing native item order"
                )
            }
        }
        return replacingItems(
            ordered,
            in: current,
            generation: current.generation &+ 1
        )
    }

    private func replacingItems(
        _ items: [MenuBarItemDescriptor],
        in snapshot: MenuBarSnapshot,
        generation: UInt64? = nil
    ) -> MenuBarSnapshot {
        MenuBarSnapshot(
            generation: generation ?? snapshot.generation,
            capturedAt: Date(),
            items: items.enumerated().map { index, item in item.replacing(order: index) },
            displayIDs: snapshot.displayIDs,
            displayIdentities: snapshot.displayIdentities,
            activeSpaceIsValid: snapshot.activeSpaceIsValid,
            menuTrackingIsActive: false
        )
    }
}
