import Foundation

/// Merges a saved ordering with newly discovered items. Unspecified items and
/// immovable items keep their mutual order; saved movable items may move around
/// those anchors. This computes a target, not permission to synthesize events.
public enum ProfileLayoutReconciler {
    public enum Failure: Error, Equatable, Sendable {
        case ambiguousIdentity
        case missingItem
        case immovableSectionChange
        case immovableOrderChange
        case cannotHideItem
        case unsupportedDestination
    }

    public struct Plan: Equatable, Sendable {
        public let target: ProfileLayout
        public let operations: [MenuBarMoveOperation]
    }

    public struct ScopedTarget: Equatable, Sendable {
        public let displayID: MenuBarDisplayID?
        public let layout: ProfileLayout
    }

    public struct DisplayPlan: Equatable, Sendable {
        public let targets: [ScopedTarget]
        public let operations: [MenuBarMoveOperation]
        public let isGloballyScoped: Bool

        /// Validate the complete admitted target, including preserved anchors.
        /// A new or missing item during execution invalidates this transaction.
        public func matches(items: [MenuBarItemDescriptor]) -> Bool {
            guard Set(items.map(\.id)).count == items.count else { return false }
            if isGloballyScoped,
               Set(items.map(\.id)) != Set(targets.flatMap(\.layout.allItemIDs))
            {
                return false
            }
            return targets.allSatisfy { target in
                ProfileLayoutReconciler.observedLayout(
                    items: items.filter { $0.displayID == target.displayID }
                ) == target.layout
            }
        }
    }

    /// Authority is based on the same fixed-anchor ordering as activation, not
    /// a saved prefix that would incorrectly displace newly discovered items.
    public static func matches(
        layout: ProfileLayout,
        items: [MenuBarItemDescriptor],
        displayID: MenuBarDisplayID? = nil,
        destinationSupport: MenuBarMoveDestinationSupport = .existingItemRequired
    ) -> Bool {
        if destinationSupport == .logicalSectionsPreserveNativeOrder {
            guard let plan = try? planAcrossDisplays(
                layout: layout,
                items: items,
                displayID: displayID,
                destinationSupport: destinationSupport
            ) else { return false }
            return plan.matches(items: items)
        }
        guard Set(items.map(\.id)).count == items.count,
              Set(layout.allItemIDs).count == layout.allItemIDs.count
        else { return false }
        let scoped = displayID.map { display in items.filter { $0.displayID == display } } ?? items
        let known = Set(scoped.map(\.id))
        guard layout.allItemIDs.allSatisfy({ known.contains($0) }) else { return false }
        return Set(scoped.map(\.displayID)).allSatisfy { display in
            let localItems = scoped.filter { $0.displayID == display }
            let ids = Set(localItems.map(\.id))
            let localLayout = ProfileLayout(
                visible: layout.visible.filter { ids.contains($0) },
                hidden: layout.hidden.filter { ids.contains($0) },
                alwaysHidden: layout.alwaysHidden.filter { ids.contains($0) }
            )
            if observedLayout(items: localItems) == localLayout {
                return true
            }
            guard let target = try? reconcile(layout: localLayout, items: localItems) else { return false }
            return observedLayout(items: localItems) == target
        }
    }

    private static func observedLayout(items: [MenuBarItemDescriptor]) -> ProfileLayout {
        let ordered = items.sorted { $0.order < $1.order }
        return ProfileLayout(
            visible: ordered.filter { $0.section == .visible }.map(\.id),
            hidden: ordered.filter { $0.section == .hidden }.map(\.id),
            alwaysHidden: ordered.filter { $0.section == .alwaysHidden }.map(\.id)
        )
    }

    /// Separators are draggable in the native menu bar, but moving one changes
    /// section membership for neighboring items. A saved-layout transaction must
    /// move items across these boundaries, never move the boundaries themselves.
    private static func canReposition(_ item: MenuBarItemDescriptor) -> Bool {
        item.isMovable && !item.isBarlineControlItem
    }

