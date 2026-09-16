#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Darwin
import Foundation

private enum Configuration {
    static let measuredCycles = positiveEnvironmentInteger("BARLINE_PERFORMANCE_CYCLES") ?? 20
    static let warmupCycles = positiveEnvironmentInteger("BARLINE_PERFORMANCE_WARMUPS") ?? 2
    static let feedbackBudget = Duration.milliseconds(250)
    static let iconTimeout = Duration.seconds(5)
    static let openTimeout = Duration.milliseconds(1500)
    static let closeTimeout = Duration.milliseconds(1000)
    static let pollingIntervalMicroseconds: useconds_t = 10000
    static let committedVisibilitySamples = 2
    static let probe = ProcessInfo.processInfo.environment["BARLINE_PERFORMANCE_PROBE"] ?? "runtime-smoke"
    static let enforceBudget = ProcessInfo.processInfo.environment["BARLINE_PERFORMANCE_ENFORCE_BUDGET"] != "0"
    static let appBundleIdentifier: String = {
        guard let value = ProcessInfo.processInfo.environment["BARLINE_APP_BUNDLE_IDENTIFIER"],
              !value.isEmpty,
              !value.contains("$(")
        else {
            fputs("error: BARLINE_APP_BUNDLE_IDENTIFIER is required\n", stderr)
            exit(2)
        }
        return value
    }()

    static func notificationName(_ suffix: String) -> Notification.Name {
        Notification.Name("\(appBundleIdentifier).\(suffix)")
    }

    private static func positiveEnvironmentInteger(_ name: String) -> Int? {
        guard
            let value = ProcessInfo.processInfo.environment[name],
            let integer = Int(value),
            integer > 0,
            integer <= 1000
        else {
            return nil
        }
        return integer
    }
}

private struct WindowSnapshot {
    let windowNumber: CGWindowID?
    let ownerProcessIdentifier: pid_t?
    let ownerName: String?
    let windowName: String?
    let layer: Int?
    let bounds: CGRect
}

private func processIsRunning(_ processIdentifier: pid_t) -> Bool {
    kill(processIdentifier, 0) == 0
}

private enum ProbeError: Error, CustomStringConvertible, Sendable {
    case applicationNotRunning
    case applicationProcessChanged
    case appleEventRejected(String)
    case recoveryFailed(String)
    case recoveryTimedOut
    case presentationTimedOut
    case settingsBaselineTimedOut
    case barlineIconNotFound
    case unableToCloseBaseline
    case unableToSynthesizeClick
    case coldFirstClickTimedOut
    case unexpectedForegroundUI
    case openingTimedOut(Int)

    var description: String {
        switch self {
        case .applicationNotRunning:
            "The production Barline application is not running"
        case .applicationProcessChanged:
            "Barline changed processes during the reopen response probe"
        case let .appleEventRejected(message):
            "The production reopen request was rejected: \(message)"
        case let .recoveryFailed(reason):
            "The production reopen recovery reported failure: \(reason)"
        case .recoveryTimedOut:
            "The production reopen recovery did not complete"
        case .presentationTimedOut:
            "The production reopen did not present Settings in time"
        case .settingsBaselineTimedOut:
            "The Settings window did not reach the hidden reopen-probe baseline"
        case .barlineIconNotFound:
            "No uniquely verified on-screen Barline control item was found"
        case .unableToCloseBaseline:
            "The Barline Bar could not be closed before measurement"
        case .unableToSynthesizeClick:
            "The status-item click event could not be created"
        case .coldFirstClickTimedOut:
            "The cold first status-item click did not commit the Barline Bar"
        case .unexpectedForegroundUI:
            "Unexpected foreground UI interrupted the shelf probe; not a timing sample"
        case let .openingTimedOut(cycle):
            "Shelf opening timed out at cycle \(cycle); stopped without further clicks"
        }
    }
}

