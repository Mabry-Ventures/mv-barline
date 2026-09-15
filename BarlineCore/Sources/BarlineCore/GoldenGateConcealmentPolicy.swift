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
        for (bundleIdentifier, items) in Dictionary(grouping: allItems, by: \.bundleIdentifier) {
            guard
                bundleIdentifier != barlineBundleIdentifier.lowercased(),
                !bundleIdentifier.hasPrefix("com.apple."),
                !items.isEmpty,
                items.allSatisfy(concealed.contains)
            else { continue }
            concealedBundles.insert(bundleIdentifier)
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
        guard item.bundleIdentifier == "com.apple.controlcenter" else { return nil }
        let title = (item.accessibilityIdentifier ?? item.title ?? "")
            .lowercased()
            .filter(\.isLetter)
        return switch title {
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
        return resolution.concealedBundleIdentifiers.contains(item.bundleIdentifier)
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
        guard item.bundleIdentifier != barlineBundleIdentifier.lowercased() else {
            return false
        }
        if item.bundleIdentifier.hasPrefix("com.apple.") {
            return systemItemIdentifier(for: item) != nil
        }
        return allItems.count { $0.bundleIdentifier == item.bundleIdentifier } == 1
    }
}
