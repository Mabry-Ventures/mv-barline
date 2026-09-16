//
//  GoldenGateMenuBarSnapshotBuilder.swift
//  BarlineCore
//

import Foundation

/// A privacy-bounded, public-API observation captured by Barline's trusted app
/// process on macOS 27 and later.
public struct GoldenGateMenuBarObservation: Equatable, Sendable {
    public let bundleIdentifier: String
    public let localizedApplicationName: String?
    public let identifier: String?
    public let displayTitle: String
    public let stableTitle: String
    public let fallbackFingerprint: String
    public let bounds: MenuBarRect
    public let ownerProcessIdentifier: Int32

    public init(
        bundleIdentifier: String,
        localizedApplicationName: String?,
        identifier: String?,
        displayTitle: String,
        stableTitle: String,
        fallbackFingerprint: String,
        bounds: MenuBarRect,
        ownerProcessIdentifier: Int32
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedApplicationName = localizedApplicationName
        self.identifier = identifier
        self.displayTitle = displayTitle
        self.stableTitle = stableTitle
        self.fallbackFingerprint = fallbackFingerprint
        self.bounds = bounds
        self.ownerProcessIdentifier = ownerProcessIdentifier
    }
}

/// Converts app-process Accessibility observations into the same stable domain
/// snapshot consumed by Barline on earlier macOS releases.
public enum GoldenGateMenuBarSnapshotBuilder {
    public static func identifiers(
        for observations: [GoldenGateMenuBarObservation]
    ) -> [MenuBarItemID] {
        var occurrenceBySemanticKey = [String: Int]()
        return observations.map { observation in
            let semanticKey = "\(observation.bundleIdentifier.lowercased())|\(observation.stableTitle.lowercased())"
            let occurrence = occurrenceBySemanticKey[semanticKey, default: 0]
            occurrenceBySemanticKey[semanticKey] = occurrence + 1
            return MenuBarItemID(
                bundleIdentifier: observation.bundleIdentifier,
                accessibilityIdentifier: observation.identifier,
                title: observation.stableTitle,
                alias: "occurrence-\(occurrence)",
                fallbackFingerprint: observation.fallbackFingerprint
            )
        }
    }

    public static func build(
        observations: [GoldenGateMenuBarObservation],
        displayIdentities: [MenuBarDisplayIdentity],
        activeDisplayID: MenuBarDisplayID,
        activeDisplayBounds: MenuBarRect,
        appSigningIdentifier: String,
        rememberedSections: [MenuBarItemID: MenuBarSection] = [:],
        assignedSections: [MenuBarItemID: MenuBarSection] = [:],
        generation: UInt64,
        capturedAt: Date = Date()
    ) throws -> MenuBarSnapshot {
        let displayIDs = Set(displayIdentities.map(\.runtimeID))
        guard displayIDs.contains(activeDisplayID) else {
            throw MenuBarBackendError.unavailableCapability("active menu bar display")
        }

        let identifiers = identifiers(for: observations)
        let preliminary = zip(observations.indices, zip(observations, identifiers)).map {
            order, pair in
            let (observation, itemID) = pair
            let isControlItem = observation.bundleIdentifier.caseInsensitiveCompare(
                appSigningIdentifier
            ) == .orderedSame && observation.stableTitle.hasPrefix("Barline.ControlItem.")
            let ownership: MenuBarSourceOwnership = observation.bundleIdentifier.hasPrefix(
                "com.apple."
            ) ? .system : .application
            let semantics = semanticFlags(
                namespace: observation.bundleIdentifier,
                title: observation.stableTitle
            )
            return MenuBarItemDescriptor(
                id: itemID,
                section: .visible,
                order: order,
                displayID: activeDisplayID,
                isSystemItem: ownership == .system,
                sourceOwnership: ownership,
                isBarlineControlItem: isControlItem,
                tagNamespace: isControlItem
                    ? appSigningIdentifier
                    : observation.bundleIdentifier,
                title: observation.stableTitle,
                displayName: presentationName(for: observation),
                ownerProcessIdentifier: observation.ownerProcessIdentifier,
                sourceProcessIdentifier: observation.ownerProcessIdentifier,
                bounds: observation.bounds,
                isOnScreen: intersects(activeDisplayBounds, observation.bounds),
                isMovable: false,
                canBeHidden: semantics.canBeHidden,
                isBentoBox: semantics.isBentoBox,
                isSystemClone: semantics.isSystemClone,
                isResponsive: true
            )
        }

        guard let hiddenControl = preliminary.first(where: {
            $0.isBarlineControlItem && $0.title == "Barline.ControlItem.Hidden"
        }) else {
            throw MenuBarBackendError.unavailableCapability("Barline section controls")
        }
        let alwaysHiddenControl = preliminary.first {
            $0.isBarlineControlItem && $0.title == "Barline.ControlItem.AlwaysHidden"
        }
        let descriptors = try preliminary.map { descriptor in
            let section: MenuBarSection
            if descriptor.isBarlineControlItem {
                section = switch descriptor.title {
                case "Barline.ControlItem.AlwaysHidden": .alwaysHidden
                case "Barline.ControlItem.Hidden": .hidden
                default: .visible
                }
            } else {
                if let assigned = assignedSections[descriptor.id] {
                    return descriptor.replacingSection(assigned)
                }
                if let remembered = rememberedSections[descriptor.id] {
                    return descriptor.replacingSection(remembered)
                }
                guard let classified = MenuBarDividerSectionClassifier.classify(
                    itemBounds: descriptor.bounds,
                    hiddenControlBounds: hiddenControl.bounds,
                    alwaysHiddenControlBounds: alwaysHiddenControl?.bounds
                ) else {
                    throw MenuBarBackendError.unavailableCapability(
                        "unambiguous Barline section geometry"
                    )
                }
                section = classified
            }
            return descriptor.replacingSection(section)
        }

        return MenuBarSnapshot(
            generation: generation,
            capturedAt: capturedAt,
            // The builder owns identity and divider geometry only. Runtime
            // movability depends on an exact macOS 27 position-table key and
            // is applied by the platform provider after the table is read.
            items: descriptors.map { $0.replacing(isMovable: false) },
            displayIDs: displayIDs,
            displayIdentities: displayIdentities,
            activeSpaceIsValid: !displayIDs.isEmpty,
            menuTrackingIsActive: false
        )
    }

