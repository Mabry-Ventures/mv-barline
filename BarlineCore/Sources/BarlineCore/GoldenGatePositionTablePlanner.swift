import Foundation

/// One targeted key change inside a macOS 27 position-table transaction.
public struct GoldenGatePositionChange: Codable, Equatable, Sendable {
    public let key: String
    public let originalValue: Int
    public let proposedValue: Int

    public init(key: String, originalValue: Int, proposedValue: Int) {
        self.key = key
        self.originalValue = originalValue
        self.proposedValue = proposedValue
    }
}

/// A targeted transaction against MenuBarAgent's macOS 27 position table.
///
/// The table is an ordering substrate, not a visibility API. Barline moves an
/// item across one of its own section dividers, then lets the divider's native
/// status-item width conceal or reveal the resulting section.
public struct GoldenGatePositionMutation: Codable, Equatable, Sendable {
    public let changes: [GoldenGatePositionChange]

    public init(changes: [GoldenGatePositionChange]) {
        self.changes = changes
    }
}

public enum GoldenGatePositionTableError: Error, Equatable, Sendable {
    case unresolvedItem
    case unresolvedDivider
    case ambiguousAxis
    case unresolvedAffectedItem
    case inconsistentPositionOrder
}

/// Pure planning for the macOS 27 `TrailingItemPreferredPositions` table.
///
/// This is intentionally conservative. Only an exact bundle/item key or a
/// unique suffix match is accepted. Unknown keys and system modules are never
/// rewritten, and a move without a collision-free integer slot fails closed.
public enum GoldenGatePositionTablePlanner {
    private static let statusPrefix = "status:"
    private static let keySeparator = "::"

    public static func resolvedKey(
        for itemID: MenuBarItemID,
        localizedApplicationName: String? = nil,
        existingKeys: some Collection<String>
    ) -> String? {
        let keys = Array(existingKeys)
        if itemID.bundleIdentifier.hasPrefix("com.apple."),
           let title = itemID.title,
           !title.isEmpty,
           let module = uniqueCaseInsensitiveMatch("module:\(title)", in: keys)
        {
            return module
        }
        let identifiers = [itemID.accessibilityIdentifier, itemID.title]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return nil }

        for identifier in identifiers {
            let exact = "\(statusPrefix)\(itemID.bundleIdentifier)\(keySeparator)\(identifier)"
            if let match = uniqueCaseInsensitiveMatch(exact, in: keys) {
                return match
            }
        }

