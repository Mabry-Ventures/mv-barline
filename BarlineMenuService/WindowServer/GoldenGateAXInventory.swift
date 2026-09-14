import AppKit
import BarlineCore
import CryptoKit
import Foundation
import os

/// Read-only menu-bar inventory for macOS 27, where WindowServer no longer
/// exposes one window per status item. Accessibility remains the auditable,
/// public source of item identity, ownership, geometry, and order.
@available(macOS 27.0, *)
enum GoldenGateAXInventory {
    struct ResolvedItem {
        let id: MenuBarItemID
        let ownerPID: pid_t
    }

    struct Observation {
        let bundleIdentifier: String
        let localizedApplicationName: String?
        let identifier: String?
        let displayTitle: String
        let stableTitle: String
        let bounds: CGRect
        let ownerPID: pid_t
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
    private static let logger = Logger(category: "GoldenGateAXInventory")
    private static let cache = OSAllocatedUnfairLock(
        initialState: (capturedAt: UInt64?.none, observations: [Observation]())
    )

    static func collect() throws -> [Observation] {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cached = cache.withLock({ state -> [Observation]? in
            guard let capturedAt = state.capturedAt,
                  now >= capturedAt,
                  now - capturedAt < cacheLifetimeNanoseconds
            else {
                return nil
            }
            return state.observations
        }) {
            return cached
        }

        let observations = try collectFresh()
        cache.withLock { state in
            state = (capturedAt: now, observations: observations)
        }
        return observations
    }

    static func identifiers(for observations: [Observation]) -> [MenuBarItemID] {
        GoldenGateMenuBarSnapshotBuilder.identifiers(
            for: observations.map { observation in
                GoldenGateMenuBarObservation(
                    bundleIdentifier: observation.bundleIdentifier,
                    localizedApplicationName: observation.localizedApplicationName,
                    identifier: observation.identifier,
                    displayTitle: observation.displayTitle,
                    stableTitle: observation.stableTitle,
                    fallbackFingerprint: fallbackFingerprint(
                        bundleIdentifier: observation.bundleIdentifier,
                        stableTitle: observation.stableTitle
                    ),
                    bounds: MenuBarRect(
                        x: observation.bounds.minX,
                        y: observation.bounds.minY,
                        width: observation.bounds.width,
                        height: observation.bounds.height
                    ),
                    ownerProcessIdentifier: observation.ownerPID
                )
            }
        )
    }

    static func resolve(_ itemID: MenuBarItemID) throws -> ResolvedItem {
        let observations = try collect()
        let identifiers = identifiers(for: observations)
        guard let resolvedID = GoldenGateMenuBarIdentityResolver.resolve(
            itemID,
            among: identifiers
        ),
            let index = identifiers.firstIndex(of: resolvedID)
        else {
            throw MenuBarBackendError.staleItem(itemID)
        }
        return ResolvedItem(id: resolvedID, ownerPID: observations[index].ownerPID)
    }

    private static func collectFresh() throws -> [Observation] {
        guard AXHelpers.isProcessTrusted() else {
            throw MenuBarBackendError.unavailableCapability("Accessibility menu bar inventory")
        }

        var observations = [Observation]()
        for runningApplication in NSWorkspace.shared.runningApplications where !runningApplication.isTerminated {
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
                      bounds.height <= maximumItemHeight,
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
                    Observation(
                        bundleIdentifier: bundleIdentifier,
                        localizedApplicationName: runningApplication.localizedName,
                        identifier: identifier,
                        displayTitle: displayTitle,
                        stableTitle: stableTitle,
                        bounds: semanticBounds,
                        ownerPID: AXHelpers.pid(for: child)
                            ?? runningApplication.processIdentifier
                    )
                )
            }
        }

        let deduplicated = deduplicatingMenuBarAgentRevends(observations)
        logger.info(
            "Accessibility inventory completed: raw=\(observations.count, privacy: .public), deduplicated=\(deduplicated.count, privacy: .public)"
        )
        return deduplicated
            .sorted {
                if abs($0.bounds.minY - $1.bounds.minY) > duplicateTolerance {
                    return $0.bounds.minY < $1.bounds.minY
                }
                return $0.bounds.minX < $1.bounds.minX
            }
    }

    static func fallbackFingerprint(
        bundleIdentifier: String,
        stableTitle: String
    ) -> String {
        let digest = SHA256.hash(
            data: Data("\(bundleIdentifier.lowercased())|\(stableTitle.lowercased())".utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func deduplicatingMenuBarAgentRevends(
        _ observations: [Observation]
    ) -> [Observation] {
        let directOrigins = observations
            .filter { $0.bundleIdentifier != menuBarAgentBundleIdentifier }
            .map(\.bounds.origin)
        guard !directOrigins.isEmpty else { return observations }

        return observations.filter { observation in
            guard observation.bundleIdentifier == menuBarAgentBundleIdentifier else {
                return true
            }
            return !directOrigins.contains { origin in
                abs(origin.x - observation.bounds.minX) <= duplicateTolerance &&
                    abs(origin.y - observation.bounds.minY) <= duplicateTolerance
            }
        }
    }

    private static func isNativeOverflowPlaceholder(
        bundleIdentifier: String,
        title: String
    ) -> Bool {
        guard bundleIdentifier == menuBarAgentBundleIdentifier else { return false }
        let normalized = title.filter { !$0.isWhitespace }
        if normalized.caseInsensitiveCompare("AXOverflowButton") == .orderedSame {
            return true
        }
        let glyphs = Set("<>‹›«»")
        return !normalized.isEmpty && normalized.count <= 4 &&
            normalized.allSatisfy { glyphs.contains($0) }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func semanticBounds(
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
              bounds.height <= maximumItemHeight,
              bounds.width > 0
        else {
            return nil
        }
        return bounds
    }
}
