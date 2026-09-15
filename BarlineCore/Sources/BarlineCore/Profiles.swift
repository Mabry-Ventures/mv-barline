//
//  Profiles.swift
//  Barline
//

import Foundation

public enum ProfileColorHex {
    public static func canonical(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit)
        else { return trimmed }
        let uppercased = digits.uppercased()
        if uppercased.count == 8, uppercased.hasSuffix("FF") {
            return "#\(uppercased.dropLast(2))"
        }
        return "#\(uppercased)"
    }
}

public enum ProfileSchema {
    public static let currentVersion = 7
    public static let archiveFormatVersion = 1
}

public struct ProfileLayout: Codable, Hashable, Sendable {
    public var visible: [MenuBarItemID]
    public var hidden: [MenuBarItemID]
    public var alwaysHidden: [MenuBarItemID]

    public init(
        visible: [MenuBarItemID] = [],
        hidden: [MenuBarItemID] = [],
        alwaysHidden: [MenuBarItemID] = []
    ) {
        self.visible = visible
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }

    public var allItemIDs: [MenuBarItemID] {
        visible + hidden + alwaysHidden
    }
}

public struct ProfileGroup: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var symbol: String?
    public var itemIDs: [MenuBarItemID]

    public init(id: UUID = UUID(), name: String, symbol: String? = nil, itemIDs: [MenuBarItemID]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.itemIDs = itemIDs
    }
}

public struct ProfileSpacer: Codable, Hashable, Sendable, Identifiable {
    public enum Placement: Codable, Hashable, Sendable {
        case beginning(MenuBarSection)
        case after(MenuBarItemID)
        case end(MenuBarSection)
    }

    public let id: UUID
    public var placement: Placement
    public var width: Double

    public init(id: UUID = UUID(), placement: Placement, width: Double = 12) {
        self.id = id
        self.placement = placement
        self.width = width
    }
}

public struct DisplayProfileOverride: Codable, Hashable, Sendable {
    public var displayID: MenuBarDisplayID
    public var displayFingerprint: MenuBarDisplayHardwareFingerprint?
    public var layout: ProfileLayout
    public var groups: [ProfileGroup]
    public var spacers: [ProfileSpacer]

    public init(
        displayID: MenuBarDisplayID,
        displayFingerprint: MenuBarDisplayHardwareFingerprint? = nil,
        layout: ProfileLayout,
        groups: [ProfileGroup] = [],
        spacers: [ProfileSpacer] = []
    ) {
        self.displayID = displayID
        self.displayFingerprint = displayFingerprint
        self.layout = layout
        self.groups = groups
        self.spacers = spacers
    }
}

