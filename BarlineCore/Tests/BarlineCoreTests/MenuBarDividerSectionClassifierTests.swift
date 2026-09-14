@testable import BarlineCore
import Testing

@Suite("Menu bar divider section classification")
struct MenuBarDividerSectionClassifierTests {
    @Test("An empty section divider parked below the display leaves live-row items visible")
    func parkedDivider() {
        let item = MenuBarRect(x: 1600, y: 3, width: 34, height: 24)
        let parked = MenuBarRect(x: 7, y: 1083, width: 5002, height: 24)
        #expect(classify(item, hidden: parked) == .visible)
    }

    @Test("A live divider separates hidden and visible items")
    func liveDivider() {
        let divider = MenuBarRect(x: 1711, y: 3, width: 5, height: 24)
        #expect(classify(
            MenuBarRect(x: 1681, y: 3, width: 24, height: 24),
            hidden: divider
        ) == .hidden)
        #expect(classify(
            MenuBarRect(x: 1723, y: 4, width: 26, height: 22),
            hidden: divider
        ) == .visible)
    }

    @Test("Golden Gate's two-point divider attachment inset remains classifiable")
    func goldenGateAttachmentInset() {
        let divider = MenuBarRect(x: 1564, y: 3, width: 5, height: 24)
        #expect(classify(
            MenuBarRect(x: 1474, y: 3, width: 92, height: 24),
            hidden: divider
        ) == .hidden)
        #expect(classify(
            MenuBarRect(x: 1567, y: 3, width: 34, height: 24),
            hidden: divider
        ) == .visible)
    }

    @Test("An overlap beyond the measured attachment inset stays ambiguous")
    func overlapBeyondAttachmentInset() {
        let divider = MenuBarRect(x: 1564, y: 3, width: 5, height: 24)
        #expect(classify(
            MenuBarRect(x: 1473, y: 3, width: 94, height: 24),
            hidden: divider
        ) == nil)
    }

    @Test("An expanded sentinel frame still uses its leading edge as the divider")
    func sentinelDivider() {
        let divider = MenuBarRect(x: 1681, y: 3, width: 5002, height: 24)
        #expect(classify(
            MenuBarRect(x: 1640, y: 3, width: 35, height: 24),
            hidden: divider
        ) == .hidden)
        #expect(classify(
            MenuBarRect(x: 1723, y: 4, width: 26, height: 22),
            hidden: divider
        ) == .visible)
    }

    @Test("Always-hidden geometry is classified before the hidden divider")
    func alwaysHiddenDivider() {
        let alwaysHidden = MenuBarRect(x: 1600, y: 3, width: 5, height: 24)
        let hidden = MenuBarRect(x: 1711, y: 3, width: 5, height: 24)
        #expect(classify(
            MenuBarRect(x: 1560, y: 4, width: 30, height: 22),
            hidden: hidden,
            alwaysHidden: alwaysHidden
        ) == .alwaysHidden)
    }

    @Test("Overlapping, reversed-row, and malformed geometry fail closed")
    func ambiguousGeometry() {
        let divider = MenuBarRect(x: 1711, y: 3, width: 5, height: 24)
        #expect(classify(
            MenuBarRect(x: 1710, y: 3, width: 4, height: 24),
            hidden: divider
        ) == nil)
        #expect(classify(
            MenuBarRect(x: 1600, y: 1083, width: 24, height: 24),
            hidden: divider
        ) == nil)
        #expect(classify(.zero, hidden: divider) == nil)
    }

    private func classify(
        _ item: MenuBarRect,
        hidden: MenuBarRect,
        alwaysHidden: MenuBarRect? = nil
    ) -> MenuBarSection? {
        MenuBarDividerSectionClassifier.classify(
            itemBounds: item,
            hiddenControlBounds: hidden,
            alwaysHiddenControlBounds: alwaysHidden
        )
    }
}
