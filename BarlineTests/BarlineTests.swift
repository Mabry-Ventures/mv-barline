import BarlineCore
import XCTest

final class BarlineTests: XCTestCase {
    func testPersistentDeviceFlagsDoNotBlockPointerTransactions() {
        let blockingMask: UInt = 0b0001_1111
        for persistentFlags: UInt in [0, 0b0010_0000, 0b0100_0000, 0b0110_0000] {
            XCTAssertFalse(
                PointerInputIdlePolicy.hasActivePointerModifier(
                    flagsRawValue: persistentFlags,
                    blockingMaskRawValue: blockingMask
                )
            )
        }
    }

    func testHeldChordModifiersBlockPointerTransactions() {
        let blockingMask: UInt = 0b0001_1111
        for modifier: UInt in [0b0000_0001, 0b0000_0010, 0b0000_0100, 0b0000_1000, 0b0001_0000] {
            XCTAssertTrue(
                PointerInputIdlePolicy.hasActivePointerModifier(
                    flagsRawValue: modifier | 0b0010_0000,
                    blockingMaskRawValue: blockingMask
                )
            )
        }
    }

    func testFixtureCanConstructStableMenuBarIdentity() {
        let identity = MenuBarItemID(bundleIdentifier: "com.example.fixture", title: "Fixture")
        XCTAssertTrue(identity.isPlausiblyStable)
        XCTAssertEqual(identity.description, "com.example.fixture|fixture")
    }

    func testDockPreferenceKeepsEveryRequestedPolicyAccessory() {
        XCTAssertFalse(
            DockVisibilityPolicy.usesRegularActivationPolicy(
                requestedRegular: true,
                hideDockIcon: true
            )
        )
        XCTAssertFalse(
            DockVisibilityPolicy.usesRegularActivationPolicy(
                requestedRegular: false,
                hideDockIcon: true
            )
        )
    }

    func testVisibleDockPreservesRequestedPolicy() {
        XCTAssertTrue(
            DockVisibilityPolicy.usesRegularActivationPolicy(
                requestedRegular: true,
                hideDockIcon: false
            )
        )
        XCTAssertFalse(
            DockVisibilityPolicy.usesRegularActivationPolicy(
                requestedRegular: false,
                hideDockIcon: false
            )
        )
    }
}