public struct ProfileAppearance: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, Sendable { case standard, rounded, split }

    public static let itemSpacingRange: ClosedRange<Double> = -16 ... 16

    public var tintHex: String?
    public var gradientHex: [String]
    public var gradientStops: [ProfileGradientStop]
    public var showsBorder: Bool
    public var borderHex: String
    public var borderWidth: Double
    public var showsShadow: Bool
    public var shape: Shape
    public var shapeDetails: ProfileShapeDetails
    public var itemSpacing: Double
    public var dynamicAppearance: ProfileDynamicAppearance?
    public var isDynamic: Bool

    public init(
        tintHex: String? = nil,
        gradientHex: [String] = [],
        gradientStops: [ProfileGradientStop]? = nil,
        showsBorder: Bool = false,
        borderHex: String = "#000000",
        borderWidth: Double = 1,
        showsShadow: Bool = false,
        shape: Shape = .standard,
        shapeDetails: ProfileShapeDetails = .default,
        itemSpacing: Double = 0,
        dynamicAppearance: ProfileDynamicAppearance? = nil,
        isDynamic: Bool = false
    ) {
        self.tintHex = tintHex.map(ProfileColorHex.canonical)
        let resolvedStops = if let gradientStops, !gradientStops.isEmpty || gradientHex.isEmpty {
            gradientStops
        } else {
            ProfileGradientStop.evenlySpaced(colors: gradientHex)
        }
        self.gradientStops = resolvedStops.map {
            ProfileGradientStop(colorHex: $0.colorHex, location: $0.location)
        }
        self.gradientHex = self.gradientStops.isEmpty
            ? gradientHex.map(ProfileColorHex.canonical)
            : self.gradientStops.map(\.colorHex)
        self.showsBorder = showsBorder
        self.borderHex = ProfileColorHex.canonical(borderHex)
        self.borderWidth = borderWidth
        self.showsShadow = showsShadow
        self.shape = shape
        self.shapeDetails = shapeDetails
        self.itemSpacing = itemSpacing
        self.dynamicAppearance = dynamicAppearance
        self.isDynamic = isDynamic
    }

    private enum CodingKeys: CodingKey {
        case tintHex
        case gradientHex
        case gradientStops
        case showsBorder
        case borderHex
        case borderWidth
        case showsShadow
        case shape
        case shapeDetails
        case itemSpacing
        case dynamicAppearance
        case isDynamic
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tintHex: container.decodeIfPresent(String.self, forKey: .tintHex),
            gradientHex: container.decodeIfPresent([String].self, forKey: .gradientHex) ?? [],
            gradientStops: container.decodeIfPresent([ProfileGradientStop].self, forKey: .gradientStops),
            showsBorder: container.decodeIfPresent(Bool.self, forKey: .showsBorder) ?? false,
            borderHex: container.decodeIfPresent(String.self, forKey: .borderHex) ?? "#000000",
            borderWidth: container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 1,
            showsShadow: container.decodeIfPresent(Bool.self, forKey: .showsShadow) ?? false,
            shape: container.decodeIfPresent(Shape.self, forKey: .shape) ?? .standard,
            shapeDetails: container.decodeIfPresent(ProfileShapeDetails.self, forKey: .shapeDetails) ?? .default,
            itemSpacing: container.decodeIfPresent(Double.self, forKey: .itemSpacing) ?? 0,
            dynamicAppearance: container.decodeIfPresent(
                ProfileDynamicAppearance.self,
                forKey: .dynamicAppearance
            ),
            isDynamic: container.decodeIfPresent(Bool.self, forKey: .isDynamic) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tintHex, forKey: .tintHex)
        try container.encode(gradientHex, forKey: .gradientHex)
        try container.encode(gradientStops, forKey: .gradientStops)
        try container.encode(showsBorder, forKey: .showsBorder)
        try container.encode(borderHex, forKey: .borderHex)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(showsShadow, forKey: .showsShadow)
        try container.encode(shape, forKey: .shape)
        try container.encode(shapeDetails, forKey: .shapeDetails)
        try container.encode(itemSpacing, forKey: .itemSpacing)
        try container.encodeIfPresent(dynamicAppearance, forKey: .dynamicAppearance)
        try container.encode(isDynamic, forKey: .isDynamic)
    }
}

public struct ProfileGradientStop: Codable, Hashable, Sendable {
    public var colorHex: String
    public var location: Double

    public init(colorHex: String, location: Double) {
        self.colorHex = ProfileColorHex.canonical(colorHex)
        self.location = location
    }

    static func evenlySpaced(colors: [String]) -> [Self] {
        let denominator = max(colors.count - 1, 1)
        return colors.enumerated().map { index, color in
            Self(colorHex: color, location: Double(index) / Double(denominator))
        }
    }
}

public enum ProfileEndCap: String, Codable, Hashable, Sendable {
    case square
    case round
}

public struct ProfileFullShape: Codable, Hashable, Sendable {
    public var leading: ProfileEndCap
    public var trailing: ProfileEndCap

    public init(leading: ProfileEndCap = .round, trailing: ProfileEndCap = .round) {
        self.leading = leading
        self.trailing = trailing
    }
}

public struct ProfileShapeDetails: Codable, Hashable, Sendable {
    public var full: ProfileFullShape
    public var splitLeading: ProfileFullShape
    public var splitTrailing: ProfileFullShape
    public var isInset: Bool

    public init(
        full: ProfileFullShape = ProfileFullShape(),
        splitLeading: ProfileFullShape = ProfileFullShape(),
        splitTrailing: ProfileFullShape = ProfileFullShape(),
        isInset: Bool = true
    ) {
        self.full = full
        self.splitLeading = splitLeading
        self.splitTrailing = splitTrailing
        self.isInset = isInset
    }

    public static let `default` = Self()
}

public struct ProfileShelfBehavior: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var followsActiveDisplay: Bool

    public init(isEnabled: Bool = false, followsActiveDisplay: Bool = true) {
        self.isEnabled = isEnabled
        self.followsActiveDisplay = followsActiveDisplay
    }
}

public struct ProfileRevealTriggers: Codable, Hashable, Sendable {
    public var click: Bool
    public var hover: Bool
    public var scroll: Bool

    public init(click: Bool = true, hover: Bool = false, scroll: Bool = false) {
        self.click = click
        self.hover = hover
        self.scroll = scroll
    }
}

