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

    /// Drops references the live menu bar no longer contains. An item that is
    /// absent cannot be concealed or revealed, so keeping its reference only
    /// invalidates every other assignment in the same configuration.
    public func retainingOnly(_ liveItemIDs: Set<MenuBarItemID>) -> Self {
        Self(
            visibleItemIDs: visibleItemIDs.filter(liveItemIDs.contains),
            concealedItemIDs: concealedItemIDs.filter(liveItemIDs.contains)
        )
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

/// The exact inputs committed to the native assertion. Logical assignments
/// alone are not sufficient: a newly running visible app needs an allowlist
/// entry even when no saved visibility assignment changed.
public struct GoldenGateNativeConcealmentState: Equatable, Sendable {
    public let resolution: GoldenGateResolvedConcealment
    public let allowedBundleIdentifiers: Set<String>

    public init(
        resolution: GoldenGateResolvedConcealment,
        runningBundleIdentifiers: [String],
        barlineBundleIdentifier: String
    ) {
        self.resolution = resolution
        guard !resolution.concealedBundleIdentifiers.isEmpty ||
            resolution.allowedSystemItemIdentifiers != GoldenGateConcealmentPolicy.allSystemItemIdentifiers
        else {
            // No assertion is needed in the all-visible state. App churn must
            // not create needless private-runtime transactions.
            allowedBundleIdentifiers = []
            return
        }
        let concealed = Set(resolution.concealedBundleIdentifiers.map { $0.lowercased() })
        allowedBundleIdentifiers = Set(runningBundleIdentifiers.filter {
            !$0.isEmpty && !concealed.contains($0.lowercased())
        }).union([
            barlineBundleIdentifier, "com.apple.systemuiserver",
            "com.apple.finder", "com.apple.dock",
        ])
    }
}

/// Maps Barline's stable item identities to macOS 27's native assessment-mode
/// model. Unknown Apple items and mixed per-app assignments deliberately remain
/// visible; hiding the wrong item is worse than declining an unsupported hide.
public enum GoldenGateConcealmentPolicy {
    public static let allSystemItemIdentifiers = Set(0 ... 8)

    /// Recovery only, never a successful-activation inventory exemption. The
    /// native catalogue has no Focus category; an active assessment assertion
    /// suppresses this control even with every known system item allowed.
    public static func permitsFocusDeassertionRecovery(
        original: MenuBarSnapshot,
        current: MenuBarSnapshot,
        transactionOwnedItemIDs: Set<MenuBarItemID>
    ) -> Bool {
        let originalIDs = Set(original.items.map(\.id))
        let currentIDs = Set(current.items.map(\.id))
        let missing = original.items.filter { !currentIDs.contains($0.id) }
        guard !transactionOwnedItemIDs.isEmpty,
              transactionOwnedItemIDs.isSubset(of: originalIDs),
              originalIDs.count == original.items.count,
              currentIDs.count == current.items.count,
              currentIDs.isSubset(of: originalIDs),
              missing.count == 1,
              let focus = missing.first,
              focus.section == .visible,
              focus.isSystemItem, focus.sourceOwnership == .system,
              ["com.apple.menubaragent", "com.apple.controlcenter"].contains(focus.id.bundleIdentifier),
              let identifier = focus.id.accessibilityIdentifier,
              ["focus", "focusmode", "focusmodes", "donotdisturb"].contains(
                  (identifier.split(separator: ".").last.map(String.init) ?? identifier).lowercased()
              ),
              // Only restoring an all-visible original state can remove the
              // assertion. Reasserting its nine-item list cannot restore Focus.
              original.items.filter({ !$0.isBarlineControlItem }).allSatisfy({ $0.section == .visible })
        else { return false }
        return preservesUnownedRecoveryInventory(
            original: original, current: current, transactionOwnedItemIDs: transactionOwnedItemIDs
        )
    }

    public static func preservesUnownedRecoveryInventory(
        original: MenuBarSnapshot,
        current: MenuBarSnapshot,
        transactionOwnedItemIDs: Set<MenuBarItemID>
    ) -> Bool {
        guard original.displayIDs == current.displayIDs,
              original.displayIdentities == current.displayIdentities,
              original.activeSpaceIsValid, current.activeSpaceIsValid,
              !original.menuTrackingIsActive, !current.menuTrackingIsActive,
              Set(original.items.map(\.id)).count == original.items.count,
              Set(current.items.map(\.id)).count == current.items.count
        else { return false }
        let originalByID = Dictionary(uniqueKeysWithValues: original.items.map { ($0.id, $0) })
        guard current.items.allSatisfy({ item in
            guard let prior = originalByID[item.id] else { return false }
            return item.displayID == prior.displayID &&
                (transactionOwnedItemIDs.contains(item.id) || item.section == prior.section)
        }) else { return false }
        let unchangedIDs = Set(current.items.map(\.id)).subtracting(transactionOwnedItemIDs)
        for display in Set(original.items.map(\.displayID)) {
            for section in [MenuBarSection.hidden, .alwaysHidden] {
                let before = original.items.filter {
                    $0.displayID == display && $0.section == section && unchangedIDs.contains($0.id)
                }.sorted { $0.order < $1.order }.map(\.id)
                let after = current.items.filter {
                    $0.displayID == display && $0.section == section && unchangedIDs.contains($0.id)
                }.sorted { $0.order < $1.order }.map(\.id)
                guard before == after else { return false }
            }
        }
        return true
    }

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
        guard requested.isSubset(of: Set(allItems)) else {
            return false
        }

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

    /// Read-only canonicalization must preserve the original observation and
    /// open-menu guard. It is not a proposed mutation or a new observation.
    public static func canonicalizingSnapshot(
        _ snapshot: MenuBarSnapshot, barlineBundleIdentifier: String
    ) -> (snapshot: MenuBarSnapshot, repairedItemIDs: Set<MenuBarItemID>) {
        let items = snapshot.items.filter { !$0.isBarlineControlItem }
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: items.filter { $0.section == .visible }.map(\.id),
            concealedItemIDs: items.filter { $0.section != .visible }.map(\.id)
        )
        let canonical = canonicalConfiguration(configuration, allItems: items.map(\.id), barlineBundleIdentifier: barlineBundleIdentifier)
        let visible = Set(canonical.visibleItemIDs)
        let repaired = Set(items.compactMap { $0.section != .visible && visible.contains($0.id) ? $0.id : nil })
        guard !repaired.isEmpty else { return (snapshot, []) }
        return (MenuBarSnapshot(
            generation: snapshot.generation, capturedAt: snapshot.capturedAt,
            items: snapshot.items.map { repaired.contains($0.id) ? $0.replacingSection(.visible) : $0 },
            displayIDs: snapshot.displayIDs, displayIdentities: snapshot.displayIdentities,
            activeSpaceIsValid: snapshot.activeSpaceIsValid, menuTrackingIsActive: snapshot.menuTrackingIsActive
        ), repaired)
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
        guard !normalizedBundleIdentifier.isEmpty else {
            return false
        }
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
        guard !normalizedBundleIdentifier.isEmpty else {
            return false
        }
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
