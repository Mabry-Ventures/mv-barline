// Compile with the actual production Connection, Shared Service, and test-only
// XPC module. No application, GUI, real XPC service, preferences, or signing work.
import BarlineCore
import BarlineTestXPC
import Darwin
import Dispatch
import Foundation
import OSLog

private struct Failure: Error { let message: String }

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw Failure(message: message) }
}

private final class Barrier: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func enter() throws {
        arrived.signal()
        guard released.wait(timeout: .now() + 8) == .success else {
            throw Failure(message: "barrier release exceeded hard timeout")
        }
    }

    func waitForArrival() throws {
        try require(arrived.wait(timeout: .now() + 3) == .success, "barrier was not reached")
    }

    func release() {
        released.signal()
    }
}

@available(macOS 26.0, *)
private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var value: BarlineMenuService.Response?
    func finish(_ response: BarlineMenuService.Response?) {
        lock.lock()
        value = response
        lock.unlock()
        done.signal()
    }

    func wait(seconds: Double = 3) throws -> BarlineMenuService.Response? {
        try require(done.wait(timeout: .now() + seconds) == .success, "actual Session request exceeded test timeout")
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct RequestRecord: Sendable {
    let sessionID: Int
    let operation: String
    let configuration: String?
}

@available(macOS 26.0, *)
private final class SyntheticHelper: @unchecked Sendable {
    private let lock = NSLock()
    private var recordsStorage: [RequestRecord] = []
    private var configurationStorage: String?
    private var rejectConfiguration = false
    private var nextStartBarrier: Barrier?
    private var nextHealthBarrier: Barrier?

    var records: [RequestRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsStorage
    }

    var configuration: String? {
        lock.lock()
        defer { lock.unlock() }
        return configurationStorage
    }

    func clearConfiguration() {
        lock.lock()
        configurationStorage = nil
        lock.unlock()
    }

    func rejectConfigurations(_ reject: Bool) {
        lock.lock()
        rejectConfiguration = reject
        lock.unlock()
    }

    func holdNextStart(_ barrier: Barrier) {
        lock.lock()
        nextStartBarrier = barrier
        lock.unlock()
    }

    func holdNextHealth(_ barrier: Barrier) {
        lock.lock()
        nextHealthBarrier = barrier
        lock.unlock()
    }

    func handle(_ envelope: XPCMockRequest) throws -> XPCDictionary {
        let request = try envelope.decode(as: BarlineMenuService.Request.self)
        let response: BarlineMenuService.Response
        switch request {
        case .start:
            lock.lock()
            recordsStorage.append(.init(sessionID: envelope.sessionID, operation: "start", configuration: nil))
            let barrier = nextStartBarrier
            nextStartBarrier = nil
            lock.unlock()
            try barrier?.enter()
            response = .start
        case let .configureConcealment(configuration, deadline):
            let label = configuration.concealedItemIDs.first?.bundleIdentifier
            lock.lock()
            recordsStorage.append(.init(sessionID: envelope.sessionID, operation: "configure", configuration: label))
            let rejected = rejectConfiguration || DispatchTime.now().uptimeNanoseconds >= deadline
            if !rejected {
                configurationStorage = label
            }
            lock.unlock()
            response = rejected ? .activation(.failure(.interrupted)) : .activation(.success(.init()))
        case .restart:
            lock.lock()
            recordsStorage.append(.init(sessionID: envelope.sessionID, operation: "restart", configuration: nil))
            configurationStorage = nil
            lock.unlock()
            response = .restart
        case .health:
            lock.lock()
            recordsStorage.append(.init(sessionID: envelope.sessionID, operation: "health", configuration: nil))
            let barrier = nextHealthBarrier
            nextHealthBarrier = nil
            lock.unlock()
            try barrier?.enter()
            response = .health(.init(backendName: "synthetic", state: .healthy, message: nil))
        default:
            throw Failure(message: "unexpected request in orchestration fixture")
        }
        return try XPCDictionary(encoding: response)
    }
}

@available(macOS 26.0, *)
private final class Fixture: @unchecked Sendable {
    let name: String
    let queue: DispatchQueue
    let helper: SyntheticHelper
    let session: BarlineMenuService.Session

    init(readCompletionGrace: DispatchTimeInterval = .milliseconds(200)) {
        let name = "test.barline.session." + UUID().uuidString
        let queue = DispatchQueue(label: "test.barline.session.requests")
        let helper = SyntheticHelper()
        self.name = name
        self.queue = queue
        self.helper = helper
        XPCMock.install(serviceName: name) { try helper.handle($0) }
        session = BarlineMenuService.Session(
            logger: Logger(subsystem: "test.barline", category: "session-orchestration"),
            requestQueue: queue,
            serviceName: name,
            readCompletionGrace: readCompletionGrace,
            peerRequirement: { XPCPeerRequirement(lightweightCodeRequirements: XPCDictionary()) }
        )
    }

    deinit {
        session.cancel(reason: "test fixture finished")
        XPCMock.remove(serviceName: name)
    }

    func enqueue(_ request: BarlineMenuService.Request, lease: MenuBarRequestLease? = nil) -> PendingReply {
        let pending = PendingReply()
        let lease = lease ?? session.makeLease(for: request)
        queue.async { [session] in
            pending.finish(session.send(request: request, lease: lease))
        }
        return pending
    }

    func configure(_ label: String) -> BarlineMenuService.Request {
        .configureConcealment(
            .init(visibleItemIDs: [], concealedItemIDs: [
                MenuBarItemID(bundleIdentifier: "test." + label, accessibilityIdentifier: "fixture"),
            ]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        )
    }

    func seedA() throws {
        try require(try isConfigured(enqueue(configure("a")).wait()), "configuration A did not seed")
        try require(helper.configuration == "test.a", "helper did not accept A")
    }

    func drain() throws {
        try require(session.drainTransport(timeout: .now() + 3), "transport worker did not drain")
    }
}

private func isStarted(_ response: BarlineMenuService.Response?) -> Bool {
    if case .start? = response {
        return true
    }
    return false
}

@available(macOS 26.0, *)
private func shortHealthLease(_ fixture: Fixture) -> MenuBarRequestLease {
    MenuBarRequestLease(
        admittedEpoch: fixture.session.makeLease(for: .health).admittedEpoch,
        deadline: DispatchTime.now().uptimeNanoseconds + 50_000_000
    )
}

private func timerFence(_ seconds: Double) throws {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.signal() }
    try require(done.wait(timeout: .now() + seconds + 1) == .success, "timer fence did not finish")
}

@available(macOS 26.0, *)
private func readyReadCompletesDuringGrace() throws {
    let fixture = Fixture()
    try fixture.seedA()
    let barrier = Barrier()
    defer { barrier.release() }
    fixture.helper.holdNextHealth(barrier)
    let pending = fixture.enqueue(.health, lease: shortHealthLease(fixture))
    try barrier.waitForArrival()
    try require(try pending.wait() == nil, "expired read returned a value")
    barrier.release()
    try fixture.drain()
    try timerFence(0.3)
    try require(XPCMock.events(serviceName: fixture.name).filter { $0.kind == "created" }.count == 1,
                "completed slow read retired a healthy session")
    try require(fixture.helper.configuration == "test.a", "completed read altered configuration")
}

@available(macOS 26.0, *)
private func hungReadyReadRetiresOnlyItsGeneration() throws {
    let fixture = Fixture()
    try fixture.seedA()
    guard let originalID = fixture.helper.records.last?.sessionID else { throw Failure(message: "missing original session") }
    let barrier = Barrier()
    defer { barrier.release() }
    fixture.helper.holdNextHealth(barrier)
    let pending = fixture.enqueue(.health, lease: shortHealthLease(fixture))
    try barrier.waitForArrival()
    try require(try pending.wait() == nil, "expired hung read returned a value")
    try require(XPCMock.waitForEvent(serviceName: fixture.name, sessionID: originalID, kind: "cancelled") != nil,
                "unfinished ready read survived its cleanup budget")
    try require(try isStarted(fixture.enqueue(.start).wait()), "hung read prevented replacement startup")
    try require(fixture.helper.configuration == "test.a", "replacement did not restore accepted configuration")
    barrier.release()
    try fixture.drain()
}

@available(macOS 26.0, *)
private func obsoleteReadCleanupCannotCancelReplacement() throws {
    let fixture = Fixture()
    try fixture.seedA()
    let barrier = Barrier()
    defer { barrier.release() }
    fixture.helper.holdNextHealth(barrier)
    let pending = fixture.enqueue(.health, lease: shortHealthLease(fixture))
    try barrier.waitForArrival()
    try require(try pending.wait() == nil, "expired old read returned a value")
    fixture.session.cancel(reason: "replace before delayed read cleanup")
    try require(try isConfigured(fixture.enqueue(fixture.configure("b")).wait()), "replacement B failed")
    guard let replacementID = fixture.helper.records.last?.sessionID else { throw Failure(message: "missing replacement") }
    try timerFence(0.3)
    try require(!XPCMock.events(serviceName: fixture.name).contains { $0.sessionID == replacementID && $0.kind == "cancelled" },
                "obsolete read cleanup cancelled replacement B")
    barrier.release()
    try fixture.drain()
    try require(fixture.helper.configuration == "test.b", "old read overwrote replacement B")
}

@available(macOS 26.0, *)
private func transportWorkersRemainBounded() throws {
    let fixture = Fixture(readCompletionGrace: .seconds(2))
    try fixture.seedA()
    var barriers = [Barrier]()
    defer { barriers.forEach { $0.release() } }
    for _ in 0 ..< 8 {
        let barrier = Barrier()
        barriers.append(barrier)
        fixture.helper.holdNextHealth(barrier)
        let pending = fixture.enqueue(.health, lease: shortHealthLease(fixture))
        try barrier.waitForArrival()
        try require(try pending.wait() == nil, "paused read returned a value")
    }
    let before = fixture.helper.records.count
    try require(try fixture.enqueue(.health, lease: shortHealthLease(fixture)).wait() == nil,
                "worker limit admitted another request")
    try require(fixture.helper.records.count == before, "worker limit still issued XPC")
    let allocations = XPCMock.events(serviceName: fixture.name).filter { $0.kind == "created" }.count
    fixture.session.cancel(reason: "new epoch cannot reset transport occupancy")
    try require(try fixture.enqueue(.start).wait() == nil, "fresh epoch bypassed occupied transport limit")
    try require(fixture.helper.records.count == before, "fresh epoch issued another request at the worker limit")
    try require(XPCMock.events(serviceName: fixture.name).filter { $0.kind == "created" }.count == allocations,
                "fresh epoch allocated a transport beyond the worker limit")
    barriers.forEach { $0.release() }
    try fixture.drain()
    try require(try isStarted(fixture.enqueue(.start).wait()), "released worker budget did not recover")
}

private func isConfigured(_ response: BarlineMenuService.Response?) -> Bool {
    if case .activation(.success)? = response {
        return true
    }
    return false
}

private func isRestarted(_ response: BarlineMenuService.Response?) -> Bool {
    if case .restart? = response {
        return true
    }
    return false
}

@available(macOS 26.0, *)
private func queuedBeforeAllocation() throws {
    let fixture = Fixture()
    let request = fixture.configure("b")
    // Both leases precede ANY session allocation, without relying on timing.
    let firstLease = fixture.session.makeLease(for: .start)
    let secondLease = fixture.session.makeLease(for: request)
    let first = fixture.enqueue(.start, lease: firstLease)
    let second = fixture.enqueue(request, lease: secondLease)
    try require(try isStarted(first.wait()), "first startup failed")
    try require(try isConfigured(second.wait()), "healthy allocation invalidated queued B")
    try require(fixture.helper.configuration == "test.b", "queued B was not final state")
    try require(XPCMock.events(serviceName: fixture.name).filter { $0.kind == "created" }.count == 1,
                "healthy queued work created more than one session")
    try fixture.drain()
}

@available(macOS 26.0, *)
private func explicitRestartRestoresA() throws {
    let fixture = Fixture()
    try fixture.seedA()
    fixture.session.cancel(reason: "explicit compatibility restart")
    let before = fixture.helper.records.count
    try require(try isRestarted(fixture.enqueue(.restart).wait()), "restart acknowledgement missing")
    try require(fixture.helper.configuration == nil, "restart fixture failed to clear assertion")
    try require(try isStarted(fixture.enqueue(.start).wait()), "restart follow-up start failed")
    let tail = Array(fixture.helper.records.dropFirst(before))
    try require(tail.map(\.operation) == ["restart", "start", "configure"],
                "restart replay occurred before clearing or was omitted afterward")
    try require(fixture.helper.configuration == "test.a", "restart reported ready without restoring A")
    try fixture.drain()
}

@available(macOS 26.0, *)
private func rejectedReplayIsNotReady() throws {
    let fixture = Fixture()
    try fixture.seedA()
    fixture.session.cancel(reason: "simulate replacement")
    fixture.helper.clearConfiguration()
    fixture.helper.rejectConfigurations(true)
    let before = fixture.helper.records.count
    try require(try fixture.enqueue(.start).wait() == nil, "failed replay was returned as successful start")
    try require(try fixture.enqueue(.start).wait() == nil, "failed replay left replacement marked ready")
    try require(fixture.helper.configuration == nil, "rejected replay changed helper state")
    let attempts = fixture.helper.records.dropFirst(before).filter { $0.operation == "configure" }
    try require(attempts.count >= 2, "second start bypassed required replay")
    fixture.session.cancel(reason: "stop test recovery retries")
    try fixture.drain()
}

@available(macOS 26.0, *)
private func timedOutOldHandshakeCannotOverwriteReplacement(request: BarlineMenuService.Request = .start) throws {
    let fixture = Fixture()
    try fixture.seedA()
    fixture.session.cancel(reason: "begin replacement scenario")
    fixture.helper.clearConfiguration()
    let barrier = Barrier()
    fixture.helper.holdNextStart(barrier)
    defer { barrier.release() }
    let admission = fixture.session.makeLease(for: request)
    let shortLease = MenuBarRequestLease(
        admittedEpoch: admission.admittedEpoch,
        deadline: DispatchTime.now().uptimeNanoseconds + 250_000_000
    )
    let old = PendingReply()
    let replacement = PendingReply()
    // Keep both operations on the actual serial request queue. Capture B's
    // lease after timeout retirement and before a background retry can run.
    fixture.queue.async {
        old.finish(fixture.session.send(request: request, lease: shortLease))
        let request = fixture.configure("b")
        let lease = fixture.session.makeLease(for: request)
        replacement.finish(fixture.session.send(request: request, lease: lease))
    }
    try barrier.waitForArrival()
    let oldSessionID = try {
        guard let record = fixture.helper.records.last(where: { $0.operation == "start" }) else {
            throw Failure(message: "paused handshake was not recorded")
        }
        return record.sessionID
    }()
    try require(try old.wait(seconds: 2) == nil, "old handshake did not time out")
    try require(try isConfigured(replacement.wait(seconds: 2)),
                "replacement B waited on obsolete initialization or failed")
    try require(fixture.helper.configuration == "test.b", "replacement did not commit B")
    guard let newSessionID = fixture.helper.records.last(where: {
        $0.operation == "configure" && $0.configuration == "test.b"
    })?.sessionID else { throw Failure(message: "replacement configuration record missing") }
    try require(newSessionID != oldSessionID, "replacement reused retired session")
    XPCMock.deliverLateCancellation(sessionID: oldSessionID)
    try require(XPCMock.waitForEvent(serviceName: fixture.name, sessionID: oldSessionID,
                                     kind: "late-cancellation-delivered") != nil,
                "late old cancellation callback did not execute")
    barrier.release()
    try fixture.drain()
    try require(fixture.helper.configuration == "test.b", "obsolete recovery overwrote B")
    try require(!fixture.helper.records.contains { $0.sessionID == oldSessionID && $0.operation == "configure" },
                "obsolete handshake initiated a replay")
    try require(!XPCMock.events(serviceName: fixture.name).contains {
        $0.sessionID == newSessionID && $0.kind == "cancelled"
    }, "old worker or callback cancelled replacement")
    fixture.session.cancel(reason: "stop pending background retry")
}

@available(macOS 26.0, *)
private func explicitCancelBeforeRecoveryScheduling() throws {
    let fixture = Fixture()
    try fixture.seedA()
    let cancellationBarrier = Barrier()
    let requestBarrier = Barrier()
    fixture.helper.holdNextStart(requestBarrier)
    fixture.session.cancel(reason: "prepare cold session")
    XPCMock.holdCancellation(serviceName: fixture.name) {
        try? cancellationBarrier.enter()
    }
    defer { requestBarrier.release(); cancellationBarrier.release() }
    let admission = fixture.session.makeLease(for: .start)
    let shortLease = MenuBarRequestLease(
        admittedEpoch: admission.admittedEpoch,
        deadline: DispatchTime.now().uptimeNanoseconds + 150_000_000
    )
    let pending = fixture.enqueue(.start, lease: shortLease)
    try requestBarrier.waitForArrival()
    // The timed-out generation has been removed, but transport cancellation
    // has not returned to scheduleRecovery yet. Cancel exactly in that gap.
    try cancellationBarrier.waitForArrival()
    fixture.session.cancel(reason: "explicit stop before stale scheduling")
    let recordsBefore = fixture.helper.records.count
    let allocationsBefore = XPCMock.events(serviceName: fixture.name).filter { $0.kind == "created" }.count
    cancellationBarrier.release()
    try require(try pending.wait(seconds: 2) == nil, "retired request unexpectedly succeeded")
    requestBarrier.release()
    try fixture.drain()
    let fence = DispatchSemaphore(value: 0)
    fixture.queue.asyncAfter(deadline: .now() + 0.3) { fence.signal() }
    try require(fence.wait(timeout: .now() + 2) == .success, "stale scheduling fence timed out")
    try require(fixture.helper.records.count == recordsBefore, "cancelled retirement scheduled new messages")
    try require(XPCMock.events(serviceName: fixture.name).filter { $0.kind == "created" }.count == allocationsBefore,
                "cancelled retirement scheduled a fresh session")
}

@available(macOS 26.0, *)
private func rejectedPersistenceCannotPoisonReplay() throws {
    let fixture = Fixture()
    try fixture.seedA()
    try require(try isConfigured(fixture.enqueue(fixture.configure("b")).wait()), "proposal B not accepted")
    fixture.helper.rejectConfigurations(true)
    let pending = PendingReply()
    fixture.queue.async {
        guard case let .configureConcealment(previous, _) = fixture.configure("a") else { return }
        fixture.session.restoreAcceptedConcealmentForRecovery(previous)
        pending.finish(fixture.session.send(request: fixture.configure("a"), lease: fixture.session.makeLease(for: fixture.configure("a"))))
    }
    try require(try !isConfigured(pending.wait()), "rollback fixture unexpectedly accepted A")
    fixture.session.cancel(reason: "replace helper after failed native rollback")
    fixture.helper.clearConfiguration()
    fixture.helper.rejectConfigurations(false)
    try require(try isStarted(fixture.enqueue(.start).wait()), "replacement handshake failed")
    try require(fixture.helper.configuration == "test.a", "unpersisted rejected B survived as recovery state")
    try fixture.drain()
}

@available(macOS 26.0, *)
private func explicitCancelInvalidatesDelayedRetry() throws {
    let fixture = Fixture()
    try fixture.seedA()
    guard let sessionID = fixture.helper.records.last?.sessionID else {
        throw Failure(message: "initial session missing")
    }
    let queueBarrier = Barrier()
    let barrierFailure = PendingReply()
    fixture.queue.async {
        do { try queueBarrier.enter(); barrierFailure.finish(.start) }
        catch { barrierFailure.finish(nil) }
    }
    defer { queueBarrier.release() }
    try queueBarrier.waitForArrival()
    XPCMock.interrupt(sessionID: sessionID)
    try require(XPCMock.waitForEvent(serviceName: fixture.name, sessionID: sessionID,
                                     kind: "cancellation-delivered") != nil,
                "external cancellation did not schedule recovery")
    fixture.session.cancel(reason: "explicit cancellation revokes retry epoch")
    let recordsBefore = fixture.helper.records.count
    let allocationsBefore = XPCMock.events(serviceName: fixture.name).filter { $0.kind == "created" }.count
    // This bounded timer advances beyond the production 100ms first backoff;
    // the blocked serial queue prevents the stale job from executing early.
    let timer = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { timer.signal() }
    try require(timer.wait(timeout: .now() + 1) == .success, "backoff readiness timer failed")
    queueBarrier.release()
    try require(try isStarted(barrierFailure.wait()), "request queue barrier failed")
    let fence = DispatchSemaphore(value: 0)
    fixture.queue.async { fence.signal() }
    try require(fence.wait(timeout: .now() + 2) == .success, "request queue failed to drain stale retry")
    try fixture.drain()
    try require(fixture.helper.records.count == recordsBefore, "revoked delayed retry sent a request")
    try require(XPCMock.events(serviceName: fixture.name).filter { $0.kind == "created" }.count == allocationsBefore,
                "revoked delayed retry allocated a session")
}

@main
private enum SessionRecoveryTestMain {
    static func main() {
        // Backstop even an unexpected production deadlock. Individual waits
        // above are also bounded; this never opens or contacts a real service.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            print("FAIL: session orchestration suite exceeded hard watchdog")
            exit(2)
        }
        guard #available(macOS 26.0, *) else {
            print("SKIP: macOS 26 required to compile production Session orchestration")
            exit(77)
        }
        do {
            let tests: [(String, () throws -> Void)] = [
                ("queued requests survive healthy first allocation", queuedBeforeAllocation),
                ("explicit restart restores accepted configuration", explicitRestartRestoresA),
                ("replay rejection cannot report readiness", rejectedReplayIsNotReady),
                ("expired old worker cannot overwrite or cancel replacement", { try timedOutOldHandshakeCannotOverwriteReplacement() }),
                ("expired initializing read cannot block replacement", { try timedOutOldHandshakeCannotOverwriteReplacement(request: .health) }),
                ("explicit cancellation revokes delayed retry", explicitCancelInvalidatesDelayedRetry),
                ("explicit cancellation rejects not-yet-scheduled stale recovery", explicitCancelBeforeRecoveryScheduling),
                ("failed persistence and native rollback cannot poison recovery replay", rejectedPersistenceCannotPoisonReplay),
                ("ready read finishing during grace preserves healthy session", readyReadCompletesDuringGrace),
                ("unfinished ready read retires only its own generation", hungReadyReadRetiresOnlyItsGeneration),
                ("obsolete read cleanup cannot cancel replacement", obsoleteReadCleanupCannotCancelReplacement),
                ("outstanding transport workers remain bounded", transportWorkersRemainBounded),
            ]
            for (name, test) in tests {
                try test()
                print("PASS: \(name)")
            }
            print("PASS: \(tests.count) actual Session orchestration regressions; mock transport only")
        } catch let failure as Failure {
            print("FAIL: \(failure.message)")
            exit(1)
        } catch {
            print("FAIL: unexpected synthetic transport or decoding error")
            exit(1)
        }
    }
}
