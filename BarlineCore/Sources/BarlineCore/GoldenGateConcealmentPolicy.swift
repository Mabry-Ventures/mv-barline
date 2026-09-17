import Foundation

/// Complete desired visibility state for Golden Gate's application-level
/// menu-bar restriction. The helper must receive both sides so bundle-grouped
/// items can fail visible when an app has mixed assignments.
public struct MenuBarConcealmentConfiguration: Codable, Equatable, Sendable {
    public let visibleItemIDs: [MenuBarItemID]
    public let concealedItemIDs: [MenuBarItemID]

    public init(visibleItemIDs: [MenuBarItemID], concealedItemIDs: [MenuBarItemID]) {
        self.visibleItemIDs = visibleItemIDs
        self.concealedItemIDs = concealedItemIDs
    }
}

public struct GoldenGateResolvedConcealment: Equatable, Sendable {
    public let concealedBundleIdentifiers: Set<String>
    public let allowedSystemItemIdentifiers: Set<Int>

    public init(
        concealedBundleIdentifiers: Set<String>,
        allowedSystemItemIdentifiers: Set<Int>
    ) {
        self.concealedBundleIdentifiers = concealedBundleIdentifiers
        self.allowedSystemItemIdentifiers = allowedSystemItemIdentifiers
    }
}

/// Maps Barline's stable item identities to macOS 27's native assessment-mode
/// model. Unknown Apple items and mixed per-app assignments deliberately remain
/// visible; hiding the wrong item is worse than declining an unsupported hide.
public enum GoldenGateConcealmentPolicy {
    public static let allSystemItemIdentifiers = Set(0 ... 8)

    public static func resolve(
        _ configuration: MenuBarConcealmentConfiguration,
        barlineBundleIdentifier: String
    ) -> GoldenGateResolvedConcealment {
        let visible = Set(configuration.visibleItemIDs)
        let concealed = Set(configuration.concealedItemIDs).subtracting(visible)
        let allItems = visible.union(concealed)

        var concealedBundles = Set<String>()
        for (normalizedBundleIdentifier, items) in Dictionary(
            grouping: allItems,
            by: { $0.bundleIdentifier.lowercased() }
        ) {
            guard
                normalizedBundleIdentifier != barlineBundleIdentifier.lowercased(),
                !normalizedBundleIdentifier.hasPrefix("com.apple."),
                !items.isEmpty,
                items.allSatisfy(concealed.contains)
            else { continue }
            if let bundleIdentifier = items.first?.bundleIdentifier {
                concealedBundles.insert(bundleIdentifier)
            }
        }

        let visibleSystemIDs = Set(visible.compactMap(systemItemIdentifier))
        let concealedSystemIDs = Set(concealed.compactMap(systemItemIdentifier))
            .subtracting(visibleSystemIDs)
        return GoldenGateResolvedConcealment(
            concealedBundleIdentifiers: concealedBundles,
            allowedSystemItemIdentifiers: allSystemItemIdentifiers.subtracting(concealedSystemIDs)
        )
    }

    public static func systemItemIdentifier(for item: MenuBarItemID) -> Int? {
        let bundleIdentifier = item.bundleIdentifier.lowercased()
        guard bundleIdentifier == "com.apple.controlcenter" ||
            bundleIdentifier == "com.apple.menubaragent"
        else { return nil }
        let semanticName = [item.accessibilityIdentifier, item.title]
            .compactMap(\.self)
            .lazy
            .map { value in
                (value.split(separator: ".").last.map(String.init) ?? value)
                    .lowercased()
                    .filter(\.isLetter)
            }
            .first(where: { knownSystemItemIdentifier(for: $0) != nil })
        guard let semanticName else { return nil }
        return knownSystemItemIdentifier(for: semanticName)
    }

    private static func knownSystemItemIdentifier(for semanticName: String) -> Int? {
        switch semanticName {
        case "battery": 0
        case "bluetooth": 1
        case "clock": 2
        case "displays", "display": 3
        case "keyboard": 4
        case "sound": 5
        case "wifi": 6
        case "screenmirroring": 7
        case "controlcenter", "bentobox": 8
        default: nil
        }
    }

    public static func supportsConcealing(
        _ item: MenuBarItemID,
        in resolution: GoldenGateResolvedConcealment
    ) -> Bool {
        if let systemIdentifier = systemItemIdentifier(for: item) {
            return !resolution.allowedSystemItemIdentifiers.contains(systemIdentifier)
        }
        return resolution.concealedBundleIdentifiers.contains {
            $0.caseInsensitiveCompare(item.bundleIdentifier) == .orderedSame
        }
    }

