//
//  MenuBarItem.swift
//  Barline
//

import BarlineCore
import Cocoa

/// The app-side projection of a helper-validated menu bar item.
///
/// Stable domain identity is the only identity retained outside the helper.
/// Geometry and process metadata are observational snapshot values and are
/// refreshed before helper-side operations.
struct MenuBarItem: CustomStringConvertible, Equatable, Hashable {
    /// Presentation and mutation share the same validated, last-known-good authority.
    static let snapshotCoordinator = MenuBarStateCoordinator(backend: XPCMenuBarBackend())
    let stableID: MenuBarItemID
    let tag: MenuBarItemTag
    let ownerPID: pid_t
    let sourcePID: pid_t?
    let bounds: CGRect
    let title: String?
    let isOnScreen: Bool
    let isMovable: Bool
    let canBeHidden: Bool
    let isControlItem: Bool
    let isBentoBox: Bool
    let isSystemClone: Bool
    let isResponsive: Bool
    let displayName: String

    var owningApplication: NSRunningApplication? {
        guard ownerPID > 0 else { return nil }
        return NSRunningApplication(processIdentifier: ownerPID)
    }

    var sourceApplication: NSRunningApplication? {
        guard let sourcePID, sourcePID > 0 else { return nil }
        return NSRunningApplication(processIdentifier: sourcePID)
    }

    var description: String {
        "\(displayName) (\(tag))"
    }

    var logString: String {
        "menu_bar_item"
    }

    init(descriptor: MenuBarItemDescriptor) {
        stableID = descriptor.id
        tag = MenuBarItemTag(
            namespace: .optional(descriptor.tagNamespace ?? descriptor.id.bundleIdentifier),
            title: descriptor.title ?? descriptor.id.title ?? ""
        )
        ownerPID = descriptor.ownerProcessIdentifier.map { pid_t($0) } ?? 0
        sourcePID = descriptor.sourceProcessIdentifier.map { pid_t($0) }
        bounds = CGRect(descriptor.bounds)
        title = descriptor.title
        isOnScreen = descriptor.isOnScreen
        isMovable = descriptor.isMovable
        canBeHidden = descriptor.canBeHidden
        isControlItem = descriptor.isBarlineControlItem
        isBentoBox = descriptor.isBentoBox
        isSystemClone = descriptor.isSystemClone
        isResponsive = descriptor.isResponsive
        displayName = descriptor.displayName
    }
}

// MARK: - MenuBarItem List

extension MenuBarItem {
    struct ListOption: OptionSet {
        let rawValue: Int

        static let onScreen = ListOption(rawValue: 1 << 0)
        static let activeSpace = ListOption(rawValue: 1 << 1)
    }

    static func getMenuBarItems(
        on display: CGDirectDisplayID? = nil,
        option: ListOption,
        interactionID: UUID? = nil
    ) async -> [MenuBarItem] {
        do {
            return try await loadMenuBarItems(
                on: display,
                option: option,
                interactionID: interactionID
            )
        } catch {
            return []
        }
    }

    /// Loads menu bar items while preserving discovery errors for callers that
    /// need to distinguish a failed snapshot from a legitimate empty result.
    static func loadMenuBarItems(
        on display: CGDirectDisplayID? = nil,
        option: ListOption,
        interactionID: UUID? = nil
    ) async throws -> [MenuBarItem] {
        let snapshot = try await snapshotCoordinator.refresh(interactionID: interactionID)
        let displayBounds = display.map(CGDisplayBounds)
        return snapshot.items
            .filter { descriptor in
                (!option.contains(.onScreen) || descriptor.isOnScreen) &&
                    displayBounds.map { $0.intersects(CGRect(descriptor.bounds)) } != false
            }
            .sorted { $0.order < $1.order }
            .map(MenuBarItem.init)
    }
}

private extension CGRect {
    init(_ rect: MenuBarRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
