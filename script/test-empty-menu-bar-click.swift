// Authorized installed-candidate gap-click regression. No AXPress, content
// capture, guessed status-item clicks, or production notification bridges.
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

enum GapClickError: Error { case rejected(String) }

@main
@MainActor
enum EmptyMenuBarClickJourney {
    static func read(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementSetMessagingTimeout(element, 0.05) == .success,
              AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = read(element, kAXPositionAttribute), let size = read(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func shelfVisible(pid: Int32) throws -> Bool {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw GapClickError.rejected("window_observation_unavailable")
        }
        return rows.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
                ($0[kCGWindowName as String] as? String) == "Barline Bar"
        }
    }

    static func click(_ point: CGPoint) throws {
        guard CGWarpMouseCursorPosition(point) == .success,
              let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { throw GapClickError.rejected("event_creation") }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        up.post(tap: .cghidEventTap)
    }

    static func wait(pid: Int32, visible: Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if try shelfVisible(pid: pid) == visible { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        throw GapClickError.rejected(visible ? "gap_click_did_not_open" : "gap_click_did_not_close")
    }

    static func run() throws {
        let environment = ProcessInfo.processInfo.environment
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
              let rawPID = environment["BARLINE_EXPECTED_PID"], let pid = Int32(rawPID),
              let path = environment["BARLINE_CANDIDATE_APP"],
              let expectedHash = environment["BARLINE_EXECUTABLE_SHA256"],
              let source = environment["BARLINE_SOURCE_SHA"], source.count == 40,
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == "com.mabryventures.Barline", app.bundleURL?.path == path,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.mabryventures.Barline").count == 1,
              let originalPointer = CGEvent(source: nil)?.location,
              try !shelfVisible(pid: pid)
        else { throw GapClickError.rejected("closed_candidate_or_permissions_unverified") }
        let binary = URL(fileURLWithPath: path).appendingPathComponent("Contents/MacOS/Barline")
        let hash = try SHA256.hash(data: Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedHash else { throw GapClickError.rejected("candidate_binary_mismatch") }
        let root = AXUIElementCreateApplication(pid)
        guard let rawBar = read(root, "AXExtrasMenuBar"), CFGetTypeID(rawBar) == AXUIElementGetTypeID(),
              let children = read(unsafeDowncast(rawBar, to: AXUIElement.self), kAXChildrenAttribute) as? [AXUIElement]
        else { throw GapClickError.rejected("candidate_control_unavailable") }
        let controls = children.filter { read($0, "AXIdentifier") as? String == "Barline.ControlItem.Visible" }
        guard controls.count == 1, let control = controls.first.flatMap(frame),
              let screen = NSScreen.screens.first(where: {
                  guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                  return CGDisplayBounds(number.uint32Value).contains(control)
              }), let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw GapClickError.rejected("control_display_relationship_unverified") }
        let display = CGDisplayBounds(number.uint32Value)
        let point = CGPoint(x: display.minX + (control.minX - display.minX) / 2, y: control.midY)
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, 0.05) == .success else { throw GapClickError.rejected("hit_test_unavailable") }
        defer { _ = AXUIElementSetMessagingTimeout(system, 0) }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit, read(hit, kAXRoleAttribute) as? String == kAXMenuBarRole
        else { throw GapClickError.rejected("selected_point_not_verified_menu_bar_background") }
        var pointerRestored = false
        defer {
            if !pointerRestored { _ = CGWarpMouseCursorPosition(originalPointer) }
        }
        for _ in 0..<3 {
            try click(point)
            try wait(pid: pid, visible: true)
            try click(point)
            try wait(pid: pid, visible: false)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        guard try !shelfVisible(pid: pid), !app.isTerminated else { throw GapClickError.rejected("stable_closure_failed") }
        pointerRestored = CGWarpMouseCursorPosition(originalPointer) == .success
        guard pointerRestored else { throw GapClickError.rejected("pointer_restoration_failed") }
        let result: [String: Any] = [
            "journey": "verified-menu-bar-background-click", "verdict": "PASS", "cycles": 3,
            "sourceSHA": source, "executableSHA256": hash, "processIdentifier": pid,
            "originalPointerRestored": true, "stableClosureObserved": true,
            "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        do { try run() } catch {
            print("{\"verdict\":\"FAIL\",\"error\":\"\(error)\"}")
            exit(1)
        }
    }
}