private func establishHiddenSettingsBaseline(
    processIdentifier: pid_t,
    timeout: Duration = Configuration.closeTimeout
) throws -> Int {
    let baselineGenerationKey = "ReopenProbeBaselineGeneration" as CFString
    let presentationGenerationKey = "ReopenProbePresentationGeneration" as CFString
    let applicationID = Configuration.appBundleIdentifier as CFString
    CFPreferencesAppSynchronize(applicationID)
    let startingGeneration =
        (CFPreferencesCopyAppValue(baselineGenerationKey, applicationID) as? NSNumber)?.intValue ?? 0
    guard processIsRunning(processIdentifier) else {
        throw ProbeError.applicationNotRunning
    }
    DistributedNotificationCenter.default().postNotificationName(
        Configuration.notificationName("reopen-probe.hide-settings"),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    let start = ContinuousClock.now
    while start.duration(to: .now) < timeout {
        guard processIsRunning(processIdentifier) else {
            throw ProbeError.applicationProcessChanged
        }
        CFPreferencesAppSynchronize(applicationID)
        let generation =
            (CFPreferencesCopyAppValue(baselineGenerationKey, applicationID) as? NSNumber)?.intValue ?? 0
        if generation > startingGeneration {
            return (CFPreferencesCopyAppValue(presentationGenerationKey, applicationID) as? NSNumber)?.intValue ?? 0
        }
        usleep(Configuration.pollingIntervalMicroseconds)
    }
    throw ProbeError.settingsBaselineTimedOut
}

private func requestProductionReopen(
    processIdentifier: pid_t,
    startingPresentationGeneration: Int,
    timeout: Duration = Configuration.iconTimeout
) throws -> (presentationMilliseconds: Double, recoveryMilliseconds: Double) {
    let recoveryGenerationKey = "ReopenRecoveryGeneration" as CFString
    let recoveryFailureKey = "ReopenRecoveryFailure" as CFString
    let recoverySucceededKey = "ReopenRecoverySucceeded" as CFString
    let presentationGenerationKey = "ReopenProbePresentationGeneration" as CFString
    let presentationProcessIdentifierKey = "ReopenProbePresentationProcessIdentifier" as CFString
    let applicationID = Configuration.appBundleIdentifier as CFString
    CFPreferencesAppSynchronize(applicationID)
    let startingGeneration = (CFPreferencesCopyAppValue(recoveryGenerationKey, applicationID) as? NSNumber)?.intValue ?? 0
    guard processIsRunning(processIdentifier) else {
        throw ProbeError.applicationNotRunning
    }
    let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass),
        eventID: AEEventID(kAEReopenApplication),
        targetDescriptor: target,
        returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID)
    )
    let start = ContinuousClock.now
    do {
        _ = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 5)
    } catch {
        throw ProbeError.appleEventRejected(error.localizedDescription)
    }
    guard
        processIsRunning(processIdentifier)
    else {
        throw ProbeError.applicationProcessChanged
    }
    var presentationMilliseconds: Double?
    while start.duration(to: .now) < timeout {
        CFPreferencesAppSynchronize(applicationID)
        let presentationGeneration =
            (CFPreferencesCopyAppValue(presentationGenerationKey, applicationID) as? NSNumber)?.intValue ?? 0
        let acknowledgedProcessIdentifier =
            (CFPreferencesCopyAppValue(presentationProcessIdentifierKey, applicationID) as? NSNumber)?.int32Value ?? 0
        if presentationGeneration > startingPresentationGeneration,
           acknowledgedProcessIdentifier == processIdentifier,
           expectedApplicationIsPresented(processIdentifier: processIdentifier)
        {
            presentationMilliseconds = milliseconds(start.duration(to: .now))
            break
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard let presentationMilliseconds else {
        throw ProbeError.presentationTimedOut
    }
    while start.duration(to: .now) < timeout {
        CFPreferencesAppSynchronize(applicationID)
        let generation = (CFPreferencesCopyAppValue(recoveryGenerationKey, applicationID) as? NSNumber)?.intValue ?? 0
        if generation > startingGeneration {
            let succeeded = (CFPreferencesCopyAppValue(recoverySucceededKey, applicationID) as? NSNumber)?.boolValue ?? false
            guard succeeded else {
                let reason = CFPreferencesCopyAppValue(recoveryFailureKey, applicationID) as? String
                throw ProbeError.recoveryFailed(reason ?? "unknown compatibility error")
            }
            return (
                presentationMilliseconds,
                milliseconds(start.duration(to: .now))
            )
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    throw ProbeError.recoveryTimedOut
}

private func windowSnapshots() -> [WindowSnapshot] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

    return rows.compactMap { row in
        guard
            let dictionary = row[kCGWindowBounds as String] as? [String: Any],
            let x = (dictionary["X"] as? NSNumber)?.doubleValue,
            let y = (dictionary["Y"] as? NSNumber)?.doubleValue,
            let width = (dictionary["Width"] as? NSNumber)?.doubleValue,
            let height = (dictionary["Height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }

        return WindowSnapshot(
            windowNumber: (row[kCGWindowNumber as String] as? NSNumber).map {
                CGWindowID($0.uint32Value)
            },
            ownerProcessIdentifier: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            ownerName: row[kCGWindowOwnerName as String] as? String,
            windowName: row[kCGWindowName as String] as? String,
            layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
            bounds: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}

private func expectedApplicationIsPresented(processIdentifier: pid_t) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
        return false
    }
    return windowSnapshots().contains {
        $0.ownerProcessIdentifier == processIdentifier &&
            $0.layer == 0 &&
            $0.bounds.width > 0 &&
            $0.bounds.height > 0
    }
}

private func barlineIconCenter() throws -> CGPoint {
    let start = ContinuousClock.now
    let expectedProcessIdentifier = ProcessInfo.processInfo.environment["BARLINE_EXPECTED_PID"]
        .flatMap(pid_t.init)
    guard let expectedProcessIdentifier,
          NSRunningApplication(processIdentifier: expectedProcessIdentifier)?.bundleIdentifier == Configuration.appBundleIdentifier
    else { throw ProbeError.applicationNotRunning }
    while start.duration(to: .now) < Configuration.iconTimeout {
        let candidates = windowSnapshots().filter {
            $0.windowName == "Barline.ControlItem.Visible" &&
                $0.bounds.width > 0 &&
                $0.bounds.width < 100
        }
        if let icon = candidates.first(where: { candidate in
            if candidate.ownerProcessIdentifier == expectedProcessIdentifier {
                return true
            }
            // macOS 26 hosts status windows in Control Center. Never trust only a
            // title: prove an AX extras-bar child of the exact Barline process has
            // the same geometry, and require the known system hosting process.
            guard let owner = candidate.ownerProcessIdentifier,
                  NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.controlcenter"
            else { return false }
            return sourceStatusFrames(processIdentifier: expectedProcessIdentifier).contains {
                StatusItemFrameMatching.matches(source: $0, hosted: candidate.bounds)
            }
        }) {
            return CGPoint(x: icon.bounds.midX, y: icon.bounds.midY)
        }
        if candidates.isEmpty,
           let source = sourceVisibleStatusFrame(processIdentifier: expectedProcessIdentifier)
        {
            let compositedMenuBars = windowSnapshots().filter {
                $0.windowName == "Menubar" && $0.layer == 24 &&
                    $0.bounds.width > 0 && $0.bounds.height > 0 &&
                    $0.bounds.contains(CGPoint(x: source.midX, y: source.midY))
            }
            if compositedMenuBars.count == 1 {
                // macOS 27 no longer publishes one named CGWindow per status
                // item. Require the exact app-owned AX control to lie within
                // the one visible WindowServer Menubar composite.
                return CGPoint(x: source.midX, y: source.midY)
            }
        }
        usleep(Configuration.pollingIntervalMicroseconds)
    }
    throw ProbeError.barlineIconNotFound
}

private func sourceVisibleStatusFrame(processIdentifier: pid_t) -> CGRect? {
    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.2)
    var rawBar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &rawBar) == .success,
          let rawBar, CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return nil }
    let bar = unsafeDowncast(rawBar, to: AXUIElement.self)
    var rawChildren: CFTypeRef?
    guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &rawChildren) == .success,
          let children = rawChildren as? [AXUIElement] else { return nil }
    let matches = children.compactMap { child -> CGRect? in
        var rawIdentifier: CFTypeRef?
        var rawRole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &rawIdentifier) == .success,
              AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &rawRole) == .success,
              rawIdentifier as? String == "Barline.ControlItem.Visible",
              rawRole as? String == kAXMenuBarItemRole else { return nil }
        return sourceStatusFrame(child)
    }
    guard matches.count == 1, let match = matches.first,
          match.width > 0, match.width < 100, match.height > 0 else { return nil }
    return match
}

