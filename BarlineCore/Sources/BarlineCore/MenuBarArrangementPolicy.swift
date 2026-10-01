public enum MenuBarNativeOrderApplication: String, Codable, Equatable, Sendable {
    case applySavedOrder
    case preserveCurrentOrder
}

public enum MenuBarShelfOrderApplication: String, Codable, Equatable, Sendable {
    case applySavedOrder
    case preserveCurrentOrder
}

public struct MenuBarArrangementExecutionPlan: Codable, Equatable, Sendable {
    public let concealment: MenuBarConcealmentConfiguration?
    public let nativeOrder: MenuBarNativeOrderApplication
    public let shelfOrder: MenuBarShelfOrderApplication

    public init(
        concealment: MenuBarConcealmentConfiguration?,
        nativeOrder: MenuBarNativeOrderApplication,
        shelfOrder: MenuBarShelfOrderApplication
    ) {
        self.concealment = concealment
        self.nativeOrder = nativeOrder
        self.shelfOrder = shelfOrder
    }
}

public enum MenuBarArrangementPolicyError: Error, Equatable, Sendable {
    case visibilityUnavailable
    case unsupportedVisibilityAssignment
}

public struct MenuBarArrangementPolicy: Sendable {
    public init() {}

    public func plan(
        layout: ProfileLayout,
        snapshot: MenuBarSnapshot,
        capabilities: MenuBarArrangementCapabilities,
        barlineBundleIdentifier: String
    ) throws -> MenuBarArrangementExecutionPlan {
        let items = snapshot.items.filter { !$0.isBarlineControlItem }
        let known = Set(items.map(\.id))
        let requestedVisible = layout.visible.filter(known.contains)
        let requestedConcealed = (layout.hidden + layout.alwaysHidden).filter(known.contains)
        let requested = Set(requestedVisible + requestedConcealed)
        // Saved layouts are partial: newly discovered items remain at their
        // current sections in the reconciler's target. Validate that same full
        // target here, rather than rejecting an unchanged visible app because
        // it now publishes another item. Never hide an omitted visible sibling
        // merely to make application-level concealment representable.
        let omitted = items.filter { !requested.contains($0.id) }
        let visible = requestedVisible + omitted.filter { $0.section == .visible }.map(\.id)
        let concealed = requestedConcealed + omitted.filter { $0.section != .visible }.map(\.id)
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: visible,
            concealedItemIDs: concealed
        )
        let currentSections = Dictionary(uniqueKeysWithValues: snapshot.items
            .filter { !$0.isBarlineControlItem }
            .map { ($0.id, $0.section) })
        let changesVisibility = visible.contains {
            currentSections[$0] != .visible
        } || concealed.contains {
            currentSections[$0] == .visible
        }

        let concealment: MenuBarConcealmentConfiguration?
        switch capabilities.visibilityAssignmentGranularity {
        case .unavailable:
            guard !changesVisibility else {
                throw MenuBarArrangementPolicyError.visibilityUnavailable
            }
            concealment = nil
        case .item:
            concealment = configuration
        case .applicationGroupAndKnownSystemItem:
            guard GoldenGateConcealmentPolicy.supports(
                configuration,
                allItems: snapshot.items.filter { !$0.isBarlineControlItem }.map(\.id),
                barlineBundleIdentifier: barlineBundleIdentifier
            ) else {
                throw MenuBarArrangementPolicyError.unsupportedVisibilityAssignment
            }
            concealment = configuration
        }

        return MenuBarArrangementExecutionPlan(
            concealment: concealment,
            nativeOrder: capabilities.canApplySavedNativeOrder
                ? .applySavedOrder
                : .preserveCurrentOrder,
            shelfOrder: capabilities.canReorderShelfItems
                ? .applySavedOrder
                : .preserveCurrentOrder
        )
    }
}
