@testable import BarlineCore
import Testing

@Suite("Menu bar fallback artwork layout")
struct MenuBarFallbackArtworkLayoutTests {
    @Test("A wide item keeps its geometry while its fallback stays icon-sized and centered")
    func wideItem() {
        let rect = MenuBarFallbackArtworkLayout.drawingRect(
            imageWidth: 128,
            imageHeight: 128,
            boundsWidth: 160,
            boundsHeight: 24
        )

        #expect(rect == MenuBarRect(x: 71, y: 3, width: 18, height: 18))
    }

    @Test("A narrow item never clips its fallback artwork")
    func narrowItem() {
        let rect = MenuBarFallbackArtworkLayout.drawingRect(
            imageWidth: 32,
            imageHeight: 16,
            boundsWidth: 12,
            boundsHeight: 24
        )

        #expect(rect == MenuBarRect(x: 0, y: 9, width: 12, height: 6))
    }

    @Test("Invalid image geometry fails closed")
    func invalidGeometry() {
        let rect = MenuBarFallbackArtworkLayout.drawingRect(
            imageWidth: .nan,
            imageHeight: 16,
            boundsWidth: 24,
            boundsHeight: 24
        )

        #expect(rect == .zero)
    }
}
