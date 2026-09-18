@testable import BarlineCore
import Testing

@Suite("Shelf placement")
struct ShelfPlacementPolicyTests {
    @Test("Dynamic placement is centered even when a right-side anchor fits")
    func dynamicPlacementIsCentered() {
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

    @Test("Dynamic placement centers instead of sticking to the right edge")
    func dynamicRightEdgeFallback() {
        #expect(origin(anchor: 1420, dynamic: true) == 520)
    }

    @Test("Dynamic placement centers instead of sticking to the left edge")
    func dynamicLeftEdgeFallback() {
        #expect(origin(anchor: 20, dynamic: true) == 520)
    }

    @Test("Dynamic placement keeps an anchor that fits without clamping")
    func dynamicAnchorFits() {
        #expect(origin(anchor: 900, dynamic: true) == 700)
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
