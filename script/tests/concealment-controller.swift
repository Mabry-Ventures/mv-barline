// TEST-ONLY DRAFT. Compile in the SAME module as the unmodified production
// GoldenGateConcealmentController.swift and Shared/Utilities/Logging.swift,
// linking the current BarlineCore module/object files. Do NOT import the ObjC
// bridging header or link GoldenGateAssessmentModeBridge.m: these Swift shims
// replace its functions. This executable never opens a real private assertion.
// Requires macOS 27 to execute the production controller's availability branch.
// The local NSWorkspace declaration intentionally shadows imported AppKit's
// type for this isolated executable; no real running applications are modified.
import AppKit
import BarlineCore
import Foundation

@MainActor
final class NSWorkspace {
    static let shared = NSWorkspace()
    struct Application {
        let bundleIdentifier: String?
    }

    var runningApplications: [Application] = []
}

private struct Payload: Equatable, Sendable {
    let concealed: Set<String>
    let system: Set<Int>
    let allowed: Set<String>
}

private final class BridgeSpy: @unchecked Sendable {
    struct State {
        var begins: [Payload] = []
        var commits = 0
        var aborts = 0
        var invalidations = 0
        var nextToken: UInt64 = 0
        var pending: [UInt64: Payload] = [:]
        var committed: Payload?
        var failNextCommit = false
        var failNextBegin = false
        var acknowledgedState = false
        var mismatchAfterNextCommit = false
        var committedStateOverride: Int32?
    }

    private let lock = NSLock()
    private var state = State()

    func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private let bridgeSpy = BridgeSpy()

func BLNGoldenGateAssessmentCreate() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: 1)
}

func BLNGoldenGateAssessmentBegin(
    _: UnsafeMutableRawPointer,
    _ concealed: CFArray,
    _ system: CFArray,
    _ allowed: CFArray
) -> UInt64 {
    // CFArray/NSArray are toll-free bridged. Retain only copied value types.
    let concealedArray = unsafeBitCast(concealed, to: NSArray.self)
    let systemArray = unsafeBitCast(system, to: NSArray.self)
    let allowedArray = unsafeBitCast(allowed, to: NSArray.self)
    let payload = Payload(
        concealed: Set(concealedArray.compactMap { $0 as? String }),
        system: Set(systemArray.compactMap { ($0 as? NSNumber)?.intValue }),
        allowed: Set(allowedArray.compactMap { $0 as? String })
    )
    return bridgeSpy.withState {
        $0.begins.append(payload)
        if $0.failNextBegin {
            $0.failNextBegin = false
            return 0
        }
        $0.nextToken += 1
        $0.pending[$0.nextToken] = payload
        return $0.nextToken
    }
}

func BLNGoldenGateAssessmentActivationState(_: UnsafeMutableRawPointer, _ token: UInt64) -> Int32 {
    bridgeSpy.withState { $0.pending[token] == nil ? -2 : 1 }
}

func BLNGoldenGateAssessmentCommit(_: UnsafeMutableRawPointer, _ token: UInt64) -> Bool {
    bridgeSpy.withState {
        if $0.failNextCommit {
            $0.failNextCommit = false
            return false
        }
        guard let payload = $0.pending.removeValue(forKey: token) else { return false }
        $0.committed = payload
        $0.acknowledgedState = true
        if $0.mismatchAfterNextCommit {
            $0.mismatchAfterNextCommit = false
            $0.committedStateOverride = -1
        }
        $0.commits += 1
        return true
    }
}

func BLNGoldenGateAssessmentAbort(_: UnsafeMutableRawPointer, _ token: UInt64) -> Bool {
    bridgeSpy.withState {
        guard $0.pending.removeValue(forKey: token) != nil else { return false }
        $0.aborts += 1
        return true
    }
}

func BLNGoldenGateAssessmentCommittedState(_: UnsafeMutableRawPointer) -> Int32 {
    bridgeSpy.withState {
        if let overridden = $0.committedStateOverride {
            $0.committedStateOverride = nil
            return overridden
        }
        guard $0.pending.isEmpty, $0.acknowledgedState else { return -1 }
        guard let payload = $0.committed else { return 0 }
        return payload.concealed.isEmpty && payload.system == Set(0 ... 8) ? 0 : 1
    }
}

func BLNGoldenGateAssessmentInvalidate(_: UnsafeMutableRawPointer) {
    bridgeSpy.withState {
        $0.invalidations += 1
        $0.pending.removeAll()
        $0.committed = nil
        $0.acknowledgedState = false
    }
}

func BLNGoldenGateAssessmentDestroy(_: UnsafeMutableRawPointer) {}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw CheckFailure(description: message)
    }
}