    private static func validateBoundaryOrder(
        _ ids: [MenuBarItemID], section: MenuBarSection,
        known: [MenuBarItemID: MenuBarItemDescriptor]
    ) throws {
        let title: String
        switch section {
        case .visible: return
        case .hidden: title = "Barline.ControlItem.Hidden"
        case .alwaysHidden: title = "Barline.ControlItem.AlwaysHidden"
        }
        for display in Set(ids.compactMap { known[$0] }.map(\.displayID)) {
            let local = ids.filter { known[$0]?.displayID == display }
            let boundaries = local.filter { known[$0]?.isBarlineControlItem == true && known[$0]?.title == title }
            guard boundaries.count <= 1 else { throw Failure.ambiguousIdentity }
            if let boundary = boundaries.first, local.last != boundary {
                throw Failure.unsupportedDestination
            }
        }
    }

    /// Compose display-local plans while translating each operation against the
    /// simulated global section state, exactly as the helper indexes candidates.
    public static func planAcrossDisplays(
        layout: ProfileLayout,
        items: [MenuBarItemDescriptor],
        displayID: MenuBarDisplayID? = nil,
        destinationSupport: MenuBarMoveDestinationSupport = .existingItemRequired
    ) throws -> DisplayPlan {
        guard Set(items.map(\.id)).count == items.count,
              Set(layout.allItemIDs).count == layout.allItemIDs.count
        else { throw Failure.ambiguousIdentity }
        let scopedItems = displayID.map { display in items.filter { $0.displayID == display } } ?? items
        let known = Dictionary(uniqueKeysWithValues: scopedItems.map { ($0.id, $0) })
        guard layout.allItemIDs.allSatisfy({ known[$0] != nil }) else { throw Failure.missingItem }
        let displays = Set(scopedItems.map(\.displayID)).sorted { ($0?.value ?? "") < ($1?.value ?? "") }
        let allKnown = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var global = Dictionary(uniqueKeysWithValues: MenuBarSection.allCases.map { section in
            (section, items.filter { $0.section == section }.sorted { $0.order < $1.order }.map(\.id))
        })
        var targets = [ScopedTarget]()
        var operations = [MenuBarMoveOperation]()
        for display in displays {
            let localItems = scopedItems.filter { $0.displayID == display }
            let ids = Set(localItems.map(\.id))
            let localLayout = ProfileLayout(
                visible: layout.visible.filter { ids.contains($0) },
                hidden: layout.hidden.filter { ids.contains($0) },
                alwaysHidden: layout.alwaysHidden.filter { ids.contains($0) }
            )
            let localPlan = try plan(layout: localLayout, items: localItems, destinationSupport: destinationSupport)
            targets.append(ScopedTarget(displayID: display, layout: localPlan.target))
            for operation in localPlan.operations {
                let destination = global[operation.section] ?? []
                let localDestination = destination.filter { allKnown[$0]?.displayID == display }
                let insertion: Int
                if operation.index < localDestination.count {
                    guard let index = destination.firstIndex(of: localDestination[operation.index]) else {
                        throw Failure.unsupportedDestination
                    }
                    insertion = index
                } else if localDestination.isEmpty, destinationSupport != .existingItemRequired {
                    insertion = destination.count
                } else {
                    guard let last = localDestination.last,
                          let index = destination.firstIndex(of: last)
                    else { throw Failure.unsupportedDestination }
                    insertion = index + 1
                }
                guard let sourceSection = global.first(where: { $0.value.contains(operation.itemID) })?.key,
                      let sourceIndex = global[sourceSection]?.firstIndex(of: operation.itemID)
                else { throw Failure.missingItem }
                let adjusted = insertion - (sourceSection == operation.section && sourceIndex < insertion ? 1 : 0)
                global[sourceSection]?.remove(at: sourceIndex)
                global[operation.section]?.insert(operation.itemID, at: adjusted)
                operations.append(MenuBarMoveOperation(
                    itemID: operation.itemID, section: operation.section,
                    index: insertion, destinationDisplayID: display
                ))
            }
        }
        return DisplayPlan(targets: targets, operations: operations, isGloballyScoped: displayID == nil)
    }

