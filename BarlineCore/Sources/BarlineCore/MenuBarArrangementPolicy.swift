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
        let known = Set(snapshot.items.filter { !$0.isBarlineControlItem }.map(\.id))
        let visible = layout.visible.filter(known.contains)
        let concealed = (layout.hidden + layout.alwaysHidden).filter(known.contains)
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: visible,
            concealedItemIDs: concealed
        )
        let currentVisible = Set(snapshot.items.filter {
            !$0.isBarlineControlItem && $0.section == .visible
        }.map(\.id))
        let requestedVisible = Set(visible)
        let requestedConcealed = Set(concealed)
        let changesVisibility = !requestedConcealed.isEmpty || requestedVisible != currentVisible

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
                allItems: snapshot.items.map(\.id),
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
