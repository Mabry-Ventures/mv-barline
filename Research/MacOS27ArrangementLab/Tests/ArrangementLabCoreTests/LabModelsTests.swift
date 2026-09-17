import ArrangementLabCore
import Testing

@Suite("macOS 27 arrangement lab models")
struct LabModelsTests {
    @Test("screen order is deterministic")
    func screenOrder() {
        let items = [
            item("gamma", x: 300),
            item("alpha", x: 100),
            item("beta", x: 200),
        ]
        #expect(FixtureOrderVerifier.tokensByScreenPosition(items) == ["alpha", "beta", "gamma"])
    }

    @Test("unrelated relative order ignores only the selected item")
    func unrelatedOrder() {
        #expect(FixtureOrderVerifier.preservesRelativeOrder(
            before: ["alpha", "beta", "gamma"],
            after: ["beta", "alpha", "gamma"],
            excluding: "alpha"
        ))
        #expect(!FixtureOrderVerifier.preservesRelativeOrder(
            before: ["alpha", "beta", "gamma"],
            after: ["alpha", "gamma", "beta"],
            excluding: "alpha"
        ))
    }

    @Test("frame matching is bounded")
    func frameMatching() {
        let reference = LabRect(x: 10, y: 20, width: 30, height: 24)
        #expect(reference.approximatelyMatches(LabRect(x: 10.5, y: 20, width: 30, height: 24)))
        #expect(!reference.approximatelyMatches(LabRect(x: 12, y: 20, width: 30, height: 24)))
    }

    private func item(_ token: String, x: Double) -> ObservedFixtureItem {
        ObservedFixtureItem(
            token: token,
            generation: 1,
            frame: LabRect(x: x, y: 0, width: 20, height: 24),
            relativeIndex: 0,
            hitTestMatched: true,
            role: "AXMenuBarItem",
            subrole: nil
        )
    }

    @Test("AppKit frames convert to Accessibility coordinates")
    func coordinateConversion() {
        let result = CoordinateSpaceTransformer.appKitToAccessibility(
            item: LabRect(x: 1302, y: 1050, width: 55, height: 30),
            appKitScreen: LabRect(x: 0, y: 0, width: 1920, height: 1080),
            accessibilityScreen: LabRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        #expect(result == LabRect(x: 1302, y: 0, width: 55, height: 30))
        #expect(result.approximatelySharesCenter(
            with: LabRect(x: 1301, y: 3, width: 57, height: 24)
        ))
    }
}