@main
struct ControllerSkipPathProbe {
    @MainActor
    static func main() async throws {
        guard #available(macOS 27.0, *) else {
            throw CheckFailure(description: "Requires macOS 27; no controller test executed")
        }
        let hiddenBundle = "test.barline.hidden"
        let existing = "test.barline.existing"
        let newlyRunning = "test.barline.new"
        let another = "test.barline.another"
        let hidden = MenuBarItemID(bundleIdentifier: hiddenBundle, accessibilityIdentifier: "fixture")
        let configuration = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [hidden])
        let allVisible = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [])
        let mandatory: Set = [
            "com.mabryventures.Barline", "com.apple.systemuiserver", "com.apple.finder", "com.apple.dock",
        ]
        func running(_ bundles: [String]) {
            NSWorkspace.shared.runningApplications = bundles.map { .init(bundleIdentifier: $0) }
        }
        func beginCount() -> Int {
            bridgeSpy.withState { $0.begins.count }
        }
        let controller = GoldenGateConcealmentController()
        let initialReceipt = try await controller.receipt()
        try require(initialReceipt.phase == .unknown && !initialReceipt.isStable,
                    "unconfigured helper must supply no stable receipt")

        running([existing, hiddenBundle])
        let firstReceipt = try await controller.configure(configuration)
        try require(firstReceipt.isStable && firstReceipt.phase == .asserted &&
            firstReceipt.configurationRevision == 1,
            "first acknowledgement must describe committed assertion ownership")
        try require(beginCount() == 1, "first configuration must Begin")
        try require(bridgeSpy.withState { $0.committed?.allowed == mandatory.union([existing]) },
                    "Begin must receive the captured effective allowlist")
        let noOpReceipt = try await controller.configure(configuration)
        try require(beginCount() == 1, "identical shelf/configure call must skip Begin")
        try require(noOpReceipt == firstReceipt, "true no-op must preserve exact receipt")

        let hiddenSibling = MenuBarItemID(bundleIdentifier: hiddenBundle, accessibilityIdentifier: "sibling")
        let siblingConfiguration = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [hiddenSibling])
        let siblingReceipt = try await controller.configure(siblingConfiguration)
        try require(beginCount() == 1 && siblingReceipt.configurationRevision == firstReceipt.configurationRevision + 1 &&
            siblingReceipt.effectiveStateDigest == firstReceipt.effectiveStateDigest &&
            siblingReceipt.assertionRevision > firstReceipt.assertionRevision,
            "changed logical configuration with identical native state needs a new acknowledgement")
        try await controller.configure(configuration)

        running([hiddenBundle, existing, existing])
        try await controller.configure(configuration)
        try require(beginCount() == 1, "reordering/duplicate running bundle must skip Begin")
        running([existing])
        try await controller.configure(configuration)
        running([existing, hiddenBundle])
        try await controller.configure(configuration)
        try require(beginCount() == 1, "concealed app termination/relaunch must skip Begin")

        running([existing, hiddenBundle, newlyRunning])
        try await controller.configure(configuration)
        try require(beginCount() == 2, "new visible app must refresh unchanged logical configuration")
        try require(bridgeSpy.withState { $0.committed?.allowed == mandatory.union([existing, newlyRunning]) },
                    "new visible bundle must reach actual Begin argument")
        try await controller.configure(configuration)
        try require(beginCount() == 2, "successful replacement must deduplicate")

        let accepted = bridgeSpy.withState { $0.committed }
        running([existing, hiddenBundle, newlyRunning, another])
        bridgeSpy.withState { $0.failNextCommit = true }
        var failed = false
        do { try await controller.configure(configuration) } catch { failed = true }
        try require(failed, "failed native Commit must propagate")
        try require(bridgeSpy.withState { $0.aborts == 1 && $0.committed == accepted && $0.pending.isEmpty },
                    "failed Commit must abort and preserve prior accepted assertion")
        let failedReceipt = try await controller.receipt()
        try require(failedReceipt.phase == .unknown && failedReceipt.effectiveStateDigest == nil,
                    "aborting a candidate does not reauthorize prior native proof")
        try await controller.configure(configuration)
        try require(beginCount() == 4, "failed candidate must not poison committed dedup key")
        try await controller.configure(configuration)
        try require(beginCount() == 4, "successful retry must publish committed key")

        running([existing, hiddenBundle])
        try await controller.configure(configuration)
        try require(beginCount() == 5, "departed allowed bundles must refresh exact allowlist")
        let firstReveal = try await controller.beginTemporaryReveal(hidden)
        try require(firstReveal && beginCount() == 6, "temporary reveal must update native state")
        let revealReceipt = try await controller.receipt()
        try require(revealReceipt.phase == .transient && !revealReceipt.isStable,
                    "cleared assertion remains transient while reveal is owned")
        _ = try await controller.beginTemporaryReveal(hidden)
        try require(beginCount() == 6, "overlapping same-item reveal must deduplicate")
        let nestedReceipt = try await controller.receipt()
        try require(nestedReceipt.assertionRevision > revealReceipt.assertionRevision &&
            nestedReceipt.configurationRevision == revealReceipt.configurationRevision,
            "nested reveal ownership changes receipt without rebuilding native state")
        try await controller.endTemporaryReveal(hidden)
        try require(beginCount() == 6, "first reveal lease end must preserve second lease")
        try await controller.endTemporaryReveal(hidden)
        try require(beginCount() == 7, "final reveal lease end must restore concealed state")
        try await require(controller.receipt().phase == .asserted,
                          "last reveal restoration establishes stable committed ownership")

        let clearReceipt = try await controller.configure(allVisible)
        try require(beginCount() == 8, "all-visible transition must clear prior assertion")
        try require(clearReceipt.phase == .deasserted && clearReceipt.isStable,
                    "all-visible acknowledgement must not claim a held assertion")
        running([another, newlyRunning])
        try await controller.configure(allVisible)
        try require(beginCount() == 8, "all-visible app churn must skip Begin")
        await controller.invalidate()
        let invalidatedReceipt = try await controller.receipt()
        try require(invalidatedReceipt.helperSessionID != clearReceipt.helperSessionID &&
            invalidatedReceipt.phase == .unknown,
            "lifecycle invalidation must revoke the old session proof")
        try await controller.configure(allVisible)
        try require(beginCount() == 9, "invalidate must clear the committed native key")
        await controller.invalidate()

        running([existing, hiddenBundle])
        let restrictiveReceipt = try await controller.configure(configuration)
        let beforeFailedBegin = beginCount()
        bridgeSpy.withState { $0.failNextBegin = true }
        var beginFailed = false
        do { try await controller.configure(allVisible) } catch let error as MenuBarBackendError {
            beginFailed = error == .operationFailed("Golden Gate native concealment could not start")
        }
        try require(beginFailed, "zero token must propagate uncertain native failure")
        let unknownReceipt = try await controller.receipt()
        try require(unknownReceipt.phase == .unknown &&
            unknownReceipt.assertionRevision > restrictiveReceipt.assertionRevision,
            "zero token must revoke prior receipt even when old committed pointer remains")
        let retryReceipt = try await controller.configure(configuration)
        try require(beginCount() == beforeFailedBegin + 2 && retryReceipt.isStable,
                    "old configuration after unknown state must not take equality fast path")

        _ = try await controller.beginTemporaryReveal(hidden)
        bridgeSpy.withState { $0.failNextCommit = true }
        var revealRestoreFailed = false
        do { try await controller.endTemporaryReveal(hidden) } catch let error as MenuBarBackendError {
            revealRestoreFailed = error == .interrupted
        }
        try require(revealRestoreFailed, "failed final reveal restoration must propagate typed failure")
        try await require(controller.receipt().phase == .unknown,
                          "failed final reveal restoration must not authorize transient or prior state")
        try await controller.endTemporaryReveal(hidden)
        let restoredRevealReceipt = try await controller.receipt()
        try require(restoredRevealReceipt.phase == .asserted && restoredRevealReceipt.isStable &&
            restoredRevealReceipt.configurationRevision == retryReceipt.configurationRevision,
            "failed final reveal retains its lease so retry can establish accepted state")

        bridgeSpy.withState { $0.mismatchAfterNextCommit = true }
        var mismatchFailed = false
        do { try await controller.configure(allVisible) } catch let error as MenuBarBackendError {
            mismatchFailed = error == .mutationRecoveryFailed
        }
        try require(mismatchFailed, "unexpected bridge acknowledgement must fail closed")
        try await require(controller.receipt().phase == .unknown,
                          "committed-state mismatch cannot authorize a stable receipt")
        let beforeMismatchRetry = beginCount()
        try await controller.configure(configuration)
        try require(beginCount() == beforeMismatchRetry + 1,
                    "committed-state mismatch must clear the equality key before old configuration retry")

        let beforeClock = try await controller.receipt()
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        let clockPressed = try await controller.pressSystemClockLiftingConcealment(
            deadlineUptimeNanoseconds: deadline, isCurrent: { true }, { true }
        )
        let afterClock = try await controller.receipt()
        try require(clockPressed && afterClock.isStable && afterClock != beforeClock &&
            afterClock.configurationRevision == beforeClock.configurationRevision &&
            afterClock.effectiveStateDigest == beforeClock.effectiveStateDigest,
            "clock lift/reapply must never reuse pre-lift observation proof")
        bridgeSpy.withState { $0.failNextCommit = true }
        var clockFailed = false
        do {
            _ = try await controller.pressSystemClockLiftingConcealment(
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 3_000_000_000,
                isCurrent: { true }, { true }
            )
        } catch let error as MenuBarBackendError { clockFailed = error == .mutationRecoveryFailed }
        try require(clockFailed, "failed clock restoration must propagate typed failure")
        try await require(controller.receipt().phase == .unknown,
                          "scheduled clock recovery must not authorize old proof")
        await controller.invalidate()
        let revoked = try await controller.receipt()
        try await Task.sleep(for: .milliseconds(1100))
        try await require(controller.receipt() == revoked,
                          "revoked recovery worker must not establish successor authority")
        print("PASS: real concealment controller receipts, skip path, exact bridge payload, uncertain failures, reveal leases, clock recovery, and invalidation")
    }
}