public struct ProfileAutoRehide: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var strategy: ProfileAutoRehideStrategy
    public var delaySeconds: Double

    public init(
        isEnabled: Bool = true,
        strategy: ProfileAutoRehideStrategy = .timed,
        delaySeconds: Double = 5
    ) {
        self.isEnabled = isEnabled
        self.strategy = strategy
        self.delaySeconds = delaySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case strategy
        case delaySeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        strategy = try container.decodeIfPresent(ProfileAutoRehideStrategy.self, forKey: .strategy) ?? .timed
        delaySeconds = try container.decode(Double.self, forKey: .delaySeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(strategy, forKey: .strategy)
        try container.encode(delaySeconds, forKey: .delaySeconds)
    }
}

public enum ProfileAutoRehideStrategy: String, Codable, CaseIterable, Sendable {
    case smart
    case timed
    case focusedApp
}

/// The non-layout settings that must commit and roll back with a profile's
/// menu-bar layout. Keeping this value in Core lets history and Focus recovery
/// preserve an exact custom workspace without importing AppKit state.
public struct ProfileWorkspaceState: Codable, Hashable, Sendable {
    public var appearance: ProfileAppearance
    public var shelfBehavior: ProfileShelfBehavior
    public var revealTriggers: ProfileRevealTriggers
    public var autoRehide: ProfileAutoRehide
    public var applicationMenuOverlapBehavior: ApplicationMenuOverlapBehavior
    public var presentation: ResolvedProfilePresentation?

    public init(
        appearance: ProfileAppearance,
        shelfBehavior: ProfileShelfBehavior,
        revealTriggers: ProfileRevealTriggers,
        autoRehide: ProfileAutoRehide,
        applicationMenuOverlapBehavior: ApplicationMenuOverlapBehavior,
        presentation: ResolvedProfilePresentation? = nil
    ) {
        self.appearance = appearance
        self.shelfBehavior = shelfBehavior
        self.revealTriggers = revealTriggers
        self.autoRehide = autoRehide
        self.applicationMenuOverlapBehavior = applicationMenuOverlapBehavior
        self.presentation = presentation
    }

    public init(profile: BarlineProfile, displayID: MenuBarDisplayID? = nil) {
        self.init(
            appearance: profile.appearance,
            shelfBehavior: profile.shelfBehavior,
            revealTriggers: profile.revealTriggers,
            autoRehide: profile.autoRehide,
            applicationMenuOverlapBehavior: profile.applicationMenuOverlapBehavior,
            presentation: profile.resolvedPresentation(for: displayID)
        )
    }

    /// Reverts fields that still equal a failed activation's target while
    /// preserving every field changed concurrently by the user.
    public func rollingBackUnchangedFields(
        applied target: ProfileWorkspaceState,
        to original: ProfileWorkspaceState
    ) -> ProfileWorkspaceState {
        func reverted<Value: Equatable>(
            _ current: Value,
            _ applied: Value,
            _ prior: Value
        ) -> Value {
            current == applied ? prior : current
        }

        var result = self
        result.appearance.tintHex = reverted(
            appearance.tintHex, target.appearance.tintHex, original.appearance.tintHex
        )
        result.appearance.gradientHex = reverted(
            appearance.gradientHex, target.appearance.gradientHex, original.appearance.gradientHex
        )
        result.appearance.gradientStops = reverted(
            appearance.gradientStops,
            target.appearance.gradientStops,
            original.appearance.gradientStops
        )
        result.appearance.showsBorder = reverted(
            appearance.showsBorder,
            target.appearance.showsBorder,
            original.appearance.showsBorder
        )
        result.appearance.borderHex = reverted(
            appearance.borderHex, target.appearance.borderHex, original.appearance.borderHex
        )
        result.appearance.borderWidth = reverted(
            appearance.borderWidth,
            target.appearance.borderWidth,
            original.appearance.borderWidth
        )
        result.appearance.showsShadow = reverted(
            appearance.showsShadow,
            target.appearance.showsShadow,
            original.appearance.showsShadow
        )
        result.appearance.shape = reverted(
            appearance.shape, target.appearance.shape, original.appearance.shape
        )
        result.appearance.shapeDetails = reverted(
            appearance.shapeDetails,
            target.appearance.shapeDetails,
            original.appearance.shapeDetails
        )
        result.appearance.itemSpacing = reverted(
            appearance.itemSpacing,
            target.appearance.itemSpacing,
            original.appearance.itemSpacing
        )
        result.appearance.dynamicAppearance = reverted(
            appearance.dynamicAppearance,
            target.appearance.dynamicAppearance,
            original.appearance.dynamicAppearance
        )
        result.appearance.isDynamic = reverted(
            appearance.isDynamic,
            target.appearance.isDynamic,
            original.appearance.isDynamic
        )
        result.shelfBehavior.isEnabled = reverted(
            shelfBehavior.isEnabled,
            target.shelfBehavior.isEnabled,
            original.shelfBehavior.isEnabled
        )
        result.shelfBehavior.followsActiveDisplay = reverted(
            shelfBehavior.followsActiveDisplay,
            target.shelfBehavior.followsActiveDisplay,
            original.shelfBehavior.followsActiveDisplay
        )
        result.revealTriggers.click = reverted(
            revealTriggers.click, target.revealTriggers.click, original.revealTriggers.click
        )
        result.revealTriggers.hover = reverted(
            revealTriggers.hover, target.revealTriggers.hover, original.revealTriggers.hover
        )
        result.revealTriggers.scroll = reverted(
            revealTriggers.scroll, target.revealTriggers.scroll, original.revealTriggers.scroll
        )
        result.autoRehide.isEnabled = reverted(
            autoRehide.isEnabled, target.autoRehide.isEnabled, original.autoRehide.isEnabled
        )
        result.autoRehide.strategy = reverted(
            autoRehide.strategy, target.autoRehide.strategy, original.autoRehide.strategy
        )
        result.autoRehide.delaySeconds = reverted(
            autoRehide.delaySeconds,
            target.autoRehide.delaySeconds,
            original.autoRehide.delaySeconds
        )
        result.applicationMenuOverlapBehavior = reverted(
            applicationMenuOverlapBehavior,
            target.applicationMenuOverlapBehavior,
            original.applicationMenuOverlapBehavior
        )
        result.presentation = reverted(
            presentation, target.presentation, original.presentation
        )
        return result
    }
}

