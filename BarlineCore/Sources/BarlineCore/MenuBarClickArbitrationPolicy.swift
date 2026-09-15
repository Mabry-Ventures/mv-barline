//
//  MenuBarClickArbitrationPolicy.swift
//  Barline
//

public enum MenuBarClickArbitrationPolicy {
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
