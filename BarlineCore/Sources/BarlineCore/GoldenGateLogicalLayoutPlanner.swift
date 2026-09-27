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
        // status-item order. A cross-section drop expresses a section choice,
        // not a physical reorder, so preserve native order and ignore its
        // synthetic destination index. Same-section reorders remain unsupported.
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
        guard source.section != operation.section ||
            MenuBarMovePlanner().resultMatches(operation, in: candidate, from: snapshot)
        else {
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

    /// Applies Barline-owned ordering only to concealed shelf sections. The
    /// visible menu bar is ordered by macOS and must never be cosmetically
    /// reordered from persisted ranks.
    public func applyingExplicitShelfOrder(
        to snapshot: MenuBarSnapshot,
        assignments: [MenuBarItemID: GoldenGateLogicalAssignment],
        fallbackRank: Int = 512
    ) -> MenuBarSnapshot {
        guard !assignments.isEmpty else { return snapshot }
        let visible = snapshot.items
            .filter { $0.section == .visible }
            .sorted { $0.order < $1.order }
        let concealed = [MenuBarSection.hidden, .alwaysHidden].flatMap { section in
            snapshot.items.filter { $0.section == section }.sorted { lhs, rhs in
                if lhs.isBarlineControlItem != rhs.isBarlineControlItem {
                    return !lhs.isBarlineControlItem
                }
                let lhsRank = assignments[lhs.id]?.rank ?? (fallbackRank + lhs.order)
                let rhsRank = assignments[rhs.id]?.rank ?? (fallbackRank + rhs.order)
                return lhsRank == rhsRank ? lhs.order < rhs.order : lhsRank < rhsRank
            }
        }
        return replacingItems(visible + concealed, in: snapshot)
    }

    /// Produces a bounded, deterministic persistence document. Assignments for
    /// temporarily absent applications are retained. A runtime snapshot may
    /// temporarily fail a mixed bundle visible, so only explicitly edited
    /// identities may replace previously saved intent.
    public func assignmentsForPersistence(
        from snapshot: MenuBarSnapshot,
        preserving existing: [MenuBarItemID: GoldenGateLogicalAssignment],
        editing editedItemIDs: Set<MenuBarItemID>,
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
                .compactMap { rank, item in
                    if !editedItemIDs.contains(item.id) {
                        return existing[item.id]
                    }
                    return GoldenGateLogicalAssignment(
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
        let ranks = consistentRanks(
            current: current,
            retained: retained,
            editedItemIDs: editedItemIDs,
            snapshotPositions: Self.physicalPositions(in: snapshot)
        )
        return Array((current + retained).map { assignment in
            GoldenGateLogicalAssignment(
                itemID: assignment.itemID,
                section: assignment.section,
                rank: ranks[assignment.itemID] ?? assignment.rank
            )
        }.prefix(maximumCount))
    }

    /// Left-to-right menu bar positions. The snapshot passed in may already be
    /// in display order (concealed items after visible ones, sorted by saved
    /// rank), so use each item's physical frame when every item has one; macOS
    /// 27 keeps a concealed item's source frame in the menu bar. Otherwise fall
    /// back to snapshot order for all items, never a mix of the two.
    static func physicalPositions(in snapshot: MenuBarSnapshot) -> [MenuBarItemID: Double] {
        let framed = snapshot.items.allSatisfy {
            $0.bounds.width > 0 && $0.bounds.x.isFinite && $0.bounds.y.isFinite
        }
        let pairs = snapshot.items.enumerated().map { index, item in
            (item.id, framed ? item.bounds.x : Double(index))
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    /// Saved ranks and live snapshot positions are different numbering spaces.
    /// Within each section, keep untouched items in their saved order, place
    /// each edited item after the untouched item that precedes it in the live
    /// menu bar, then renumber the section from zero. Sections never change.
    private func consistentRanks(
        current: [GoldenGateLogicalAssignment],
        retained: [GoldenGateLogicalAssignment],
        editedItemIDs: Set<MenuBarItemID>,
        snapshotPositions: [MenuBarItemID: Double]
    ) -> [MenuBarItemID: Int] {
        var ranks = [MenuBarItemID: Int]()
        for section in MenuBarSection.allCases {
            let members = (current + retained).filter { $0.section == section }
            let edited = members
                .filter { editedItemIDs.contains($0.itemID) }
                .sorted { (snapshotPositions[$0.itemID] ?? .infinity) < (snapshotPositions[$1.itemID] ?? .infinity) }
            var ordered = members
                .filter { !editedItemIDs.contains($0.itemID) }
                .sorted {
                    if $0.rank != $1.rank {
                        return $0.rank < $1.rank
                    }
                    let lhs = snapshotPositions[$0.itemID] ?? .infinity
                    let rhs = snapshotPositions[$1.itemID] ?? .infinity
                    return lhs == rhs ? $0.itemID.description < $1.itemID.description : lhs < rhs
                }
                .map(\.itemID)
            for assignment in edited {
                guard let position = snapshotPositions[assignment.itemID] else {
                    ordered.append(assignment.itemID)
                    continue
                }
                // Untouched neighbours with a live position. A concealed or
                // absent item has none and cannot anchor placement.
                let liveNeighbours = ordered
                    .filter { !editedItemIDs.contains($0) }
                    .compactMap { candidate in snapshotPositions[candidate].map { (candidate, $0) } }
                if let predecessorID = liveNeighbours.filter({ $0.1 < position }).max(by: { $0.1 < $1.1 })?.0,
                   let predecessor = ordered.firstIndex(of: predecessorID)
                {
                    var index = predecessor + 1
                    // Keep edited items that share a predecessor in live order.
                    while index < ordered.count, editedItemIDs.contains(ordered[index]) {
                        index += 1
                    }
                    ordered.insert(assignment.itemID, at: index)
                } else if let successorID = liveNeighbours.filter({ $0.1 > position })
                    .min(by: { $0.1 < $1.1 })?.0,
                    let successor = ordered.firstIndex(of: successorID)
                {
                    ordered.insert(assignment.itemID, at: successor)
                } else {
                    // No live anchor: follow the saved items rather than jump ahead.
                    ordered.append(assignment.itemID)
                }
            }
            for (rank, itemID) in ordered.enumerated() {
                ranks[itemID] = rank
            }
        }
        return ranks
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
