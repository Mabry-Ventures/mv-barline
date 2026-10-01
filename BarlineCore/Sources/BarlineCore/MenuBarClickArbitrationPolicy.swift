//
//  MenuBarClickArbitrationPolicy.swift
//  Barline
//

public enum MenuBarClickArbitrationPolicy {
    public enum EmptySpaceAction: Equatable, Sendable {
        case hidden, alwaysHidden, secondaryContextMenu
    }

    /// Routing modifiers exclude incidental device flags such as Caps Lock,
    /// numeric-pad and function. Ambiguous shortcuts must not toggle a shelf.
    public static func emptySpaceAction(
        control: Bool,
        option: Bool,
        command: Bool,
        shift: Bool
    ) -> EmptySpaceAction? {
        guard !command, !shift, !(control && option) else { return nil }
        if control {
            return .secondaryContextMenu
        }
        if option {
            return .alwaysHidden
        }
        return .hidden
    }

    /// An asynchronous hit test describes the current window stack, not the
    /// stack that received mouse-down. Never reinterpret a dismissed popup's
    /// click as a new empty-space request or carry it into a newer presentation.
    public static func canCommitDeferredEmptySpaceClick(
        eventAge: Double,
        isCurrentInput: Bool,
        isCurrentPresentation: Bool,
        monitoringEnabled: Bool,
        featureEnabled: Bool,
        nativeInterfaceActive: Bool,
        hitWindowAtMouseDown: Int,
        hitWindowAtCommit: Int
    ) -> Bool {
        eventAge.isFinite && (0 ... 0.5).contains(eventAge) &&
            isCurrentInput && isCurrentPresentation && monitoringEnabled && featureEnabled &&
            !nativeInterfaceActive && hitWindowAtMouseDown > 0 &&
            hitWindowAtMouseDown == hitWindowAtCommit
    }

    /// Stretching layout separators occupy window geometry but are not buttons.
    public static func isLayoutSeparator(title: String?) -> Bool {
        title == "Barline.ControlItem.Hidden" || title == "Barline.ControlItem.AlwaysHidden"
    }

    /// A hosted control click can have no local window and stale menu-bar
    /// geometry. Its live hit region still owns the event exclusively.
    public static func shouldScheduleSmartRehide(
        hasVisibleSection: Bool,
        eventTargetsPrimaryControlItem: Bool,
        isInsidePrimaryControlItem: Bool,
        isInsideShelf: Bool,
        isInsideMenuBar: Bool
    ) -> Bool {
        hasVisibleSection &&
            !eventTargetsPrimaryControlItem &&
            !isInsidePrimaryControlItem &&
            !isInsideShelf &&
            !isInsideMenuBar
    }

    /// Returns whether a global click should be treated as occurring in empty
    /// menu-bar space rather than on an application menu, control item, cached
    /// status item, or notch.
    public static func isEmptyMenuBarSpace(
        isInsideMenuBar: Bool,
        isInsideApplicationMenu: Bool,
        isInsidePrimaryControlItem: Bool,
        eventTargetsShelf: Bool = false,
        isInsideCachedMenuBarItem: Bool,
        isInsideNotch: Bool,
        eventTargetsPrimaryControlItem: Bool = false,
        hasHitTestSnapshot: Bool = true
    ) -> Bool {
        hasHitTestSnapshot && isInsideMenuBar &&
            !eventTargetsPrimaryControlItem &&
            !eventTargetsShelf &&
            !isInsideApplicationMenu &&
            !isInsidePrimaryControlItem &&
            !isInsideCachedMenuBarItem &&
            !isInsideNotch
    }
}
