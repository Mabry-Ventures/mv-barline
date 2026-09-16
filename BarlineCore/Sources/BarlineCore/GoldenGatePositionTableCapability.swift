//
//  GoldenGatePositionTableCapability.swift
//  BarlineCore
//

import Foundation

/// The capability boundary for macOS 27's protected menu-bar position table.
///
/// Being eligible to participate in the table is distinct from being eligible
/// to move into the hidden section. An item that is already hidden must remain
/// restorable even when macOS reports that it cannot be hidden again.
public enum GoldenGatePositionTableCapability {
    /// Returns whether the descriptor is a third-party status item that Barline
    /// may safely attempt to match to a position-table record.
    public static func isCandidate(_ item: MenuBarItemDescriptor) -> Bool {
        item.sourceOwnership == .application &&
            !item.id.bundleIdentifier.hasPrefix("com.apple.") &&
            !item.isBarlineControlItem
    }

    /// Returns whether the item may be assigned to the requested section.
    /// macOS only needs `canBeHidden` for a transition *into* Hidden; it is not
    /// a prerequisite for restoring an item that is already there.
    public static func canAssign(
        _ item: MenuBarItemDescriptor,
        to section: MenuBarSection
    ) -> Bool {
        guard isCandidate(item) else { return false }
        return section == .visible || item.canBeHidden
    }
}
