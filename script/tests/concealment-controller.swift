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

func BLNGoldenGateAssessmentInvalidate(_: UnsafeMutableRawPointer) {
    bridgeSpy.withState {
        $0.invalidations += 1
        $0.pending.removeAll()
        $0.committed = nil
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

        running([existing, hiddenBundle])
        try await controller.configure(configuration)
        try require(beginCount() == 1, "first configuration must Begin")
        try require(bridgeSpy.withState { $0.committed?.allowed == mandatory.union([existing]) },
                    "Begin must receive the captured effective allowlist")
        try await controller.configure(configuration)
        try require(beginCount() == 1, "identical shelf/configure call must skip Begin")

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
        try await controller.configure(configuration)
        try require(beginCount() == 4, "failed candidate must not poison committed dedup key")
        try await controller.configure(configuration)
        try require(beginCount() == 4, "successful retry must publish committed key")

        running([existing, hiddenBundle])
        try await controller.configure(configuration)
        try require(beginCount() == 5, "departed allowed bundles must refresh exact allowlist")
        let firstReveal = try await controller.beginTemporaryReveal(hidden)
        try require(firstReveal && beginCount() == 6, "temporary reveal must update native state")
        _ = try await controller.beginTemporaryReveal(hidden)
        try require(beginCount() == 6, "overlapping same-item reveal must deduplicate")
        try await controller.endTemporaryReveal(hidden)
        try require(beginCount() == 6, "first reveal lease end must preserve second lease")
        try await controller.endTemporaryReveal(hidden)
        try require(beginCount() == 7, "final reveal lease end must restore concealed state")

        try await controller.configure(allVisible)
        try require(beginCount() == 8, "all-visible transition must clear prior assertion")
        running([another, newlyRunning])
        try await controller.configure(allVisible)
        try require(beginCount() == 8, "all-visible app churn must skip Begin")
        await controller.invalidate()
        try await controller.configure(allVisible)
        try require(beginCount() == 9, "invalidate must clear the committed native key")
        await controller.invalidate()
        print("PASS: real concealment controller skip path, exact bridge payload, commit failure, reveal leases, and invalidation")
    }
}
