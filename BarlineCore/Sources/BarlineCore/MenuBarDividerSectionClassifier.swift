import Foundation

/// Classifies status-item geometry relative to Barline's section dividers.
///
/// macOS may park an empty section's divider below the physical display. That
/// state means the live menu-bar row remains visible, not that its items overlap
/// an enormous off-screen divider frame.
public enum MenuBarDividerSectionClassifier {
    private static let maximumPhysicalDividerWidth = 256.0

    public static func classify(
        itemBounds: MenuBarRect,
        hiddenControlBounds: MenuBarRect,
        alwaysHiddenControlBounds: MenuBarRect? = nil
    ) -> MenuBarSection? {
        guard valid(itemBounds), valid(hiddenControlBounds) else { return nil }
        if !rowsOverlap(itemBounds, hiddenControlBounds) {
            return itemBounds.y + itemBounds.height <= hiddenControlBounds.y
                ? .visible
                : nil
        }

        let itemMaxX = itemBounds.x + itemBounds.width
        if let alwaysHiddenControlBounds {
            guard valid(alwaysHiddenControlBounds) else { return nil }
            if rowsOverlap(itemBounds, alwaysHiddenControlBounds),
               itemMaxX <= alwaysHiddenControlBounds.x
            {
                return .alwaysHidden
            }
        }
        if itemMaxX <= hiddenControlBounds.x {
            return .hidden
        }
        let hiddenControlMaxX = hiddenControlBounds.width > maximumPhysicalDividerWidth
            ? hiddenControlBounds.x
            : hiddenControlBounds.x + hiddenControlBounds.width
        if itemBounds.x >= hiddenControlMaxX {
            return .visible
        }
        return nil
    }

    private static func valid(_ bounds: MenuBarRect) -> Bool {
        bounds.isFiniteAndNonnegative && bounds.width > 0 && bounds.height > 0
    }

    private static func rowsOverlap(_ lhs: MenuBarRect, _ rhs: MenuBarRect) -> Bool {
        lhs.y < rhs.y + rhs.height && rhs.y < lhs.y + lhs.height
    }
}
