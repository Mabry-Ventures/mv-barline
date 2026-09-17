@testable import BarlineCore
import Testing

struct GoldenGateConcealmentPolicyTests {
    @Test("Canonicalization repairs unsupported legacy Apple concealment")
    func canonicalizesUnknownAppleItemsVisible() {
        let focus = item(
            "com.apple.menubaragent",
            "com.apple.menuextra.focusmode",
            accessibilityIdentifier: "com.apple.menuextra.focusmode"
        )
        let wifi = item(
            "com.apple.menubaragent",
            "com.apple.menuextra.wifi",
            accessibilityIdentifier: "com.apple.menuextra.wifi"
        )
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: [],
            concealedItemIDs: [focus, wifi]
        )

        let canonical = GoldenGateConcealmentPolicy.canonicalConfiguration(
            configuration,
            allItems: [focus, wifi],
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(canonical.visibleItemIDs == [focus])
        #expect(canonical.concealedItemIDs == [wifi])
        #expect(GoldenGateConcealmentPolicy.supports(
            canonical,
            allItems: [focus, wifi],
            barlineBundleIdentifier: "com.mabryventures.Barline"
        ))
    }

    @Test("Canonicalization fails mixed third-party groups visible")
    func canonicalizesMixedAppGroupsVisible() {
        let first = item("com.example.stats", "CPU")
        let second = item("com.example.stats", "Disk")
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: [first],
            concealedItemIDs: [second]
        )

        let canonical = GoldenGateConcealmentPolicy.canonicalConfiguration(
            configuration,
            allItems: [first, second],
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(canonical.visibleItemIDs == [first, second])
        #expect(canonical.concealedItemIDs.isEmpty)
    }

    @Test("Canonicalization preserves supported whole-app concealment")
    func canonicalizationPreservesWholeAppConcealment() {
        let first = item("com.example.stats", "CPU")
        let second = item("com.example.stats", "Disk")
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: [],
            concealedItemIDs: [first, second]
        )

        let canonical = GoldenGateConcealmentPolicy.canonicalConfiguration(
            configuration,
            allItems: [first, second],
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(canonical.visibleItemIDs.isEmpty)
        #expect(canonical.concealedItemIDs == [first, second])
    }

    @Test("Legacy Golden Gate assignments no longer poison supported app moves")
    func canonicalizesObservedGoldenGateLegacyLayout() {
        let statsCPU = item("eu.exelban.stats", "item-1")
        let statsDisk = item("eu.exelban.stats", "item-2")
        let focus = item(
            "com.apple.menubaragent",
            "com.apple.menuextra.focusmode",
            accessibilityIdentifier: "com.apple.menuextra.focusmode"
        )
        let screenSharing = item(
            "com.apple.ssmenuagent",
            "com.apple.screensharing.menuextra",
            accessibilityIdentifier: "com.apple.screensharing.menuextra"
        )
        let clock = item(
            "com.apple.menubaragent",
            "com.apple.menuextra.clock",
            accessibilityIdentifier: "com.apple.menuextra.clock"
        )
        let allItems = [statsCPU, statsDisk, focus, screenSharing, clock]
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: [clock],
            concealedItemIDs: [statsCPU, statsDisk, focus, screenSharing]
        )

        let canonical = GoldenGateConcealmentPolicy.canonicalConfiguration(
            configuration,
            allItems: allItems,
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )

        #expect(canonical.visibleItemIDs == [focus, screenSharing, clock])
        #expect(canonical.concealedItemIDs == [statsCPU, statsDisk])
        #expect(GoldenGateConcealmentPolicy.supports(
            canonical,
            allItems: allItems,
            barlineBundleIdentifier: "com.mabryventures.Barline"
        ))
    }

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

    @Test func goldenGateMenuBarAgentItemsUseAccessibilityIdentifierSuffix() {
        let clock = item(
            "com.apple.menubaragent",
            "com.apple.menuextra.clock",
            accessibilityIdentifier: "com.apple.menuextra.clock"
        )
        let controlCenter = item(
            "com.apple.menubaragent",
            "com.apple.menuextra.controlcenter",
            accessibilityIdentifier: "com.apple.menuextra.controlcenter"
        )
        let focus = item(
            "com.apple.menubaragent",
            "com.apple.menuextra.focusmode",
            accessibilityIdentifier: "com.apple.menuextra.focusmode"
        )

        #expect(GoldenGateConcealmentPolicy.systemItemIdentifier(for: clock) == 2)
        #expect(GoldenGateConcealmentPolicy.systemItemIdentifier(for: controlCenter) == 8)
        #expect(GoldenGateConcealmentPolicy.systemItemIdentifier(for: focus) == nil)
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
        let control = item("COM.MABRYVENTURES.BARLINE", "Barline.ControlItem.Hidden")
        let resolved = GoldenGateConcealmentPolicy.resolve(
            .init(visibleItemIDs: [], concealedItemIDs: [control]),
            barlineBundleIdentifier: barlineID
        )
        #expect(resolved.concealedBundleIdentifiers.isEmpty)
    }

    @Test func bundleIdentityChecksAreCaseInsensitive() {
        let first = item("COM.EXAMPLE.UTILITY", "first")
        let second = item("com.example.utility", "second")
        #expect(!GoldenGateConcealmentPolicy.supportsIndependentAssignment(
            first,
            among: [first, second],
            barlineBundleIdentifier: barlineID
        ))
        let clock = item("COM.APPLE.CONTROLCENTER", "Clock")
        #expect(GoldenGateConcealmentPolicy.systemItemIdentifier(for: clock) == 2)
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

    @Test func multipleThirdPartyItemsCanBeAssignedAsOneLogicalGroup() {
        let first = item("COM.EXAMPLE.UTILITY", "first")
        let second = item("com.example.utility", "second")
        #expect(GoldenGateConcealmentPolicy.supportsLogicalAssignment(
            first,
            among: [first, second],
            barlineBundleIdentifier: barlineID
        ))
    }

    @Test func logicalAssignmentRejectsBarlineAndUnknownAppleItems() {
        let control = item("com.mabryventures.Barline", "control")
        let unknownAppleItem = item("com.apple.systemuiserver", "TimeMachine")
        #expect(!GoldenGateConcealmentPolicy.supportsLogicalAssignment(
            control,
            among: [control],
            barlineBundleIdentifier: barlineID
        ))
        #expect(!GoldenGateConcealmentPolicy.supportsLogicalAssignment(
            unknownAppleItem,
            among: [unknownAppleItem],
            barlineBundleIdentifier: barlineID
        ))
    }

    private func item(
        _ bundleIdentifier: String,
        _ title: String,
        accessibilityIdentifier: String? = nil
    ) -> MenuBarItemID {
        MenuBarItemID(
            bundleIdentifier: bundleIdentifier,
            accessibilityIdentifier: accessibilityIdentifier,
            title: title
        )
    }
}
