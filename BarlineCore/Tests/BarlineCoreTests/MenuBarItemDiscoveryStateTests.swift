@testable import BarlineCore
import Testing

@Suite("Menu bar item discovery state")
struct MenuBarItemDiscoveryStateTests {
    @Test("Successful discovery distinguishes items from a legitimate empty result")
    func completedDiscovery() {
        #expect(MenuBarItemDiscoveryState.completed(managedItemCount: 3) == .ready)
        #expect(MenuBarItemDiscoveryState.completed(managedItemCount: 0) == .empty)
    }

    @Test("A failed initial discovery reaches a terminal error state")
    func initialFailure() {
        #expect(MenuBarItemDiscoveryState.loading.preservingUsableSnapshotOrFailure() == .failed)
        #expect(MenuBarItemDiscoveryState.idle.preservingUsableSnapshotOrFailure() == .failed)
    }

    @Test("A failed refresh preserves every usable last-known-good state")
    func preservesUsableSnapshot() {
        #expect(MenuBarItemDiscoveryState.ready.preservingUsableSnapshotOrFailure() == .ready)
        #expect(MenuBarItemDiscoveryState.empty.preservingUsableSnapshotOrFailure() == .empty)
    }
}
