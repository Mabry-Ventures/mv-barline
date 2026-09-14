//
//  GoldenGateAXSnapshotProvider.swift
//  Barline
//

@preconcurrency import AppKit
import BarlineCore
import CoreGraphics
import CryptoKit
import Foundation
import os

/// macOS grants Accessibility to the signed application identity, not to its
/// embedded XPC service. Keep public AX inventory here in the trusted app and
/// leave all private WindowServer access isolated in BarlineMenuService.
actor GoldenGateAXSnapshotProvider {
    private struct RememberedAssignment: Codable {
        let itemID: MenuBarItemID
        let section: BarlineCore.MenuBarSection
    }

    private struct RememberedAssignments: Codable {
        let version: Int
        let assignments: [RememberedAssignment]
    }

    private struct ElementMetadata {
        let identifier: String?
        let accessibilityDescription: String?
        let title: String?
        let bounds: CGRect?
    }

    private static let maximumItemHeight: CGFloat = 40
    private static let duplicateTolerance: CGFloat = 1
    private static let cacheLifetimeNanoseconds: UInt64 = 100_000_000
    private static let menuBarAgentBundleIdentifier = "com.apple.MenuBarAgent"
    private static let rememberedSectionsKey = "GoldenGateRememberedMenuBarSections"
    private static let maximumRememberedBytes = 256 * 1024
    private static let maximumRememberedAssignments = 512

    private let logger = Logger(category: "GoldenGateAXSnapshotProvider")
    private var generation: UInt64 = 0
    private var cachedAt: UInt64?
    private var cachedSnapshot: MenuBarSnapshot?
    private var rememberedSections = GoldenGateAXSnapshotProvider.loadRememberedSections()

    var capabilities: MenuBarCapabilities {
        get async {
            let canSnapshot = (try? snapshot()) != nil
            return MenuBarCapabilities(
                canSnapshot: canSnapshot,
                canMove: false,
                canReveal: false,
                canActivate: false,
                canRestore: false,
                canCapture: false
            )
        }
    }

    func snapshot() throws -> MenuBarSnapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cachedAt,
           let cachedSnapshot,
           now >= cachedAt,
           now - cachedAt < Self.cacheLifetimeNanoseconds
        {
            return cachedSnapshot
        }

        guard AXHelpers.isProcessTrusted() else {
            throw MenuBarBackendError.unavailableCapability("Accessibility menu bar inventory")
        }
        let observations = collectObservations()
        guard !observations.isEmpty else {
            throw MenuBarBackendError.unavailableCapability("Accessibility menu bar inventory")
        }
        let activeDisplays = activeDisplayIDs()
        let displayIdentities = activeDisplays.map { displayID in
            MenuBarDisplayIdentity(
                runtimeID: stableDisplayID(displayID),
                hardwareFingerprint: hardwareFingerprint(for: displayID)
            )
        }
        guard let activeScreen = NSScreen.screenWithActiveMenuBar,
              activeDisplays.contains(activeScreen.displayID)
        else {
            throw MenuBarBackendError.unavailableCapability("active menu bar display")
        }
        generation &+= 1
        let activeBounds = CGDisplayBounds(activeScreen.displayID)
        let signingIdentifier = Bundle.main.bundleIdentifier
            ?? "com.mabryventures.Barline"
        let hiddenControlUsesLiveGeometry = observations.contains { observation in
            observation.bundleIdentifier.caseInsensitiveCompare(signingIdentifier) == .orderedSame &&
                observation.stableTitle == "Barline.ControlItem.Hidden" &&
                activeBounds.intersects(CGRect(
                    x: observation.bounds.x,
                    y: observation.bounds.y,
                    width: observation.bounds.width,
                    height: observation.bounds.height
                ))
        }
        let result = try GoldenGateMenuBarSnapshotBuilder.build(
            observations: observations,
            displayIdentities: displayIdentities,
            activeDisplayID: stableDisplayID(activeScreen.displayID),
            activeDisplayBounds: MenuBarRect(
                x: activeBounds.minX,
                y: activeBounds.minY,
                width: activeBounds.width,
                height: activeBounds.height
            ),
            appSigningIdentifier: signingIdentifier,
            rememberedSections: hiddenControlUsesLiveGeometry ? [:] : rememberedSections,
            generation: generation
        )
        if hiddenControlUsesLiveGeometry {
            rememberSections(from: result)
        }
        cachedAt = now
        cachedSnapshot = result
        logger.info(
            "Main-process Golden Gate inventory completed: items=\(result.items.count, privacy: .public), controls=\(result.items.count(where: \.isBarlineControlItem), privacy: .public)"
        )
        return result
    }

    func health() async -> MenuBarBackendHealth {
        let available = (try? snapshot()) != nil
        return MenuBarBackendHealth(
            backendName: "GoldenGateMainProcessAX",
            state: available ? .healthy : .unavailable,
            message: available ? nil : "Accessibility inventory is unavailable"
        )
    }

    func restart() {
        cachedAt = nil
        cachedSnapshot = nil
    }

    private static func loadRememberedSections() -> [MenuBarItemID: BarlineCore.MenuBarSection] {
        guard let data = UserDefaults.standard.data(forKey: rememberedSectionsKey),
              data.count <= maximumRememberedBytes,
              let document = try? JSONDecoder().decode(RememberedAssignments.self, from: data),
              document.version == 1,
              document.assignments.count <= maximumRememberedAssignments
        else {
            return [:]
        }
        var result = [MenuBarItemID: BarlineCore.MenuBarSection]()
        for assignment in document.assignments {
            guard assignment.itemID.isPlausiblyStable,
                  result.updateValue(assignment.section, forKey: assignment.itemID) == nil
            else {
                return [:]
            }
        }
        return result
    }

    private func rememberSections(from snapshot: MenuBarSnapshot) {
        let assignments = snapshot.items
            .filter { !$0.isBarlineControlItem && $0.id.isPlausiblyStable }
            .prefix(Self.maximumRememberedAssignments)
            .map { RememberedAssignment(itemID: $0.id, section: $0.section) }
        let document = RememberedAssignments(version: 1, assignments: assignments)
        guard let data = try? JSONEncoder().encode(document),
              data.count <= Self.maximumRememberedBytes
        else {
            return
        }
        rememberedSections = Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.itemID, $0.section)
        })
        UserDefaults.standard.set(data, forKey: Self.rememberedSectionsKey)
    }

    private func collectObservations() -> [GoldenGateMenuBarObservation] {
        var observations = [GoldenGateMenuBarObservation]()
        for runningApplication in NSWorkspace.shared.runningApplications
            where !runningApplication.isTerminated
        {
            guard
                let application = AXHelpers.application(for: runningApplication),
                let extrasMenuBar = AXHelpers.extrasMenuBar(for: application)
            else {
                continue
            }

            let bundleIdentifier = runningApplication.bundleIdentifier
                ?? "barline.unknown-menu-owner"
            var unnamedIndex = 0
            for child in AXHelpers.children(for: extrasMenuBar) {
                guard let bounds = AXHelpers.frame(for: child),
                      bounds.height > 0,
                      bounds.height <= Self.maximumItemHeight,
                      bounds.width > 0
                else {
                    continue
                }

                let candidates = [child] + AXHelpers.children(for: child)
                let metadata = candidates.map { element in
                    ElementMetadata(
                        identifier: nonempty(AXHelpers.identifier(for: element)),
                        accessibilityDescription: nonempty(
                            AXHelpers.accessibilityDescription(for: element)
                        ),
                        title: nonempty(AXHelpers.title(for: element)),
                        bounds: AXHelpers.frame(for: element)
                    )
                }
                let identifier = metadata.compactMap(\.identifier).first
                let accessibilityDescription = metadata.compactMap(
                    \.accessibilityDescription
                ).first
                let title = metadata.compactMap(\.title).first
                let fallbackTitle = "Item-\(unnamedIndex)"
                let displayTitle = title ?? accessibilityDescription ?? identifier ?? fallbackTitle
                if title == nil, accessibilityDescription == nil, identifier == nil {
                    unnamedIndex += 1
                }
                let stableTitle = identifier ?? accessibilityDescription ?? displayTitle
                let semanticBounds = semanticBounds(
                    in: metadata,
                    identifier: identifier,
                    accessibilityDescription: accessibilityDescription,
                    title: title
                ) ?? bounds
                guard !isNativeOverflowPlaceholder(
                    bundleIdentifier: bundleIdentifier,
                    title: stableTitle
                ) else {
                    continue
                }

                observations.append(
                    GoldenGateMenuBarObservation(
                        bundleIdentifier: bundleIdentifier,
                        localizedApplicationName: runningApplication.localizedName,
                        identifier: identifier,
                        displayTitle: displayTitle,
                        stableTitle: stableTitle,
                        fallbackFingerprint: fallbackFingerprint(
                            bundleIdentifier: bundleIdentifier,
                            stableTitle: stableTitle
                        ),
                        bounds: MenuBarRect(
                            x: semanticBounds.minX,
                            y: semanticBounds.minY,
                            width: semanticBounds.width,
                            height: semanticBounds.height
                        ),
                        ownerProcessIdentifier: AXHelpers.pid(for: child)
                            ?? runningApplication.processIdentifier
                    )
                )
            }
        }
        return deduplicatingMenuBarAgentRevends(observations).sorted {
            if abs($0.bounds.y - $1.bounds.y) > Self.duplicateTolerance {
                return $0.bounds.y < $1.bounds.y
            }
            return $0.bounds.x < $1.bounds.x
        }
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return []
        }
        return Array(displays.prefix(Int(count)))
    }

    private func stableDisplayID(_ displayID: CGDirectDisplayID) -> MenuBarDisplayID {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return MenuBarDisplayID("display-\(displayID)")
        }
        return MenuBarDisplayID(
            CFUUIDCreateString(nil, unmanagedUUID.takeRetainedValue()) as String
        )
    }

    private func hardwareFingerprint(
        for displayID: CGDirectDisplayID
    ) -> MenuBarDisplayHardwareFingerprint? {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let unknownVendor: UInt32 = 0x756E_6B6E
        let genericProduct: UInt32 = 0x0717
        guard vendor != 0,
              vendor != unknownVendor,
              model != 0,
              model != genericProduct,
              serial != 0
        else { return nil }

        var payload = Data("com.mabryventures.Barline.display-fingerprint.v1\0".utf8)
        for component in [vendor, model, serial] {
            var bigEndian = component.bigEndian
            withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return MenuBarDisplayHardwareFingerprint("v1:\(digest)")
    }

    private func fallbackFingerprint(
        bundleIdentifier: String,
        stableTitle: String
    ) -> String {
        let digest = SHA256.hash(
            data: Data("\(bundleIdentifier.lowercased())|\(stableTitle.lowercased())".utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func deduplicatingMenuBarAgentRevends(
        _ observations: [GoldenGateMenuBarObservation]
    ) -> [GoldenGateMenuBarObservation] {
        let directOrigins = observations
            .filter { $0.bundleIdentifier != Self.menuBarAgentBundleIdentifier }
            .map { ($0.bounds.x, $0.bounds.y) }
        guard !directOrigins.isEmpty else { return observations }

        return observations.filter { observation in
            guard observation.bundleIdentifier == Self.menuBarAgentBundleIdentifier else {
                return true
            }
            return !directOrigins.contains { origin in
                abs(origin.0 - observation.bounds.x) <= Self.duplicateTolerance &&
                    abs(origin.1 - observation.bounds.y) <= Self.duplicateTolerance
            }
        }
    }

    private func isNativeOverflowPlaceholder(
        bundleIdentifier: String,
        title: String
    ) -> Bool {
        guard bundleIdentifier == Self.menuBarAgentBundleIdentifier else { return false }
        let normalized = title.filter { !$0.isWhitespace }
        if normalized.caseInsensitiveCompare("AXOverflowButton") == .orderedSame {
            return true
        }
        let glyphs = Set("<>‹›«»")
        return !normalized.isEmpty && normalized.count <= 4 &&
            normalized.allSatisfy { glyphs.contains($0) }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func semanticBounds(
        in metadata: [ElementMetadata],
        identifier: String?,
        accessibilityDescription: String?,
        title: String?
    ) -> CGRect? {
        let selected: ElementMetadata? = if let identifier {
            metadata.first { $0.identifier == identifier }
        } else if let accessibilityDescription {
            metadata.first { $0.accessibilityDescription == accessibilityDescription }
        } else if let title {
            metadata.first { $0.title == title }
        } else {
            nil
        }
        guard let bounds = selected?.bounds,
              bounds.height > 0,
              bounds.height <= Self.maximumItemHeight,
              bounds.width > 0
        else {
            return nil
        }
        return bounds
    }
}
