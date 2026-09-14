@testable import BarlineCore
import Testing

struct MenuBarDiscoveryRefreshPolicyTests {
    @Test("Automatic lifecycle churn coalesces while discovery is running")
    func automaticRefreshCoalesces() {
        #expect(!MenuBarDiscoveryRefreshPolicy.shouldStart(
            intent: .automatic,
            discoveryIsInFlight: true
        ))
    }

    @Test("Automatic refresh starts when discovery is idle")
    func automaticRefreshStartsWhenIdle() {
        #expect(MenuBarDiscoveryRefreshPolicy.shouldStart(
            intent: .automatic,
            discoveryIsInFlight: false
        ))
    }

    @Test("Authoritative refresh supersedes an in-flight discovery")
    func authoritativeRefreshSupersedes() {
        #expect(MenuBarDiscoveryRefreshPolicy.shouldStart(
            intent: .authoritative,
            discoveryIsInFlight: true
        ))
    }

    @Test("Cold state always performs discovery even when inventory is unchanged")
    func coldStateRunsDiscovery() {
        #expect(MenuBarDiscoveryRefreshPolicy.shouldRunDiscovery(
            inventoryChanged: false,
            displayChanged: false,
            hasUsableSnapshot: false
        ))
    }

    @Test("Usable unchanged state skips redundant discovery")
    func usableUnchangedStateSkipsDiscovery() {
        #expect(!MenuBarDiscoveryRefreshPolicy.shouldRunDiscovery(
            inventoryChanged: false,
            displayChanged: false,
            hasUsableSnapshot: true
        ))
    }

    @Test("Inventory or display changes refresh a usable snapshot")
    func changedStateRunsDiscovery() {
        #expect(MenuBarDiscoveryRefreshPolicy.shouldRunDiscovery(
            inventoryChanged: true,
            displayChanged: false,
            hasUsableSnapshot: true
        ))
        #expect(MenuBarDiscoveryRefreshPolicy.shouldRunDiscovery(
            inventoryChanged: false,
            displayChanged: true,
            hasUsableSnapshot: true
        ))
    }

    @Test("Discovery diagnostics contain only bounded counters and outcome codes")
    func discoveryDiagnostics() {
        var diagnostics = MenuBarItemDiscoveryDiagnostics()
        diagnostics.recordStartedRequest(intent: .automatic)
        diagnostics.recordStartedRequest(intent: .authoritative)
        diagnostics.recordCoalescedAutomaticRequest()
        diagnostics.recordAttemptFailure(code: .missingControlItems)
        diagnostics.recordCompletion(attemptCount: 2, managedItemCount: 7)

        #expect(diagnostics.automaticStartCount == 1)
        #expect(diagnostics.authoritativeStartCount == 1)
        #expect(diagnostics.coalescedAutomaticCount == 1)
        #expect(diagnostics.lastAttemptCount == 2)
        #expect(diagnostics.lastManagedItemCount == 7)
        #expect(diagnostics.lastOutcomeCode == "ready")
        #expect(diagnostics.lastAttemptFailureCode == nil)
    }

    @Test("A refresh burst produces at most one trailing pass")
    func refreshBurstIsBounded() {
        var gate = MenuBarDiscoveryRefreshGate()
        let firstStarted = gate.begin(intent: .automatic)
        let secondStarted = gate.begin(intent: .automatic)
        #expect(firstStarted)
        #expect(!secondStarted)
        #expect(gate.hasPendingAutomaticRefresh)
        let shouldRunTrailing = gate.finish(
            allowsTrailingAutomaticRefresh: true,
            reachedUsableTerminalState: true
        )
        #expect(shouldRunTrailing)

        let trailingStarted = gate.begin(intent: .automatic)
        let eventDuringTrailingStarted = gate.begin(intent: .automatic)
        #expect(trailingStarted)
        #expect(!eventDuringTrailingStarted)
        let shouldRunAnotherTrailing = gate.finish(
            allowsTrailingAutomaticRefresh: false,
            reachedUsableTerminalState: true
        )
        #expect(!shouldRunAnotherTrailing)
        #expect(!gate.isInFlight)
        #expect(!gate.hasPendingAutomaticRefresh)
    }

    @Test("A failed pass reaches terminal state without an automatic retry loop")
    func failedRefreshDoesNotTrail() {
        var gate = MenuBarDiscoveryRefreshGate()
        let firstStarted = gate.begin(intent: .automatic)
        let secondStarted = gate.begin(intent: .automatic)
        #expect(firstStarted)
        #expect(!secondStarted)
        let shouldRunTrailing = gate.finish(
            allowsTrailingAutomaticRefresh: true,
            reachedUsableTerminalState: false
        )
        #expect(!shouldRunTrailing)
        #expect(!gate.isInFlight)
        #expect(!gate.hasPendingAutomaticRefresh)
    }
}
