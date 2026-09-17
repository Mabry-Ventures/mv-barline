import Foundation

public struct MenuBarItemID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let bundleIdentifier: String
    public let accessibilityIdentifier: String?
    public let title: String?
    public let alias: String?
    public let fallbackFingerprint: String?

    public init(
        bundleIdentifier: String,
        accessibilityIdentifier: String? = nil,
        title: String? = nil,
        alias: String? = nil,
        fallbackFingerprint: String? = nil
    ) {
        self.bundleIdentifier = Self.normalize(bundleIdentifier)
        self.accessibilityIdentifier = Self.normalizeOptional(accessibilityIdentifier)
        self.title = Self.normalizeOptional(title)
        self.alias = Self.normalizeOptional(alias)
        self.fallbackFingerprint = Self.normalizeOptional(fallbackFingerprint)
    }

    public var description: String {
        [bundleIdentifier, accessibilityIdentifier, title, alias, fallbackFingerprint]
            .compactMap(\.self)
            .joined(separator: "|")
    }

    /// A collision-free opaque search identity. Field labels, explicit nil
    /// markers, and byte counts preserve which stable-ID component supplied a
    /// value without exposing this representation as a user-facing label.
    public var searchDocumentID: SearchDocumentID {
        let fields: [(String, String?)] = [
            ("bundle", bundleIdentifier),
            ("accessibility", accessibilityIdentifier),
            ("title", title),
            ("alias", alias),
            ("fingerprint", fallbackFingerprint),
        ]
        let encoded = fields.map { label, value in
            guard let value else { return "\(label):nil" }
            return "\(label):\(value.utf8.count):\(value)"
        }.joined(separator: "|")
        return SearchDocumentID("menu-item|\(encoded)")
    }

    public var isPlausiblyStable: Bool {
        !bundleIdentifier.isEmpty && (
            accessibilityIdentifier != nil || title != nil || alias != nil || fallbackFingerprint != nil
        )
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalize(value)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct MenuBarDisplayID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var description: String {
        value
    }
}

/// An opaque alias used to recognize a physical display when macOS assigns it
/// a different runtime identifier after reconnecting.
public struct MenuBarDisplayHardwareFingerprint: Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let value: String

    public init(_ value: String) {
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isWellFormed: Bool {
        guard value.hasPrefix("v1:") else { return false }
        let digest = value.dropFirst(3)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    public var description: String {
        "<redacted-display-fingerprint>"
    }
}

public struct MenuBarDisplayIdentity: Codable, Hashable, Sendable {
    public let runtimeID: MenuBarDisplayID
    public let hardwareFingerprint: MenuBarDisplayHardwareFingerprint?

    public init(
        runtimeID: MenuBarDisplayID,
        hardwareFingerprint: MenuBarDisplayHardwareFingerprint? = nil
    ) {
        self.runtimeID = runtimeID
        self.hardwareFingerprint = hardwareFingerprint
    }
}

public enum MenuBarSection: String, Codable, CaseIterable, Sendable {
    case visible
    case hidden
    case alwaysHidden
}

/// A Foundation-only rectangle used at the compatibility boundary.
///
/// Raw WindowServer identifiers never leave the helper. Geometry is safe to
/// project into the app because every mutation re-resolves the stable item ID
/// against a fresh helper-side enumeration before acting.
public struct MenuBarRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = MenuBarRect(x: 0, y: 0, width: 0, height: 0)

    public var isFiniteAndNonnegative: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
            width >= 0 && height >= 0
    }
}

/// Keeps replacement artwork legible without misrepresenting an item's measured
/// menu bar geometry. This is used when the OS cannot provide a per-item preview.
public enum MenuBarFallbackArtworkLayout {
    public static func drawingRect(
        imageWidth: Double,
        imageHeight: Double,
        boundsWidth: Double,
        boundsHeight: Double,
        maximumDimension: Double = 18
    ) -> MenuBarRect {
        guard imageWidth.isFinite,
              imageHeight.isFinite,
              boundsWidth.isFinite,
              boundsHeight.isFinite,
              maximumDimension.isFinite,
              imageWidth > 0,
              imageHeight > 0,
              boundsWidth > 0,
              boundsHeight > 0,
              maximumDimension > 0
        else {
            return .zero
        }

        let scale = min(
            1,
            maximumDimension / imageWidth,
            maximumDimension / imageHeight,
            boundsWidth / imageWidth,
            boundsHeight / imageHeight
        )
        let width = imageWidth * scale
        let height = imageHeight * scale
        return MenuBarRect(
            x: (boundsWidth - width) / 2,
            y: (boundsHeight - height) / 2,
            width: width,
            height: height
        )
    }
}

