@testable import BarlineCore
import Testing

@Suite("Golden Gate position-table capability")
struct GoldenGatePositionTableCapabilityTests {
    @Test("A hidden third-party item can be restored even when it cannot be hidden again")
    func hiddenItemCanBeRestored() {
        let item = descriptor(canBeHidden: false)

        #expect(GoldenGatePositionTableCapability.isCandidate(item))
        #expect(GoldenGatePositionTableCapability.canAssign(item, to: .visible))
        #expect(!GoldenGatePositionTableCapability.canAssign(item, to: .hidden))
    }

    @Test("System and Barline controls are never position-table candidates")
    func protectedItemsAreRejected() {
        let systemItem = MenuBarItemDescriptor(
            id: MenuBarItemID(bundleIdentifier: "com.apple.controlcenter", title: "Control Center"),
            section: .visible,
            order: 0,
            sourceOwnership: .system
        )
        let barlineItem = MenuBarItemDescriptor(
            id: MenuBarItemID(bundleIdentifier: "com.mabryventures.Barline", title: "Control"),
            section: .visible,
            order: 0,
            sourceOwnership: .application,
            isBarlineControlItem: true
        )

        #expect(!GoldenGatePositionTableCapability.isCandidate(systemItem))
        #expect(!GoldenGatePositionTableCapability.isCandidate(barlineItem))
    }

    private func descriptor(canBeHidden: Bool) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: MenuBarItemID(bundleIdentifier: "com.example.status", title: "Status"),
            section: .hidden,
            order: 0,
            sourceOwnership: .application,
            canBeHidden: canBeHidden
        )
    }
}
