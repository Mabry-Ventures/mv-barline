/// Display ownership and physical visibility are separate: a hidden item's
/// off-screen coordinates cannot erase or redirect its WindowServer ownership.
public enum MenuBarDisplayOwnershipPolicy {
    public static func hasStableGeometry(
        before: [MenuBarDisplayID: MenuBarRect], after: [MenuBarDisplayID: MenuBarRect]
    ) -> Bool {
        !before.isEmpty && before == after &&
            before.allSatisfy { !$0.key.value.isEmpty && valid($0.value) }
    }

    /// Logical section assignment cannot transfer an item between displays.
    /// A requested destination needs positively matching source ownership.
    public static func permitsLogicalMove(
        sourceDisplayID: MenuBarDisplayID?, destinationDisplayID: MenuBarDisplayID?
    ) -> Bool {
        destinationDisplayID == nil || sourceDisplayID == destinationDisplayID
    }

    public static func resolve(
        itemBounds: MenuBarRect,
        displays: [MenuBarDisplayID: MenuBarRect],
        membershipDisplayIDs: Set<MenuBarDisplayID>?
    ) -> MenuBarDisplayID? {
        guard valid(itemBounds), !displays.isEmpty,
              displays.allSatisfy({ !$0.key.value.isEmpty && valid($0.value) })
        else { return nil }

        let candidates: Set<MenuBarDisplayID>
        if let membershipDisplayIDs {
            // A completed query with no owner is not permission to guess.
            guard !membershipDisplayIDs.isEmpty,
                  membershipDisplayIDs.isSubset(of: Set(displays.keys))
            else { return nil }
            if membershipDisplayIDs.count == 1 {
                return membershipDisplayIDs.first
            }
            candidates = membershipDisplayIDs
        } else {
            // No membership capability: geometry can resolve a visible item,
            // but never infer a hidden item's ownership from a nearest display.
            candidates = Set(displays.keys)
        }

        let containing = candidates.filter { displayID in
            guard let bounds = displays[displayID] else { return false }
            return MenuBarVisibilityPolicy.isClickable(
                reportedVisible: true, itemBounds: itemBounds, displayBounds: [bounds]
            )
        }
        return containing.count == 1 ? containing.first : nil
    }

    private static func valid(_ rect: MenuBarRect) -> Bool {
        rect.isFiniteAndNonnegative && rect.width > 0 && rect.height > 0 &&
            (rect.x + rect.width).isFinite && (rect.y + rect.height).isFinite
    }
}