/// Stable presentation choices for status items whose native pixels are not
/// available. macOS 27 exposes item semantics through Accessibility, but no
/// longer guarantees a usable per-item WindowServer image.
public enum MenuBarInventoryPresentation {
    public static func fallbackSymbolName(displayName: String, title: String?) -> String {
        let value = "\(displayName) \(title ?? "")".lowercased()
        if value.contains("wi-fi") || value.contains("wifi") {
            return "wifi"
        }
        if value.contains("battery") || value.contains("power") {
            return "battery.100"
        }
        if value.contains("clock") || value.contains("date") || value.contains("time") {
            return "clock"
        }
        if value.contains("controlcenter") || value.contains("control center") {
            return "switch.2"
        }
        if value.contains("bluetooth") {
            return "wave.3.right"
        }
        if value.contains("volume") || value.contains("sound") || value.contains("audio") {
            return "speaker.wave.2"
        }
        if value.contains("focus") || value.contains("do not disturb") {
            return "moon"
        }
        if value.contains("spotlight") || value.contains("search") {
            return "magnifyingglass"
        }
        if value.contains("display") || value.contains("screen mirroring") {
            return "rectangle.on.rectangle"
        }
        if value.contains("vpn") {
            return "lock.shield"
        }
        return "circle.grid.2x2"
    }
}

/// The source application is distinct from the WindowServer host. On macOS 26,
/// Control Center hosts third-party items; an unresolved host is not a system item.
public enum MenuBarSourceOwnership: String, Codable, Hashable, Sendable {
    case unknown
    case system
    case application
}

/// Keep unknown observation fail-closed without requiring AppKit in the domain.
public enum MenuBarTrackingPolicy {
    public static func isTransientInterface(role: String?, subrole: String?) -> Bool {
        role == "AXMenu" || role == "AXPopover" || subrole == "AXPopover"
    }

    public static func blocksMutation(
        sceneIsAvailable: Bool,
        nativeMenuIsVisible: Bool,
        sourceInterfaceIsVisible: Bool
    ) -> Bool {
        !sceneIsAvailable || nativeMenuIsVisible || sourceInterfaceIsVisible
    }
}

public struct MenuBarItemDescriptor: Codable, Hashable, Sendable {
    public let id: MenuBarItemID
    public let section: MenuBarSection
    public let order: Int
    public let displayID: MenuBarDisplayID?
    public let isSystemItem: Bool
    /// Optional for decoding archives written before ownership was explicit.
    public let sourceOwnership: MenuBarSourceOwnership?
    public let isBarlineControlItem: Bool
    public let tagNamespace: String?
    public let title: String?
    public let displayName: String
    public let ownerProcessIdentifier: Int32?
    public let sourceProcessIdentifier: Int32?
    public let bounds: MenuBarRect
    public let isOnScreen: Bool
    public let isMovable: Bool
    public let canBeHidden: Bool
    public let isBentoBox: Bool
    public let isSystemClone: Bool
    public let isResponsive: Bool

    public init(
        id: MenuBarItemID,
        section: MenuBarSection,
        order: Int,
        displayID: MenuBarDisplayID? = nil,
        isSystemItem: Bool = false,
        sourceOwnership: MenuBarSourceOwnership? = nil,
        isBarlineControlItem: Bool = false,
        tagNamespace: String? = nil,
        title: String? = nil,
        displayName: String = "Menu Bar Item",
        ownerProcessIdentifier: Int32? = nil,
        sourceProcessIdentifier: Int32? = nil,
        bounds: MenuBarRect = .zero,
        isOnScreen: Bool = false,
        isMovable: Bool = true,
        canBeHidden: Bool = true,
        isBentoBox: Bool = false,
        isSystemClone: Bool = false,
        isResponsive: Bool = true
    ) {
        self.id = id
        self.section = section
        self.order = order
        self.displayID = displayID
        self.isSystemItem = isSystemItem
        self.sourceOwnership = sourceOwnership
        self.isBarlineControlItem = isBarlineControlItem
        self.tagNamespace = tagNamespace
        self.title = title
        self.displayName = displayName
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.sourceProcessIdentifier = sourceProcessIdentifier
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.isMovable = isMovable
        self.canBeHidden = canBeHidden
        self.isBentoBox = isBentoBox
        self.isSystemClone = isSystemClone
        self.isResponsive = isResponsive
    }

