@testable import BarlineCore
import Testing

struct GoldenGateConcealmentPolicyTests {
    private let barlineID = "com.mabryventures.barline"

    @Test func concealsFullyHiddenThirdPartyBundle() {
        let hidden = item("com.example.utility", "status")
        let resolved = GoldenGateConcealmentPolicy.resolve(
            .init(visibleItemIDs: [], concealedItemIDs: [hidden]),
            barlineBundleIdentifier: barlineID
        )
        #expect(resolved.concealedBundleIdentifiers == ["com.example.utility"])
        #expect(resolved.allowedSystemItemIdentifiers == Set(0 ... 8))
    }

    @Test func mixedBundleAssignmentFailsVisible() {
        let visible = item("com.example.utility", "primary")
        let hidden = item("com.example.utility", "secondary")
        let resolved = GoldenGateConcealmentPolicy.resolve(
            .init(visibleItemIDs: [visible], concealedItemIDs: [hidden]),
            barlineBundleIdentifier: barlineID
        )
        #expect(resolved.concealedBundleIdentifiers.isEmpty)
    }

    @Test func visibleAssignmentWinsDuplicateIdentity() {
        let duplicated = item("com.example.utility", "status")
        let resolved = GoldenGateConcealmentPolicy.resolve(
            .init(visibleItemIDs: [duplicated], concealedItemIDs: [duplicated]),
            barlineBundleIdentifier: barlineID
        )
        #expect(resolved.concealedBundleIdentifiers.isEmpty)
    }

    @Test func knownSystemItemsUseExplicitAllowlistIdentifiers() {
        let wifi = item("com.apple.controlcenter", "WiFi")
        let clock = item("com.apple.controlcenter", "Clock")
        let resolved = GoldenGateConcealmentPolicy.resolve(
            .init(visibleItemIDs: [clock], concealedItemIDs: [wifi]),
            barlineBundleIdentifier: barlineID
        )
        #expect(!resolved.allowedSystemItemIdentifiers.contains(6))
        #expect(resolved.allowedSystemItemIdentifiers.contains(2))
        #expect(resolved.concealedBundleIdentifiers.isEmpty)
    }

    @Test func unknownAppleItemFailsVisible() {
        let unknown = item("com.apple.systemuiserver", "TimeMachine")
        let resolved = GoldenGateConcealmentPolicy.resolve(
            .init(visibleItemIDs: [], concealedItemIDs: [unknown]),
            barlineBundleIdentifier: barlineID
        )
        #expect(resolved.concealedBundleIdentifiers.isEmpty)
        #expect(resolved.allowedSystemItemIdentifiers == Set(0 ... 8))
    }

    @Test func barlineControlsCanNeverBeConcealed() {
        let control = item(barlineID, "Barline.ControlItem.Hidden")
        let resolved = GoldenGateConcealmentPolicy.resolve(
            .init(visibleItemIDs: [], concealedItemIDs: [control]),
            barlineBundleIdentifier: barlineID
        )
        #expect(resolved.concealedBundleIdentifiers.isEmpty)
    }

    @Test func singleThirdPartyItemCanBeAssignedIndependently() {
        let utility = item("com.example.utility", "status")
        #expect(GoldenGateConcealmentPolicy.supportsIndependentAssignment(
            utility,
            among: [utility],
            barlineBundleIdentifier: barlineID
        ))
    }

    @Test func multipleThirdPartyItemsCannotBeAssignedIndependently() {
        let first = item("com.example.utility", "first")
        let second = item("com.example.utility", "second")
        #expect(!GoldenGateConcealmentPolicy.supportsIndependentAssignment(
            first,
            among: [first, second],
            barlineBundleIdentifier: barlineID
        ))
    }

    private func item(_ bundleIdentifier: String, _ title: String) -> MenuBarItemID {
        MenuBarItemID(bundleIdentifier: bundleIdentifier, title: title)
    }
}
