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
    /// Collapses live readings so an item keeps one identity while its title
    /// changes. A menu bar title that renders processor load, temperature,
    /// transfer rate, or battery percentage is rewritten every few seconds;
    /// identity derived from it changes with it, and every saved assignment
    /// for that application stops resolving. Digit runs (with any decimal
    /// separator inside them) become a placeholder, so "CPU 9%" and "CPU 43%"
    /// share an identity while "Control Center" and "Clock" keep theirs.
    public static func identityTitle(_ title: String) -> String {
        var result = ""
        var index = title.startIndex
        var pendingNumber = false
        while index < title.endIndex {
            let character = title[index]
            if character.isNumber {
                if !pendingNumber {
                    result.append("<n>")
                    pendingNumber = true
                }
                index = title.index(after: index)
                continue
            }
            if pendingNumber, character == "." || character == "," {
                let next = title.index(after: index)
                if next < title.endIndex, title[next].isNumber {
                    index = next
                    continue
                }
            }
            pendingNumber = false
            result.append(character)
            index = title.index(after: index)
        }
        return result
    }

    public static func identifiers(
        for observations: [GoldenGateMenuBarObservation]
    ) -> [MenuBarItemID] {
        var occurrenceBySemanticKey = [MenuBarItemID: Int]()
        return observations.map { observation in
            if observation.bundleIdentifier.caseInsensitiveCompare("com.apple.MenuBarAgent") == .orderedSame,
               observation.identifier == "com.apple.menuextra.focusmode"
            {
                // The Focus menu extra is a platform-owned control whose
                // presence is represented by an atomic runtime sidecar. Its
                // identity must not depend on localized wording or occurrence.
                return MenuBarPlatformPresenceIdentity.focusItemID
            }
            // Count only indistinguishable items. Distinct AX identifiers must
            // not exchange aliases when geometry or sibling inventory changes.
            // The structured key shares MenuBarItemID's canonical normalization
            // and cannot collide through separators embedded in a field.
            let semanticKey = MenuBarItemID(
                bundleIdentifier: observation.bundleIdentifier,
                accessibilityIdentifier: observation.identifier,
                title: observation.stableTitle,
                fallbackFingerprint: observation.fallbackFingerprint
            )
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

    /// Section classification is separate from authorization to mutate. The
    /// native policy is selected only by the qualified macOS 27 provider.
    public enum SectionPolicy: Sendable {
        case dividerGeometry
        case nativeVisibilityAssignments
    }

    public static func build(
        observations: [GoldenGateMenuBarObservation],
        displayIdentities: [MenuBarDisplayIdentity],
        activeDisplayID: MenuBarDisplayID,
        displayBounds: [MenuBarDisplayID: MenuBarRect],
        activeSpaceIsValid: Bool,
        menuTrackingIsActive: Bool,
        appSigningIdentifier: String,
        rememberedSections: [MenuBarItemID: MenuBarSection] = [:],
        assignedSections: [MenuBarItemID: MenuBarSection] = [:],
        sectionPolicy: SectionPolicy = .dividerGeometry,
        generation: UInt64,
        capturedAt: Date = Date()
    ) throws -> MenuBarSnapshot {
        let displayIDs = Set(displayIdentities.map(\.runtimeID))
        guard displayIDs.contains(activeDisplayID), Set(displayBounds.keys) == displayIDs else {
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
            let ownerDisplay = MenuBarDisplayOwnershipPolicy.resolve(
                itemBounds: observation.bounds, displays: displayBounds, membershipDisplayIDs: nil
            )
            return MenuBarItemDescriptor(
                id: itemID,
                section: .visible,
                order: order,
                displayID: ownerDisplay,
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
                isOnScreen: ownerDisplay != nil && MenuBarVisibilityPolicy.isClickable(
                    reportedVisible: true, itemBounds: observation.bounds,
                    displayBounds: Array(displayBounds.values)
                ),
                isMovable: false,
                canBeHidden: semantics.canBeHidden,
                isBentoBox: semantics.isBentoBox,
                isSystemClone: semantics.isSystemClone,
                isResponsive: true
            )
        }

        guard preliminary.contains(where: {
            $0.isBarlineControlItem && $0.title == "Barline.ControlItem.Hidden"
        }) else {
            throw MenuBarBackendError.unavailableCapability("Barline section controls")
        }
        let descriptors = preliminary.map { descriptor in
            if MenuBarPlatformPresenceIdentity.isFocusItem(descriptor.id) {
                // Saved legacy assignments cannot turn the native Focus
                // control into a Barline-managed shelf item.
                return descriptor.replacing(
                    section: .visible,
                    isMovable: false,
                    canBeHidden: false
                )
            }
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
                if sectionPolicy == .nativeVisibilityAssignments {
                    if let remembered = rememberedSections[descriptor.id] {
                        return descriptor.replacingSection(remembered)
                    }
                    // Native visibility is a logical assignment, not a
                    // position relative to our collapsed divider. macOS can
                    // park that divider off-screen even while ordinary items
                    // remain visible. New items fail visible without losing
                    // their semantic eligibility for an explicit assignment.
                    // Unresolved display ownership still grants no capability.
                    return descriptor.replacing(
                        section: .visible,
                        isMovable: false,
                        canBeHidden: descriptor.displayID != nil && descriptor.canBeHidden
                    )
                }
                let sameDisplayControls = preliminary.filter {
                    descriptor.displayID != nil && $0.displayID == descriptor.displayID &&
                        $0.isOnScreen && $0.isBarlineControlItem
                }
                let hiddenControls = sameDisplayControls.filter { $0.title == "Barline.ControlItem.Hidden" }
                let alwaysHiddenControls = sameDisplayControls.filter { $0.title == "Barline.ControlItem.AlwaysHidden" }
                guard hiddenControls.count == 1, alwaysHiddenControls.count <= 1,
                      let hiddenControl = hiddenControls.first
                else {
                    if let remembered = rememberedSections[descriptor.id] {
                        return descriptor.replacingSection(remembered)
                    }
                    return descriptor.replacing(section: .visible, isMovable: false, canBeHidden: false)
                }
                guard let classified = MenuBarDividerSectionClassifier.classify(
                    itemBounds: descriptor.bounds,
                    hiddenControlBounds: hiddenControl.bounds,
                    alwaysHiddenControlBounds: alwaysHiddenControls.first?.bounds
                ) else {
                    // A third-party status item can publish a frame that spans
                    // Barline's divider attachment seam. Fail closed for that
                    // item without discarding the rest of a valid inventory:
                    // keep it visible and prohibit concealment until macOS
                    // reports unambiguous geometry on a later refresh.
                    return descriptor.replacing(
                        section: .visible,
                        isMovable: false,
                        canBeHidden: false
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
            activeSpaceIsValid: activeSpaceIsValid,
            menuTrackingIsActive: menuTrackingIsActive
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
