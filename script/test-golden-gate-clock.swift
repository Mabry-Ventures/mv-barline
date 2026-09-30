// A real-pointer clock journey. Run in an AX-authorized GUI harness on a free
// macOS 27 test host, against one already-running candidate. No preference
// writes, notification bridges, direct AXPress, or screenshots are used.
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

private enum ClockJourneyError: Error { case rejected(String) }

private final class ClockEventWitness: @unchecked Sendable {
    let marker = Int64.random(in: 1 ... Int64.max)
    private let lock = NSLock()
    private var value: (timestamp: UInt64, deliveryUptime: UInt64)?

    func observe(_ event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUserData) == marker else { return }
        lock.withLock { value = (event.timestamp, DispatchTime.now().uptimeNanoseconds) }
    }

    func reset() {
        lock.withLock { value = nil }
    }

    func sample() -> (timestamp: UInt64, deliveryUptime: UInt64)? {
        lock.withLock { value }
    }
}

@MainActor
@main
private enum GoldenGateClockJourney {
    static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard AXUIElementSetMessagingTimeout(element, 0.05) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = read(element, kAXPositionAttribute),
              let rawSize = read(element, kAXSizeAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func clockFrame() -> CGRect? {
        guard let owner = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
              let rawBar = read(AXUIElementCreateApplication(owner.processIdentifier), "AXExtrasMenuBar"),
              CFGetTypeID(rawBar) == AXUIElementGetTypeID()
        else { return nil }
        var remaining = 100
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        func visit(_ element: AXUIElement, depth: Int) -> CGRect? {
            guard depth < 6, remaining > 0, DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            remaining -= 1
            if read(element, "AXIdentifier") as? String == "com.apple.menuextra.clock" {
                return frame(element)
            }
            for child in (read(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(50) {
                if let found = visit(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        return visit(unsafeDowncast(rawBar, to: AXUIElement.self), depth: 0)
    }

    /// Counts only structural children of Notification Center. No titles,
    /// notification contents, app lists, or screen pixels leave the host.
    static func notificationCenterCount() throws -> Int {
        guard let owner = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first,
              let windows = read(AXUIElementCreateApplication(owner.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]
        else { throw ClockJourneyError.rejected("notification_center_unreadable") }
        var remaining = 200
        let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        func count(_ element: AXUIElement, depth: Int) throws -> Int {
            guard remaining > 0, depth < 12, DispatchTime.now().uptimeNanoseconds < deadline,
                  AXUIElementSetMessagingTimeout(element, 0.05) == .success
            else { throw ClockJourneyError.rejected("notification_center_tree_incomplete") }
            var rawChildren: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren)
            let children: [AXUIElement]
            switch result {
            case .success:
                guard let values = rawChildren as? [AXUIElement], values.count <= 100 else {
                    throw ClockJourneyError.rejected("notification_center_tree_incomplete")
                }
                children = values
            case .noValue, .attributeUnsupported:
                children = [] // A leaf can legitimately omit AXChildren.
            default:
                throw ClockJourneyError.rejected("notification_center_tree_incomplete")
            }
            remaining -= 1
            return try 1 + children.reduce(0) { try $0 + count($1, depth: depth + 1) }
        }
        return try windows.reduce(0) { try $0 + count($1, depth: 0) }
    }

    static func pump(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    static func click(_ point: CGPoint, marker: Int64) throws {
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            else { throw ClockJourneyError.rejected("pointer_event_creation_failed") }
            event.flags = []
            // Explicit creation timestamp models timely physical input. Some
            // constructor-created synthetic events otherwise retain timestamp0.
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
            pump(seconds: 0.03)
        }
    }

    static func escape() throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
        else { throw ClockJourneyError.rejected("escape_event_creation_failed") }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        pump(seconds: 0.03)
        up.post(tap: .cghidEventTap)
        pump(seconds: 0.03)
    }

    static func fixtureWitness(_ pid: Int32) throws -> [String: Any] {
        guard let rawBar = read(AXUIElementCreateApplication(pid), "AXExtrasMenuBar"),
              CFGetTypeID(rawBar) == AXUIElementGetTypeID(),
              let children = read(unsafeDowncast(rawBar, to: AXUIElement.self), kAXChildrenAttribute) as? [AXUIElement],
              let item = children.first(where: { read($0, kAXTitleAttribute) as? String == "BF Native" }),
              let rect = frame(item), rect.width > 0, rect.height > 0,
              NSScreen.screens.contains(where: {
                  guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                  let display = CGDisplayBounds(number.uint32Value)
                  return display.contains(rect) && rect.midY <= display.minY + max(40, $0.safeAreaInsets.top)
              })
        else { throw ClockJourneyError.rejected("fixture_unreadable") }
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, 0.05) == .success else {
            throw ClockJourneyError.rejected("fixture_hit_test_unavailable")
        }
        defer { _ = AXUIElementSetMessagingTimeout(system, 0) }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(rect.midX), Float(rect.midY), &hit) == .success,
              let hit else { throw ClockJourneyError.rejected("fixture_hit_test_unavailable") }
        var owner: Int32 = 0
        guard AXUIElementGetPid(hit, &owner) == .success else {
            throw ClockJourneyError.rejected("fixture_hit_test_unavailable")
        }
        return [
            "ownerMatchesFixture": owner == pid,
            "frame": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height],
        ]
    }

    static func fixtureIsConcealed(_ pid: Int32) throws -> Bool {
        try fixtureWitness(pid)["ownerMatchesFixture"] as? Bool == false
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let structuralDiagnostic = environment["BARLINE_CLOCK_STRUCTURAL_DIAGNOSTIC"] == "1"
        var receipt: [String: Any] = [
            "schemaVersion": 1, "journey": "golden-gate-clock-hid",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "notarizationQualified": false,
            "inputPath": "marker-correlated-synthetic-hid-explicit-uptime",
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            // AX structure alone cannot establish panel visibility, even when
            // its count is zero. A diagnostic never becomes release signoff.
            "initialClosedVerified": false,
            "notificationCenterVisibilityQualified": false,
            "structuralDiagnostic": structuralDiagnostic,
        ]
        let originalPointer = CGEvent(source: nil)?.location
        var openedByProbe = false
        do {
            guard originalPointer != nil else {
                throw ClockJourneyError.rejected("original_pointer_unavailable")
            }
            guard AXIsProcessTrusted() else {
                throw ClockJourneyError.rejected("harness_accessibility_unverified")
            }
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
                  let rawPID = environment["BARLINE_EXPECTED_PID"], let pid = Int32(rawPID),
                  let appPath = environment["BARLINE_CANDIDATE_APP"], appPath.hasPrefix("/"),
                  let sourceSHA = environment["BARLINE_SOURCE_SHA"], sourceSHA.count == 40,
                  let expectedHash = environment["BARLINE_EXECUTABLE_SHA256"], expectedHash.count == 64,
                  let running = NSRunningApplication(processIdentifier: pid),
                  running.bundleURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path
            else { throw ClockJourneyError.rejected("candidate_unverified") }
            let binary = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/Barline")
            let actualHash = try SHA256.hash(data: Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
            guard actualHash == expectedHash else { throw ClockJourneyError.rejected("candidate_binary_changed") }
            receipt["sourceSHA"] = sourceSHA
            receipt["executableSHA256"] = actualHash
            receipt["processIdentifier"] = pid
            let expectsConcealment = environment["BARLINE_CLOCK_EXPECT_CONCEALED"] == "1"
            let fixturePID = environment["BARLINE_FIXTURE_PID"].flatMap(Int32.init)
            let helperPID = environment["BARLINE_EXPECTED_HELPER_PID"].flatMap(Int32.init)
            guard let helperPID, kill(helperPID, 0) == 0,
                  !expectsConcealment || fixturePID != nil
            else {
                throw ClockJourneyError.rejected("helper_or_concealment_fixture_missing")
            }
            receipt["concealmentExpected"] = expectsConcealment
            receipt["helperProcessIdentifier"] = helperPID
            if environment["BARLINE_CLOCK_CALIBRATE_FIXTURE"] == "1", let fixturePID {
                // Positive fixture hit ownership is the calibration. An
                // unrelated persistent NC AX window cannot invalidate it.
                var observations = [[String: Any]]()
                for _ in 0 ..< 5 {
                    let observation = try fixtureWitness(fixturePID)
                    observations.append(observation)
                    receipt["fixtureObservations"] = observations
                    guard observation["ownerMatchesFixture"] as? Bool == true else {
                        throw ClockJourneyError.rejected("visible_fixture_calibration_failed")
                    }
                    pump(seconds: 0.1)
                }
                receipt["fixtureProcessIdentifier"] = fixturePID
                receipt["mode"] = "visible-fixture-calibration"
                receipt["status"] = "pass"
                try emit(receipt)
                exit(0)
            }
            if expectsConcealment {
                guard let fixturePID, let calibrationPath = environment["BARLINE_CLOCK_FIXTURE_CALIBRATION"],
                      let calibration = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: calibrationPath))) as? [String: Any],
                      calibration["status"] as? String == "pass",
                      calibration["mode"] as? String == "visible-fixture-calibration",
                      calibration["fixtureProcessIdentifier"] as? Int32 == fixturePID,
                      calibration["sourceSHA"] as? String == sourceSHA,
                      calibration["executableSHA256"] as? String == actualHash
                else { throw ClockJourneyError.rejected("visible_fixture_calibration_missing") }
                receipt["fixtureVisibleCalibrationVerified"] = true
            }
            let witness = ClockEventWitness()
            // AppKit global monitors exclude the injecting process's own input.
            // Listen only for our marked left-down through a Quartz tap instead.
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: 1 << CGEventType.leftMouseDown.rawValue,
                callback: { _, _, event, context in
                    if let context {
                        Unmanaged<ClockEventWitness>.fromOpaque(context).takeUnretainedValue().observe(event)
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(witness).toOpaque()
            ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            else { throw ClockJourneyError.rejected("event_monitor_unavailable") }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            defer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFMachPortInvalidate(tap)
            }
            let baseline = try notificationCenterCount()
            guard structuralDiagnostic || baseline == 0 else {
                throw ClockJourneyError.rejected("notification_center_nonzero_baseline_visibility_unknown")
            }
            for _ in 0 ..< 5 {
                pump(seconds: 0.1)
                guard try notificationCenterCount() == baseline else {
                    throw ClockJourneyError.rejected("notification_center_baseline_unstable")
                }
            }
            receipt["stableBaselineElements"] = baseline
            var samples = [[String: Any]]()
            for cycle in 1 ... 3 {
                if expectsConcealment, let fixturePID, try !fixtureIsConcealed(fixturePID) {
                    throw ClockJourneyError.rejected("fixture_not_concealed_before_click")
                }
                if expectsConcealment, let fixturePID {
                    receipt["fixtureBeforeClick"] = try fixtureWitness(fixturePID)
                }
                guard let clock = clockFrame(), clock.width > 0, clock.height > 0,
                      NSScreen.screens.contains(where: {
                          guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                          return CGDisplayBounds(id.uint32Value).contains(CGPoint(x: clock.midX, y: clock.midY))
                      })
                else { throw ClockJourneyError.rejected("clock_not_uniquely_reachable") }
                witness.reset()
                let startedAt = DispatchTime.now().uptimeNanoseconds
                try click(CGPoint(x: clock.midX, y: clock.midY), marker: witness.marker)
                let openDeadline = Date().addingTimeInterval(2)
                var opened = baseline
                while Date() < openDeadline, opened <= baseline {
                    pump(seconds: 0.03)
                    opened = try notificationCenterCount()
                }
                guard opened > baseline else { throw ClockJourneyError.rejected("notification_center_did_not_open") }
                openedByProbe = true
                let observedAt = DispatchTime.now().uptimeNanoseconds
                guard let sample = witness.sample() else {
                    throw ClockJourneyError.rejected("marked_pointer_event_not_observed")
                }
                let eventTimestamp = sample.timestamp
                let delivery = sample.deliveryUptime
                guard
                    eventTimestamp > 0, delivery >= eventTimestamp, delivery - eventTimestamp < 600_000_000
                else { throw ClockJourneyError.rejected("quartz_event_clock_origin_unverified") }
                pump(seconds: 0.4)
                guard try notificationCenterCount() > baseline else {
                    throw ClockJourneyError.rejected("notification_center_closed_without_second_click")
                }
                var observation: [String: Any] = [
                    "cycle": cycle, "baselineElements": baseline, "expandedElements": opened,
                    "expansionObservedMilliseconds": Double(observedAt - startedAt) / 1_000_000,
                    "eventDeliveryMilliseconds": Double(delivery - eventTimestamp) / 1_000_000,
                ]
                if expectsConcealment, let fixturePID {
                    // An open Notification Center can occlude a status item.
                    // This is diagnostic only; assert the closed-state witness.
                    observation["fixtureWhileOpen"] = try fixtureWitness(fixturePID)
                }
                receipt["currentObservation"] = observation
                guard let closingClock = clockFrame() else { throw ClockJourneyError.rejected("clock_disappeared") }
                witness.reset()
                let dismissWithEscape = environment["BARLINE_CLOCK_DISMISS_WITH_ESCAPE"] == "1"
                if dismissWithEscape, let fixturePID {
                    var openObservations = [[String: Any]]()
                    let holdStartedAt = DispatchTime.now().uptimeNanoseconds
                    for elapsed in 1 ... 5 {
                        pump(seconds: elapsed == 1 ? 0.6 : 1)
                        guard try notificationCenterCount() > baseline else {
                            throw ClockJourneyError.rejected("notification_center_closed_during_hold")
                        }
                        var sample = try fixtureWitness(fixturePID)
                        sample["secondsHeld"] = elapsed
                        sample["millisecondsSinceHoldStarted"] = Double(DispatchTime.now().uptimeNanoseconds - holdStartedAt) / 1_000_000
                        openObservations.append(sample)
                        observation["heldOpenFixtureObservations"] = openObservations
                        receipt["currentObservation"] = observation
                    }
                    try escape()
                    observation["dismissal"] = "escape-no-second-clock-transaction"
                } else {
                    try click(CGPoint(x: closingClock.midX, y: closingClock.midY), marker: witness.marker)
                    observation["dismissal"] = "clock-click"
                }
                let closeDeadline = Date().addingTimeInterval(2)
                var closed = opened
                while Date() < closeDeadline, closed != baseline {
                    pump(seconds: 0.03)
                    closed = try notificationCenterCount()
                }
                guard closed == baseline, !running.isTerminated, kill(helperPID, 0) == 0 else {
                    throw ClockJourneyError.rejected("notification_center_did_not_close_once")
                }
                if !dismissWithEscape {
                    guard let closingSample = witness.sample(), closingSample.timestamp > 0,
                          closingSample.deliveryUptime >= closingSample.timestamp,
                          closingSample.deliveryUptime - closingSample.timestamp < 600_000_000
                    else { throw ClockJourneyError.rejected("closing_pointer_event_not_observed") }
                    observation["closingEventDeliveryMilliseconds"] = Double(closingSample.deliveryUptime - closingSample.timestamp) / 1_000_000
                }
                openedByProbe = false
                observation["returnedBaselineElements"] = closed
                if expectsConcealment, let fixturePID {
                    let restorationStartedAt = DispatchTime.now().uptimeNanoseconds
                    let restorationDeadline = Date().addingTimeInterval(3)
                    var concealed = try fixtureIsConcealed(fixturePID)
                    while !concealed, Date() < restorationDeadline {
                        pump(seconds: 0.05)
                        concealed = try fixtureIsConcealed(fixturePID)
                    }
                    observation["fixtureAfterClose"] = try fixtureWitness(fixturePID)
                    observation["restorationObservedMilliseconds"] = Double(DispatchTime.now().uptimeNanoseconds - restorationStartedAt) / 1_000_000
                    receipt["currentObservation"] = observation
                    guard concealed else { throw ClockJourneyError.rejected("fixture_not_reconcealed_after_close") }
                    pump(seconds: 0.1)
                    guard try fixtureIsConcealed(fixturePID) else {
                        throw ClockJourneyError.rejected("fixture_concealment_not_stable")
                    }
                }
                samples.append(observation)
                receipt["samples"] = samples
            }
            receipt["samples"] = samples
            // Both modes measure AX structure, not independent visual state.
            receipt["status"] = "diagnostic-pass"
        } catch {
            receipt["status"] = "fail"
            receipt["error"] = String(describing: error)
        }
        if openedByProbe, let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
           let release = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
        {
            escape.flags = []
            release.flags = []
            escape.post(tap: .cghidEventTap)
            release.post(tap: .cghidEventTap)
        }
        if let originalPointer {
            let restored = CGWarpMouseCursorPosition(originalPointer) == .success
            receipt["originalPointerRestored"] = restored
            if !restored {
                receipt["status"] = "fail"
                receipt["error"] = "original_pointer_restoration_failed"
            }
        }
        try? emit(receipt)
        let status = receipt["status"] as? String
        exit(status == "pass" || status == "diagnostic-pass" ? 0 : 1)
    }

    static func emit(_ receipt: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        guard let output = String(data: data, encoding: .utf8) else {
            throw ClockJourneyError.rejected("receipt_encoding_failed")
        }
        print(output)
    }
}
