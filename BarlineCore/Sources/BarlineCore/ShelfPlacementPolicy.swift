import Foundation

/// Deterministic horizontal placement for Barline's transient shelf panel.
public enum ShelfPlacementPolicy {
    public static func originX(
        screenMinX: Double,
        screenMaxX: Double,
        shelfWidth: Double,
        anchorMidX: Double,
        centersWhenEdgeClamped: Bool
    ) -> Double {
        guard screenMinX.isFinite,
              screenMaxX.isFinite,
              shelfWidth.isFinite,
              anchorMidX.isFinite,
              screenMaxX >= screenMinX,
              shelfWidth > 0
        else { return screenMinX }

        let upperBound = screenMaxX - shelfWidth
        guard screenMinX <= upperBound else { return upperBound }

        let ideal = anchorMidX - shelfWidth / 2
        if centersWhenEdgeClamped,
           ideal < screenMinX || ideal > upperBound
        {
            return screenMinX + (screenMaxX - screenMinX - shelfWidth) / 2
        }
        return min(max(ideal, screenMinX), upperBound)
    }
}