    public var isConfirmedSystemItem: Bool {
        sourceOwnership.map { $0 == .system } ?? isSystemItem
    }

    public func replacingSection(_ section: MenuBarSection) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: id,
            section: section,
            order: order,
            displayID: displayID,
            isSystemItem: isSystemItem,
            sourceOwnership: sourceOwnership,
            isBarlineControlItem: isBarlineControlItem,
            tagNamespace: tagNamespace,
            title: title,
            displayName: displayName,
            ownerProcessIdentifier: ownerProcessIdentifier,
            sourceProcessIdentifier: sourceProcessIdentifier,
            bounds: bounds,
            isOnScreen: isOnScreen,
            isMovable: isMovable,
            canBeHidden: canBeHidden,
            isBentoBox: isBentoBox,
            isSystemClone: isSystemClone,
            isResponsive: isResponsive
        )
    }

    public func replacing(
        section: MenuBarSection? = nil,
        order: Int? = nil,
        isMovable: Bool? = nil,
        canBeHidden: Bool? = nil
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: id,
            section: section ?? self.section,
            order: order ?? self.order,
            displayID: displayID,
            isSystemItem: isSystemItem,
            sourceOwnership: sourceOwnership,
            isBarlineControlItem: isBarlineControlItem,
            tagNamespace: tagNamespace,
            title: title,
            displayName: displayName,
            ownerProcessIdentifier: ownerProcessIdentifier,
            sourceProcessIdentifier: sourceProcessIdentifier,
            bounds: bounds,
            isOnScreen: isOnScreen,
            isMovable: isMovable ?? self.isMovable,
            canBeHidden: canBeHidden ?? self.canBeHidden,
            isBentoBox: isBentoBox,
            isSystemClone: isSystemClone,
            isResponsive: isResponsive
        )
    }
}

public struct MenuBarSnapshot: Codable, Hashable, Sendable {
    public let generation: UInt64
    public let capturedAt: Date
    public let items: [MenuBarItemDescriptor]
    public let displayIDs: Set<MenuBarDisplayID>
    public let displayIdentities: [MenuBarDisplayIdentity]?
    public let activeSpaceIsValid: Bool
    public let menuTrackingIsActive: Bool

    public init(
        generation: UInt64,
        capturedAt: Date,
        items: [MenuBarItemDescriptor],
        displayIDs: Set<MenuBarDisplayID>,
        displayIdentities: [MenuBarDisplayIdentity]? = nil,
        activeSpaceIsValid: Bool,
        menuTrackingIsActive: Bool = false
    ) {
        self.generation = generation
        self.capturedAt = capturedAt
        self.items = items
        self.displayIDs = displayIDs
        self.displayIdentities = displayIdentities
        self.activeSpaceIsValid = activeSpaceIsValid
        self.menuTrackingIsActive = menuTrackingIsActive
    }

    public func displayIdentity(for runtimeID: MenuBarDisplayID) -> MenuBarDisplayIdentity? {
        displayIdentities?.first { $0.runtimeID == runtimeID }
    }