private func sourceStatusFrame(_ child: AXUIElement) -> CGRect? {
    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &rawPosition) == .success,
          AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &rawSize) == .success,
          let rawPosition, let rawSize,
          CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size)
    else { return nil }
    return CGRect(origin: point, size: size)
}

private func sourceStatusFrames(processIdentifier: pid_t) -> [CGRect] {
    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.2)
    var rawBar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &rawBar) == .success,
          let rawBar, CFGetTypeID(rawBar) == AXUIElementGetTypeID()
    else { return [] }
    let bar = unsafeDowncast(rawBar, to: AXUIElement.self)
    var rawChildren: CFTypeRef?
    guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &rawChildren) == .success,
          let children = rawChildren as? [AXUIElement]
    else { return [] }
    return children.compactMap { child in
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }
}

private func isBarlineShelfVisible(snapshots: [WindowSnapshot]? = nil) -> Bool {
    barlineShelfSnapshot(snapshots: snapshots) != nil
}

/// macOS 27 can omit the owner and title of a nonactivating panel from its
/// WindowServer rows. The DEBUG-only runtime probe publishes the AppKit window
/// number only after the panel is visible and on the active Space; match that
/// number against an external WindowServer row rather than guessing by title.
private func runtimeSmokePanelWindowNumber(expectedProcessIdentifier: pid_t?) -> CGWindowID? {
    guard Configuration.probe == "runtime-smoke", let expectedProcessIdentifier else { return nil }
    let applicationID = Configuration.appBundleIdentifier as CFString
    CFPreferencesAppSynchronize(applicationID)
    let received = (CFPreferencesCopyAppValue(
        "RuntimeSmokeToggleReceived" as CFString,
        applicationID
    ) as? NSNumber)?.boolValue == true
    let processIdentifier = (CFPreferencesCopyAppValue(
        "RuntimeSmokeToggleProcessIdentifier" as CFString,
        applicationID
    ) as? NSNumber)?.int32Value
    guard received, processIdentifier == expectedProcessIdentifier else { return nil }
    let windowNumber = (CFPreferencesCopyAppValue(
        "RuntimeSmokePanelWindowNumber" as CFString,
        applicationID
    ) as? NSNumber)?.intValue ?? 0
    guard windowNumber > 0 else { return nil }
    return CGWindowID(windowNumber)
}