    public static func supports(
        _ configuration: MenuBarConcealmentConfiguration,
        allItems: [MenuBarItemID],
        barlineBundleIdentifier: String
    ) -> Bool {
        let visible = Set(configuration.visibleItemIDs)
        let concealed = Set(configuration.concealedItemIDs)
        guard visible.isDisjoint(with: concealed) else { return false }
        let requested = visible.union(concealed)
        guard requested.isSubset(of: Set(allItems)) else { return false }

        for (normalizedBundleIdentifier, items) in Dictionary(
            grouping: allItems,
            by: { $0.bundleIdentifier.lowercased() }
        ) {
            let itemSet = Set(items)
            let requestedForBundle = requested.intersection(itemSet)
            guard requestedForBundle.isEmpty || requestedForBundle == itemSet else {
                return false
            }
            if normalizedBundleIdentifier == barlineBundleIdentifier.lowercased(),
               !concealed.isDisjoint(with: itemSet)
            {
                return false
            }
            if normalizedBundleIdentifier.hasPrefix("com.apple."),
               concealed.intersection(itemSet).contains(where: { systemItemIdentifier(for: $0) == nil })
            {
                return false
            }
            if !normalizedBundleIdentifier.hasPrefix("com.apple."),
               !concealed.isDisjoint(with: itemSet),
               !itemSet.isSubset(of: concealed)
            {
                return false
            }
        }
        return true
    }

    /// Repairs legacy or cross-version assignments that macOS 27 cannot
    /// represent. Unsupported state always fails visible: Barline never hides
    /// an unknown Apple control, itself, or only part of a third-party app's
    /// status-item group. The returned arrays follow `allItems` order and are
    /// deduplicated so the result is safe to persist as the new baseline.
    public static func canonicalConfiguration(
        _ configuration: MenuBarConcealmentConfiguration,
        allItems: [MenuBarItemID],
        barlineBundleIdentifier: String
    ) -> MenuBarConcealmentConfiguration {
        let barlineBundleIdentifier = barlineBundleIdentifier.lowercased()
        var orderedItems = [MenuBarItemID]()
        var seen = Set<MenuBarItemID>()
        for item in allItems where seen.insert(item).inserted {
            orderedItems.append(item)
        }

        let allItemSet = Set(orderedItems)
        var visible = Set(configuration.visibleItemIDs).intersection(allItemSet)
        var concealed = Set(configuration.concealedItemIDs)
            .intersection(allItemSet)
            .subtracting(visible)

        for (normalizedBundleIdentifier, items) in Dictionary(
            grouping: orderedItems,
            by: { $0.bundleIdentifier.lowercased() }
        ) {
            let itemSet = Set(items)
            if normalizedBundleIdentifier == barlineBundleIdentifier {
                visible.formUnion(itemSet)
                concealed.subtract(itemSet)
                continue
            }
            if normalizedBundleIdentifier.hasPrefix("com.apple.") {
                let unsupported = itemSet.filter { systemItemIdentifier(for: $0) == nil }
                visible.formUnion(unsupported)
                concealed.subtract(unsupported)
                continue
            }
            if !visible.isDisjoint(with: itemSet), !concealed.isDisjoint(with: itemSet) {
                visible.formUnion(itemSet)
                concealed.subtract(itemSet)
            }
        }

        // Live inventory is complete. Any newly observed item missing from an
        // older persistence document also fails visible.
        visible.formUnion(allItemSet.subtracting(concealed))
        return MenuBarConcealmentConfiguration(
            visibleItemIDs: orderedItems.filter(visible.contains),
            concealedItemIDs: orderedItems.filter(concealed.contains)
        )
    }

    /// Returns whether macOS 27 can independently assign an item between
    /// Barline's visible and concealed sections. Third-party applications are
    /// controlled at bundle granularity, so an application exposing multiple
    /// status items cannot safely move just one of them. Apple items require a
    /// known native assessment identifier.
    public static func supportsIndependentAssignment(
        _ item: MenuBarItemID,
        among allItems: [MenuBarItemID],
        barlineBundleIdentifier: String
    ) -> Bool {
        let normalizedBundleIdentifier = item.bundleIdentifier.lowercased()
        guard normalizedBundleIdentifier != barlineBundleIdentifier.lowercased() else {
            return false
        }
        if normalizedBundleIdentifier.hasPrefix("com.apple.") {
            return systemItemIdentifier(for: item) != nil
        }
        return allItems.count {
            $0.bundleIdentifier.caseInsensitiveCompare(item.bundleIdentifier) == .orderedSame
        } == 1
    }

    /// Returns whether selecting this item can express a safe logical
    /// visibility assignment. Third-party applications are assigned as one
    /// complete bundle group when they publish multiple status items; Apple
    /// items remain limited to known native assessment identifiers.
    public static func supportsLogicalAssignment(
        _ item: MenuBarItemID,
        among allItems: [MenuBarItemID],
        barlineBundleIdentifier: String
    ) -> Bool {
        let normalizedBundleIdentifier = item.bundleIdentifier.lowercased()
        guard normalizedBundleIdentifier != barlineBundleIdentifier.lowercased() else {
            return false
        }
        if normalizedBundleIdentifier.hasPrefix("com.apple.") {
            return systemItemIdentifier(for: item) != nil
        }
        return allItems.contains {
            $0.bundleIdentifier.caseInsensitiveCompare(item.bundleIdentifier) == .orderedSame
        }
    }
}