public struct ResolvedProfilePresentation: Codable, Hashable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        case base
        case displayOverride(MenuBarDisplayID)
    }

    public var source: Source
    public var destinationDisplayID: MenuBarDisplayID?
    public var layout: ProfileLayout
    public var groups: [ProfileGroup]
    public var spacers: [ProfileSpacer]

    public init(
        source: Source,
        destinationDisplayID: MenuBarDisplayID?,
        layout: ProfileLayout,
        groups: [ProfileGroup],
        spacers: [ProfileSpacer]
    ) {
        self.source = source
        self.destinationDisplayID = destinationDisplayID
        self.layout = layout
        self.groups = groups
        self.spacers = spacers
    }

    /// Resolve old source-based IDs at the point of use. Archives remain intact,
    /// and ambiguity fails before any layout or workspace mutation starts.
    public func resolvingItemIdentities(
        in snapshot: MenuBarSnapshot,
        requireCompleteInventory: Bool = true
    ) throws -> Self {
        var mapping = [MenuBarItemID: MenuBarItemID]()
        var resolvedIDs = Set<MenuBarItemID>()
        for storedID in layout.allItemIDs {
            let resolvedID = snapshot.resolvedItemID(for: storedID)
            guard resolvedID != nil || !requireCompleteInventory,
                  resolvedIDs.insert(resolvedID ?? storedID).inserted
            else { throw MenuBarBackendError.staleItem(storedID) }
            mapping[storedID] = resolvedID ?? storedID
        }
        func resolve(_ id: MenuBarItemID) -> MenuBarItemID {
            mapping[id] ?? id
        }
        var result = self
        result.layout = ProfileLayout(
            visible: layout.visible.map(resolve),
            hidden: layout.hidden.map(resolve),
            alwaysHidden: layout.alwaysHidden.map(resolve)
        )
        result.groups = groups.map { group in
            var result = group
            result.itemIDs = group.itemIDs.map(resolve)
            return result
        }
        result.spacers = spacers.map { spacer in
            var result = spacer
            if case let .after(id) = spacer.placement {
                result.placement = .after(resolve(id))
            }
            return result
        }
        return result
    }
}

public enum ProfileDisplayMatchMethod: String, Codable, Hashable, Sendable {
    case exactRuntimeID
    case uniqueHardwareFingerprint
}

public struct ResolvedDisplayProfileOverride: Hashable, Sendable {
    public let override: DisplayProfileOverride
    public let liveDisplayID: MenuBarDisplayID
    public let method: ProfileDisplayMatchMethod