private func barlineShelfSnapshot(snapshots: [WindowSnapshot]? = nil) -> WindowSnapshot? {
    let expectedProcessIdentifier = ProcessInfo.processInfo.environment["BARLINE_EXPECTED_PID"]
        .flatMap(pid_t.init)
    let windows = snapshots ?? windowSnapshots()
    let runtimeWindowNumber = runtimeSmokePanelWindowNumber(
        expectedProcessIdentifier: expectedProcessIdentifier
    )
    return windows.first {
        let ownerMatches = expectedProcessIdentifier == nil ||
            $0.ownerProcessIdentifier == expectedProcessIdentifier
        let namedShelf = $0.ownerName == "Barline" && $0.windowName == "Barline Bar"
        let runtimeShelf = runtimeWindowNumber != nil && $0.windowNumber == runtimeWindowNumber
        return ownerMatches && (namedShelf || runtimeShelf)
    }
}

/// Buffer transport metadata rather than logging/querying windows in the hot
/// path. No coordinates, app names, content, or input outside this probe are kept.
private struct ClickDispatch: Codable {
    let sequence: Int
    let startedNanoseconds: UInt64
    let completedNanoseconds: UInt64
    let downTimestamp: UInt64
    let upTimestamp: UInt64
    let downFlags: UInt64
    let upFlags: UInt64
    let targetMoved: Bool
}

