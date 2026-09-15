@testable import BarlineCore
import Testing

@Suite("Temporary reveal observation registry")
struct TemporaryRevealObservationRegistryTests {
    private let item = MenuBarItemID(bundleIdentifier: "com.example.item", title: "Item")

    @Test("Only one restoration attempt can consume an observation token")
    func restorationReservationIsIdempotent() {
        var registry = TemporaryRevealObservationRegistry()
        let token = MenuBarRevealObservationToken()
        let epoch = registry.lifecycleEpoch
        let registered = registry.register(token, item: item, at: epoch)
        #expect(registered)

        #expect(registry.reserve(token)?.item == item)
        #expect(registry.reserve(token) == nil)
    }

    @Test("A failed pre-restart restoration cannot resurrect stale ownership")
    func restartRejectsStaleFailure() {
        var registry = TemporaryRevealObservationRegistry()
        let token = MenuBarRevealObservationToken()
        let epoch = registry.lifecycleEpoch
        let registered = registry.register(token, item: item, at: epoch)
        #expect(registered)
        let reservation = registry.reserve(token)

        let beganRestart = registry.beginRestart()
        #expect(beganRestart)

        #expect(reservation.map { registry.restoreFailed($0) } == false)
        #expect(registry.reserve(token) == nil)
    }

    @Test("A reveal completed after restart cannot register in the new epoch")
    func restartRejectsLateRegistration() {
        var registry = TemporaryRevealObservationRegistry()
        let token = MenuBarRevealObservationToken()
        let oldEpoch = registry.lifecycleEpoch

        let beganRestart = registry.beginRestart()
        #expect(beganRestart)

        let registered = registry.register(token, item: item, at: oldEpoch)
        #expect(!registered)
        #expect(registry.reserve(token) == nil)
    }

    @Test("Operations are admitted before and after restart but never during cleanup")
    func restartAdmissionFence() {
        var registry = TemporaryRevealObservationRegistry()
        #expect(registry.canAdmitOperations)

        let beganRestart = registry.beginRestart()
        #expect(beganRestart)
        #expect(!registry.canAdmitOperations)
        let duplicateRestart = registry.beginRestart()
        #expect(!duplicateRestart)

        registry.finishRestart()
        #expect(registry.canAdmitOperations)
    }
}
