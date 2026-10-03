@testable import BarlineCore
import Testing

@Suite("Bounded delayed publisher observation")
struct MenuBarPublisherObservationBudgetTests {
    private func require(_ token: UInt64?) throws -> UInt64 {
        try #require(token)
    }

    @Test("No-op observations cannot renew a deadline and a new lifetime does not renew peers")
    func deadlinesArePerLifetime() {
        var budget = MenuBarPublisherObservationBudget<Int, Int>(durationNanoseconds: 30)
        #expect(budget.pending([1: 10], now: 0) == [1])
        for time in 1 ..< 30 {
            #expect(budget.pending([1: 10], now: UInt64(time)) == [1])
        }
        #expect(budget.pending([1: 10, 2: 20], now: 30) == [2])
        #expect(budget.pending([1: 10, 2: 20], now: 59) == [2])
        #expect(budget.pending([1: 10, 2: 20], now: 60).isEmpty)
        #expect(budget.pending([1: 10, 2: 20], now: 300).isEmpty)
    }

    @Test("Departure prunes scheduling state and explicit renewed eligibility gets a bounded opportunity")
    func eligibilityMayReturnWithoutBlacklisting() {
        var budget = MenuBarPublisherObservationBudget<Int, Int>(durationNanoseconds: 10)
        #expect(budget.pending([1: 10], now: 0) == [1])
        #expect(budget.pending([:], now: 2).isEmpty)
        #expect(budget.pending([1: 10], now: 20) == [1])
        #expect(budget.pending([1: 10], now: 30).isEmpty)
    }

    @Test("Intermittent kernel-read uncertainty never renews the same process budget")
    func uncertaintyIsNotANewLifetime() {
        var budget = MenuBarPublisherObservationBudget<Int, Int>(durationNanoseconds: 30)
        #expect(budget.pending([1: 10, 2: nil], now: 0) == [1, 2])
        for time in 1 ..< 30 {
            let witness: Int? = time.isMultiple(of: 2) ? 10 : nil
            #expect(budget.pending([1: witness, 2: witness], now: UInt64(time)) == [1, 2])
        }
        for time in 30 ..< 100 {
            let witness: Int? = time.isMultiple(of: 2) ? 10 : nil
            #expect(budget.pending([1: witness, 2: witness], now: UInt64(time)).isEmpty)
        }
        #expect(budget.pending([1: 11, 2: 10], now: 100) == [1])
        #expect(budget.pending([1: nil, 2: 10], now: 129) == [1])
        #expect(budget.pending([1: 11, 2: 10], now: 130).isEmpty)
    }

    @Test("Repeated workspace signals never renew the window; replacement revokes the old token")
    func lifecycleWindowIsRevocableAndFinite() throws {
        var window = MenuBarLifecycleRefreshWindow<Set<Int>>(durationNanoseconds: 30)
        let first = try require(window.begin(signal: [1], now: 0))
        for time in 1 ..< 30 {
            #expect(window.begin(signal: [1], now: UInt64(time)) == nil)
            #expect(window.isCurrent(first, now: UInt64(time)))
        }
        #expect(!window.isCurrent(first, now: 30))
        #expect(window.begin(signal: [1], now: 40) == nil)
        let second = try require(window.begin(signal: [1, 2], now: 40))
        #expect(!window.isCurrent(first, now: 41))
        #expect(window.isCurrent(second, now: 41))
        let wake = try require(window.begin(signal: [1, 2], now: 42, force: true))
        #expect(!window.isCurrent(second, now: 43))
        #expect(window.isCurrent(wake, now: 43))
        #expect(!window.isCurrent(wake, now: 72))
    }

    @Test("Saturating deadlines cannot wrap into a newly active window")
    func overflowIsFinite() throws {
        var budget = MenuBarPublisherObservationBudget<Int, Int>(durationNanoseconds: 30)
        #expect(budget.pending([1: 10], now: UInt64.max - 2) == [1])
        #expect(budget.pending([1: 10], now: UInt64.max).isEmpty)
        var window = MenuBarLifecycleRefreshWindow<Int>(durationNanoseconds: 30)
        let token = try require(window.begin(signal: 1, now: UInt64.max - 2))
        #expect(window.isCurrent(token, now: UInt64.max - 1))
        #expect(!window.isCurrent(token, now: UInt64.max))
    }
}

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

    @Test("Automatic refresh does not restart a terminal cold failure")
    func automaticRefreshDoesNotRestartTerminalFailure() {
        #expect(!MenuBarDiscoveryRefreshPolicy.shouldStart(
            intent: .automatic,
            discoveryIsInFlight: false,
            terminalFailureWithoutSnapshot: true
        ))
    }

    @Test("Authoritative refresh can retry a terminal cold failure")
    func authoritativeRefreshRetriesTerminalFailure() {
        #expect(MenuBarDiscoveryRefreshPolicy.shouldStart(
            intent: .authoritative,
            discoveryIsInFlight: false,
            terminalFailureWithoutSnapshot: true
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

@Suite("Discovery retry when the session becomes available")
struct MenuBarDiscoverySessionRetryTests {
    @Test("A terminal failure with no usable snapshot retries after unlock")
    func terminalFailureRetries() {
        #expect(
            MenuBarDiscoveryRefreshPolicy.shouldRetryWhenSessionBecomesAvailable(state: .failed)
        )
    }

    @Test("Healthy or in-progress discovery is left alone")
    func otherStatesDoNotRetry() {
        for state: MenuBarItemDiscoveryState in [.idle, .loading, .ready, .empty] {
            #expect(
                !MenuBarDiscoveryRefreshPolicy.shouldRetryWhenSessionBecomesAvailable(state: state)
            )
        }
    }
}
