import Foundation

/// Reconciles macOS 27's transient Accessibility inventory with Barline's
/// committed logical inventory. Native concealment may remove an item from the
/// AX tree, but that must not erase the item users need in order to reveal it.
public enum GoldenGateRetainedInventoryPolicy {
    public static func merging(
        live snapshot: MenuBarSnapshot,
        retainedDescriptors: [MenuBarItemID: MenuBarItemDescriptor],
        assignments: [MenuBarItemID: GoldenGateLogicalAssignment],
        runningBundleIdentifiers: Set<String>
    ) -> MenuBarSnapshot {
        let normalizedRunningBundles = Set(runningBundleIdentifiers.map {
            $0.lowercased()
        })
        let liveIDs = Set(snapshot.items.map(\.id))
        let fallbackDisplayID = snapshot.displayIDs.count == 1
            ? snapshot.displayIDs.first
            : nil

        let retained = assignments.values
            .filter { assignment in
                assignment.section != .visible &&
                    !liveIDs.contains(assignment.itemID) &&
                    assignment.itemID.isPlausiblyStable &&
                    normalizedRunningBundles.contains(
                        assignment.itemID.bundleIdentifier.lowercased()
                    )
            }
            .sorted { lhs, rhs in
                if lhs.section != rhs.section {
                    return lhs.section.rawValue < rhs.section.rawValue
                }
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.itemID.description < rhs.itemID.description
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
                    order: assignment.rank,
                    displayID: displayID,
                    isSystemItem: descriptor.isSystemItem,
                    sourceOwnership: descriptor.sourceOwnership,
                    isBarlineControlItem: false,
                    tagNamespace: descriptor.tagNamespace,
                    title: descriptor.title,
                    displayName: descriptor.displayName,
                    bounds: .zero,
                    isOnScreen: false,
                    isMovable: descriptor.isMovable,
                    canBeHidden: descriptor.canBeHidden,
                    isBentoBox: descriptor.isBentoBox,
                    isSystemClone: descriptor.isSystemClone,
                    isResponsive: descriptor.isResponsive
                )
            }

        let items = (snapshot.items + retained).enumerated().map { index, item in
            item.replacing(order: index)
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
