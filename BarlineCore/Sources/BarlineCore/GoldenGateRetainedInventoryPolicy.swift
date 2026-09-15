import Foundation

/// Reconciles macOS 27's transient Accessibility inventory with Barline's
/// committed logical inventory. Native concealment may remove an item from the
/// AX tree, but that must not erase the item users need in order to reveal it.
public enum GoldenGateRetainedInventoryPolicy {
    public static func merging(
        live snapshot: MenuBarSnapshot,
        retainedDescriptors: [MenuBarItemID: MenuBarItemDescriptor],
        assignments: [MenuBarItemID: GoldenGateLogicalAssignment],
        runningBundleIdentifiers: Set<String>,
        barlineBundleIdentifier: String
    ) -> MenuBarSnapshot {
        let normalizedRunningBundles = Set(runningBundleIdentifiers.map {
            $0.lowercased()
        })
        let liveIDSet = Set(snapshot.items.map(\.id))
        let fallbackDisplayID = snapshot.displayIDs.count == 1
            ? snapshot.displayIDs.first
            : nil

        let retained = assignments.values
            .filter { assignment in
                assignment.section != .visible &&
                    !liveIDSet.contains(assignment.itemID) &&
                    assignment.itemID.isPlausiblyStable &&
                    normalizedRunningBundles.contains(
                        assignment.itemID.bundleIdentifier.lowercased()
                    )
            }
            .compactMap { assignment -> MenuBarItemDescriptor? in
                guard let descriptor = retainedDescriptors[assignment.itemID],
                      !descriptor.isBarlineControlItem
                else { return nil }
                let displayID = descriptor.displayID.flatMap {
                    snapshot.displayIDs.contains($0) ? $0 : nil
                } ?? fallbackDisplayID
                return MenuBarItemDescriptor(
                    id: descriptor.id,
                    section: assignment.section,
                    // `order` is global native order. Section-relative ranks
                    // are not a safe substitute after AX drops a hidden item.
                    order: descriptor.order,
                    displayID: displayID,
                    isSystemItem: descriptor.isSystemItem,
                    sourceOwnership: descriptor.sourceOwnership,
                    isBarlineControlItem: false,
                    tagNamespace: descriptor.tagNamespace,
                    title: descriptor.title,
                    displayName: descriptor.displayName,
                    bounds: .zero,
                    isOnScreen: false,
                    isMovable: false,
                    canBeHidden: descriptor.canBeHidden,
                    isBentoBox: descriptor.isBentoBox,
                    isSystemClone: descriptor.isSystemClone,
                    isResponsive: descriptor.isResponsive
                )
            }

        let retainedByID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        let liveByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        let eligibleIDs = Set(liveByID.keys).union(retainedByID.keys)
        let previousOrder = retainedDescriptors.values
            .filter { eligibleIDs.contains($0.id) }
            .sorted {
                $0.order == $1.order
                    ? $0.id.description < $1.id.description
                    : $0.order < $1.order
            }
            .map(\.id)

        // Keep prior slots for AX-absent items, while letting the current live
        // sequence authoritatively reorder every item it can still observe.
        let previousIDSet = Set(previousOrder)
        var currentKnownLive = snapshot.items.map(\.id).filter(previousIDSet.contains)
        var orderedIDs = previousOrder.map { priorID -> MenuBarItemID in
            if liveByID[priorID] != nil, !currentKnownLive.isEmpty {
                return currentKnownLive.removeFirst()
            }
            return priorID
        }

        // Insert newly observed live items adjacent to their nearest live
        // neighbor. This preserves live AX order without moving retained gaps.
        let liveIDs = snapshot.items.map(\.id)
        for (liveIndex, liveID) in liveIDs.enumerated() where !orderedIDs.contains(liveID) {
            if let nextID = liveIDs.dropFirst(liveIndex + 1).first(where: orderedIDs.contains),
               let index = orderedIDs.firstIndex(of: nextID)
            {
                orderedIDs.insert(liveID, at: index)
            } else if let previousID = liveIDs[..<liveIndex].last(where: orderedIDs.contains),
                      let index = orderedIDs.firstIndex(of: previousID)
            {
                orderedIDs.insert(liveID, at: index + 1)
            } else {
                orderedIDs.append(liveID)
            }
        }

        let ordered = orderedIDs.compactMap { liveByID[$0] ?? retainedByID[$0] }
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: ordered.filter { !$0.isBarlineControlItem && $0.section == .visible }.map(\.id),
            concealedItemIDs: ordered.filter { !$0.isBarlineControlItem && $0.section != .visible }.map(\.id)
        )
        let resolved = GoldenGateConcealmentPolicy.resolve(
            configuration,
            barlineBundleIdentifier: barlineBundleIdentifier
        )
        let allItemIDs = ordered.map(\.id)
        let items = ordered.enumerated().map { index, item in
            let section = !item.isBarlineControlItem &&
                item.section != .visible &&
                !GoldenGateConcealmentPolicy.supportsConcealing(item.id, in: resolved)
                ? MenuBarSection.visible
                : item.section
            let isMovable = item.canBeHidden &&
                !item.isBarlineControlItem &&
                GoldenGateConcealmentPolicy.supportsIndependentAssignment(
                    item.id,
                    among: allItemIDs,
                    barlineBundleIdentifier: barlineBundleIdentifier
                )
            return item.replacing(section: section, order: index, isMovable: isMovable)
        }
        return MenuBarSnapshot(
            generation: snapshot.generation,
            capturedAt: snapshot.capturedAt,
            items: items,
            displayIDs: snapshot.displayIDs,
            displayIdentities: snapshot.displayIdentities,
            activeSpaceIsValid: snapshot.activeSpaceIsValid,
            menuTrackingIsActive: snapshot.menuTrackingIsActive
        )
    }
}