    /// Resolves pre-hosted-identity profiles without guessing among duplicate
    /// items. Source bundle, title and semantic fingerprint must all agree;
    /// occurrence aliases are not evidence of identity after process relaunch.
    public func resolvedItemID(for storedID: MenuBarItemID) -> MenuBarItemID? {
        if items.contains(where: { $0.id == storedID }) {
            return storedID
        }
        guard let title = storedID.title,
              let fingerprint = storedID.fallbackFingerprint
        else { return nil }
        let matches = items.filter { item in
            guard item.id.bundleIdentifier == "barline.hosted-menu-item",
                  item.id.title == title,
                  item.id.fallbackFingerprint == fingerprint
            else { return false }
            let resolvedSource = item.tagNamespace?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return resolvedSource == storedID.bundleIdentifier ||
                storedID.bundleIdentifier == "com.apple.controlcenter"
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}

public struct MenuBarMovePlanner: Sendable {
    public enum LogicalSectionVerificationFailure: String, Sendable {
        case sourceMissing = "source_missing"
        case applicationGroupEmpty = "application_group_empty"
        case semanticIdentityChanged = "semantic_identity_changed"
        case requestedSectionMissing = "requested_section_missing"
        case requestedDisplayMissing = "requested_display_missing"
        case unrelatedLayoutChanged = "unrelated_layout_changed"
        case itemMissing = "item_missing"
    }

    public init() {}

    /// Returns the helper's global, section-relative candidate index. Prefer
    /// the last candidate on the item's display without mistaking a
    /// display-local count for the helper's global index space.
    public func destinationIndex(
        in snapshot: MenuBarSnapshot,
        section: MenuBarSection,
        preferredDisplayID: MenuBarDisplayID?
    ) -> Int {
        let candidates = snapshot.items.filter { $0.section == section }
        guard !candidates.isEmpty else { return 0 }
        if let preferredDisplayID,
           let index = candidates.lastIndex(where: { $0.displayID == preferredDisplayID })
        {
            return index
        }
        return candidates.count - 1
    }

    public func resultMatches(
        _ operation: MenuBarMoveOperation,
        in snapshot: MenuBarSnapshot,
        from previousSnapshot: MenuBarSnapshot,
        destinationSupport: MenuBarMoveDestinationSupport? = nil,
        visibilityAssignmentGranularity: MenuBarVisibilityAssignmentGranularity? = nil
    ) -> Bool {
        if destinationSupport == .logicalSectionsPreserveNativeOrder {
            return logicalSectionResultMatches(
                operation,
                in: snapshot,
                from: previousSnapshot,
                visibilityAssignmentGranularity: visibilityAssignmentGranularity
            )
        }
        let candidates = snapshot.items.filter { $0.section == operation.section }
        guard let itemIndex = candidates.firstIndex(where: { $0.id == operation.itemID }) else {
            return false
        }
        guard operation.destinationDisplayID.map({ candidates[itemIndex].displayID == $0 }) != false else {
            return false
        }
        let previousCandidates = previousSnapshot.items.filter {
            $0.section == operation.section
        }
        var insertionIndex = min(max(operation.index, 0), previousCandidates.count)
        if let sourceIndex = previousCandidates.firstIndex(where: { $0.id == operation.itemID }),
           sourceIndex < insertionIndex
        {
            // The operation index is an insertion offset in the pre-move
            // section. Removing an earlier source shifts that offset left.
            insertionIndex -= 1
        }
        let destinationCandidates = previousCandidates.filter { $0.id != operation.itemID }
        insertionIndex = min(insertionIndex, destinationCandidates.count)

        // Validate against the stable neighbor that defined the insertion
        // slot. Absolute ordinals can shift when macOS adds or removes an
        // unrelated status item while the move is in flight.
        if insertionIndex < destinationCandidates.count {
            let rightAnchorID = destinationCandidates[insertionIndex].id
            guard let anchorIndex = candidates.firstIndex(where: { $0.id == rightAnchorID }) else {
                return false
            }
            return itemIndex + 1 == anchorIndex
        }
        if let leftAnchorID = destinationCandidates.last?.id {
            guard let anchorIndex = candidates.firstIndex(where: { $0.id == leftAnchorID }) else {
                return false
            }
            return itemIndex == anchorIndex + 1
        }
        return itemIndex == 0
    }

    private func logicalSectionResultMatches(
        _ operation: MenuBarMoveOperation,
        in snapshot: MenuBarSnapshot,
        from previousSnapshot: MenuBarSnapshot,
        visibilityAssignmentGranularity: MenuBarVisibilityAssignmentGranularity?
    ) -> Bool {
        logicalSectionVerificationFailure(
            operation,
            in: snapshot,
            from: previousSnapshot,
            visibilityAssignmentGranularity: visibilityAssignmentGranularity
        ) == nil
    }

    public func logicalSectionVerificationFailure(
        _ operation: MenuBarMoveOperation,
        in snapshot: MenuBarSnapshot,
        from previousSnapshot: MenuBarSnapshot,
        visibilityAssignmentGranularity: MenuBarVisibilityAssignmentGranularity?
    ) -> LogicalSectionVerificationFailure? {
        guard let previousItem = previousSnapshot.items.first(where: {
            $0.id == operation.itemID
        }) else { return .sourceMissing }

        if visibilityAssignmentGranularity == .applicationGroupAndKnownSystemItem,
           !previousItem.id.bundleIdentifier.lowercased().hasPrefix("com.apple.")
        {
            let bundleIdentifier = previousItem.id.bundleIdentifier
            let previousGroup = previousSnapshot.items.filter {
                $0.id.bundleIdentifier == bundleIdentifier
            }
            let currentGroup = snapshot.items.filter {
                $0.id.bundleIdentifier == bundleIdentifier
            }
            let previousIdentities = Set(previousGroup.map { LogicalSemanticIdentity($0.id) })
            let currentIdentities = Set(currentGroup.map { LogicalSemanticIdentity($0.id) })
            // Golden Gate can collapse several status-item AX roots into one
            // live root after either app-scoped visibility transition, and it
            // can briefly publish both old and rebound occurrence aliases.
            // Multiplicity is therefore not an independently verifiable
            // property. Every semantic identity that remains observable must
            // still belong to the prior application group; convergence is
            // confirmed separately from two consecutive observations.
            let identitiesMatch = currentIdentities.isSubset(of: previousIdentities)
            guard !currentGroup.isEmpty else { return .applicationGroupEmpty }
            guard identitiesMatch else { return .semanticIdentityChanged }
            guard currentGroup.allSatisfy({ $0.section == operation.section }) else {
                return .requestedSectionMissing
            }
            guard operation.destinationDisplayID.map({ displayID in
                currentGroup.allSatisfy { $0.displayID == displayID }
            }) != false else {
                return .requestedDisplayMissing
            }
            guard unchangedLogicalItemsMatch(
                previousSnapshot,
                snapshot,
                excludingPrevious: Set(previousGroup.map(\.id)),
                excludingCurrent: Set(currentGroup.map(\.id))
            ) else {
                return .unrelatedLayoutChanged
            }
            return nil
        }

        guard let item = snapshot.items.first(where: { $0.id == operation.itemID }),
              item.section == operation.section
        else { return .itemMissing }
        guard operation.destinationDisplayID.map({ item.displayID == $0 }) != false else {
            return .requestedDisplayMissing
        }
        guard unchangedLogicalItemsMatch(
            previousSnapshot,
            snapshot,
            excludingPrevious: [operation.itemID],
            excludingCurrent: [operation.itemID]
        ) else {
            return .unrelatedLayoutChanged
        }
        return nil
    }

    private struct LogicalSemanticIdentity: Hashable {
        let bundleIdentifier: String
        let accessibilityIdentifier: String?
        let title: String?
        let fallbackFingerprint: String?

        init(_ id: MenuBarItemID) {
            bundleIdentifier = id.bundleIdentifier
            accessibilityIdentifier = id.accessibilityIdentifier
            title = id.title
            fallbackFingerprint = id.fallbackFingerprint
        }
    }

    private func unchangedLogicalItemsMatch(
        _ previousSnapshot: MenuBarSnapshot,
        _ snapshot: MenuBarSnapshot,
        excludingPrevious previousExcludedIDs: Set<MenuBarItemID>,
        excludingCurrent currentExcludedIDs: Set<MenuBarItemID>
    ) -> Bool {
        let previousByID = Dictionary(uniqueKeysWithValues: previousSnapshot.items.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        let sharedIDs = Set(previousByID.keys)
            .subtracting(previousExcludedIDs)
            .intersection(Set(currentByID.keys).subtracting(currentExcludedIDs))
        // Golden Gate owns native ordering. A visibility transaction can make
        // AX re-enumerate otherwise unchanged status-item roots in a different
        // order even though no native item moved. The logical backend must not
        // reinterpret that observation order as a mutation. It does, however,
        // still verify every stable unaffected item remains assigned to the
        // same section and display, so an unrelated visibility or display
        // side effect continues to fail closed.
        return sharedIDs.allSatisfy { id in
            previousByID[id]?.section == currentByID[id]?.section &&
                previousByID[id]?.displayID == currentByID[id]?.displayID
        }
    }

    public func restoreOperations(for snapshot: MenuBarSnapshot) -> [MenuBarMoveOperation] {
        MenuBarSection.allCases.flatMap { section in
            snapshot.items
                .filter { $0.section == section }
                .enumerated()
                .map { index, descriptor in
                    MenuBarMoveOperation(
                        itemID: descriptor.id,
                        section: section,
                        index: index,
                        destinationDisplayID: descriptor.displayID
                    )
                }
        }
    }
}