private final class ClickDispatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatches = [ClickDispatch]()

    func record(
        startedNanoseconds: UInt64,
        completedNanoseconds: UInt64,
        downTimestamp: UInt64,
        upTimestamp: UInt64,
        downFlags: UInt64,
        upFlags: UInt64,
        targetMoved: Bool
    ) {
        lock.withLock {
            guard dispatches.count < 2004 else { return }
            dispatches.append(ClickDispatch(
                sequence: dispatches.count + 1,
                startedNanoseconds: startedNanoseconds,
                completedNanoseconds: completedNanoseconds,
                downTimestamp: downTimestamp,
                upTimestamp: upTimestamp,
                downFlags: downFlags,
                upFlags: upFlags,
                targetMoved: targetMoved
            ))
        }
    }

    func snapshot() -> [ClickDispatch] {
        lock.withLock { dispatches }
    }
}

private let dispatchOriginUnixSeconds = Date().timeIntervalSince1970
private let dispatchOriginNanoseconds = DispatchTime.now().uptimeNanoseconds
private let clickDispatchRecorder = ClickDispatchRecorder()

private func click(at point: CGPoint) throws {
    switch Configuration.probe {
    case "runtime-smoke":
        DistributedNotificationCenter.default().postNotificationName(
            Configuration.notificationName("runtime-smoke.toggle-shelf"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    case "status-item-click":
        // Status items can move while Control Center relays out the bar. Resolve
        // the exact app's current target for every dispatch, not once per burst.
        let currentPoint = try barlineIconCenter()
        if ProcessInfo.processInfo.environment["BARLINE_PERFORMANCE_TRACE"] == "1" {
            let moved = hypot(currentPoint.x - point.x, currentPoint.y - point.y) > 1
            print("TRACE click monotonic_ns=\(DispatchTime.now().uptimeNanoseconds) target_moved=\(moved) shelf_before=\(isBarlineShelfVisible())")
            fflush(stdout)
        }
        guard
            let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: currentPoint,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: currentPoint,
                mouseButton: .left
            )
        else {
            throw ProbeError.unableToSynthesizeClick
        }
        let started = DispatchTime.now().uptimeNanoseconds
        mouseDown.post(tap: .cghidEventTap)
        usleep(20000)
        mouseUp.post(tap: .cghidEventTap)
        clickDispatchRecorder.record(
            startedNanoseconds: started,
            completedNanoseconds: DispatchTime.now().uptimeNanoseconds,
            downTimestamp: mouseDown.timestamp,
            upTimestamp: mouseUp.timestamp,
            downFlags: mouseDown.flags.rawValue,
            upFlags: mouseUp.flags.rawValue,
            targetMoved: hypot(currentPoint.x - point.x, currentPoint.y - point.y) > 1
        )
    default:
        fputs("error: shelf click requires runtime-smoke or status-item-click\n", stderr)
        exit(2)
    }
}

private func waitForVisibility(
    _ target: Bool,
    timeout: Duration,
    relativeTo measurementStart: ContinuousClock.Instant? = nil,
    isCancelled: (() -> Bool)? = nil
) throws -> Duration? {
    let measurementStart = measurementStart ?? .now
    let deadline = measurementStart.advanced(by: timeout)
    var consecutiveSamples = 0
    var committedWindowNumber: CGWindowID?
    while ContinuousClock.now < deadline {
        if isCancelled?() == true {
            return nil
        }
        let snapshots = windowSnapshots()
        if unexpectedForegroundUIPresent(snapshots: snapshots) {
            throw ProbeError.unexpectedForegroundUI
        }
        let shelfSnapshot = barlineShelfSnapshot(snapshots: snapshots)
        let matchesTarget: Bool
        if target, let shelfSnapshot {
            if let committedWindowNumber {
                matchesTarget = shelfSnapshot.windowNumber == committedWindowNumber
            } else {
                committedWindowNumber = shelfSnapshot.windowNumber
                matchesTarget = shelfSnapshot.windowNumber != nil
            }
        } else {
            matchesTarget = (shelfSnapshot != nil) == target
        }

        if matchesTarget {
            consecutiveSamples += 1
            if consecutiveSamples >= Configuration.committedVisibilitySamples {
                return measurementStart.duration(to: .now)
            }
        } else {
            consecutiveSamples = 0
            committedWindowNumber = nil
        }
        usleep(max(Configuration.pollingIntervalMicroseconds, 16000))
    }
    return nil
}

/// Observes WindowServer state while synthetic input is still being delivered.
///
/// `CGEvent.post` and status-item target discovery can block during helper recovery.
/// Starting the observer first keeps the measured latency tied to the user's visible
/// result without removing input dispatch or target discovery from the probe cycle.
private typealias ConcurrentVisibilityObservation = ConcurrentObservation<Duration?>

private func observeVisibilityConcurrently(
    target: Bool,
    timeout: Duration,
    relativeTo measurementStart: ContinuousClock.Instant
) -> ConcurrentVisibilityObservation {
    ConcurrentObservation { isCancelled in
        try waitForVisibility(
            target,
            timeout: timeout,
            relativeTo: measurementStart,
            isCancelled: isCancelled
        )
    }
}

private func unexpectedForegroundUIPresent(snapshots: [WindowSnapshot]? = nil) -> Bool {
    guard Configuration.probe == "status-item-click" else {
        return false
    }
    guard
        let rawProcessIdentifier = ProcessInfo.processInfo.environment["BARLINE_EXPECTED_PID"],
        let expectedProcessIdentifier = pid_t(rawProcessIdentifier)
    else {
        return true
    }
    if Thread.isMainThread, NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedProcessIdentifier {
        return true
    }
    let windows = snapshots ?? windowSnapshots()
    return windows.contains {
        $0.ownerProcessIdentifier == expectedProcessIdentifier &&
            $0.layer == 0 &&
            $0.bounds.width > 0 &&
            $0.bounds.height > 0
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
}

/// Returns DEBUG-only presentation receipts when a runtime shelf probe fails.
/// They make failures actionable without altering production behavior.
private func runtimeSmokeDiagnostics() -> String? {
    guard Configuration.probe == "runtime-smoke" else { return nil }
    let applicationID = Configuration.appBundleIdentifier as CFString
    CFPreferencesAppSynchronize(applicationID)
    let received = (CFPreferencesCopyAppValue(
        "RuntimeSmokeToggleReceived" as CFString,
        applicationID
    ) as? NSNumber)?.boolValue
    let processIdentifier = (CFPreferencesCopyAppValue(
        "RuntimeSmokeToggleProcessIdentifier" as CFString,
        applicationID
    ) as? NSNumber)?.int32Value
    let state = CFPreferencesCopyAppValue(
        "RuntimeSmokePresentationState" as CFString,
        applicationID
    ) as? String
    let windowNumber = (CFPreferencesCopyAppValue(
        "RuntimeSmokePanelWindowNumber" as CFString,
        applicationID
    ) as? NSNumber)?.intValue
    let receivedDescription = received?.description ?? "missing"
    let processIdentifierDescription = processIdentifier.map { String($0) } ?? "missing"
    let stateDescription = state ?? "missing"
    let windowNumberDescription = windowNumber.map { String($0) } ?? "missing"
    return "toggleReceived=\(receivedDescription) togglePID=\(processIdentifierDescription) panelWindowNumber=\(windowNumberDescription) state=\(stateDescription)"
}

private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else {
        return 0
    }
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
    return sorted[min(rank - 1, sorted.count - 1)]
}

private func ensureClosed(iconPoint: CGPoint) throws {
    guard isBarlineShelfVisible() else {
        return
    }
    try click(at: iconPoint)
    guard try waitForVisibility(false, timeout: Configuration.closeTimeout) != nil else {
        throw ProbeError.unableToCloseBaseline
    }
}

private func runSingleClick(iconPoint: CGPoint) throws -> Double? {
    let start = ContinuousClock.now
    var openingObservation: ConcurrentVisibilityObservation?
    return try ShelfProbeCycle.run(
        baselineClosed: { !isBarlineShelfVisible() },
        click: {
            if openingObservation == nil {
                openingObservation = observeVisibilityConcurrently(
                    target: true,
                    timeout: Configuration.openTimeout,
                    relativeTo: start
                )
            }
            do {
                try click(at: iconPoint)
                guard !unexpectedForegroundUIPresent() else {
                    openingObservation?.cancel()
                    _ = try? openingObservation?.value()
                    throw ProbeError.unexpectedForegroundUI
                }
            } catch {
                openingObservation?.cancel()
                _ = try? openingObservation?.value()
                throw error
            }
        },
        waitForOpen: {
            guard
                let observation = openingObservation,
                let duration = try observation.value()
            else {
                return nil
            }
            guard !unexpectedForegroundUIPresent() else {
                throw ProbeError.unexpectedForegroundUI
            }
            return milliseconds(duration)
        },
        waitForClose: { try waitForVisibility(false, timeout: Configuration.closeTimeout) != nil }
    )
}

private func runRapidRetry(iconPoint: CGPoint) throws -> (feedbackInBudget: Bool, silentCancellation: Bool) {
    let start = ContinuousClock.now
    let openingObservation = observeVisibilityConcurrently(
        target: true,
        timeout: Configuration.feedbackBudget,
        relativeTo: start
    )
    do {
        try click(at: iconPoint)
        guard !unexpectedForegroundUIPresent() else {
            openingObservation.cancel()
            _ = try? openingObservation.value()
            throw ProbeError.unexpectedForegroundUI
        }
    } catch {
        openingObservation.cancel()
        _ = try? openingObservation.value()
        throw error
    }
    if let duration = try openingObservation.value() {
        guard !unexpectedForegroundUIPresent() else {
            throw ProbeError.unexpectedForegroundUI
        }
        let feedbackInBudget = duration <= Configuration.feedbackBudget
        try click(at: iconPoint)
        guard try waitForVisibility(false, timeout: Configuration.closeTimeout) != nil else {
            throw ShelfProbeCycle.Failure.closeTimedOut
        }
        return (feedbackInBudget, false)
    }

    // Reproduce a user retrying because the first click produced no visible feedback.
    try click(at: iconPoint)
    let silentCancellation = try waitForVisibility(true, timeout: Configuration.closeTimeout) == nil

    if isBarlineShelfVisible() {
        try click(at: iconPoint)
        guard try waitForVisibility(false, timeout: Configuration.closeTimeout) != nil else {
            throw ShelfProbeCycle.Failure.closeTimedOut
        }
    }
    return (false, silentCancellation)
}

private let initialPointer = CGEvent(source: nil)?.location
atexit {
    let clickDispatches = clickDispatchRecorder.snapshot()
    if !clickDispatches.isEmpty {
        print("DISPATCH_ORIGIN unix_seconds=\(dispatchOriginUnixSeconds) monotonic_ns=\(dispatchOriginNanoseconds)")
        if let data = try? JSONEncoder().encode(clickDispatches) {
            print("DISPATCH_TRACE \(String(decoding: data, as: UTF8.self))")
        }
    }
    let restored = initialPointer.map { CGWarpMouseCursorPosition($0) == .success } ?? false
    print("{\"originalPointerRestored\":\(restored)}")
    if !restored {
        fflush(stdout)
        _exit(EXIT_FAILURE)
    }
}

do {
    if Configuration.probe == "apple-event-reopen" {
        guard
            let rawProcessIdentifier = ProcessInfo.processInfo.environment["BARLINE_EXPECTED_PID"],
            let processIdentifier = pid_t(rawProcessIdentifier),
            processIdentifier > 0,
            processIsRunning(processIdentifier)
        else {
            throw ProbeError.applicationNotRunning
        }
        for warmup in 0 ..< Configuration.warmupCycles {
            // The first request can arrive while a cold Release launch is still
            // completing setup and its initial XPC snapshot. Establish readiness
            // outside the measured window, then retain the strict timeout below.
            let timeout: Duration = warmup == 0 ? .seconds(30) : Configuration.iconTimeout
            let presentationGeneration = try establishHiddenSettingsBaseline(processIdentifier: processIdentifier)
            _ = try requestProductionReopen(
                processIdentifier: processIdentifier,
                startingPresentationGeneration: presentationGeneration,
                timeout: timeout
            )
        }
        var latencies = [Double]()
        var recoveryLatencies = [Double]()
        for cycle in 1 ... Configuration.measuredCycles {
            let presentationGeneration = try establishHiddenSettingsBaseline(processIdentifier: processIdentifier)
            let result = try requestProductionReopen(
                processIdentifier: processIdentifier,
                startingPresentationGeneration: presentationGeneration
            )
            latencies.append(result.presentationMilliseconds)
            recoveryLatencies.append(result.recoveryMilliseconds)
            print(
                String(
                    format: "cycle=%02d status=OK latency_ms=%.1f recovery_ms=%.1f",
                    cycle,
                    result.presentationMilliseconds,
                    result.recoveryMilliseconds
                )
            )
        }
        let median = percentile(latencies, 0.50)
        let p95 = percentile(latencies, 0.95)
        let maximum = latencies.max() ?? 0
        let recoveryP95 = percentile(recoveryLatencies, 0.95)
        let recoveryMaximum = recoveryLatencies.max() ?? 0
        let budgetMilliseconds = milliseconds(Configuration.feedbackBudget)
        let passed = p95 <= budgetMilliseconds
        let verdict = passed ? "PASS" : (Configuration.enforceBudget ? "FAIL" : "OBSERVED")
        print(
            String(
                format: "RESULT samples=%d timeouts=0 median_ms=%.1f p95_ms=%.1f max_ms=%.1f recovery_p95_ms=%.1f recovery_max_ms=%.1f recovery_succeeded=true feedback_in_250ms=%@ silent_cancellation=false verdict=%@",
                latencies.count,
                median,
                p95,
                maximum,
                recoveryP95,
                recoveryMaximum,
                passed.description,
                verdict
            )
        )
        exit(passed || !Configuration.enforceBudget ? EXIT_SUCCESS : EXIT_FAILURE)
    }
    guard Configuration.probe == "runtime-smoke" || Configuration.probe == "status-item-click" else {
        fputs(
            "error: BARLINE_PERFORMANCE_PROBE must be runtime-smoke, status-item-click, or apple-event-reopen\n",
            stderr
        )
        exit(2)
    }

    let iconPoint = try barlineIconCenter()

    guard !unexpectedForegroundUIPresent() else {
        throw ProbeError.unexpectedForegroundUI
    }
    try ensureClosed(iconPoint: iconPoint)

    var latencies = [Double]()
    let timeouts = 0

    let firstMeasuredCycle: Int
    if Configuration.probe == "status-item-click" {
        guard let coldLatency = try runSingleClick(iconPoint: iconPoint) else {
            throw ProbeError.coldFirstClickTimedOut
        }
        latencies.append(coldLatency)
        print(String(format: "cycle=%02d status=OK cold=true latency_ms=%.1f", 1, coldLatency))
        firstMeasuredCycle = 2
    } else {
        for _ in 0 ..< Configuration.warmupCycles {
            guard try runSingleClick(iconPoint: iconPoint) != nil else {
                throw ProbeError.coldFirstClickTimedOut
            }
        }
        firstMeasuredCycle = 1
    }

    if firstMeasuredCycle <= Configuration.measuredCycles {
        for cycle in firstMeasuredCycle ... Configuration.measuredCycles {
            if let latency = try runSingleClick(iconPoint: iconPoint) {
                latencies.append(latency)
                print(String(format: "cycle=%02d status=OK latency_ms=%.1f", cycle, latency))
            } else {
                print(String(format: "cycle=%02d status=TIMEOUT", cycle))
                throw ProbeError.openingTimedOut(cycle)
            }
        }
    }

    let rapidRetry = try runRapidRetry(iconPoint: iconPoint)
    let median = percentile(latencies, 0.50)
    let p95 = percentile(latencies, 0.95)
    let maximum = latencies.max() ?? 0
    let budgetMilliseconds = milliseconds(Configuration.feedbackBudget)
    let passed = timeouts == 0 &&
        p95 <= budgetMilliseconds &&
        rapidRetry.feedbackInBudget &&
        !rapidRetry.silentCancellation

    print(
        String(
            format: "RESULT samples=%d timeouts=%d median_ms=%.1f p95_ms=%.1f max_ms=%.1f feedback_in_250ms=%@ silent_cancellation=%@ verdict=%@",
            latencies.count,
            timeouts,
            median,
            p95,
            maximum,
            rapidRetry.feedbackInBudget ? "true" : "false",
            rapidRetry.silentCancellation ? "true" : "false",
            passed ? "PASS" : "FAIL"
        )
    )

    exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
} catch {
    fputs("ERROR \(error)\n", stderr)
    if let diagnostics = runtimeSmokeDiagnostics() {
        fputs("RUNTIME_SMOKE_DIAGNOSTICS \(diagnostics)\n", stderr)
    }
    exit(EXIT_FAILURE)
}