        let ownerNames = Set(
            [localizedApplicationName, itemID.bundleIdentifier]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.lowercased() }
        )
        for identifier in identifiers {
            let suffix = "\(keySeparator)\(identifier)"
            let candidates = keys.filter {
                $0.lowercased().hasPrefix(statusPrefix) &&
                    $0.lowercased().hasSuffix(suffix.lowercased())
            }
            let ownerMatches = candidates.filter { key in
                guard let owner = statusOwner(in: key) else { return false }
                return ownerNames.contains(owner.lowercased())
            }
            if ownerMatches.count == 1 {
                return ownerMatches[0]
            }
        }
        return nil
    }

    /// Returns the exact physical candidate represented by a drag operation.
    /// Unlike the pre-macOS-27 logical planner, this preserves the requested
    /// destination index and supports same-section reordering.
    public static func candidateSnapshot(
        applying operation: MenuBarMoveOperation,
        to snapshot: MenuBarSnapshot
    ) throws -> MenuBarSnapshot {
        let layout = try desiredLayout(operation, in: snapshot)
        return MenuBarSnapshot(
            generation: snapshot.generation &+ 1,
            capturedAt: Date(),
            items: layout.desired.enumerated().map { index, item in
                item.id == operation.itemID
                    ? item.replacing(section: operation.section, order: index)
                    : item.replacing(order: index)
            },
            displayIDs: snapshot.displayIDs,
            displayIdentities: snapshot.displayIdentities,
            activeSpaceIsValid: snapshot.activeSpaceIsValid,
            menuTrackingIsActive: false
        )
    }

    /// Reconciles AX inventory with the authoritative macOS 27 position table.
    /// Items missing from AX retain their descriptor metadata, but their
    /// section and global order come from the freshly synchronized native
    /// table rather than a proposed logical assignment.
    public static func applyingPositions(
        to snapshot: MenuBarSnapshot,
        positions: [String: Int],
        keysByItemID: [MenuBarItemID: String],
        excludingFromAxis excludedItemIDs: Set<MenuBarItemID> = [],
        usingKnownAxis knownAxis: AxisDirection? = nil
    ) throws -> MenuBarSnapshot {
        let axis = if let knownAxis {
            knownAxis
        } else {
            try resolvedAxisDirection(
                snapshot: snapshot,
                positions: positions,
                keysByItemID: keysByItemID,
                excludingItemIDs: excludedItemIDs
            )
        }
        let resolved = snapshot.items.compactMap { item -> (MenuBarItemDescriptor, Int)? in
            guard let key = keysByItemID[item.id], let value = positions[key] else { return nil }
            return (item, value)
        }.sorted { lhs, rhs in
            switch axis {
            case .ascendingLeftToRight: lhs.1 < rhs.1
            case .descendingLeftToRight: lhs.1 > rhs.1
            }
        }
        let resolvedIDs = Set(resolved.map(\.0.id))
        let hiddenIndex = resolved.firstIndex {
            $0.0.isBarlineControlItem && $0.0.title == "Barline.ControlItem.Hidden"
        }
        guard let hiddenIndex else { throw GoldenGatePositionTableError.unresolvedDivider }
        let alwaysHiddenIndex = resolved.firstIndex {
            $0.0.isBarlineControlItem && $0.0.title == "Barline.ControlItem.AlwaysHidden"
        }
        if let alwaysHiddenIndex, alwaysHiddenIndex >= hiddenIndex {
            throw GoldenGatePositionTableError.inconsistentPositionOrder
        }

        let tableLiveIDs = resolved.compactMap { item, _ in
            item.isOnScreen ? item.id : nil
        }
        let observedLiveIDs = snapshot.items
            .filter { item in
                item.isOnScreen && keysByItemID[item.id].flatMap { positions[$0] } != nil
            }
            .sorted(by: physicalOrder)
            .map(\.id)
        guard tableLiveIDs == observedLiveIDs else {
            throw GoldenGatePositionTableError.inconsistentPositionOrder
        }

        let classified = resolved.enumerated().map { index, pair in
            let item = pair.0
            let section: MenuBarSection = if item.isOnScreen || item.isBarlineControlItem {
                item.section
            } else if let alwaysHiddenIndex, index < alwaysHiddenIndex {
                .alwaysHidden
            } else if index < hiddenIndex {
                .hidden
            } else {
                .visible
            }
            return item.replacing(section: section, order: index)
        }
        let classifiedByID = Dictionary(uniqueKeysWithValues: classified.map { ($0.id, $0) })
        var resolvedSequence = classified.map(\.id)[...]
        let prior = snapshot.items.sorted(by: physicalOrder)
        var merged = prior.map { item -> MenuBarItemDescriptor in
            guard resolvedIDs.contains(item.id), let nextID = resolvedSequence.popFirst() else {
                return item
            }
            return classifiedByID[nextID]!
        }
        merged = merged.enumerated().map { index, item in
            item.replacing(section: item.section, order: index)
        }
        return MenuBarSnapshot(
            generation: snapshot.generation,
            capturedAt: snapshot.capturedAt,
            items: merged,
            displayIDs: snapshot.displayIDs,
            displayIdentities: snapshot.displayIdentities,
            activeSpaceIsValid: snapshot.activeSpaceIsValid,
            menuTrackingIsActive: snapshot.menuTrackingIsActive
        )
    }

    public static func planMove(
        _ operation: MenuBarMoveOperation,
        in snapshot: MenuBarSnapshot,
        positions: [String: Int],
        keysByItemID: [MenuBarItemID: String]
    ) throws -> GoldenGatePositionMutation {
        let layout = try desiredLayout(operation, in: snapshot)
        let ordered = layout.ordered
        let desired = layout.desired
        let desiredIndex = layout.desiredIndex
        guard let sourceKey = keysByItemID[operation.itemID],
              positions[sourceKey] != nil
        else {
            throw GoldenGatePositionTableError.unresolvedItem
        }

        let axis = try resolvedAxisDirection(
            snapshot: snapshot,
            positions: positions,
            keysByItemID: keysByItemID
        )
        let resolvedOrder = ordered.compactMap { item -> Int? in
            keysByItemID[item.id].flatMap { positions[$0] }
        }
        for pair in zip(resolvedOrder, resolvedOrder.dropFirst()) {
            let isOrdered = switch axis {
            case .ascendingLeftToRight: pair.0 < pair.1
            case .descendingLeftToRight: pair.0 > pair.1
            }
            guard isOrdered else {
                throw GoldenGatePositionTableError.inconsistentPositionOrder
            }
        }
        if let proposed = proposedSourceValue(
            sourceKey: sourceKey,
            desiredIndex: desiredIndex,
            desired: desired,
            positions: positions,
            keysByItemID: keysByItemID,
            axis: axis
        ), proposed != positions[sourceKey] {
            return GoldenGatePositionMutation(changes: [
                GoldenGatePositionChange(
                    key: sourceKey,
                    originalValue: positions[sourceKey]!,
                    proposedValue: proposed
                ),
            ])
        }

        // Adjacent integer weights leave no midpoint. Re-space only the
        // destination section's application items while holding both Barline
        // divider weights fixed. A divider is a physical section boundary, so
        // rotating its slot would move the boundary instead of the item.
        let changes = try respacedDestinationChanges(
            operation: operation,
            desired: desired,
            positions: positions,
            keysByItemID: keysByItemID,
            axis: axis
        )
        guard !changes.isEmpty else {
            throw GoldenGatePositionTableError.inconsistentPositionOrder
        }
        return GoldenGatePositionMutation(changes: changes)
    }

    /// Plans a saved-layout restore as one preference transaction. Items that
    /// were launched after the layout was saved retain their existing numeric
    /// positions; only items shared by the target and current snapshots move.
    public static func planRestore(
        target: MenuBarSnapshot,
        current: MenuBarSnapshot,
        positions: [String: Int],
        keysByItemID: [MenuBarItemID: String]
    ) throws -> GoldenGatePositionMutation {
        guard Set(target.items.map(\.id)).count == target.items.count,
              Set(current.items.map(\.id)).count == current.items.count
        else {
            throw MenuBarBackendError.operationFailed("saved layout contains duplicate menu bar items")
        }
        let currentByID = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
        let sharedTargetItems = target.items.filter {
            !$0.isBarlineControlItem && currentByID[$0.id] != nil
        }
        for targetItem in sharedTargetItems {
            guard let currentItem = currentByID[targetItem.id] else { continue }
            if !currentItem.isMovable {
                guard currentItem.section == targetItem.section else {
                    throw MenuBarBackendError.operationFailed(
                        "saved layout attempts to move a protected menu bar item"
                    )
                }
                continue
            }
            if targetItem.section != .visible, !currentItem.canBeHidden {
                throw MenuBarBackendError.operationFailed("saved layout contains an item that cannot be hidden")
            }
            guard let key = keysByItemID[targetItem.id], positions[key] != nil else {
                throw GoldenGatePositionTableError.unresolvedItem
            }
        }
        let requiredItemIDs = Set(sharedTargetItems.map(\.id))
        if restoreMatches(
            target: target,
            current: current,
            requiredItemIDs: requiredItemIDs
        ) {
            return GoldenGatePositionMutation(changes: [])
        }
        let axis = try resolvedAxisDirection(
            snapshot: current,
            positions: positions,
            keysByItemID: keysByItemID
        )
        let controls = Dictionary(uniqueKeysWithValues: current.items.compactMap {
            item -> (String, MenuBarItemDescriptor)? in
            guard item.isBarlineControlItem, let title = item.title else { return nil }
            return (title, item)
        })
        guard let hidden = controls["Barline.ControlItem.Hidden"] else {
            throw GoldenGatePositionTableError.unresolvedDivider
        }
        let alwaysHidden = controls["Barline.ControlItem.AlwaysHidden"]
        var workingPositions = positions
        var changes = [GoldenGatePositionChange]()

        for section in MenuBarSection.allCases {
            let sectionItems = sharedTargetItems
                .filter { $0.section == section }
                .sorted(by: physicalOrder)
            guard !sectionItems.isEmpty else { continue }
            let sectionBoundaries: (left: MenuBarItemDescriptor?, right: MenuBarItemDescriptor?) =
                switch section {
                case .visible: (hidden, nil)
                case .hidden: (alwaysHidden, hidden)
                case .alwaysHidden: (nil, alwaysHidden)
                }
            var index = 0
            while index < sectionItems.count {
                guard currentByID[sectionItems[index].id]?.isMovable == true else {
                    index += 1
                    continue
                }
                let start = index
                while index < sectionItems.count,
                      currentByID[sectionItems[index].id]?.isMovable == true
                {
                    index += 1
                }
                let run = Array(sectionItems[start ..< index])
                let leftAnchor = start > 0 ? sectionItems[start - 1] : sectionBoundaries.left
                let rightAnchor = index < sectionItems.count
                    ? sectionItems[index]
                    : sectionBoundaries.right
                let leftValue = try resolvedBoundaryValue(
                    leftAnchor,
                    positions: workingPositions,
                    keysByItemID: keysByItemID
                )
                let rightValue = try resolvedBoundaryValue(
                    rightAnchor,
                    positions: workingPositions,
                    keysByItemID: keysByItemID
                )
                let runKeys = try run.map { item -> String in
                    guard let key = keysByItemID[item.id], workingPositions[key] != nil else {
                        throw GoldenGatePositionTableError.unresolvedItem
                    }
                    return key
                }
                let mutableKeys = Set(runKeys)
                let occupied = Set(workingPositions.compactMap { key, value in
                    mutableKeys.contains(key) ? nil : value
                })
                let proposed = try respacedValues(
                    count: run.count,
                    leftBoundary: leftValue,
                    rightBoundary: rightValue,
                    occupied: occupied,
                    axis: axis
                )
                for (key, proposedValue) in zip(runKeys, proposed) {
                    guard let original = positions[key] else {
                        throw GoldenGatePositionTableError.unresolvedItem
                    }
                    workingPositions[key] = proposedValue
                    if original != proposedValue {
                        changes.append(GoldenGatePositionChange(
                            key: key,
                            originalValue: original,
                            proposedValue: proposedValue
                        ))
                    }
                }
            }
        }
        return GoldenGatePositionMutation(changes: changes)
    }

    /// Saved layouts constrain shared items only. A newly launched app is not
    /// deleted, moved, or treated as a verification failure.
    public static func restoreMatches(
        target: MenuBarSnapshot,
        current: MenuBarSnapshot,
        requiredItemIDs: Set<MenuBarItemID>
    ) -> Bool {
        let currentIDs = Set(current.items.map(\.id))
        guard requiredItemIDs.isSubset(of: currentIDs) else { return false }
        let sharedTargetItems = target.items.filter {
            requiredItemIDs.contains($0.id)
        }
        for section in MenuBarSection.allCases {
            let expected = sharedTargetItems
                .filter { $0.section == section }
                .sorted(by: physicalOrder)
                .map(\.id)
            let expectedSet = Set(expected)
            let actual = current.items
                .filter { $0.section == section && expectedSet.contains($0.id) }
                .sorted(by: physicalOrder)
                .map(\.id)
            if actual != expected {
                return false
            }
        }
        return sharedTargetItems.allSatisfy { targetItem in
            current.items.first(where: { $0.id == targetItem.id })?.section == targetItem.section
        }
    }

    /// Produces a rollback only while the live value still equals the value
    /// Barline attempted. A concurrent user or system change always wins.
    public static func conditionalRollback(
        for mutation: GoldenGatePositionMutation,
        currentPositions: [String: Int]
    ) -> GoldenGatePositionMutation? {
        guard !mutation.changes.isEmpty,
              mutation.changes.allSatisfy({ currentPositions[$0.key] == $0.proposedValue })
        else { return nil }
        return GoldenGatePositionMutation(changes: mutation.changes.map {
            GoldenGatePositionChange(
                key: $0.key,
                originalValue: $0.proposedValue,
                proposedValue: $0.originalValue
            )
        })
    }

    /// Rebases a journaled mutation onto the latest coordinated table. Only
    /// the named keys change; unrelated system writes remain authoritative.
    public static func rebasedPositions(
        applying mutation: GoldenGatePositionMutation,
        to currentPositions: [String: Int]
    ) -> [String: Int]? {
        guard !mutation.changes.isEmpty,
              mutation.changes.allSatisfy({
                  currentPositions[$0.key] == $0.originalValue
              })
        else { return nil }
        var result = currentPositions
        for change in mutation.changes {
            result[change.key] = change.proposedValue
        }
        return result
    }

    public enum AxisDirection: Equatable, Sendable {
        case ascendingLeftToRight
        case descendingLeftToRight
    }

    private struct DesiredLayout {
        let ordered: [MenuBarItemDescriptor]
        let desired: [MenuBarItemDescriptor]
        let desiredIndex: Int
    }

    private static func desiredLayout(
        _ operation: MenuBarMoveOperation,
        in snapshot: MenuBarSnapshot
    ) throws -> DesiredLayout {
        let ordered = snapshot.items.sorted(by: physicalOrder)
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == operation.itemID }) else {
            throw GoldenGatePositionTableError.unresolvedItem
        }
        let source = ordered[sourceIndex]
        guard source.isMovable else {
            throw MenuBarBackendError.operationFailed("menu bar item cannot be assigned independently")
        }
        if operation.section != .visible, !source.canBeHidden {
            throw MenuBarBackendError.operationFailed("menu bar item cannot be hidden")
        }
        let withoutSource = ordered.filter { $0.id != source.id }
        let previousDestinationItems = ordered.filter {
            $0.section == operation.section
        }
        var insertionIndex = min(max(operation.index, 0), previousDestinationItems.count)
        if let priorSourceIndex = previousDestinationItems.firstIndex(where: {
            $0.id == source.id
        }), priorSourceIndex < insertionIndex {
            // MenuBarMoveOperation indices are insertion offsets in the
            // pre-move section. Removing an earlier same-section source shifts
            // that offset left, matching MenuBarMovePlanner.resultMatches.
            insertionIndex -= 1
        }
        let destinationItems = withoutSource.filter {
            $0.section == operation.section && !$0.isBarlineControlItem
        }
        insertionIndex = min(insertionIndex, destinationItems.count)
        let leftItem = insertionIndex > 0 ? destinationItems[insertionIndex - 1] : nil
        let rightItem = insertionIndex < destinationItems.count
            ? destinationItems[insertionIndex]
            : nil
        let controlPairs: [(String, MenuBarItemDescriptor)] = ordered.compactMap { item in
            guard item.isBarlineControlItem, let title = item.title else { return nil }
            return (title, item)
        }
        let controls = Dictionary(uniqueKeysWithValues: controlPairs)
        let sectionBoundaries = try boundaries(
            for: operation.section,
            leftItem: leftItem,
            rightItem: rightItem,
            controls: controls
        )
        let insertionOffset: Int
        if let right = sectionBoundaries.right,
           let rightIndex = withoutSource.firstIndex(where: { $0.id == right.id })
        {
            insertionOffset = rightIndex
        } else if let left = sectionBoundaries.left,
                  let leftIndex = withoutSource.firstIndex(where: { $0.id == left.id })
        {
            insertionOffset = leftIndex + 1
        } else {
            throw GoldenGatePositionTableError.unresolvedDivider
        }
        var desired = withoutSource
        desired.insert(source, at: insertionOffset)
        guard let desiredIndex = desired.firstIndex(where: { $0.id == source.id }) else {
            throw GoldenGatePositionTableError.unresolvedItem
        }
        return DesiredLayout(
            ordered: ordered,
            desired: desired,
            desiredIndex: desiredIndex
        )
    }

    private static func proposedSourceValue(
        sourceKey: String,
        desiredIndex: Int,
        desired: [MenuBarItemDescriptor],
        positions: [String: Int],
        keysByItemID: [MenuBarItemID: String],
        axis: AxisDirection
    ) -> Int? {
        let leftItem = desiredIndex > 0 ? desired[desiredIndex - 1] : nil
        let rightItem = desiredIndex + 1 < desired.count ? desired[desiredIndex + 1] : nil
        let leftValue = leftItem.flatMap { item in
            keysByItemID[item.id].flatMap { positions[$0] }
        }
        let rightValue = rightItem.flatMap { item in
            keysByItemID[item.id].flatMap { positions[$0] }
        }
        guard leftItem == nil || leftValue != nil,
              rightItem == nil || rightValue != nil
        else { return nil }
        let occupied = Set(positions.filter { $0.key != sourceKey }.map(\.value))
        let proposed: Int?
        switch (leftValue, rightValue) {
        case let (left?, right?):
            let lower = min(left, right)
            let upper = max(left, right)
            let (distance, overflowed) = upper.subtractingReportingOverflow(lower)
            guard !overflowed, distance > 1 else { return nil }
            proposed = lower + distance / 2
        case let (left?, nil):
            proposed = offsetFromEdge(
                left,
                delta: axis == .ascendingLeftToRight ? 1024 : -1024
            )
        case let (nil, right?):
            proposed = offsetFromEdge(
                right,
                delta: axis == .ascendingLeftToRight ? -1024 : 1024
            )
        case (nil, nil):
            proposed = nil
        }
        guard let proposed, !occupied.contains(proposed) else { return nil }
        return proposed
    }

    private static func offsetFromEdge(_ value: Int, delta: Int) -> Int? {
        let (result, overflowed) = value.addingReportingOverflow(delta)
        return overflowed ? nil : result
    }

    private static func respacedDestinationChanges(
        operation: MenuBarMoveOperation,
        desired: [MenuBarItemDescriptor],
        positions: [String: Int],
        keysByItemID: [MenuBarItemID: String],
        axis: AxisDirection
    ) throws -> [GoldenGatePositionChange] {
        let destinationItems = desired.filter {
            !$0.isBarlineControlItem &&
                ($0.id == operation.itemID || $0.section == operation.section)
        }
        // Re-spacing is a last-resort fallback. Treat every protected or
        // system-owned item as an immovable anchor rather than rewriting its
        // position. If an anchor makes the local integer interval too tight,
        // fail closed and let the user arrange the native menu bar directly.
        guard destinationItems.allSatisfy({
            $0.id == operation.itemID || $0.isMovable
        }) else {
            throw GoldenGatePositionTableError.unresolvedAffectedItem
        }
        let items = destinationItems.filter { $0.id == operation.itemID || $0.isMovable }
        guard !items.isEmpty else {
            throw GoldenGatePositionTableError.unresolvedAffectedItem
        }
        let resolved = try items.map { item -> (key: String, value: Int) in
            guard let key = keysByItemID[item.id], let value = positions[key] else {
                throw GoldenGatePositionTableError.unresolvedAffectedItem
            }
            return (key, value)
        }
        let controls = Dictionary(uniqueKeysWithValues: desired.compactMap {
            item -> (String, MenuBarItemDescriptor)? in
            guard item.isBarlineControlItem, let title = item.title else { return nil }
            return (title, item)
        })
        let hidden = controls["Barline.ControlItem.Hidden"]
        let alwaysHidden = controls["Barline.ControlItem.AlwaysHidden"]
        let boundaryItems: (left: MenuBarItemDescriptor?, right: MenuBarItemDescriptor?) =
            switch operation.section {
            case .visible: (hidden, nil)
            case .hidden: (alwaysHidden, hidden)
            case .alwaysHidden: (nil, alwaysHidden)
            }
        let boundaryValues = try (
            left: resolvedBoundaryValue(
                boundaryItems.left,
                positions: positions,
                keysByItemID: keysByItemID
            ),
            right: resolvedBoundaryValue(
                boundaryItems.right,
                positions: positions,
                keysByItemID: keysByItemID
            )
        )
        guard boundaryValues.left != nil || boundaryValues.right != nil else {
            throw GoldenGatePositionTableError.unresolvedDivider
        }

        let mutableKeys = Set(resolved.map(\.key))
        let occupied = Set(positions.compactMap { key, value in
            mutableKeys.contains(key) ? nil : value
        })
        let proposedValues = try respacedValues(
            count: resolved.count,
            leftBoundary: boundaryValues.left,
            rightBoundary: boundaryValues.right,
            occupied: occupied,
            axis: axis
        )
        return zip(resolved, proposedValues).compactMap { current, proposed in
            guard current.value != proposed else { return nil }
            return GoldenGatePositionChange(
                key: current.key,
                originalValue: current.value,
                proposedValue: proposed
            )
        }
    }

    private static func resolvedBoundaryValue(
        _ item: MenuBarItemDescriptor?,
        positions: [String: Int],
        keysByItemID: [MenuBarItemID: String]
    ) throws -> Int? {
        guard let item else { return nil }
        guard let key = keysByItemID[item.id], let value = positions[key] else {
            throw GoldenGatePositionTableError.unresolvedDivider
        }
        return value
    }

    private static func respacedValues(
        count: Int,
        leftBoundary: Int?,
        rightBoundary: Int?,
        occupied: Set<Int>,
        axis: AxisDirection
    ) throws -> [Int] {
        let direction = axis == .ascendingLeftToRight ? 1 : -1
        if let leftBoundary, let rightBoundary {
            var result = [Int]()
            var candidate = leftBoundary
            while result.count < count {
                let (next, overflowed) = candidate.addingReportingOverflow(direction)
                guard !overflowed else {
                    throw GoldenGatePositionTableError.inconsistentPositionOrder
                }
                candidate = next
                let reachedRight = direction > 0
                    ? candidate >= rightBoundary
                    : candidate <= rightBoundary
                guard !reachedRight else {
                    throw GoldenGatePositionTableError.inconsistentPositionOrder
                }
                if !occupied.contains(candidate) {
                    result.append(candidate)
                }
            }
            return result
        }

        if let leftBoundary {
            var distance = 1
            while distance <= occupied.count + count + 1 {
                let values = try offsetSequence(
                    from: leftBoundary,
                    firstDistance: distance,
                    count: count,
                    direction: direction
                )
                if values.allSatisfy({ !occupied.contains($0) }) {
                    return values
                }
                distance += 1
            }
        }

        if let rightBoundary {
            var distance = 1
            while distance <= occupied.count + count + 1 {
                let farthestDistance = distance + count - 1
                let values = try (0 ..< count).map { index in
                    let magnitude = farthestDistance - index
                    let (value, overflowed) = rightBoundary
                        .addingReportingOverflow(-direction * magnitude)
                    guard !overflowed else {
                        throw GoldenGatePositionTableError.inconsistentPositionOrder
                    }
                    return value
                }
                if values.allSatisfy({ !occupied.contains($0) }) {
                    return values
                }
                distance += 1
            }
        }
        throw GoldenGatePositionTableError.inconsistentPositionOrder
    }

    private static func offsetSequence(
        from boundary: Int,
        firstDistance: Int,
        count: Int,
        direction: Int
    ) throws -> [Int] {
        try (0 ..< count).map { index in
            let magnitude = firstDistance + index
            let (value, overflowed) = boundary
                .addingReportingOverflow(direction * magnitude)
            guard !overflowed else {
                throw GoldenGatePositionTableError.inconsistentPositionOrder
            }
            return value
        }
    }

    public static func resolvedAxisDirection(
        snapshot: MenuBarSnapshot,
        positions: [String: Int],
        keysByItemID: [MenuBarItemID: String],
        excludingItemIDs: Set<MenuBarItemID> = []
    ) throws -> AxisDirection {
        let resolved = snapshot.items.compactMap { item -> (x: Double, value: Int)? in
            // Retained descriptors deliberately keep their last-known bounds
            // after macOS removes the AX node. Those coordinates can be stale
            // after later moves, so they must never determine the table axis.
            guard item.isOnScreen, !excludingItemIDs.contains(item.id) else { return nil }
            guard let key = keysByItemID[item.id], let value = positions[key] else { return nil }
            return (item.bounds.x + item.bounds.width / 2, value)
        }.sorted { $0.x < $1.x }

        var ascendingVotes = 0
        var descendingVotes = 0
        for leftIndex in resolved.indices {
            for rightIndex in resolved.index(after: leftIndex) ..< resolved.endIndex {
                let left = resolved[leftIndex]
                let right = resolved[rightIndex]
                guard left.x != right.x, left.value != right.value else { continue }
                if left.value < right.value {
                    ascendingVotes += 1
                } else {
                    descendingVotes += 1
                }
            }
        }
        let totalVotes = ascendingVotes + descendingVotes
        guard totalVotes > 0 else {
            throw GoldenGatePositionTableError.ambiguousAxis
        }
        // A transient AX animation or stale geometry sample must never let one
        // pair invert the entire native position table. Require at least 80%
        // agreement across every comparable live pair; otherwise fail closed
        // and let the bounded caller retry with a fresh snapshot.
        if ascendingVotes > descendingVotes,
           ascendingVotes * 5 >= totalVotes * 4
        {
            return .ascendingLeftToRight
        }
        if descendingVotes > ascendingVotes,
           descendingVotes * 5 >= totalVotes * 4
        {
            return .descendingLeftToRight
        }
        throw GoldenGatePositionTableError.ambiguousAxis
    }

    private static func boundaries(
        for section: MenuBarSection,
        leftItem: MenuBarItemDescriptor?,
        rightItem: MenuBarItemDescriptor?,
        controls: [String: MenuBarItemDescriptor]
    ) throws -> (left: MenuBarItemDescriptor?, right: MenuBarItemDescriptor?) {
        let hidden = controls["Barline.ControlItem.Hidden"]
        let alwaysHidden = controls["Barline.ControlItem.AlwaysHidden"]
        switch section {
        case .visible:
            guard let hidden else { throw GoldenGatePositionTableError.unresolvedDivider }
            return (leftItem ?? hidden, rightItem)
        case .hidden:
            guard let hidden else { throw GoldenGatePositionTableError.unresolvedDivider }
            return (leftItem ?? alwaysHidden, rightItem ?? hidden)
        case .alwaysHidden:
            guard let alwaysHidden else { throw GoldenGatePositionTableError.unresolvedDivider }
            return (leftItem, rightItem ?? alwaysHidden)
        }
    }

    private static func physicalOrder(
        _ lhs: MenuBarItemDescriptor,
        _ rhs: MenuBarItemDescriptor
    ) -> Bool {
        if !lhs.isOnScreen || !rhs.isOnScreen {
            return lhs.order < rhs.order
        }
        if lhs.bounds.x != rhs.bounds.x {
            return lhs.bounds.x < rhs.bounds.x
        }
        return lhs.order < rhs.order
    }

    private static func uniqueCaseInsensitiveMatch(
        _ expected: String,
        in keys: [String]
    ) -> String? {
        let matches = keys.filter { $0.caseInsensitiveCompare(expected) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func statusOwner(in key: String) -> String? {
        guard key.lowercased().hasPrefix(statusPrefix),
              let separator = key.range(of: keySeparator)
        else { return nil }
        return String(key[key.index(key.startIndex, offsetBy: statusPrefix.count) ..< separator.lowerBound])
    }
}
