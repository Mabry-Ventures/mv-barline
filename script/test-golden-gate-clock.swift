// A real-pointer clock journey. Run in an AX-authorized GUI harness on a free
// macOS 27 test host, against one already-running candidate. No preference
// writes, notification bridges, direct AXPress, or screenshots are used.
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

private enum ClockJourneyError: Error { case rejected(String) }

@MainActor
private final class ClockEventWitness {
    var timestamp: UInt64?
    var deliveryUptime: UInt64?

    func observe(_ event: NSEvent) {
        timestamp = event.cgEvent?.timestamp
        deliveryUptime = DispatchTime.now().uptimeNanoseconds
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

    static func click(_ point: CGPoint) throws {
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            else { throw ClockJourneyError.rejected("pointer_event_creation_failed") }
            event.flags = []
            event.post(tap: .cghidEventTap)
            pump(seconds: 0.03)
        }
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        var receipt: [String: Any] = [
            "schemaVersion": 1, "journey": "golden-gate-clock-physical",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "notarizationQualified": false,
        ]
        var openedByProbe = false
        do {
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
                  AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
                  let rawPID = environment["BARLINE_EXPECTED_PID"], let pid = Int32(rawPID),
                  let appPath = environment["BARLINE_CANDIDATE_APP"], appPath.hasPrefix("/"),
                  let sourceSHA = environment["BARLINE_SOURCE_SHA"], sourceSHA.count == 40,
                  let expectedHash = environment["BARLINE_EXECUTABLE_SHA256"], expectedHash.count == 64,
                  let running = NSRunningApplication(processIdentifier: pid),
                  running.bundleURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path
            else { throw ClockJourneyError.rejected("candidate_or_permissions_unverified") }
            let binary = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/Barline")
            let actualHash = try SHA256.hash(data: Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
            guard actualHash == expectedHash else { throw ClockJourneyError.rejected("candidate_binary_changed") }
            receipt["sourceSHA"] = sourceSHA
            receipt["executableSHA256"] = actualHash
            receipt["processIdentifier"] = pid
            // The caller must separately establish/record native concealment.
            // A passing toggle alone does not prove that hidden items return.
            receipt["concealmentExpected"] = environment["BARLINE_CLOCK_EXPECT_CONCEALED"] == "1"
            let witness = ClockEventWitness()
            guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { witness.observe($0) })
            else { throw ClockJourneyError.rejected("event_monitor_unavailable") }
            defer { NSEvent.removeMonitor(monitor) }
            let baseline = try notificationCenterCount()
            var samples = [[String: Any]]()
            for cycle in 1 ... 3 {
                guard let clock = clockFrame(), clock.width > 0, clock.height > 0,
                      NSScreen.screens.contains(where: {
                          guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                          return CGDisplayBounds(id.uint32Value).contains(CGPoint(x: clock.midX, y: clock.midY))
                      })
                else { throw ClockJourneyError.rejected("clock_not_uniquely_reachable") }
                witness.timestamp = nil
                witness.deliveryUptime = nil
                let startedAt = DispatchTime.now().uptimeNanoseconds
                try click(CGPoint(x: clock.midX, y: clock.midY))
                let openDeadline = Date().addingTimeInterval(2)
                var opened = baseline
                while Date() < openDeadline, opened <= baseline {
                    pump(seconds: 0.03)
                    opened = try notificationCenterCount()
                }
                guard opened > baseline else { throw ClockJourneyError.rejected("notification_center_did_not_open") }
                openedByProbe = true
                let observedAt = DispatchTime.now().uptimeNanoseconds
                guard let eventTimestamp = witness.timestamp, let delivery = witness.deliveryUptime,
                      eventTimestamp > 0, delivery >= eventTimestamp, delivery - eventTimestamp < 600_000_000
                else { throw ClockJourneyError.rejected("quartz_event_clock_origin_unverified") }
                pump(seconds: 0.4)
                guard try notificationCenterCount() > baseline else {
                    throw ClockJourneyError.rejected("notification_center_closed_without_second_click")
                }
                guard let closingClock = clockFrame() else { throw ClockJourneyError.rejected("clock_disappeared") }
                try click(CGPoint(x: closingClock.midX, y: closingClock.midY))
                let closeDeadline = Date().addingTimeInterval(2)
                var closed = opened
                while Date() < closeDeadline, closed != baseline {
                    pump(seconds: 0.03)
                    closed = try notificationCenterCount()
                }
                guard closed == baseline, !running.isTerminated else {
                    throw ClockJourneyError.rejected("notification_center_did_not_close_once")
                }
                openedByProbe = false
                samples.append([
                    "cycle": cycle, "baselineElements": baseline, "openElements": opened, "closedElements": closed,
                    "openObservedMilliseconds": Double(observedAt - startedAt) / 1_000_000,
                    "eventDeliveryMilliseconds": Double(delivery - eventTimestamp) / 1_000_000,
                ])
            }
            receipt["samples"] = samples
            receipt["status"] = "pass"
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
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
           let output = String(data: data, encoding: .utf8)
        {
            print(output)
        }
        exit(receipt["status"] as? String == "pass" ? 0 : 1)
    }
}