    public init(
        override: DisplayProfileOverride,
        liveDisplayID: MenuBarDisplayID,
        method: ProfileDisplayMatchMethod
    ) {
        self.override = override
        self.liveDisplayID = liveDisplayID
        self.method = method
    }
}

public struct DisplayProfileOverrideResolver: Sendable {
    public init() {}

    /// Reconnects a persisted presentation to a live display without trusting
    /// its ephemeral destination identifier. Every durable presentation field
    /// must still match the current profile; only the live destination may
    /// change through a unique hardware-fingerprint match.
    public func resolvePersistedPresentation(
        profile: BarlineProfile,
        persisted: ResolvedProfilePresentation,
        snapshot: MenuBarSnapshot
    ) -> ResolvedProfilePresentation? {
        // Display reconnection can run before a full item census. Unresolved IDs
        // stay unchanged here; authority matching and activation require every ID.
        guard let persisted = try? persisted.resolvingItemIdentities(
            in: snapshot, requireCompleteInventory: false
        ) else { return nil }
        switch persisted.source {
        case .base:
            guard let current = try? profile.resolvedPresentation(for: nil)
                .resolvingItemIdentities(in: snapshot, requireCompleteInventory: false)
            else { return nil }
            return current == persisted ? current : nil
        case let .displayOverride(storedID):
            let storedOverrideStillExists = profile.displayOverrides.contains {
                $0.displayID == storedID
            }
            let acceptedOverrideID: MenuBarDisplayID
            if storedOverrideStillExists {
                acceptedOverrideID = storedID
            } else {
                let payloadMatches = profile.displayOverrides.filter {
                    guard let presentation = try? profile.resolvedPresentation(for: $0.displayID)
                        .resolvingItemIdentities(in: snapshot, requireCompleteInventory: false)
                    else { return false }
                    return presentation.layout == persisted.layout
                        && presentation.groups == persisted.groups
                        && presentation.spacers == persisted.spacers
                }
                guard payloadMatches.count == 1 else { return nil }
                acceptedOverrideID = payloadMatches[0].displayID
            }
            let matches = snapshot.displayIDs.compactMap { liveID in
                resolve(
                    profile: profile,
                    requestedDisplayID: liveID,
                    snapshot: snapshot
                )
            }.filter { $0.override.displayID == acceptedOverrideID }
            guard matches.count == 1 else { return nil }
            guard let resolved = try? profile.resolvedPresentation(using: matches[0])
                .resolvingItemIdentities(in: snapshot, requireCompleteInventory: false)
            else { return nil }
            var normalizedPersisted = persisted
            if !storedOverrideStillExists {
                normalizedPersisted.source = resolved.source
            }
            normalizedPersisted.destinationDisplayID = resolved.destinationDisplayID
            guard normalizedPersisted == resolved else { return nil }
            return resolved
        }
    }

    public func resolve(
        profile: BarlineProfile,
        requestedDisplayID: MenuBarDisplayID,
        snapshot: MenuBarSnapshot
    ) -> ResolvedDisplayProfileOverride? {
        guard snapshot.displayIDs.contains(requestedDisplayID) else { return nil }
        let liveIdentity = snapshot.displayIdentity(for: requestedDisplayID)
        let exact = profile.displayOverrides.first(where: { $0.displayID == requestedDisplayID })

        if let fingerprint = liveIdentity?.hardwareFingerprint {
            let matchingOverrides = profile.displayOverrides.filter {
                $0.displayFingerprint == fingerprint
            }
            let matchingDisplays = snapshot.displayIdentities?.filter {
                $0.hardwareFingerprint == fingerprint
            } ?? []
            if !matchingOverrides.isEmpty {
                guard matchingOverrides.count == 1, matchingDisplays.count == 1 else { return nil }
                return ResolvedDisplayProfileOverride(
                    override: matchingOverrides[0],
                    liveDisplayID: requestedDisplayID,
                    method: .uniqueHardwareFingerprint
                )
            }
            guard let exact, exact.displayFingerprint == nil else { return nil }
            return ResolvedDisplayProfileOverride(
                override: exact,
                liveDisplayID: requestedDisplayID,
                method: .exactRuntimeID
            )
        }

        guard let exact, exact.displayFingerprint == nil else { return nil }
        return ResolvedDisplayProfileOverride(
            override: exact,
            liveDisplayID: requestedDisplayID,
            method: .exactRuntimeID
        )
    }
}

public enum ProfilePresentationElement: Codable, Hashable, Sendable, Identifiable {
    public enum ID: Hashable, Sendable {
        case group(UUID)
        case item(MenuBarItemID)
        case spacer(UUID)
    }

