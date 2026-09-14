import AppKit
@preconcurrency import AXSwift
import BarlineCore
import CryptoKit
import Foundation
import os

/// Read-only menu-bar inventory for macOS 27, where WindowServer no longer
/// exposes one window per status item. Accessibility remains the auditable,
/// public source of item identity, ownership, geometry, and order.
@available(macOS 27.0, *)
enum GoldenGateAXInventory {
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

    private struct Entry {
        let observation: Observation
        let element: AXUIElement
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

    private static func collectFresh() throws -> [Observation] {
        try collectFreshEntries().map(\.observation)
    }

    static func activate(_ itemID: MenuBarItemID, button: MenuBarMouseButton) throws {
        guard button == .left else {
            throw MenuBarBackendError.unavailableCapability(
                "Golden Gate Accessibility activation for non-left click"
            )
        }
        let entries = try collectFreshEntries()
        var occurrenceBySemanticKey = [String: Int]()
        for entry in entries {
            let observation = entry.observation
            let semanticKey = "\(observation.bundleIdentifier.lowercased())|\(observation.stableTitle.lowercased())"
            let occurrence = occurrenceBySemanticKey[semanticKey, default: 0]
            occurrenceBySemanticKey[semanticKey] = occurrence + 1
            guard identifier(for: observation, occurrence: occurrence) == itemID else {
                continue
            }
            AXUIElementSetMessagingTimeout(entry.element, 0.25)
            let result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
            switch GoldenGateAXActivationPolicy.disposition(forAXError: result.rawValue) {
            case .delivered, .deliveredIndeterminately:
                // `cannotComplete` is explicitly not retried. The caller's
                // interface observer determines whether an interface appeared.
                return
            case .failed:
                throw MenuBarBackendError.operationFailed(
                    "Golden Gate Accessibility activation failed"
                )
            }
        }
        throw MenuBarBackendError.staleItem(itemID)
    }

    static func identifier(for observation: Observation, occurrence: Int) -> MenuBarItemID {
        MenuBarItemID(
            bundleIdentifier: observation.bundleIdentifier,
            accessibilityIdentifier: observation.identifier,
            title: observation.stableTitle,
            alias: "occurrence-\(occurrence)",
            fallbackFingerprint: fallbackFingerprint(
                bundleIdentifier: observation.bundleIdentifier,
                stableTitle: observation.stableTitle
            )
        )
    }

    private static func collectFreshEntries() throws -> [Entry] {
        guard AXHelpers.isProcessTrusted() else {
            throw MenuBarBackendError.unavailableCapability("Accessibility menu bar inventory")
        }

        var entries = [Entry]()
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

                entries.append(
                    Entry(
                        observation: Observation(
                            bundleIdentifier: bundleIdentifier,
                            localizedApplicationName: runningApplication.localizedName,
                            identifier: identifier,
                            displayTitle: displayTitle,
                            stableTitle: stableTitle,
                            bounds: semanticBounds,
                            ownerPID: AXHelpers.pid(for: child)
                                ?? runningApplication.processIdentifier
                        ),
                        element: child.element
                    )
                )
            }
        }

        let deduplicated = deduplicatingMenuBarAgentRevends(entries)
        logger.info(
            "Accessibility inventory completed: raw=\(entries.count, privacy: .public), deduplicated=\(deduplicated.count, privacy: .public)"
        )
        return deduplicated
            .sorted {
                if abs($0.observation.bounds.minY - $1.observation.bounds.minY) > duplicateTolerance {
                    return $0.observation.bounds.minY < $1.observation.bounds.minY
                }
                return $0.observation.bounds.minX < $1.observation.bounds.minX
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
        _ entries: [Entry]
    ) -> [Entry] {
        let directOrigins = entries
            .filter { $0.observation.bundleIdentifier != menuBarAgentBundleIdentifier }
            .map(\.observation.bounds.origin)
        guard !directOrigins.isEmpty else { return entries }

        return entries.filter { entry in
            let observation = entry.observation
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