    private static func semanticFlags(
        namespace: String,
        title: String
    ) -> (canBeHidden: Bool, isBentoBox: Bool, isSystemClone: Bool) {
        let normalizedNamespace = namespace.lowercased()
        let isControlCenter = normalizedNamespace == "com.apple.controlcenter"
        let isBentoBox = isControlCenter && title.hasPrefix("BentoBox")
        let isClock = isControlCenter && title == "Clock"
        let isSystemClone = title == "System Status Item Clone" &&
            !normalizedNamespace.hasPrefix("com.apple.")
        let explicitlyNonHideable = isControlCenter && [
            "AudioVideoModule",
            "FaceTime",
        ].contains(title) || (
            title == "Item-0" && [
                "com.apple.controlcenter",
                "com.apple.screencaptureui",
            ].contains(normalizedNamespace)
        )
        return (
            canBeHidden: !isClock && !isBentoBox && !explicitlyNonHideable,
            isBentoBox: isBentoBox,
            isSystemClone: isSystemClone
        )
    }

    private static func presentationName(
        for observation: GoldenGateMenuBarObservation
    ) -> String {
        let generatedPrefix = "Item-"
        if observation.displayTitle.hasPrefix(generatedPrefix),
           Int(observation.displayTitle.dropFirst(generatedPrefix.count)) != nil
        {
            return observation.localizedApplicationName ?? observation.displayTitle
        }
        return observation.displayTitle
    }

    private static func intersects(_ lhs: MenuBarRect, _ rhs: MenuBarRect) -> Bool {
        lhs.x < rhs.x + rhs.width && rhs.x < lhs.x + lhs.width &&
            lhs.y < rhs.y + rhs.height && rhs.y < lhs.y + lhs.height
    }
}

/// Rebinds an item after a temporary menu-bar move changes only its
/// order-derived occurrence alias. Every semantic identity field must still
/// agree, and ambiguous duplicates fail closed.
public enum GoldenGateMenuBarIdentityResolver {
    public static func resolve(
        _ requestedID: MenuBarItemID,
        among candidateIDs: [MenuBarItemID]
    ) -> MenuBarItemID? {
        if candidateIDs.contains(requestedID) {
            return requestedID
        }
        let semanticMatches = candidateIDs.filter { candidateID in
            candidateID.bundleIdentifier == requestedID.bundleIdentifier &&
                candidateID.accessibilityIdentifier == requestedID.accessibilityIdentifier &&
                candidateID.title == requestedID.title &&
                candidateID.fallbackFingerprint == requestedID.fallbackFingerprint
        }
        return semanticMatches.count == 1 ? semanticMatches[0] : nil
    }
}