    case groupMarker(id: UUID, name: String, symbol: String?)
    case item(MenuBarItemID)
    case spacer(id: UUID, width: Double)

    public var id: ID {
        switch self {
        case let .groupMarker(id, _, _): .group(id)
        case let .item(itemID): .item(itemID)
        case let .spacer(id, _): .spacer(id)
        }
    }
}

public struct ProfilePresentationProjector: Sendable {
    public init() {}

    public func elements(
        presentation: ResolvedProfilePresentation?,
        section: MenuBarSection,
        orderedItemIDs: [MenuBarItemID]
    ) -> [ProfilePresentationElement] {
        guard let presentation else {
            return orderedItemIDs.map(ProfilePresentationElement.item)
        }
        var result: [ProfilePresentationElement] = presentation.spacers.compactMap { spacer in
            guard case let .beginning(spacerSection) = spacer.placement,
                  spacerSection == section
            else { return nil }
            return ProfilePresentationElement.spacer(id: spacer.id, width: spacer.width)
        }
        let presentIDs = Set(orderedItemIDs)
        let firstMembers = presentation.groups.compactMap { group -> (MenuBarItemID, ProfileGroup)? in
            guard let first = orderedItemIDs.first(where: {
                group.itemIDs.contains($0) && presentIDs.contains($0)
            }) else { return nil }
            return (first, group)
        }
        for itemID in orderedItemIDs {
            result += firstMembers.compactMap { first, group in
                guard first == itemID else { return nil }
                return .groupMarker(id: group.id, name: group.name, symbol: group.symbol)
            }
            result.append(.item(itemID))
            result += presentation.spacers.compactMap { spacer in
                guard case let .after(anchor) = spacer.placement, anchor == itemID else { return nil }
                return .spacer(id: spacer.id, width: spacer.width)
            }
        }
        result += presentation.spacers.compactMap { spacer in
            guard case let .end(spacerSection) = spacer.placement,
                  spacerSection == section
            else { return nil }
            return .spacer(id: spacer.id, width: spacer.width)
        }
        return result
    }
}

public struct ProfileAppearanceMode: Codable, Hashable, Sendable {
    public var tintHex: String?
    public var gradientHex: [String]
    public var gradientStops: [ProfileGradientStop]
    public var showsBorder: Bool
    public var borderHex: String
    public var borderWidth: Double
    public var showsShadow: Bool

    public init(
        tintHex: String? = nil,
        gradientHex: [String] = [],
        gradientStops: [ProfileGradientStop]? = nil,
        showsBorder: Bool = false,
        borderHex: String = "#000000",
        borderWidth: Double = 1,
        showsShadow: Bool = false
    ) {
        self.tintHex = tintHex.map(ProfileColorHex.canonical)
        let resolvedStops = if let gradientStops, !gradientStops.isEmpty || gradientHex.isEmpty {
            gradientStops
        } else {
            ProfileGradientStop.evenlySpaced(colors: gradientHex)
        }
        self.gradientStops = resolvedStops.map {
            ProfileGradientStop(colorHex: $0.colorHex, location: $0.location)
        }
        self.gradientHex = self.gradientStops.isEmpty
            ? gradientHex.map(ProfileColorHex.canonical)
            : self.gradientStops.map(\.colorHex)
        self.showsBorder = showsBorder
        self.borderHex = ProfileColorHex.canonical(borderHex)
        self.borderWidth = borderWidth
        self.showsShadow = showsShadow
    }

    private enum CodingKeys: CodingKey {
        case tintHex, gradientHex, gradientStops, showsBorder, borderHex, borderWidth, showsShadow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tintHex: container.decodeIfPresent(String.self, forKey: .tintHex),
            gradientHex: container.decodeIfPresent([String].self, forKey: .gradientHex) ?? [],
            gradientStops: container.decodeIfPresent([ProfileGradientStop].self, forKey: .gradientStops),
            showsBorder: container.decodeIfPresent(Bool.self, forKey: .showsBorder) ?? false,
            borderHex: container.decodeIfPresent(String.self, forKey: .borderHex) ?? "#000000",
            borderWidth: container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 1,
            showsShadow: container.decodeIfPresent(Bool.self, forKey: .showsShadow) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tintHex, forKey: .tintHex)
        try container.encode(gradientHex, forKey: .gradientHex)
        try container.encode(gradientStops, forKey: .gradientStops)
        try container.encode(showsBorder, forKey: .showsBorder)
        try container.encode(borderHex, forKey: .borderHex)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(showsShadow, forKey: .showsShadow)
    }
}