    /// Plan one display's layout using the helper's pre-removal insertion indices.
    /// The caller must retain generation ownership and verify the complete target.
    public static func plan(
        layout: ProfileLayout,
        items: [MenuBarItemDescriptor],
        destinationSupport: MenuBarMoveDestinationSupport = .existingItemRequired
    ) throws -> Plan {
        guard Set(items.map(\.displayID)).count <= 1 else {
            throw Failure.unsupportedDestination
        }
        if destinationSupport == .logicalSectionsPreserveNativeOrder {
            return try logicalSectionPlan(layout: layout, items: items)
        }
        let target = try reconcile(layout: layout, items: items)
        let selected = Set(layout.allItemIDs)
        let known = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var current = Dictionary(uniqueKeysWithValues: MenuBarSection.allCases.map { section in
            (section, items.filter { $0.section == section }.sorted { $0.order < $1.order }.map(\.id))
        })
        var operations = [MenuBarMoveOperation]()
        for (section, desired) in [
            (MenuBarSection.visible, target.visible), (.hidden, target.hidden), (.alwaysHidden, target.alwaysHidden),
        ] {
            for position in desired.indices.reversed() {
                let id = desired[position]
                guard selected.contains(id), let item = known[id], canReposition(item) else { continue }
                guard let sourceSection = current.first(where: { $0.value.contains(id) })?.key,
                      let sourcePosition = current[sourceSection]?.firstIndex(of: id)
                else { throw Failure.missingItem }
                let next = position + 1 < desired.count ? desired[position + 1] : nil
                let destination = current[section] ?? []
                let insertion: Int
                if let next {
                    guard let nextPosition = destination.firstIndex(of: next) else {
                        throw Failure.unsupportedDestination
                    }
                    insertion = nextPosition
                } else {
                    insertion = destination.count
                }
                let adjusted = insertion - (sourceSection == section && sourcePosition < insertion ? 1 : 0)
                if sourceSection == section, sourcePosition == adjusted {
                    continue
                }
                // The current helper needs another item as a physical destination.
                guard destinationSupport != .existingItemRequired || destination.contains(where: { $0 != id }) else {
                    throw Failure.unsupportedDestination
                }
                operations.append(MenuBarMoveOperation(
                    itemID: id, section: section, index: insertion,
                    destinationDisplayID: known[id]?.displayID
                ))
                current[sourceSection]?.remove(at: sourcePosition)
                current[section]?.insert(id, at: adjusted)
            }
        }
        guard current[.visible] == target.visible,
              current[.hidden] == target.hidden,
              current[.alwaysHidden] == target.alwaysHidden
        else { throw Failure.unsupportedDestination }
        return Plan(target: target, operations: operations)
    }

    /// macOS 27 can assign a status item to a visibility section without
    /// changing its native order. Build a target and operations that preserve
    /// that order, including the physical position of Barline's controls.
    private static func logicalSectionPlan(
        layout: ProfileLayout,
        items: [MenuBarItemDescriptor]
    ) throws -> Plan {
        let target = try logicalSectionTarget(layout: layout, items: items)
        let requestedSections = requestedSections(for: layout)
        let ordered = items.sorted { $0.order < $1.order }
        var operations = [MenuBarMoveOperation]()
        for item in ordered {
            guard let section = requestedSections[item.id], section != item.section else { continue }
            let destination = target.ids(in: section)
            guard let index = destination.firstIndex(of: item.id) else {
                throw Failure.unsupportedDestination
            }
            operations.append(MenuBarMoveOperation(
                itemID: item.id,
                section: section,
                index: index,
                destinationDisplayID: item.displayID
            ))
        }
        return Plan(target: target, operations: operations)
    }

