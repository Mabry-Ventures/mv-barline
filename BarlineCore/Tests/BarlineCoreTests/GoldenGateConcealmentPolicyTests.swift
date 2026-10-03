@testable import BarlineCore
import Foundation
import Testing

struct GoldenGateConcealmentPolicyTests {
    @Test("Focus recovery admits only the exact original all-visible inventory")
    func focusRecoveryRequiresOriginalInventory() {
        let display = MenuBarDisplayID("display")
        let owned = MenuBarItemID(bundleIdentifier: "com.example.owned", accessibilityIdentifier: "item")
        let focus = MenuBarItemID(bundleIdentifier: "com.apple.controlcenter", accessibilityIdentifier: "com.apple.controlcenter.focus")
        let original = MenuBarSnapshot(generation: 1, capturedAt: Date(), items: [
            MenuBarItemDescriptor(id: owned, section: .visible, order: 0, displayID: display),
            MenuBarItemDescriptor(id: focus, section: .visible, order: 1, displayID: display,
                                  isSystemItem: true, sourceOwnership: .system),
        ], displayIDs: [display], activeSpaceIsValid: true)
        let current = MenuBarSnapshot(generation: 2, capturedAt: Date(), items: [
            MenuBarItemDescriptor(id: owned, section: .hidden, order: 0, displayID: display),
        ], displayIDs: [display], activeSpaceIsValid: true)
        #expect(GoldenGateConcealmentPolicy.permitsFocusDeassertionRecovery(
            original: original, current: current, transactionOwnedItemIDs: [owned]
        ))
        #expect(!GoldenGateConcealmentPolicy.permitsFocusDeassertionRecovery(
            original: original, current: current, transactionOwnedItemIDs: []
        ))
    }

    @Test("Focus recovery never excuses a different inventory or external mutation", arguments: [
        "application_missing", "second_missing", "added", "weak_identity", "wrong_ownership", "wrong_bundle",
        "unknown_system", "display_relocated", "external_section", "previously_concealed", "tracking",
        "duplicate_current", "duplicate_original",
    ])
    func rejectsUnownedFocusRecovery(change: String) {
        let display = MenuBarDisplayID("display")
        let owned = MenuBarItemID(bundleIdentifier: "com.example.owned", accessibilityIdentifier: "A")
        let unrelated = MenuBarItemID(bundleIdentifier: "com.example.unrelated", accessibilityIdentifier: "B")
        let focus = MenuBarItemID(
            bundleIdentifier: change == "wrong_bundle" ? "com.example.focus" : "com.apple.controlcenter",
            accessibilityIdentifier: change == "weak_identity" ? nil :
                (change == "unknown_system" ? "com.apple.controlcenter.unknown" : "com.apple.controlcenter.focus"),
            title: "Focus"
        )
        var originalItems = [
            MenuBarItemDescriptor(id: owned, section: .visible, order: 0, displayID: display),
            MenuBarItemDescriptor(id: unrelated, section: change == "previously_concealed" ? .hidden : .visible,
                                  order: 1, displayID: display),
            MenuBarItemDescriptor(id: focus, section: .visible, order: 2, displayID: display, isSystemItem: true,
                                  sourceOwnership: change == "wrong_ownership" ? .application : .system),
        ]
        var currentItems = [
            MenuBarItemDescriptor(id: owned, section: .hidden, order: 0, displayID: display),
            MenuBarItemDescriptor(id: unrelated, section: change == "external_section" ? .hidden : .visible,
                                  order: 1, displayID: change == "display_relocated" ? MenuBarDisplayID("other") : display),
        ]
        switch change {
        case "application_missing": currentItems = [originalItems[2]]
        case "second_missing": currentItems.removeLast()
        case "added": currentItems.append(MenuBarItemDescriptor(
                id: MenuBarItemID(bundleIdentifier: "com.example.new", accessibilityIdentifier: "new"),
                section: .visible, order: 3, displayID: display
            ))
        case "duplicate_current": currentItems.append(currentItems[0])
        case "duplicate_original": originalItems.append(originalItems[0])
        default: break
        }
        let original = MenuBarSnapshot(generation: 1, capturedAt: Date(), items: originalItems, displayIDs: [display], activeSpaceIsValid: true)
        let current = MenuBarSnapshot(generation: 2, capturedAt: Date(), items: currentItems, displayIDs: [display], activeSpaceIsValid: true,
                                      menuTrackingIsActive: change == "tracking")
        #expect(!GoldenGateConcealmentPolicy.permitsFocusDeassertionRecovery(
            original: original, current: current, transactionOwnedItemIDs: [owned]
        ))
    }

    @Test("Native deduplication includes newly running allowed apps")
    func runningAppAllowlistChanges() {
        let resolution = GoldenGateResolvedConcealment(
            concealedBundleIdentifiers: ["com.example.hidden"],
            allowedSystemItemIdentifiers: GoldenGateConcealmentPolicy.allSystemItemIdentifiers
        )
        let first = GoldenGateNativeConcealmentState(
            resolution: resolution, runningBundleIdentifiers: ["com.example.visible", "com.example.hidden"],
            barlineBundleIdentifier: barlineID
        )
        let reordered = GoldenGateNativeConcealmentState(
            resolution: resolution,
            runningBundleIdentifiers: ["com.example.hidden", "com.example.visible", "com.example.visible"],
            barlineBundleIdentifier: barlineID
        )
        let launched = GoldenGateNativeConcealmentState(
            resolution: resolution,
            runningBundleIdentifiers: ["com.example.visible", "com.example.new", "com.example.hidden"],
            barlineBundleIdentifier: barlineID
        )
        #expect(first == reordered)
        #expect(first != launched)
        #expect(launched.allowedBundleIdentifiers.contains("com.example.new"))
        #expect(!launched.allowedBundleIdentifiers.contains("com.example.hidden"))
    }

    @Test("App churn does not change the all-visible native state")
    func allVisibleIgnoresRunningAppChanges() {
        let resolution = GoldenGateResolvedConcealment(
            concealedBundleIdentifiers: [],
            allowedSystemItemIdentifiers: GoldenGateConcealmentPolicy.allSystemItemIdentifiers
        )
        #expect(GoldenGateNativeConcealmentState(
            resolution: resolution, runningBundleIdentifiers: ["com.example.first"],
            barlineBundleIdentifier: barlineID
        ) == GoldenGateNativeConcealmentState(
            resolution: resolution, runningBundleIdentifiers: ["com.example.second"],
            barlineBundleIdentifier: barlineID
        ))
    }

    @Test("The configured app stays allowed even when it is missing from the running list",
          arguments: ["com.mabryventures.Barline", "com.example.CustomBarline", "COM.EXAMPLE.CUSTOMBARLINE"])
    func configuredAppIsAlwaysAllowed(barlineIdentifier: String) {
        let control = item(barlineIdentifier.lowercased(), "Barline.ControlItem.Hidden")
        let hidden = item("com.example.hidden", "status")
        let resolved = GoldenGateConcealmentPolicy.resolve(
            .init(visibleItemIDs: [], concealedItemIDs: [control, hidden]),
            barlineBundleIdentifier: barlineIdentifier
        )
        let state = GoldenGateNativeConcealmentState(
            resolution: resolved, runningBundleIdentifiers: ["com.example.hidden", "com.example.visible"],
            barlineBundleIdentifier: barlineIdentifier
        )
        #expect(!resolved.concealedBundleIdentifiers.contains(control.bundleIdentifier))
        #expect(state.allowedBundleIdentifiers.contains(barlineIdentifier))
        #expect(!state.allowedBundleIdentifiers.contains("com.example.hidden"))
        #expect(state.allowedBundleIdentifiers.contains("com.example.visible"))
        #expect(state.allowedBundleIdentifiers.isSuperset(of: ["com.apple.systemuiserver", "com.apple.finder", "com.apple.dock"]))
    }

    @Test("A changed configured identity updates an active native allowlist")
    func configuredIdentityIsPartOfNativeState() {
        let resolution = GoldenGateResolvedConcealment(
            concealedBundleIdentifiers: ["com.example.hidden"],
            allowedSystemItemIdentifiers: GoldenGateConcealmentPolicy.allSystemItemIdentifiers
        )
        let original = GoldenGateNativeConcealmentState(
            resolution: resolution, runningBundleIdentifiers: [], barlineBundleIdentifier: "com.example.Original"
        )
        let changed = GoldenGateNativeConcealmentState(
            resolution: resolution, runningBundleIdentifiers: [], barlineBundleIdentifier: "com.example.Custom"
        )
        #expect(original != changed)
        #expect(!changed.allowedBundleIdentifiers.contains("com.example.Original"))
        #expect(!changed.allowedBundleIdentifiers.contains("com.mabryventures.Barline"))
        #expect(changed.allowedBundleIdentifiers.contains("com.example.Custom"))

        let allVisible = GoldenGateNativeConcealmentState(
            resolution: .init(concealedBundleIdentifiers: [], allowedSystemItemIdentifiers: GoldenGateConcealmentPolicy.allSystemItemIdentifiers),
            runningBundleIdentifiers: ["com.example.Custom"],
            barlineBundleIdentifier: "com.example.Custom"
        )
        #expect(allVisible.allowedBundleIdentifiers.isEmpty)
    }

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

    @Test("Temporary visible item must not erase a saved hidden bundle")
    func temporaryVisibleSiblingRestoresSavedConcealment() {
        let first = item("com.example.fixture", "Native")
        let second = item("com.example.fixture", "Popover")
        let temporary = item("com.example.fixture", "UI Test")
        let saved = MenuBarConcealmentConfiguration(
            visibleItemIDs: [],
            concealedItemIDs: [first, second]
        )
        let mixed = MenuBarConcealmentConfiguration(
            visibleItemIDs: [temporary],
            concealedItemIDs: saved.concealedItemIDs
        )

        let failVisible = GoldenGateConcealmentPolicy.canonicalConfiguration(
            mixed,
            allItems: [first, second, temporary],
            barlineBundleIdentifier: barlineID
        )
        #expect(failVisible.visibleItemIDs == [first, second, temporary])
        #expect(failVisible.concealedItemIDs.isEmpty)

        let restored = GoldenGateConcealmentPolicy.canonicalConfiguration(
            saved,
            allItems: [first, second],
            barlineBundleIdentifier: barlineID
        )
        #expect(restored.visibleItemIDs.isEmpty)
        #expect(restored.concealedItemIDs == [first, second])
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

    @Test func logicalAssignmentRejectsEmptyBundleIdentifier() {
        let missingApplication = item("", "status")
        #expect(!GoldenGateConcealmentPolicy.supportsIndependentAssignment(
            missingApplication,
            among: [missingApplication],
            barlineBundleIdentifier: barlineID
        ))
        #expect(!GoldenGateConcealmentPolicy.supportsLogicalAssignment(
            missingApplication,
            among: [missingApplication],
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