public struct ProfileDynamicAppearance: Codable, Hashable, Sendable {
    public var light: ProfileAppearanceMode
    public var dark: ProfileAppearanceMode

    public init(light: ProfileAppearanceMode, dark: ProfileAppearanceMode) {
        self.light = light
        self.dark = dark
    }
}

public enum ProfileAuthorityMatcher {
    public static func matches(
        profile: BarlineProfile,
        checkpoint: MenuBarWorkspaceCheckpoint,
        destinationSupport: MenuBarMoveDestinationSupport = .existingItemRequired
    ) -> Bool {
        let match = checkpoint.activeDisplayID.flatMap { displayID in
            DisplayProfileOverrideResolver().resolve(
                profile: profile,
                requestedDisplayID: displayID,
                snapshot: checkpoint.snapshot
            )
        }
        guard let presentation = try? profile.resolvedPresentation(using: match)
            .resolvingItemIdentities(in: checkpoint.snapshot)
        else { return false }
        var expectedWorkspace = ProfileWorkspaceState(profile: profile)
        expectedWorkspace.presentation = presentation
        guard expectedWorkspace == checkpoint.workspace else {
            return false
        }
        return ProfileLayoutReconciler.matches(
            layout: presentation.layout,
            items: checkpoint.snapshot.items,
            displayID: presentation.destinationDisplayID,
            destinationSupport: destinationSupport
        )
    }
}

public enum ApplicationMenuOverlapBehavior: String, Codable, Sendable {
    case leaveVisible
    case hideWhenNeeded
}

public struct ProfileHotkey: Codable, Hashable, Sendable {
    public var key: String
    public var modifiers: Set<Modifier>

    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case command, option, control, shift
    }

    public init(key: String, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct BarlineProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var symbol: String?
    public var layout: ProfileLayout
    public var groups: [ProfileGroup]
    public var spacers: [ProfileSpacer]
    public var displayOverrides: [DisplayProfileOverride]
    public var appearance: ProfileAppearance
    public var shelfBehavior: ProfileShelfBehavior
    public var revealTriggers: ProfileRevealTriggers
    public var autoRehide: ProfileAutoRehide
    public var applicationMenuOverlapBehavior: ApplicationMenuOverlapBehavior
    public var hotkey: ProfileHotkey?
    public let createdAt: Date
    public var updatedAt: Date
    public let schemaVersion: Int

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String? = nil,
        layout: ProfileLayout = ProfileLayout(),
        groups: [ProfileGroup] = [],
        spacers: [ProfileSpacer] = [],
        displayOverrides: [DisplayProfileOverride] = [],
        appearance: ProfileAppearance = ProfileAppearance(),
        shelfBehavior: ProfileShelfBehavior = ProfileShelfBehavior(),
        revealTriggers: ProfileRevealTriggers = ProfileRevealTriggers(),
        autoRehide: ProfileAutoRehide = ProfileAutoRehide(),
        applicationMenuOverlapBehavior: ApplicationMenuOverlapBehavior = .hideWhenNeeded,
        hotkey: ProfileHotkey? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = ProfileSchema.currentVersion
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.layout = layout
        self.groups = groups
        self.spacers = spacers
        self.displayOverrides = displayOverrides
        self.appearance = appearance
        self.shelfBehavior = shelfBehavior
        self.revealTriggers = revealTriggers
        self.autoRehide = autoRehide
        self.applicationMenuOverlapBehavior = applicationMenuOverlapBehavior
        self.hotkey = hotkey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public func layout(for displayID: MenuBarDisplayID?) -> ProfileLayout {
        guard let displayID else { return layout }
        return displayOverrides.first { $0.displayID == displayID }?.layout ?? layout
    }

    public func resolvedPresentation(for displayID: MenuBarDisplayID?) -> ResolvedProfilePresentation {
        guard let displayID,
              let override = displayOverrides.first(where: { $0.displayID == displayID })
        else {
            return ResolvedProfilePresentation(
                source: .base,
                destinationDisplayID: nil,
                layout: layout,
                groups: groups,
                spacers: spacers
            )
        }
        return ResolvedProfilePresentation(
            source: .displayOverride(override.displayID),
            destinationDisplayID: displayID,
            layout: override.layout,
            groups: override.groups,
            spacers: override.spacers
        )
    }

    public func resolvedPresentation(
        using match: ResolvedDisplayProfileOverride?
    ) -> ResolvedProfilePresentation {
        guard let match else { return resolvedPresentation(for: nil) }
        return ResolvedProfilePresentation(
            source: .displayOverride(match.override.displayID),
            destinationDisplayID: match.liveDisplayID,
            layout: match.override.layout,
            groups: match.override.groups,
            spacers: match.override.spacers
        )
    }

    /// All item identities referenced by the profile, including display-specific
    /// layouts, in stable archive order with duplicates removed.
    public var searchableItemIDs: [MenuBarItemID] {
        stableUnique(
            layout.allItemIDs + displayOverrides.flatMap(\.layout.allItemIDs)
        )
    }

    /// All groups referenced by the profile, including display-specific groups,
    /// in stable archive order with duplicate group values removed.
    public var searchableGroups: [ProfileGroup] {
        stableUnique(groups + displayOverrides.flatMap(\.groups))
    }

    public var searchableGroupNames: [String] {
        stableUnique(searchableGroups.map(\.name))
    }

    public func searchableGroupNames(containing itemID: MenuBarItemID) -> [String] {
        stableUnique(
            searchableGroups
                .filter { $0.itemIDs.contains(itemID) }
                .map(\.name)
        )
    }

    private func stableUnique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen = Set<Value>()
        return values.filter { seen.insert($0).inserted }
    }
}

