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

/// Isolated replacement for the helper's sealed Info.plist lookup. The actual
/// production controller must use this identity in both resolver and allowlist;
/// no application is running with this identifier in the workspace double.
enum BarlineMenuService {
    static let configuredAppIdentifier = "test.barline.CustomIdentity"

    static func requiredIdentity(forInfoKey key: String) -> String {
        precondition(key == "BarlineAppSigningIdentifier")
        return configuredAppIdentifier
    }
}

final class NSWorkspace: @unchecked Sendable {
    static let shared = NSWorkspace()
    struct Application: Sendable {
        let bundleIdentifier: String?
        var processIdentifier: Int32 = 1
        var launchDate: Date? = Date(timeIntervalSince1970: 1)
        var isTerminated = false
        var hasLiveMenuItem = true
        var kernelStartSeconds: UInt64? = 1
    }

    private let lock = NSLock()
    private var applications: [Application] = []
    var runningApplications: [Application] {
        get { lock.withLock { applications } }
        set { lock.withLock { applications = newValue } }
    }
}

enum GoldenGateAXInventory {
    static func publisherLifetime(for pid: Int32) -> GoldenGatePublisherLifetime? {
        let callback = bridgeSpy.withState {
            let callback = $0.beforeNextLifetimeRead
            $0.beforeNextLifetimeRead = nil
            return callback
        }
        callback?()
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
              let seconds = app.kernelStartSeconds else { return nil }
        return GoldenGatePublisherLifetime(pid: pid, reportedPID: UInt32(pid), bytes: 100, expectedBytes: 100, seconds: seconds, microseconds: 0)
    }

