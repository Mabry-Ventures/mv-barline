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

        var destinationItems = snapshot.items.filter {
            $0.section == operation.section && $0.id != operation.itemID
        }
        let previousItems = snapshot.items.filter { $0.section == operation.section }
        var insertionIndex = min(max(operation.index, 0), previousItems.count)
        if let priorIndex = previousItems.firstIndex(where: { $0.id == operation.itemID }),
           priorIndex < insertionIndex
        {
            insertionIndex -= 1
        }
        insertionIndex = min(insertionIndex, destinationItems.count)
        destinationItems.insert(source.replacingSection(operation.section), at: insertionIndex)

        var ordered = [MenuBarItemDescriptor]()
        for section in MenuBarSection.allCases {
            if section == operation.section {
                ordered.append(contentsOf: destinationItems)
            } else {
                ordered.append(contentsOf: snapshot.items.filter {
                    $0.section == section && $0.id != operation.itemID
                })
            }
        }
        let candidate = replacingItems(
            ordered,
            in: snapshot,
            generation: snapshot.generation &+ 1
        )
        guard MenuBarMovePlanner().resultMatches(operation, in: candidate, from: snapshot) else {
            throw MenuBarBackendError.operationFailed("menu bar assignment did not reach requested section")
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