public enum ProfileActivationSource: String, Codable, CaseIterable, Sendable {
    case configuredDefault
    case contextualRule
    case focus
    case shortcut
    case appIntent
    case manual
    case recovery

    public var retainsArbitrationRequestWhileActive: Bool {
        switch self {
        case .configuredDefault, .focus: true
        case .contextualRule, .shortcut, .appIntent, .manual, .recovery: false
        }
    }

    public var precedence: Int {
        switch self {
        case .configuredDefault: 0
        case .contextualRule: 50
        case .focus: 100
        case .shortcut: 200
        case .appIntent: 300
        case .manual: 400
        case .recovery: 500
        }
    }
}

public struct ProfileActivationRequest: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let profileID: UUID
    public let source: ProfileActivationSource
    public let requestedAt: Date

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        source: ProfileActivationSource,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.profileID = profileID
        self.source = source
        self.requestedAt = requestedAt
    }
}

public struct ProfileActivationResolver: Sendable {
    public init() {}

    public func resolve(_ requests: some Sequence<ProfileActivationRequest>) -> ProfileActivationRequest? {
        requests.max { lhs, rhs in
            if lhs.source.precedence != rhs.source.precedence {
                return lhs.source.precedence < rhs.source.precedence
            }
            if lhs.requestedAt != rhs.requestedAt {
                return lhs.requestedAt < rhs.requestedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

public struct PresentationProfileTemplate: Codable, Hashable, Sendable {
    public let profile: BarlineProfile
    public let sourceGeneration: UInt64
    public let requiresConfirmation: Bool
    public let restoresPreviousLayoutOnDeactivation: Bool
}

public struct PresentationProfileTemplateBuilder: Sendable {
    public static let profileID = UUID(uuid: (
        0xBA, 0x71, 0x1E, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    ))

    public init() {}

    public func makeTemplate(
        from snapshot: MenuBarSnapshot,
        now: Date = Date(),
        id: UUID = Self.profileID
    ) -> PresentationProfileTemplate {
        let ordered = snapshot.items.sorted { $0.order < $1.order }
        let isEssential: (MenuBarItemDescriptor) -> Bool = {
            $0.isSystemItem || $0.isBarlineControlItem
        }
        let visible = ordered.filter { isEssential($0) && $0.section == .visible }.map(\.id)
        let hidden = ordered.filter {
            $0.section == .hidden || (!isEssential($0) && $0.section == .visible)
        }.map(\.id)
        let alwaysHidden = ordered.filter { $0.section == .alwaysHidden }.map(\.id)
        let profile = BarlineProfile(
            id: id,
            name: "Presentation",
            symbol: "rectangle.on.rectangle",
            layout: ProfileLayout(visible: visible, hidden: hidden, alwaysHidden: alwaysHidden),
            revealTriggers: ProfileRevealTriggers(click: true, hover: false, scroll: false),
            autoRehide: ProfileAutoRehide(isEnabled: true, delaySeconds: 5),
            applicationMenuOverlapBehavior: .hideWhenNeeded,
            createdAt: now,
            updatedAt: now
        )
        return PresentationProfileTemplate(
            profile: profile,
            sourceGeneration: snapshot.generation,
            requiresConfirmation: true,
            restoresPreviousLayoutOnDeactivation: true
        )
    }
}