    static func publisherHasStatusItem(processIdentifier pid: Int32, bundleIdentifier: String, lifetime: GoldenGatePublisherLifetime, deadline: UInt64) -> Bool {
        let stall = bridgeSpy.withState {
            $0.publisherProbes.append(pid)
            return $0.stalledPublisherPID == pid
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if stall, now < deadline {
            Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000)
        }
        let visible = publisherLifetime(for: pid) == lifetime && DispatchTime.now().uptimeNanoseconds < deadline &&
            NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid && $0.bundleIdentifier == bundleIdentifier })?.hasLiveMenuItem == true
        let callback = bridgeSpy.withState {
            let callback = $0.afterNextPublisherObservation
            $0.afterNextPublisherObservation = nil
            return callback
        }
        callback?()
        return visible && publisherLifetime(for: pid) == lifetime &&
            NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })?.bundleIdentifier == bundleIdentifier
    }
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
        var failCreate = false
        var cancelNextBegin = false
        var cancelNextInvalidate = false
        var rejectBegins = 0
        var afterNextCommit: (@Sendable () -> Void)?
        var afterNextInvalidate: (@Sendable () -> Void)?
        var afterNextPublisherObservation: (@Sendable () -> Void)?
        var beforeNextLifetimeRead: (@Sendable () -> Void)?
        var stalledPublisherPID: Int32?
        var publisherProbes: [Int32] = []
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
    bridgeSpy.withState { $0.failCreate ? nil : UnsafeMutableRawPointer(bitPattern: 1) }
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
    let cancel = bridgeSpy.withState {
        let requested = $0.cancelNextBegin
        $0.cancelNextBegin = false
        return requested
    }
    if cancel {
        withUnsafeCurrentTask { $0?.cancel() }
    }
    return bridgeSpy.withState {
        $0.begins.append(payload)
        if $0.rejectBegins > 0 {
            $0.rejectBegins -= 1
            return 0
        }
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
    let result: (Bool, (@Sendable () -> Void)?) = bridgeSpy.withState {
        if $0.failNextCommit {
            $0.failNextCommit = false
            return (false, nil)
        }
        guard let payload = $0.pending.removeValue(forKey: token) else { return (false, nil) }
        $0.committed = payload
        $0.acknowledgedState = true
        if $0.mismatchAfterNextCommit {
            $0.mismatchAfterNextCommit = false
            $0.committedStateOverride = -1
        }
        $0.commits += 1
        let callback = $0.afterNextCommit
        $0.afterNextCommit = nil
        return (true, callback)
    }
    result.1?()
    return result.0
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
    let cancel = bridgeSpy.withState {
        let value = $0.cancelNextInvalidate
        $0.cancelNextInvalidate = false
        return value
    }
    if cancel {
        withUnsafeCurrentTask { $0?.cancel() }
    }
    let callback = bridgeSpy.withState {
        $0.invalidations += 1
        $0.pending.removeAll()
        $0.committed = nil
        $0.acknowledgedState = false
        let callback = $0.afterNextInvalidate
        $0.afterNextInvalidate = nil
        return callback
    }
    callback?()
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
    @available(macOS 27.0, *)
    private static func verifyAutonomousPublicationAndDuplicateInstances() async throws {
        let target = MenuBarItemID(bundleIdentifier: "test.autonomous.target", accessibilityIdentifier: "item")
        let sibling = MenuBarItemID(bundleIdentifier: "test.autonomous.sibling", accessibilityIdentifier: "item")
        let visible = MenuBarConcealmentConfiguration(visibleItemIDs: [target], concealedItemIDs: [sibling])
        let hidden = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [target, sibling])
        let siblingApp = NSWorkspace.Application(bundleIdentifier: sibling.bundleIdentifier, processIdentifier: 81)
        var failures = [String]()
        bridgeSpy.withState { $0 = BridgeSpy.State() }
        NSWorkspace.shared.runningApplications = [
            .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 80), siblingApp,
        ]
        let lateController = GoldenGateConcealmentController()
        try await lateController.configure(visible)
        NSWorkspace.shared.runningApplications = [
            .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 82, hasLiveMenuItem: false), siblingApp,
        ]
        try await lateController.configure(visible)
        try await Task.sleep(for: .milliseconds(300))
        // No second workspace/configuration event: only the same process's
        // status item becomes available after the launch observation.
        NSWorkspace.shared.runningApplications[0].hasLiveMenuItem = true
        try await Task.sleep(for: .milliseconds(1500))
        if bridgeSpy.withState({ $0.invalidations }) != 1 {
            failures.append("visible late publisher must recover without a second workspace event")
        }
        await lateController.invalidate()

        bridgeSpy.withState { $0 = BridgeSpy.State() }
        NSWorkspace.shared.runningApplications = [
            .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 83), siblingApp,
        ]
        let duplicateController = GoldenGateConcealmentController()
        try await duplicateController.configure(hidden)
        NSWorkspace.shared.runningApplications = [
            .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 84),
            .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 85, hasLiveMenuItem: false), siblingApp,
        ]
        var revealed = false
        do { revealed = try await duplicateController.beginTemporaryReveal(target) } catch {}
        if !revealed {
            failures.append("a nonpublisher same-bundle process must not reject an observed publisher's reveal")
        }
        if revealed {
            try await duplicateController.endTemporaryReveal(target)
            let clears = bridgeSpy.withState { $0.invalidations }
            for _ in 0 ..< 20 {
                _ = try await duplicateController.beginTemporaryReveal(target)
                try await duplicateController.endTemporaryReveal(target)
            }
            if bridgeSpy.withState({ $0.invalidations }) != clears {
                failures.append("silent same-bundle duplicate must not cause repeated reveal clears")
            }
            // The duplicate remains an independent unsettled lifetime. Its
            // later AX publication needs its own boundary, not bundle credit.
            NSWorkspace.shared.runningApplications[1].hasLiveMenuItem = true
            _ = try await duplicateController.beginTemporaryReveal(target)
            try await duplicateController.endTemporaryReveal(target)
            if bridgeSpy.withState({ $0.invalidations }) != clears + 1 {
                failures.append("same-bundle duplicate publishing later needs its own clear")
            }
        }
        await duplicateController.invalidate()

        // A settled sibling is not evidence that a new same-bundle owner was
        // observed. A stalled companion must leave a bounded read opportunity
        // for the readable publisher ordered behind it.
        bridgeSpy.withState { $0 = BridgeSpy.State() }
        let settled = NSWorkspace.Application(bundleIdentifier: target.bundleIdentifier, processIdentifier: 90)
        NSWorkspace.shared.runningApplications = [settled, siblingApp]
        let fairnessController = GoldenGateConcealmentController()
        try await fairnessController.configure(hidden)
        NSWorkspace.shared.runningApplications = [settled,
                                                  .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 91, hasLiveMenuItem: false),
                                                  .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 92), siblingApp]
        bridgeSpy.withState { $0.stalledPublisherPID = 91; $0.publisherProbes = [] }
        _ = try await fairnessController.beginTemporaryReveal(target)
        if !bridgeSpy.withState({ $0.publisherProbes.contains(92) && $0.invalidations == 1 }) {
            failures.append("settled sibling and stalled companion must not mask a newly readable publisher")
        }
        try await fairnessController.endTemporaryReveal(target)
        let fairnessClears = bridgeSpy.withState { $0.invalidations }
        for _ in 0 ..< 3 {
            _ = try await fairnessController.beginTemporaryReveal(target)
            try await fairnessController.endTemporaryReveal(target)
        }
        if bridgeSpy.withState({ $0.invalidations }) != fairnessClears {
            failures.append("stalled same-bundle companion must not cause repeated reveal clears")
        }
        await fairnessController.invalidate()
        for failure in failures {
            print("FAIL: \(failure)")
        }
        try require(failures.isEmpty, failures.joined(separator: "; "))
        print("PASS: autonomous late publication and same-bundle nonpublisher reveal regressions")
    }

    @MainActor
    @available(macOS 27.0, *)
    private static func verifyReviewRegressions() async throws {
        let hidden = MenuBarItemID(bundleIdentifier: "test.review.hidden", accessibilityIdentifier: "item")
        let other = MenuBarItemID(bundleIdentifier: "test.review.other", accessibilityIdentifier: "item")
        let configuration = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [hidden, other])
        var failures = [String]()
        for scenario in 0 ... 2 {
            bridgeSpy.withState { $0 = BridgeSpy.State() }
            var target = NSWorkspace.Application(bundleIdentifier: hidden.bundleIdentifier, processIdentifier: 40)
            if scenario == 1 {
                target.hasLiveMenuItem = false
            }
            if scenario == 2 {
                target.launchDate = nil
            }
            let sibling = NSWorkspace.Application(bundleIdentifier: other.bundleIdentifier, processIdentifier: 41)
            NSWorkspace.shared.runningApplications = [target, sibling]
            let controller = GoldenGateConcealmentController()
            try await controller.configure(configuration)
            switch scenario {
            case 0:
                target.processIdentifier = 42
                NSWorkspace.shared.runningApplications = [target, sibling]
                _ = try await controller.beginTemporaryReveal(hidden)
            case 1:
                // The retained assignment existed while the owner had no AX
                // status item. Logical configuration is not observation proof.
                target.hasLiveMenuItem = true
                NSWorkspace.shared.runningApplications = [target, sibling]
                try await controller.configure(.init(visibleItemIDs: [hidden], concealedItemIDs: [other]))
            default:
                // Same PID and unavailable AppKit launch date, new kernel birth.
                target.kernelStartSeconds = 2
                NSWorkspace.shared.runningApplications = [target, sibling]
                try await controller.configure(.init(visibleItemIDs: [hidden], concealedItemIDs: [other]))
            }
            let messages = [
                "first reveal of a relaunched hidden owner requires a clear before the proposed lease",
                "retained hidden ID without a live AX item must not settle a delayed publisher",
                "nil AppKit launch dates cannot alias a recycled PID with a new kernel birth",
            ]
            if bridgeSpy.withState({ $0.invalidations }) != 1 {
                failures.append(messages[scenario])
                print("FAIL: \(messages[scenario])")
            }
            await controller.invalidate()
        }
        try require(failures.isEmpty, "review regressions: \(failures.joined(separator: "; "))")
        print("PASS: first hidden reveal, retained delayed publisher and unavailable launch date regressions")
    }

    @MainActor
    @available(macOS 27.0, *)
    private static func verifyPublisherObservationFailures() async throws {
        for values in [(Int32(0), UInt32(40), Int32(100), UInt64(1), UInt64(0)),
                       (40, 41, 100, 1, 0), (40, 40, 99, 1, 0),
                       (40, 40, 100, 0, 0), (40, 40, 100, 1, 1_000_000)]
        {
            try require(GoldenGatePublisherLifetime(
                pid: values.0, reportedPID: values.1, bytes: values.2, expectedBytes: 100,
                seconds: values.3, microseconds: values.4
            ) == nil, "invalid, short, mismatched or missing kernel birth cannot settle an owner")
        }
        let target = MenuBarItemID(bundleIdentifier: "test.probe.target", accessibilityIdentifier: "item")
        let sibling = MenuBarItemID(bundleIdentifier: "test.probe.sibling", accessibilityIdentifier: "item")
        let hidden = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [target, sibling])
        func applications(pid: Int32, live: Bool = true, birth: UInt64? = 1) -> [NSWorkspace.Application] {
            [
                .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: pid, hasLiveMenuItem: live, kernelStartSeconds: birth),
                .init(bundleIdentifier: sibling.bundleIdentifier, processIdentifier: 51),
            ]
        }
        for failure in [true, false] {
            bridgeSpy.withState { $0 = BridgeSpy.State() }
            NSWorkspace.shared.runningApplications = applications(pid: 50)
            let controller = GoldenGateConcealmentController()
            try await controller.configure(hidden)
            NSWorkspace.shared.runningApplications = applications(pid: 52, live: false)
            if !failure {
                let published = applications(pid: 52)
                bridgeSpy.withState { $0.afterNextInvalidate = { NSWorkspace.shared.runningApplications = published } }
            }
            var rejected = false
            do { _ = try await controller.beginTemporaryReveal(target) } catch { rejected = true }
            try require(rejected == failure, "first reveal requires a fresh post-clear publisher observation")
            if failure {
                try await require(controller.receipt().isStable, "missing post-clear AX must compensate accepted hidden state")
                try require(bridgeSpy.withState {
                    $0.committed?.concealed == Set([target.bundleIdentifier, sibling.bundleIdentifier]) && $0.invalidations == 2
                }, "failed first reveal must not acquire ownership or keep rejected visibility")
                NSWorkspace.shared.runningApplications = applications(pid: 52)
                _ = try await controller.beginTemporaryReveal(target)
                try require(bridgeSpy.withState { $0.invalidations == 3 }, "later retry must still own its first clear")
            } else {
                try require(bridgeSpy.withState { $0.invalidations == 1 }, "item born while deasserted needs only one clear")
            }
            try await controller.endTemporaryReveal(target)
            try await require(controller.receipt().isStable, "single successful lease ends cleanly after missing AX")
            await controller.invalidate()
        }

        bridgeSpy.withState { $0 = BridgeSpy.State() }
        NSWorkspace.shared.runningApplications = applications(pid: 50)
        let controller = GoldenGateConcealmentController()
        try await controller.configure(hidden)
        let visible = MenuBarConcealmentConfiguration(visibleItemIDs: [target], concealedItemIDs: [sibling])
        NSWorkspace.shared.runningApplications = applications(pid: 52, birth: nil)
        try await controller.configure(visible)
        let count = bridgeSpy.withState { $0.begins.count }
        for _ in 0 ..< 100 {
            try await controller.configure(visible)
        }
        try require(bridgeSpy.withState {
            $0.begins.count == count && $0.invalidations == 0 && $0.committed?.allowed.contains(target.bundleIdentifier) == true
        }, "missing birth cannot drop allowlist membership or cause repeated clear churn")
        NSWorkspace.shared.runningApplications = applications(pid: 52)
        let replacement = applications(pid: 52, birth: 2)
        bridgeSpy.withState { $0.afterNextPublisherObservation = { NSWorkspace.shared.runningApplications = replacement } }
        try await controller.configure(visible)
        try require(bridgeSpy.withState { $0.invalidations == 0 }, "replacement during AX read must remain unobserved")
        try await controller.configure(visible)
        try require(bridgeSpy.withState { $0.invalidations == 1 }, "fresh replacement observation needs its own clear")
        await controller.invalidate()
        print("PASS: bounded missing AX, post-clear publication, compensation, birth validation, replacement and no-churn regressions")
    }

    @MainActor
    @available(macOS 27.0, *)
    private static func verifyPublisherRoutingAndBudget() async throws {
        for name in ["battery", "bluetooth", "clock", "displays", "keyboard", "sound", "wifi", "screenmirroring", "controlcenter"] {
            bridgeSpy.withState { $0 = BridgeSpy.State() }
            NSWorkspace.shared.runningApplications = []
            let controller = GoldenGateConcealmentController()
            let system = MenuBarItemID(bundleIdentifier: "com.apple.MenuBarAgent", accessibilityIdentifier: "com.apple.menuextra.\(name)")
            try await controller.configure(.init(visibleItemIDs: [], concealedItemIDs: [system]))
            _ = try await controller.beginTemporaryReveal(system)
            try await controller.endTemporaryReveal(system)
            try require(bridgeSpy.withState { $0.invalidations == 0 && $0.publisherProbes.isEmpty },
                        "known enum-backed system reveals cannot require a standalone application witness")
            try await require(controller.receipt().isStable, "system reveal restores stable ownership")
            await controller.invalidate()
        }

        bridgeSpy.withState { $0 = BridgeSpy.State() }
        let target = MenuBarItemID(bundleIdentifier: "test.priority.target", accessibilityIdentifier: "item")
        let stalled = MenuBarItemID(bundleIdentifier: "test.priority.stalled", accessibilityIdentifier: "item")
        let hidden = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [target, stalled])
        let stalledApp = NSWorkspace.Application(bundleIdentifier: stalled.bundleIdentifier, processIdentifier: 1, hasLiveMenuItem: false)
        NSWorkspace.shared.runningApplications = [stalledApp, .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 60)]
        let controller = GoldenGateConcealmentController()
        try await controller.configure(hidden)
        NSWorkspace.shared.runningApplications = [stalledApp, .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 61)]
        bridgeSpy.withState { $0.stalledPublisherPID = 1; $0.publisherProbes = [] }
        _ = try await controller.beginTemporaryReveal(target)
        try require(bridgeSpy.withState { !$0.publisherProbes.contains(1) && $0.publisherProbes.first == 61 && $0.invalidations == 1 },
                    "foreground reveal must probe clicked publisher before and instead of unrelated stalled hidden owner")
        try await controller.endTemporaryReveal(target)

        // Newly running apps during the clear interval join the fresh allowlist.
        NSWorkspace.shared.runningApplications = [stalledApp, .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 62)]
        let afterClear = NSWorkspace.shared.runningApplications + [.init(bundleIdentifier: "test.priority.late", processIdentifier: 63)]
        bridgeSpy.withState {
            $0.stalledPublisherPID = nil
            $0.afterNextInvalidate = { NSWorkspace.shared.runningApplications = afterClear }
        }
        _ = try await controller.beginTemporaryReveal(target)
        try require(bridgeSpy.withState { $0.committed?.allowed.contains("test.priority.late") == true },
                    "post-clear native allowlist must include apps launched during settlement")
        try await controller.endTemporaryReveal(target)
        await controller.invalidate()

        // Old workspace bundle plus a reused PID's new kernel identity cannot
        // count as observation of the old publisher.
        bridgeSpy.withState { $0 = BridgeSpy.State() }
        NSWorkspace.shared.runningApplications = [stalledApp, .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 70)]
        let secondController = GoldenGateConcealmentController()
        try await secondController.configure(hidden)
        NSWorkspace.shared.runningApplications = [stalledApp, .init(bundleIdentifier: target.bundleIdentifier, processIdentifier: 71)]
        let differentBundle = [stalledApp, NSWorkspace.Application(bundleIdentifier: "test.priority.replacement", processIdentifier: 71, kernelStartSeconds: 2)]
        bridgeSpy.withState { $0.beforeNextLifetimeRead = { NSWorkspace.shared.runningApplications = differentBundle } }
        try await secondController.configure(.init(visibleItemIDs: [target], concealedItemIDs: [stalled]))
        try require(bridgeSpy.withState { $0.invalidations == 0 }, "stale bundle metadata cannot settle another process's AX item")
        await secondController.invalidate()
        print("PASS: all nine system reveal routes, target-first budget, post-clear workspace and stale-bundle safeguards")
    }

    @MainActor
    @available(macOS 27.0, *)
    private static func verifyColdEnvironmentBootstrap() async throws {
        bridgeSpy.withState { $0 = BridgeSpy.State() }
        NSWorkspace.shared.runningApplications = []
        let controller = GoldenGateConcealmentController()
        let initial = try await controller.receipt()
        try require(!initial.isStable, "receipt reads must not manufacture startup proof")
        let display = MenuBarDisplayID("bootstrap-fixture")
        let scene: @Sendable () -> MenuBarEnvironmentSnapshot = {
            MenuBarEnvironmentSnapshot(
                activeDisplayID: 1, activeStableDisplayID: display, activeSpaceToken: 1,
                activeSpaceIsFullscreen: false, menuTrackingIsActive: false
            )
        }
        async let firstEnvironment = controller.environment(scene)
        async let secondEnvironment = controller.environment(scene)
        let (before, after) = try await (firstEnvironment, secondEnvironment)
        try require(before.nativeConcealmentReceipt?.isStable == true &&
            before.nativeConcealmentReceipt?.phase == .deasserted,
            "first environment must establish a verified deasserted receipt before inventory")
        try require(before == after && bridgeSpy.withState { $0.begins.count == 1 && $0.commits == 1 },
                    "repeat environment must reuse the exact acknowledged startup state")
        try require(bridgeSpy.withState {
            $0.committed == Payload(concealed: [], system: Set(0 ... 8), allowed: [])
        }, "bootstrap must never restrict any application or system item")
        let snapshot = MenuBarSnapshot(
            generation: 1, capturedAt: Date(), items: [MenuBarItemDescriptor(
                id: MenuBarItemID(bundleIdentifier: "test.barline.fixture"), section: .visible,
                order: 0, displayID: display
            )], displayIDs: [display], activeSpaceIsValid: true
        )
        let scan = MenuBarObservationScan(
            scanID: UUID(), startedAtUptimeNanoseconds: 1, completedAtUptimeNanoseconds: 2,
            observedSnapshot: snapshot, initialEnvironment: before, finalEnvironment: after
        )
        try require(MenuBarAuthorityObservation(snapshot: snapshot, scan: scan).scan != nil,
                    "first inventory must associate with actual helper startup receipt")
        async let concurrentFirst = controller.environment(scene)
        async let concurrentSecond = controller.environment(scene)
        let concurrent = try await (concurrentFirst, concurrentSecond)
        try require(concurrent.0 == before && concurrent.1 == before &&
            bridgeSpy.withState { $0.begins.count == 1 }, "concurrent reads must preserve one acknowledged bootstrap")
        await controller.invalidate()
        let invalidated = try await controller.receipt()
        try require(!invalidated.isStable && invalidated.helperSessionID != initial.helperSessionID,
                    "invalidation must revoke, not bootstrap, a new helper session")
        let restarted = try await controller.environment(scene)
        try require(restarted.nativeConcealmentReceipt?.isStable == true &&
            restarted.nativeConcealmentReceipt?.helperSessionID == invalidated.helperSessionID &&
            bridgeSpy.withState { $0.begins.count == 2 }, "new session needs its own native acknowledgement")
        await controller.invalidate()
    }

    @MainActor
    @available(macOS 27.0, *)
    private static func verifyFailedBootstrapRemainsUnknown(_ failure: Int) async throws {
        bridgeSpy.withState {
            $0 = BridgeSpy.State()
            $0.failNextBegin = failure == 0
            $0.failNextCommit = failure == 1
            $0.mismatchAfterNextCommit = failure == 2
            $0.failCreate = failure == 3
            $0.cancelNextBegin = failure == 4
        }
        let controller = GoldenGateConcealmentController()
        let scene: @Sendable () -> MenuBarEnvironmentSnapshot = {
            MenuBarEnvironmentSnapshot(
                activeDisplayID: 1, activeSpaceToken: 1, activeSpaceIsFullscreen: false,
                activeSpaceIsValid: true, menuTrackingIsActive: false
            )
        }
        var failed = false
        do {
            if failure == 3 {
                // An explicit attempt failing before Begin also consumes the
                // bootstrap opportunity. It must never be reset by a read.
                try await controller.configure(.init(visibleItemIDs: [], concealedItemIDs: [
                    MenuBarItemID(bundleIdentifier: "test.barline.fixture"),
                ]))
            } else if failure == 4 {
                let task = Task { try await controller.environment(scene) }
                _ = try await task.value
            } else {
                _ = try await controller.environment(scene)
            }
        } catch { failed = true }
        try require(failed, "injected initial transition must fail")
        if failure == 1 || failure == 4 {
            try require(bridgeSpy.withState { $0.aborts == 1 && $0.pending.isEmpty },
                        "failed Commit or post-Begin cancellation must abort the pending native transaction")
        }
        bridgeSpy.withState { $0.failCreate = false }
        let begins = bridgeSpy.withState { $0.begins.count }
        let unknown = try await controller.receipt()
        let observed = try await controller.environment(scene)
        try require(!unknown.isStable && observed.nativeConcealmentReceipt == unknown &&
            bridgeSpy.withState { $0.begins.count == begins }, "ordinary environment read must not repair failed transition by clearing intent")
        await controller.invalidate()
    }

    @MainActor
    @available(macOS 27.0, *)
    private static func verifyPublisherLifecycleRefresh() async throws {
        bridgeSpy.withState { $0 = BridgeSpy.State() }
        let publisher = MenuBarItemID(bundleIdentifier: "test.publisher", accessibilityIdentifier: "item")
        let delayed = MenuBarItemID(bundleIdentifier: "test.delayed", accessibilityIdentifier: "late-item")
        let hidden = MenuBarItemID(bundleIdentifier: "test.hidden", accessibilityIdentifier: "hidden")
        let otherHidden = MenuBarItemID(bundleIdentifier: "test.other-hidden", accessibilityIdentifier: "hidden")
        var publisherPID: Int32 = 10
        func running(includeDelayed: Bool = false) {
            NSWorkspace.shared.runningApplications = [
                .init(bundleIdentifier: publisher.bundleIdentifier, processIdentifier: publisherPID),
                .init(bundleIdentifier: hidden.bundleIdentifier, processIdentifier: 20),
                .init(bundleIdentifier: otherHidden.bundleIdentifier, processIdentifier: 21),
            ] + (includeDelayed ? [.init(bundleIdentifier: delayed.bundleIdentifier, processIdentifier: 30)] : [])
        }
        var configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: [publisher], concealedItemIDs: [hidden, otherHidden]
        )
        let controller = GoldenGateConcealmentController()
        running()
        let original = try await controller.configure(configuration)
        publisherPID = 11
        running()
        let replaced = try await controller.configure(configuration)
        try require(bridgeSpy.withState { $0.invalidations == 1 && $0.begins.count == 2 },
                    "same-bundle replacement must cross a native deassertion boundary before reassertion")
        try require(replaced.isStable && replaced.assertionRevision > original.assertionRevision &&
            replaced.effectiveStateDigest == original.effectiveStateDigest,
            "process witness must expire observation proof without changing semantic visibility")
        let noOp = try await controller.configure(configuration)
        try require(noOp == replaced && bridgeSpy.withState { $0.invalidations == 1 && $0.begins.count == 2 },
                    "unchanged publisher must not churn the native assertion")

        running(includeDelayed: true)
        try await controller.configure(configuration)
        try require(bridgeSpy.withState { $0.invalidations == 1 }, "unobserved publisher must not trigger a lift")
        configuration = .init(visibleItemIDs: [publisher, delayed], concealedItemIDs: [hidden, otherHidden])
        try await controller.configure(configuration)
        try require(bridgeSpy.withState { $0.invalidations == 2 },
                    "late first AX item must remain unsettled despite an earlier running-app sample")

        _ = try await controller.beginTemporaryReveal(hidden)
        publisherPID = 12
        running(includeDelayed: true)
        try await controller.configure(configuration)
        try require(bridgeSpy.withState { $0.invalidations == 2 }, "active reveal must defer publisher reset")
        try await controller.endTemporaryReveal(hidden)
        try await Task.sleep(for: .milliseconds(1500))
        try require(bridgeSpy.withState { $0.invalidations == 3 }, "final reveal end must reconcile deferred publisher")
        try await require(controller.receipt().isStable, "deferred publisher refresh must eventually acknowledge state")

        // A failed candidate must compensate the accepted configuration, not
        // the new configuration that configure() assigned before native work.
        publisherPID = 13
        running(includeDelayed: true)
        let rejected = MenuBarConcealmentConfiguration(visibleItemIDs: [publisher, delayed, otherHidden], concealedItemIDs: [hidden])
        bridgeSpy.withState { $0.failNextCommit = true }
        var failed = false
        do { try await controller.configure(rejected) } catch { failed = true }
        try require(failed && bridgeSpy.withState {
            $0.committed?.concealed == Set([hidden.bundleIdentifier, otherHidden.bundleIdentifier]) && $0.pending.isEmpty
        }, "post-clear failure must restore accepted hidden intent, not the rejected candidate")
        try await require(controller.receipt().isStable, "successful compensation must acknowledge its own receipt")

        // Native Commit succeeds, but its acknowledgement is ambiguous. A
        // different incarnation appears while that candidate assertion exists.
        // Compensation needs its own clear edge; the earlier witness is spent.
        publisherPID = 16
        running(includeDelayed: true)
        let compensatingSample = NSWorkspace.shared.runningApplications.map { application in
            application.bundleIdentifier == publisher.bundleIdentifier
                ? NSWorkspace.Application(bundleIdentifier: publisher.bundleIdentifier, processIdentifier: 17)
                : application
        }
        let beforeAmbiguous = bridgeSpy.withState { $0.invalidations }
        bridgeSpy.withState {
            $0.mismatchAfterNextCommit = true
            $0.afterNextCommit = { NSWorkspace.shared.runningApplications = compensatingSample }
        }
        failed = false
        do { try await controller.configure(rejected) } catch { failed = true }
        try require(failed && bridgeSpy.withState {
            $0.invalidations == beforeAmbiguous + 2 &&
                $0.committed?.concealed == Set([hidden.bundleIdentifier, otherHidden.bundleIdentifier])
        }, "ambiguous committed candidate must clear again before settling compensation's new incarnation")
        let afterCompensation = bridgeSpy.withState { $0.begins.count }
        try await controller.configure(configuration)
        try require(bridgeSpy.withState { $0.begins.count == afterCompensation + 1 },
                    "bounded compensation restores intent without AX work; new lifetime stays unsettled until reconciliation")

        // A recycled PID is not the same process incarnation.
        NSWorkspace.shared.runningApplications = compensatingSample.map { application in
            var replacement = application
            if application.bundleIdentifier == publisher.bundleIdentifier {
                replacement.launchDate = Date(timeIntervalSince1970: 2)
                replacement.kernelStartSeconds = 2
            }
            return replacement
        }
        try await controller.configure(configuration)
        try require(bridgeSpy.withState { $0.begins.count == afterCompensation + 2 },
                    "recycled PID with a different launch date must receive a new clear boundary")

        publisherPID = 14
        running(includeDelayed: true)
        bridgeSpy.withState { $0.cancelNextInvalidate = true }
        let cancelled = Task { try await controller.configure(rejected) }
        failed = false
        do { _ = try await cancelled.value } catch { failed = true }
        try require(failed && bridgeSpy.withState {
            $0.committed?.concealed == Set([hidden.bundleIdentifier, otherHidden.bundleIdentifier])
        }, "cancellation after clear must compensate independently of caller cancellation")
        try await require(controller.receipt().isStable, "cancelled reset cannot strand concealed items")

        publisherPID = 15
        running(includeDelayed: true)
        bridgeSpy.withState { $0.rejectBegins = 2 }
        failed = false
        do { try await controller.configure(rejected) } catch { failed = true }
        try require(failed, "candidate plus compensation failure must propagate")
        try await require(controller.receipt().phase == .unknown, "failed compensation must preserve unknown authority")
        await controller.invalidate()
        let revoked = try await controller.receipt()
        try await Task.sleep(for: .milliseconds(1100))
        try await require(controller.receipt() == revoked, "revoked lifecycle recovery must never replay rejected intent")
        print("PASS: publisher incarnation, delayed eligibility, no-op, deferred reveal, compensation, cancellation and recovery revocation")
    }

    @MainActor
    static func main() async throws {
        guard #available(macOS 27.0, *) else {
            throw CheckFailure(description: "Requires macOS 27; no controller test executed")
        }
        try await verifyAutonomousPublicationAndDuplicateInstances()
        try await verifyReviewRegressions()
        try await verifyPublisherObservationFailures()
        try await verifyPublisherRoutingAndBudget()
        try await verifyColdEnvironmentBootstrap()
        for failure in 0 ... 4 {
            try await verifyFailedBootstrapRemainsUnknown(failure)
        }
        try await verifyPublisherLifecycleRefresh()
        bridgeSpy.withState { $0 = BridgeSpy.State() }
        let hiddenBundle = "test.barline.hidden"
        let existing = "test.barline.existing"
        let newlyRunning = "test.barline.new"
        let another = "test.barline.another"
        let hidden = MenuBarItemID(bundleIdentifier: hiddenBundle, accessibilityIdentifier: "fixture")
        let configuration = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [hidden])
        let allVisible = MenuBarConcealmentConfiguration(visibleItemIDs: [], concealedItemIDs: [])
        let mandatory: Set = [
            BarlineMenuService.configuredAppIdentifier, "com.apple.systemuiserver", "com.apple.finder", "com.apple.dock",
        ]
        // Distinct apps cannot share one PID. Stable per-bundle fixture PIDs
        // keep lifecycle assertions meaningful when array order changes.
        var fixturePIDs = [String: Int32]()
        func running(_ bundles: [String]) {
            NSWorkspace.shared.runningApplications = bundles.map { bundle in
                if fixturePIDs[bundle] == nil {
                    fixturePIDs[bundle] = Int32(100 + fixturePIDs.count)
                }
                return .init(bundleIdentifier: bundle, processIdentifier: fixturePIDs[bundle] ?? 0)
            }
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
        let configuredEnvironment = try await controller.environment {
            MenuBarEnvironmentSnapshot(activeDisplayID: 1, activeSpaceToken: 1, activeSpaceIsFullscreen: false)
        }
        try require(configuredEnvironment.nativeConcealmentReceipt == firstReceipt && beginCount() == 1,
                    "configuration before first environment must not be cleared by bootstrap")
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
        bridgeSpy.withState { $0 = BridgeSpy.State() }
        let alternateController = GoldenGateConcealmentController()
        let selfItem = MenuBarItemID(bundleIdentifier: BarlineMenuService.configuredAppIdentifier.lowercased(), accessibilityIdentifier: "control")
        try await alternateController.configure(.init(visibleItemIDs: [], concealedItemIDs: [hidden, selfItem]))
        try require(bridgeSpy.withState {
            $0.committed?.concealed == [hiddenBundle] &&
                $0.committed?.allowed.contains(BarlineMenuService.configuredAppIdentifier) == true &&
                $0.committed?.allowed.contains("com.mabryventures.Barline") == false
        }, "configured self identity must survive both production resolver and native allowlist, even absent from running apps")
        await alternateController.invalidate()
        print("PASS: real concealment controller receipts, skip path, exact bridge payload, uncertain failures, reveal leases, clock recovery, and invalidation")
        print("PASS: configured helper identity protects the app through the actual controller and bridge payload")
    }
}