@Suite("Concealment configuration pruning")
struct MenuBarConcealmentConfigurationPruningTests {
    @Test("An item that left the menu bar cannot invalidate the other assignments")
    func retainingOnlyDropsAbsentReferences() {
        // A live-value title (processor load, transfer rate) changes item
        // identity between snapshots, which previously rejected everything.
        let stable = MenuBarItemID(bundleIdentifier: "com.example.stable", title: "Stable")
        let volatileBefore = MenuBarItemID(bundleIdentifier: "com.example.meter", title: "CPU 43°")
        let volatileAfter = MenuBarItemID(bundleIdentifier: "com.example.meter", title: "CPU 44°")

        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: [stable],
            concealedItemIDs: [volatileBefore]
        )
        let pruned = configuration.retainingOnly([stable, volatileAfter])

        #expect(pruned.visibleItemIDs == [stable])
        #expect(pruned.concealedItemIDs.isEmpty)
    }

    @Test("Pruning keeps every reference the menu bar still contains")
    func retainingOnlyKeepsPresentReferences() {
        let visible = MenuBarItemID(bundleIdentifier: "com.example.one", title: "One")
        let concealed = MenuBarItemID(bundleIdentifier: "com.example.two", title: "Two")
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: [visible],
            concealedItemIDs: [concealed]
        )

        let pruned = configuration.retainingOnly([visible, concealed])

        #expect(pruned == configuration)
    }
}

