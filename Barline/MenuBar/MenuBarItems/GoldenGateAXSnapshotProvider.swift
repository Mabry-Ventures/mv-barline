//
//  GoldenGateAXSnapshotProvider.swift
//  Barline
//

@preconcurrency import AppKit
@preconcurrency import AXSwift
import BarlineCore
import CoreGraphics
import CryptoKit
import Foundation
import os

/// macOS grants Accessibility to the signed application identity, not to its
/// embedded XPC service. Keep public AX inventory here in the trusted app and
/// leave all private WindowServer access isolated in BarlineMenuService.
actor GoldenGateAXSnapshotProvider {
    private struct ExplicitLayout: Codable {
        let version: Int
        let assignments: [GoldenGateLogicalAssignment]
    }

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

    private struct Entry {
        let observation: GoldenGateMenuBarObservation
        let element: AXUIElement
    }

    private static let maximumItemHeight: CGFloat = 40
    private static let duplicateTolerance: CGFloat = 1
    private static let cacheLifetimeNanoseconds: UInt64 = 100_000_000
    private static let menuBarAgentBundleIdentifier = "com.apple.MenuBarAgent"
    private static let rememberedSectionsKey = "GoldenGateRememberedMenuBarSections"
    private static let explicitLayoutKey = "GoldenGateExplicitMenuBarLayout"
    private static let maximumRememberedBytes = 256 * 1024
    private static let maximumRememberedAssignments = 512

    private let logger = Logger(category: "GoldenGateAXSnapshotProvider")
    private var generation: UInt64 = 0
    private var cachedAt: UInt64?
    private var cachedSnapshot: MenuBarSnapshot?
    private var rememberedSections = GoldenGateAXSnapshotProvider.loadRememberedSections()
    private var explicitAssignments = GoldenGateAXSnapshotProvider.loadExplicitAssignments()
    private let logicalLayoutPlanner = GoldenGateLogicalLayoutPlanner()

    var capabilities: MenuBarCapabilities {
        get async {
            let canSnapshot = (try? snapshot()) != nil
            return MenuBarCapabilities(
                canSnapshot: canSnapshot,
                canMove: canSnapshot,
                canReveal: false,
                canActivate: canSnapshot,
                canRestore: canSnapshot,
                canCapture: false,
                moveDestinationSupport: .logicalSectionsPreserveNativeOrder
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
        let observations = collectEntries().map(\.observation)
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
        let built = try GoldenGateMenuBarSnapshotBuilder.build(
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
            assignedSections: Dictionary(uniqueKeysWithValues: explicitAssignments.map {
                ($0.key, $0.value.section)
            }),
            generation: generation
        )
        let result = built
        if hiddenControlUsesLiveGeometry, explicitAssignments.isEmpty {
            rememberSections(from: result)
        }
        cachedAt = now
        cachedSnapshot = result
        logger.info(
            "Main-process Golden Gate inventory completed: items=\(result.items.count, privacy: .public), controls=\(result.items.count(where: \.isBarlineControlItem), privacy: .public)"
        )
        return result
    }

    func move(_ operation: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
        let before = try snapshot()
        guard let source = before.items.first(where: { $0.id == operation.itemID }) else {
            throw MenuBarBackendError.staleItem(operation.itemID)
        }
        guard source.isMovable else {
            throw MenuBarBackendError.operationFailed("menu bar item cannot be assigned independently")
        }
        if operation.section != .visible, !source.canBeHidden {
            throw MenuBarBackendError.operationFailed("menu bar item cannot be hidden")
        }

        let candidate = try logicalLayoutPlanner.applying(operation, to: before)
        let previousConfiguration = concealmentConfiguration(for: before)
        do {
            try await BarlineMenuService.Connection.shared.configureConcealment(
                concealmentConfiguration(for: candidate)
            )
            try await verifyNativeAssignments([
                source.id: operation.section == .visible,
            ])
        } catch {
            try? await BarlineMenuService.Connection.shared.configureConcealment(
                previousConfiguration
            )
            throw error
        }
        generation = candidate.generation
        rememberExplicitLayout(from: candidate)
        cachedAt = DispatchTime.now().uptimeNanoseconds
        cachedSnapshot = candidate
        return MenuBarMutationResult(
            generation: candidate.generation,
            changedItemIDs: [source.id]
        )
    }

    func restore(_ target: MenuBarSnapshot) async throws -> MenuBarMutationResult {
        let current = try snapshot()
        let candidate = try logicalLayoutPlanner.restoring(target, to: current)
        let previousConfiguration = concealmentConfiguration(for: current)
        let changedItems = candidate.items.filter { candidateItem in
            current.items.first(where: { $0.id == candidateItem.id })?.section != candidateItem.section
        }
        do {
            try await BarlineMenuService.Connection.shared.configureConcealment(
                concealmentConfiguration(for: candidate)
            )
            try await verifyNativeAssignments(
                Dictionary(uniqueKeysWithValues: changedItems.map {
                    ($0.id, $0.section == .visible)
                })
            )
        } catch {
            try? await BarlineMenuService.Connection.shared.configureConcealment(
                previousConfiguration
            )
            throw error
        }
        generation = candidate.generation
        rememberExplicitLayout(from: candidate)
        cachedAt = DispatchTime.now().uptimeNanoseconds
        cachedSnapshot = candidate
        return MenuBarMutationResult(
            generation: candidate.generation,
            changedItemIDs: changedItems.map(\.id)
        )
    }

    func health() async -> MenuBarBackendHealth {
        let available = (try? snapshot()) != nil
        return MenuBarBackendHealth(
            backendName: "GoldenGateMainProcessAX",
            state: available ? .healthy : .unavailable,
            message: available ? nil : "Accessibility inventory is unavailable"
        )
    }

    func activate(_ itemID: MenuBarItemID, button: MenuBarMouseButton) throws {
        guard button == .left else {
            throw MenuBarBackendError.unavailableCapability(
                "Golden Gate Accessibility activation for non-left click"
            )
        }
        guard AXHelpers.isProcessTrusted() else {
            throw MenuBarBackendError.unavailableCapability(
                "Accessibility menu bar activation"
            )
        }
        let entries = collectEntries()
        let identifiers = GoldenGateMenuBarSnapshotBuilder.identifiers(
            for: entries.map(\.observation)
        )
        guard let resolvedID = GoldenGateMenuBarIdentityResolver.resolve(
            itemID,
            among: identifiers
        ),
            let entry = zip(entries, identifiers).first(where: { $0.1 == resolvedID })?.0
        else {
            throw MenuBarBackendError.staleItem(itemID)
        }
        AXUIElementSetMessagingTimeout(entry.element, 0.25)
        let result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
        switch GoldenGateAXActivationPolicy.disposition(forAXError: result.rawValue) {
        case .delivered, .deliveredIndeterminately:
            // `cannotComplete` can arrive after the target handled the action.
            // Never retry it; the caller independently observes the interface.
            return
        case .failed:
            throw MenuBarBackendError.operationFailed(
                "Golden Gate Accessibility activation failed"
            )
        }
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

    private static func loadExplicitAssignments() -> [MenuBarItemID: GoldenGateLogicalAssignment] {
        guard let data = UserDefaults.standard.data(forKey: explicitLayoutKey),
              data.count <= maximumRememberedBytes,
              let document = try? JSONDecoder().decode(ExplicitLayout.self, from: data),
              document.version == 1,
              document.assignments.count <= maximumRememberedAssignments
        else { return [:] }
        var result = [MenuBarItemID: GoldenGateLogicalAssignment]()
        for assignment in document.assignments {
            guard assignment.itemID.isPlausiblyStable,
                  assignment.rank >= 0,
                  result.updateValue(assignment, forKey: assignment.itemID) == nil
            else { return [:] }
        }
        return result
    }

    private func rememberExplicitLayout(from snapshot: MenuBarSnapshot) {
        let assignments = logicalLayoutPlanner.assignmentsForPersistence(
            from: snapshot,
            preserving: explicitAssignments,
            barlineBundleIdentifier: Bundle.main.bundleIdentifier
                ?? "com.mabryventures.Barline",
            maximumCount: Self.maximumRememberedAssignments
        )
        let document = ExplicitLayout(version: 1, assignments: assignments)
        guard let data = try? JSONEncoder().encode(document),
              data.count <= Self.maximumRememberedBytes
        else { return }
        explicitAssignments = Dictionary(uniqueKeysWithValues: document.assignments.map {
            ($0.itemID, $0)
        })
        UserDefaults.standard.set(data, forKey: Self.explicitLayoutKey)
    }

    private func concealmentConfiguration(
        for snapshot: MenuBarSnapshot
    ) -> MenuBarConcealmentConfiguration {
        MenuBarConcealmentConfiguration(
            visibleItemIDs: snapshot.items.filter {
                !$0.isBarlineControlItem && $0.section == .visible
            }.map(\.id),
            concealedItemIDs: snapshot.items.filter {
                !$0.isBarlineControlItem && $0.section != .visible
            }.map(\.id)
        )
    }

    /// The private assertion acknowledges asynchronously and the AX tree
    /// settles independently. Never publish or persist a logical assignment
    /// until the native menu bar has reached the requested visibility.
    private func verifyNativeAssignments(
        _ expectations: [MenuBarItemID: Bool]
    ) async throws {
        guard !expectations.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            try Task.checkCancellation()
            let observedIDs = GoldenGateMenuBarSnapshotBuilder.identifiers(
                for: collectEntries().map(\.observation)
            )
            let didConverge = expectations.allSatisfy { itemID, shouldBeVisible in
                let isVisible = GoldenGateMenuBarIdentityResolver.resolve(
                    itemID,
                    among: observedIDs
                ) != nil
                return isVisible == shouldBeVisible
            }
            if didConverge {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw MenuBarBackendError.operationFailed(
            "native concealment did not reach requested visibility"
        )
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

    private func collectEntries() -> [Entry] {
        var entries = [Entry]()
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

                entries.append(
                    Entry(
                        observation: GoldenGateMenuBarObservation(
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
                        ),
                        element: child.element
                    )
                )
            }
        }
        return deduplicatingMenuBarAgentRevends(entries).sorted {
            if abs($0.observation.bounds.y - $1.observation.bounds.y) > Self.duplicateTolerance {
                return $0.observation.bounds.y < $1.observation.bounds.y
            }
            return $0.observation.bounds.x < $1.observation.bounds.x
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
        _ entries: [Entry]
    ) -> [Entry] {
        let directOrigins = entries
            .filter { $0.observation.bundleIdentifier != Self.menuBarAgentBundleIdentifier }
            .map { ($0.observation.bounds.x, $0.observation.bounds.y) }
        guard !directOrigins.isEmpty else { return entries }

        return entries.filter { entry in
            let observation = entry.observation
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