    private static func logicalSectionTarget(
        layout: ProfileLayout,
        items: [MenuBarItemDescriptor]
    ) throws -> ProfileLayout {
        guard Set(layout.allItemIDs).count == layout.allItemIDs.count,
              Set(items.map(\.id)).count == items.count
        else { throw Failure.ambiguousIdentity }
        let known = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let requestedSections = requestedSections(for: layout)
        guard requestedSections.keys.allSatisfy({ known[$0] != nil }) else {
            throw Failure.missingItem
        }
        for (itemID, section) in requestedSections {
            guard let item = known[itemID] else { throw Failure.missingItem }
            if item.section != section, !canReposition(item) {
                throw Failure.immovableSectionChange
            }
            if item.section != section, section != .visible, !item.canBeHidden {
                throw Failure.cannotHideItem
            }
        }

        let ordered = items.sorted { $0.order < $1.order }
        let target = ProfileLayout(
            visible: ordered.filter {
                requestedSections[$0.id, default: $0.section] == .visible
            }.map(\.id),
            hidden: ordered.filter {
                requestedSections[$0.id, default: $0.section] == .hidden
            }.map(\.id),
            alwaysHidden: ordered.filter {
                requestedSections[$0.id, default: $0.section] == .alwaysHidden
            }.map(\.id)
        )
        let selected = Set(layout.allItemIDs)
        for section in MenuBarSection.allCases {
            let requested = layout.ids(in: section).filter { known[$0]?.isBarlineControlItem != true }
            let native = target.ids(in: section).filter {
                selected.contains($0) && known[$0]?.isBarlineControlItem != true
            }
            guard requested == native else { throw Failure.immovableOrderChange }
        }
        return target
    }

    private static func requestedSections(
        for layout: ProfileLayout
    ) -> [MenuBarItemID: MenuBarSection] {
        Dictionary(uniqueKeysWithValues: MenuBarSection.allCases.flatMap { section in
            layout.ids(in: section).map { ($0, section) }
        })
    }

    public static func reconcile(
        layout: ProfileLayout,
        items: [MenuBarItemDescriptor]
    ) throws -> ProfileLayout {
        let requested = layout.allItemIDs
        guard Set(requested).count == requested.count,
              Set(items.map(\.id)).count == items.count
        else { throw Failure.ambiguousIdentity }
        let known = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        guard requested.allSatisfy({ known[$0] != nil }) else { throw Failure.missingItem }
        let selected = Set(requested)
        let sections: [(MenuBarSection, [MenuBarItemID])] = [
            (.visible, layout.visible), (.hidden, layout.hidden), (.alwaysHidden, layout.alwaysHidden),
        ]
        for (section, desired) in sections {
            for id in desired {
                guard let item = known[id] else { throw Failure.missingItem }
                if !canReposition(item), item.section != section {
                    throw Failure.immovableSectionChange
                }
                if section != .visible, !item.canBeHidden, item.section != section {
                    throw Failure.cannotHideItem
                }
            }
        }
        var merged = [MenuBarSection: [MenuBarItemID]]()
        for (section, desired) in sections {
            let anchors = items.filter {
                $0.section == section && (!selected.contains($0.id) || !canReposition($0))
            }.sorted { $0.order < $1.order }.map(\.id)
            let fixedRequested = desired.filter { known[$0].map { !canReposition($0) } == true }
            guard anchors.filter({ selected.contains($0) }) == fixedRequested else {
                throw Failure.immovableOrderChange
            }
            var result = [MenuBarItemID]()
            var anchorIndex = 0
            for id in desired {
                if known[id].map({ !canReposition($0) }) == true {
                    // Preserve newly discovered anchors before this fixed item.
                    while anchorIndex < anchors.count {
                        let anchor = anchors[anchorIndex]
                        result.append(anchor)
                        anchorIndex += 1
                        if anchor == id {
                            break
                        }
                    }
                } else {
                    result.append(id)
                }
            }
            result.append(contentsOf: anchors.dropFirst(anchorIndex))
            try validateBoundaryOrder(result, section: section, known: known)
            merged[section] = result
        }
        return ProfileLayout(
            visible: merged[.visible] ?? [],
            hidden: merged[.hidden] ?? [],
            alwaysHidden: merged[.alwaysHidden] ?? []
        )
    }
}

private extension ProfileLayout {
    func ids(in section: MenuBarSection) -> [MenuBarItemID] {
        switch section {
        case .visible: visible
        case .hidden: hidden
        case .alwaysHidden: alwaysHidden
        }
    }
}
