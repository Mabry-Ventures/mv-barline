@testable import BarlineCore
import Testing

@Suite("Shelf placement")
struct ShelfPlacementPolicyTests {
    @Test("Centered placement remains available for explicit centered surfaces")
    func centeredPlacement() {
        #expect(ShelfPlacementPolicy.centeredOriginX(
            screenMinX: 0,
            screenMaxX: 1440,
            shelfWidth: 400
        ) == 520)
    }

    @Test("Centered placement respects displays with negative global coordinates")
    func centeredPlacementOnNegativeDisplay() {
        #expect(ShelfPlacementPolicy.centeredOriginX(
            screenMinX: -1440,
            screenMaxX: 0,
            shelfWidth: 400
        ) == -920)
    }

    @Test("Status-item placement clamps beneath a right-edge anchor")
    func rightEdgeAnchor() {
        #expect(origin(anchor: 1420, dynamic: false) == 1040)
    }

    @Test("Status-item placement clamps beneath a left-edge anchor")
    func leftEdgeAnchor() {
        #expect(origin(anchor: 20, dynamic: false) == 0)
    }

    @Test("Status-item placement centers beneath an anchor when it fits")
    func anchorFits() {
        #expect(origin(anchor: 900, dynamic: false) == 700)
    }

    @Test("Explicit icon placement retains edge clamping")
    func explicitIconPlacement() {
        #expect(origin(anchor: 1420, dynamic: false) == 1040)
    }

    @Test("Placement respects displays with negative global coordinates")
    func negativeDisplayCoordinates() {
        #expect(ShelfPlacementPolicy.originX(
            screenMinX: -1440,
            screenMaxX: 0,
            shelfWidth: 400,
            anchorMidX: -20,
            centersWhenEdgeClamped: true
        ) == -920)
    }

    @Test("An oversized shelf remains right-aligned for AppKit clipping")
    func oversizedShelf() {
        #expect(ShelfPlacementPolicy.originX(
            screenMinX: 100,
            screenMaxX: 500,
            shelfWidth: 600,
            anchorMidX: 300,
            centersWhenEdgeClamped: true
        ) == -100)
    }

    private func origin(anchor: Double, dynamic: Bool) -> Double {
        ShelfPlacementPolicy.originX(
            screenMinX: 0,
            screenMaxX: 1440,
            shelfWidth: 400,
            anchorMidX: anchor,
            centersWhenEdgeClamped: dynamic
        )
    }
}