@Suite("Menu bar identity titles")
struct GoldenGateIdentityTitleTests {
    @Test("A live reading does not change an item's identity")
    func liveReadingsCollapse() {
        let readings = ["CPU 9%", "CPU 43%", "CPU 7%"]
        let identities = Set(readings.map(GoldenGateMenuBarSnapshotBuilder.identityTitle))

        #expect(identities.count == 1)
    }

    @Test("Temperatures, transfer rates and decimals collapse too")
    func otherReadingsCollapse() {
        #expect(
            GoldenGateMenuBarSnapshotBuilder.identityTitle("CPU 50°")
                == GoldenGateMenuBarSnapshotBuilder.identityTitle("CPU 49°")
        )
        #expect(
            GoldenGateMenuBarSnapshotBuilder.identityTitle("Upload 82 KB/s")
                == GoldenGateMenuBarSnapshotBuilder.identityTitle("Upload 13 KB/s")
        )
        #expect(
            GoldenGateMenuBarSnapshotBuilder.identityTitle("Disk 1.5 GB")
                == GoldenGateMenuBarSnapshotBuilder.identityTitle("Disk 12.75 GB")
        )
    }

    @Test("Distinct readings from one application stay distinct")
    func differentMetricsStayDistinct() {
        let cpu = GoldenGateMenuBarSnapshotBuilder.identityTitle("CPU 9%")
        let memory = GoldenGateMenuBarSnapshotBuilder.identityTitle("Memory Pressure 15%")
        let upload = GoldenGateMenuBarSnapshotBuilder.identityTitle("Upload 82 KB/s")

        #expect(Set([cpu, memory, upload]).count == 3)
    }

    @Test("A title without a reading is left alone")
    func stableTitlesAreUnchanged() {
        for title in ["Control Center", "Clock", "Barline.ControlItem.Hidden", "Microsoft Teams"] {
            #expect(GoldenGateMenuBarSnapshotBuilder.identityTitle(title) == title)
        }
    }
}
