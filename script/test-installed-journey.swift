#!/usr/bin/env swift

// Production journey: no notification bridges and no AXPress shortcuts.
// Run only against the one already-running signed app and a controlled fixture.
import AppKit
import CoreGraphics
import Foundation

struct Receipt: Decodable {
    let session: String
    let processIdentifier: Int32
    let sequence: Int
    let button: String
    let activations: Int
    let opens: Int
    let closes: Int
    let actions: Int
    let visible: Bool
}

enum JourneyError: Error { case failed(String) }
let environment = ProcessInfo.processInfo.environment

func required(_ name: String) throws -> String {
    guard let value = environment[name], !value.isEmpty else { throw JourneyError.failed("missing_\(name)") }
    return value
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
    else { return nil }
    return CGRect(origin: point, size: extent)
}

func matches(_ element: AXUIElement, _ name: String) -> Bool {
    [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier"].contains {
        (attribute(element, $0) as? String) == name
    }
}

/// Depth and count caps ensure an unexpected AX tree cannot become an unbounded
/// process-inventory crawl. Only these two explicitly selected apps are queried.
func find(
    _ root: AXUIElement,
    named name: String,
    aliases: [String] = [],
    requiredRole: String? = nil,
    unique: Bool = false,
    accepting: (AXUIElement) -> Bool = { _ in true }
) -> AXUIElement? {
    var remaining = 500
    var visited = Set<CFHashCode>()
    var candidates = [AXUIElement]()
    var complete = true
    let deadline = Date().addingTimeInterval(1)
    func visit(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard visited.insert(CFHash(element)).inserted else { return nil }
        guard depth < 12, remaining > 0, Date() < deadline else {
            complete = false
            return nil
        }
        remaining -= 1
        AXUIElementSetMessagingTimeout(element, 0.03)
        if matches(element, name) || aliases.contains(where: { matches(element, $0) }),
           requiredRole == nil || (attribute(element, kAXRoleAttribute) as? String) == requiredRole,
           accepting(element)
        {
            if !unique {
                return element
            }
            candidates.append(element)
        }
        for key in [kAXWindowsAttribute, kAXChildrenAttribute, kAXContentsAttribute] {
            let children = attribute(element, key) as? [AXUIElement] ?? []
            if children.count > 100 {
                complete = false
            }
            for child in children.prefix(100) {
                if let found = visit(child, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }
    let first = visit(root, depth: 0)
    return unique ? (complete && candidates.count == 1 ? candidates.first : nil) : first
}

func extras(_ app: AXUIElement) -> AXUIElement? {
    guard let value = attribute(app, "AXExtrasMenuBar"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}

func bounds(_ row: [String: Any]) -> CGRect? {
    guard let value = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: value as CFDictionary)
}

func click(_ rect: CGRect, right: Bool = false) throws {
    let point = CGPoint(x: rect.midX, y: rect.midY)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: right ? .right : .left),
        let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: right ? .right : .left)
    else { throw JourneyError.failed("event_creation") }
    // Event locations alone do not update the real pointer used by smart rehide.
    guard CGWarpMouseCursorPosition(point) == .success else {
        throw JourneyError.failed("pointer_positioning_failed")
    }
    // Warping updates the physical cursor without delivering the normal hover
    // transition. Send the move before down/up, as a real pointer journey does.
    guard let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: point, mouseButton: .left)
    else {
        throw JourneyError.failed("pointer_move_creation")
    }
    moved.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
    up.post(tap: .cghidEventTap)
}

func wait(_ reason: String, seconds: TimeInterval = 6, condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if try condition() {
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw JourneyError.failed(reason)
}

func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.midX - rhs.midX) <= 2 && abs(lhs.midY - rhs.midY) <= 2 && abs(lhs.width - rhs.width) <= 2
}

var journeyExitCode: Int32 = 0
do {
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
        throw JourneyError.failed("harness_accessibility_and_screen_recording_required_no_prompt")
    }
    let appPID = try Int32(required("BARLINE_EXPECTED_PID")) ?? 0
    let fixturePID = try Int32(required("BARLINE_FIXTURE_PID")) ?? 0
    let bundleID = try required("BARLINE_APP_BUNDLE_IDENTIFIER")
    let expectedPath = try required("BARLINE_CANDIDATE_APP")
    let session = try required("BARLINE_FIXTURE_SESSION")
    let receiptURL = try URL(fileURLWithPath: required("BARLINE_FIXTURE_RECEIPT"))
    let target = environment["BARLINE_JOURNEY_TARGET"] ?? "BF Native"
    guard ["BF Native", "BF Popover", "BF Delayed"].contains(target) else {
        throw JourneyError.failed("unsupported_fixture_target")
    }
    let right = environment["BARLINE_JOURNEY_BUTTON"] == "right"
    guard let runningApp = NSRunningApplication(processIdentifier: appPID),
          runningApp.bundleIdentifier == bundleID,
          runningApp.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: expectedPath).standardizedFileURL.path,
          NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count == 1,
          let fixtureApp = NSRunningApplication(processIdentifier: fixturePID),
          fixtureApp.bundleURL?.lastPathComponent == "BarlineFixture.app"
    else { throw JourneyError.failed("exact_single_candidate_or_fixture_mismatch") }
    let app = AXUIElementCreateApplication(appPID)
    let fixture = AXUIElementCreateApplication(fixturePID)
    AXUIElementSetMessagingTimeout(app, 0.2)
    AXUIElementSetMessagingTimeout(fixture, 0.2)
    func receipt() -> Receipt? {
        guard let data = try? Data(contentsOf: receiptURL), data.count < 4096,
              let value = try? JSONDecoder().decode(Receipt.self, from: data),
              value.session == session, value.processIdentifier == fixturePID
        else { return nil }
        return value
    }
    func targetFrame() -> CGRect? {
        guard let bar = extras(fixture), let element = find(bar, named: target) else { return nil }
        return frame(element)
    }
    let displays = NSScreen.screens.compactMap { screen -> CGRect? in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDisplayBounds(number.uint32Value)
    }
    let isGoldenGate = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    let journalURL = URL.applicationSupportDirectory
        .appendingPathComponent(bundleID, isDirectory: true)
        .appendingPathComponent("TemporaryReveals", isDirectory: true)
        .appendingPathComponent("temporary-reveals.json")
    func journalEmpty(allowMissing: Bool = false) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: journalURL.path) else {
            return allowMissing && !FileManager.default.fileExists(atPath: journalURL.path)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: journalURL), data.count <= 1024 * 1024,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return false }
        return entries.isEmpty
    }
    func nativeFixtureIsTopmost(at source: CGRect) -> Bool? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(source.midX), Float(source.midY), &hit) == .success,
              let hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success else { return nil }
        return owner == fixturePID
    }
    func hiddenFixtureFrame() -> CGRect? {
        guard let source = targetFrame(), source.width > 0, source.height > 0 else { return nil }
        if isGoldenGate {
            // macOS 27 keeps a visible source AX frame even when its native
            // status item is concealed. A system-wide hit at that exact frame
            // must no longer resolve to the fixture process.
            guard displays.contains(where: { $0.contains(CGPoint(x: source.midX, y: source.midY)) }),
                  nativeFixtureIsTopmost(at: source) == false else { return nil }
            return source
        }
        let titles = [
            "BF Native": "BarlineFixture.Journey.Native",
            "BF Popover": "BarlineFixture.Journey.Popover",
            "BF Delayed": "BarlineFixture.Journey.Delayed",
        ]
        guard let title = titles[target] else { return nil }
        let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let fixtureWindows = records.filter {
            guard let owner = ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
            return (owner == fixturePID ||
                NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.controlcenter") &&
                ($0[kCGWindowName as String] as? String) == title
        }
        let dividers = records.filter {
            guard let owner = ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
            return (owner == appPID ||
                NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.controlcenter") &&
                ($0[kCGWindowName as String] as? String) == "Barline.ControlItem.Hidden"
        }
        let alwaysHiddenDividers = records.filter {
            guard let owner = ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
            return (owner == appPID ||
                NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.controlcenter") &&
                ($0[kCGWindowName as String] as? String) == "Barline.ControlItem.AlwaysHidden"
        }
        guard fixtureWindows.count == 1, dividers.count == 1, alwaysHiddenDividers.count <= 1,
              let item = bounds(fixtureWindows[0]), let divider = bounds(dividers[0]),
              item.maxX <= divider.minX - 2,
              !displays.contains(where: { $0.intersects(item) }),
              alwaysHiddenDividers.isEmpty || alwaysHiddenDividers.contains(where: {
                  guard let edge = bounds($0) else { return false }
                  return item.minX >= edge.maxX + 2
              }) else { return nil }
        return item
    }
    let actionRole = target == "BF Popover" && !right ? kAXButtonRole : kAXMenuItemRole
    func targetAction() -> AXUIElement? {
        let visibleFixtureWindows = windows().filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == fixturePID
        }.compactMap(bounds)
        guard !visibleFixtureWindows.isEmpty else { return nil }
        // A retained popover can expose an identically named button while a
        // native menu is active. Accept only this journey's role and one visible,
        // fixture-owned action, never the first label encountered in the tree.
        return find(fixture, named: "Fixture Receipt Action", aliases: ["fixture-journey-action"],
                    requiredRole: actionRole, unique: true)
        { element in
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == fixturePID,
                  (attribute(element, kAXEnabledAttribute) as? Bool) != false,
                  (attribute(element, "AXHidden") as? Bool) != true,
                  let rect = frame(element), rect.width > 0, rect.height > 0 else { return false }
            return visibleFixtureWindows.contains { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        }
    }
    var shelfLabels = [target]
    func verifiedHostedFixtureAlias(sourceFrame: CGRect) -> String? {
        let knownTitles = [
            "BF Native": "BarlineFixture.Journey.Native",
            "BF Popover": "BarlineFixture.Journey.Popover",
            "BF Delayed": "BarlineFixture.Journey.Delayed",
        ]
        guard let expected = knownTitles[target] else { return nil }
        let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let matched = records.filter { row in
            guard let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == fixturePID || NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.controlcenter",
                  let rect = bounds(row), rect.width > 0, rect.height > 0, rect.height < 80 else { return false }
            // On macOS 26 the hosted window is 2pt narrower and 9pt taller
            // than its source AX button; center correspondence remains exact.
            return abs(rect.midX - sourceFrame.midX) <= 1 &&
                abs(rect.midY - sourceFrame.midY) <= 1 &&
                abs(rect.width - sourceFrame.width) <= 2
        }
        guard matched.count == 1,
              (matched[0][kCGWindowName as String] as? String) == expected else { return nil }
        return expected
    }
    func shelfVisible() -> Bool {
        windows().contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == appPID &&
            $0[kCGWindowName as String] as? String == "Barline Bar"
        }
    }
    func shelfRoot() -> AXUIElement? {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first {
            matches($0, "Barline Bar")
        }
    }
    func shelfTarget() -> AXUIElement? {
        guard let shelf = shelfRoot() else { return nil }
        return find(shelf, named: target, aliases: Array(shelfLabels.dropFirst()))
    }
    func shelfWindowFrame() -> CGRect? {
        let shelves = windows().filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == appPID &&
                ($0[kCGWindowName as String] as? String) == "Barline Bar"
        }
        guard shelves.count == 1 else { return nil }
        return shelves.first.flatMap(bounds)
    }
    func validatedShelfButton(_ element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0 ..< 6 {
            AXUIElementSetMessagingTimeout(current, 0.02)
            var owner: pid_t = 0
            guard AXUIElementGetPid(current, &owner) == .success, owner == appPID else { return nil }
            let exactLabel = shelfLabels.contains { label in
                matches(current, label) || (attribute(current, kAXHelpAttribute) as? String) == label
            }
            if exactLabel,
               (attribute(current, kAXRoleAttribute) as? String) == kAXButtonRole,
               let rect = frame(current), let shelf = shelfWindowFrame(),
               rect.width > 0, rect.height > 0,
               shelf.contains(CGPoint(x: rect.midX, y: rect.midY))
            {
                return current
            }
            guard let parent = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }
    /// Read-only fallback, not a guessed click. Probe points only inside the
    /// positively identified shelf, then require its exact synthetic NSButton,
    /// owning PID and current on-shelf geometry before returning a click target.
    func hitTestShelfTarget() -> AXUIElement? {
        guard let shelf = shelfWindowFrame(), shelf.width > 0, shelf.height > 0 else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.02)
        let count = min(256, max(1, Int(ceil(shelf.width / 8))))
        let deadline = Date().addingTimeInterval(3)
        for index in 0 ..< count {
            guard Date() < deadline else { return nil }
            let x = shelf.minX + (Double(index) + 0.5) * shelf.width / Double(count)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(x), Float(shelf.midY), &hit) == .success,
                  let hit, let button = validatedShelfButton(hit) else { continue }
            return button
        }
        return nil
    }
    func diagnoseShelfAX() -> [String: Any] {
        guard shelfWindowFrame() != nil, let root = shelfRoot() else {
            return ["subtreeAvailable": false]
        }
        var remaining = 160
        var visited = Set<CFHashCode>()
        var roles = [String: Int]()
        var syntheticMatches = [
            "BF Native": 0, "BF Popover": 0, "BF Delayed": 0,
            "BarlineFixture.Journey.Native": 0, "BarlineFixture.Journey.Popover": 0,
            "BarlineFixture.Journey.Delayed": 0,
        ]
        var syntheticMatchKeys = [String: Int]()
        var genericItemTitles = 0
        var buttonsWithFrame = 0
        let deadline = Date().addingTimeInterval(2)
        let permittedRoles = Set([kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, kAXButtonRole, kAXImageRole, kAXStaticTextRole])
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 12, remaining > 0, Date() < deadline,
                  visited.insert(CFHash(element)).inserted else { return }
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == appPID else { return }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.01)
            let role = attribute(element, kAXRoleAttribute) as? String ?? "other"
            roles[permittedRoles.contains(role) ? role : "other", default: 0] += 1
            if role == kAXButtonRole, let rect = frame(element), rect.width > 0, rect.height > 0 {
                buttonsWithFrame += 1
            }
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier", kAXHelpAttribute] {
                guard let text = attribute(element, key) as? String else { continue }
                if syntheticMatches[text] != nil {
                    syntheticMatches[text, default: 0] += 1
                    syntheticMatchKeys[key, default: 0] += 1
                }
                if key == kAXTitleAttribute, text.hasPrefix("Item-") {
                    genericItemTitles += 1
                }
            }
            for key in [kAXChildrenAttribute, kAXContentsAttribute, "AXVisibleChildren"] {
                for child in (attribute(element, key) as? [AXUIElement] ?? []).prefix(80) {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 0)
        return [
            "subtreeAvailable": true, "visitedNodes": 160 - remaining,
            "budgetExhausted": remaining == 0 || Date() >= deadline,
            "roleCounts": roles, "buttonsWithNonemptyFrame": buttonsWithFrame,
            "exactSyntheticMatches": syntheticMatches, "exactSyntheticMatchKeys": syntheticMatchKeys,
            "genericItemTitleCount": genericItemTitles,
        ]
    }
    func captureShelfDiagnostic() -> Bool {
        guard let requestedPath = environment["BARLINE_JOURNEY_SCREENSHOT"], requestedPath.hasPrefix("/") else { return false }
        let permittedRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".artifacts/runtime", isDirectory: true).resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: requestedPath).resolvingSymlinksInPath()
        guard output.path.hasPrefix(permittedRoot.path + "/"), output.pathExtension == "png",
              !FileManager.default.fileExists(atPath: output.path) else { return false }
        let shelves = windows().filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == appPID &&
                ($0[kCGWindowName as String] as? String) == "Barline Bar"
        }
        guard shelves.count == 1,
              let windowNumber = (shelves[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return false }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(windowNumber), output.path]
            capture.standardOutput = FileHandle.nullDevice
            capture.standardError = FileHandle.nullDevice
            try capture.run()
            let deadline = Date().addingTimeInterval(3)
            while capture.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !capture.isRunning else { capture.terminate(); return false }
            return capture.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
        } catch { return false }
    }
    guard let baseline = receipt(), !baseline.visible, let original = targetFrame(),
          hiddenFixtureFrame() != nil, journalEmpty(allowMissing: true), !shelfVisible()
    else {
        throw JourneyError.failed("fixture_ready_and_closed_shelf_baseline_required")
    }
    func checkedReceipt() throws -> Receipt? {
        guard let current = receipt() else { return nil }
        let counters = [
            ("activation", current.activations, baseline.activations),
            ("open", current.opens, baseline.opens),
            ("action", current.actions, baseline.actions),
            ("close", current.closes, baseline.closes),
        ]
        for (name, value, initial) in counters {
            guard value >= initial else { throw JourneyError.failed("target_\(name)_counter_regressed") }
            guard value - initial <= 1 else { throw JourneyError.failed("duplicate_target_\(name)_observed") }
        }
        return current
    }
    func exactlyOneCompletedJourney(_ current: Receipt) -> Bool {
        current.activations - baseline.activations == 1 && current.opens - baseline.opens == 1 &&
            current.actions - baseline.actions == 1 && current.closes - baseline.closes == 1 && !current.visible
    }
    if let hostedAlias = verifiedHostedFixtureAlias(sourceFrame: original) {
        shelfLabels.append(hostedAlias)
    }
    print("{\"fixtureHostedAliasVerified\":\(shelfLabels.count == 2)}")
    // The chosen fixture must actually be hidden; a visible-item click is not
    // evidence that reveal/activation/restore works. Do not move user items here.
    if isGoldenGate {
        guard nativeFixtureIsTopmost(at: original) == false else {
            throw JourneyError.failed("fixture_target_must_be_placed_in_hidden_section_first")
        }
    } else {
        guard !windows().contains(where: { row in
            guard let rect = bounds(row) else { return false }
            return sameFrame(rect, original) && displays.contains { $0.intersects(rect) }
        }) else { throw JourneyError.failed("fixture_target_must_be_placed_in_hidden_section_first") }
    }
    guard let sourceBar = extras(app) else { throw JourneyError.failed("barline_source_extras_unavailable") }
    let sourceItems = (attribute(sourceBar, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
        (attribute($0, "AXIdentifier") as? String) == "Barline.ControlItem.Visible" &&
            (attribute($0, kAXRoleAttribute) as? String) == kAXMenuBarItemRole
    }
    guard sourceItems.count == 1, let sourceControl = sourceItems.first.flatMap(frame),
          sourceControl.width > 0, sourceControl.width < 100, sourceControl.height > 0
    else {
        throw JourneyError.failed("status_control_source_unverified")
    }
    let controls = windows().filter { $0[kCGWindowName as String] as? String == "Barline.ControlItem.Visible" }
    let verifiedControls = controls.filter { row in
        guard let rect = bounds(row), let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
        let validHost = owner == appPID || NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.controlcenter"
        return validHost && sameFrame(sourceControl, rect)
    }
    let compositedMenuBars = windows().filter { row in
        guard row[kCGWindowName as String] as? String == "Menubar",
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 24,
              let rect = bounds(row), rect.width > 0, rect.height > 0 else { return false }
        return rect.contains(CGPoint(x: sourceControl.midX, y: sourceControl.midY))
    }
    let control: CGRect
    let controlHostProof: String
    if verifiedControls.count == 1, let hosted = verifiedControls.first.flatMap(bounds) {
        control = hosted
        controlHostProof = "named_status_window"
    } else if verifiedControls.isEmpty, compositedMenuBars.count == 1 {
        // macOS 27 composites status items into WindowServer's single Menubar
        // surface. The exact app-owned AX item and its on-screen composite must
        // both agree before a physical click is permitted.
        control = sourceControl
        controlHostProof = "composited_menubar_with_exact_ax_source"
    } else {
        throw JourneyError.failed("status_control_source_host_relationship_unverified")
    }
    guard let originalPointer = CGEvent(source: nil)?.location else {
        throw JourneyError.failed("original_pointer_unavailable")
    }
    defer {
        let restored = CGWarpMouseCursorPosition(originalPointer) == .success
        print("{\"originalPointerRestored\":\(restored)}")
        if !restored {
            journeyExitCode = 1
        }
    }
    try click(control)
    try wait("shelf_did_not_open") { shelfVisible() }
    guard let observedShelf = shelfWindowFrame(),
          CGWarpMouseCursorPosition(CGPoint(x: observedShelf.midX, y: observedShelf.midY)) == .success
    else {
        throw JourneyError.failed("shelf_pointer_positioning_failed")
    }
    // Keep the physical pointer inside the actual panel during discovery, and
    // preserve its initial state before a long AX timeout can permit rehide.
    Thread.sleep(forTimeInterval: 0.1)
    print("{\"stage\":\"shelf_initial_observation\"}")
    if environment["BARLINE_JOURNEY_SCREENSHOT"] != nil {
        print("{\"shelfOnlyScreenshotSaved\":\(captureShelfDiagnostic())}")
    }
    try print(String(decoding: JSONSerialization.data(withJSONObject: diagnoseShelfAX(), options: [.sortedKeys]), as: UTF8.self))
    // Ordering the panel precedes the hosting view's accessible layout commit.
    var shelfItem: AXUIElement?
    var shelfAXTraversalPassed = false
    do {
        try wait("synthetic_fixture_not_accessible_in_shelf") {
            guard let element = shelfTarget(), let button = validatedShelfButton(element) else { return false }
            shelfItem = button
            return true
        }
        shelfAXTraversalPassed = true
    } catch {
        let diagnostic = ["shelfWindowStillVisible": shelfVisible(), "shelfAXWindowPresent": shelfRoot() != nil]
        try print(String(decoding: JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]), as: UTF8.self))
        print("{\"stage\":\"shelf_ax_traversal\",\"verdict\":\"FAIL\",\"fallback\":\"bounded_shelf_hit_test\"}")
        shelfItem = hitTestShelfTarget()
    }
    guard let shelfItem, let verifiedItem = validatedShelfButton(shelfItem) else {
        throw JourneyError.failed("synthetic_fixture_unresolved_after_scoped_shelf_hit_test")
    }
    var stableShelfFrame: CGRect?
    var stableWindowFrame: CGRect?
    var consecutiveStableSamples = 0
    try wait("synthetic_fixture_geometry_did_not_stabilize", seconds: 3) {
        guard let candidate = frame(verifiedItem), let currentWindow = shelfWindowFrame(),
              candidate.width > 0, candidate.height > 0,
              currentWindow.contains(CGPoint(x: candidate.midX, y: candidate.midY))
        else {
            consecutiveStableSamples = 0
            stableShelfFrame = nil
            stableWindowFrame = nil
            return false
        }
        if let priorButton = stableShelfFrame, let priorWindow = stableWindowFrame,
           sameFrame(priorButton, candidate), sameFrame(priorWindow, currentWindow)
        {
            consecutiveStableSamples += 1
        } else {
            consecutiveStableSamples = 1
        }
        stableShelfFrame = candidate
        stableWindowFrame = currentWindow
        return consecutiveStableSamples >= 3
    }
    guard let shelfFrame = stableShelfFrame, let currentShelf = stableWindowFrame else {
        throw JourneyError.failed("synthetic_fixture_stable_geometry_unavailable")
    }
    let shelfGeometry: [String: Any] = [
        "stage": "shelf_target_geometry",
        "button": [
            "x": shelfFrame.minX,
            "y": shelfFrame.minY,
            "width": shelfFrame.width,
            "height": shelfFrame.height,
        ],
        "window": [
            "x": currentShelf.minX,
            "y": currentShelf.minY,
            "width": currentShelf.width,
            "height": currentShelf.height,
        ],
        "buttonInsideWindow": currentShelf.contains(
            CGPoint(x: shelfFrame.midX, y: shelfFrame.midY)
        ),
    ]
    try print(String(decoding: JSONSerialization.data(withJSONObject: shelfGeometry, options: [.sortedKeys]), as: UTF8.self))
    try click(shelfFrame, right: right)
    print("{\"stage\":\"shelf_target_clicked\"}")
    try wait("target_did_not_receive_click_and_open_interface") {
        guard let current = try checkedReceipt(), current.activations - baseline.activations == 1,
              current.opens - baseline.opens == 1, current.visible,
              current.button == (right ? "right" : "left") else { return false }
        // The witness reports its delegate transition; independently require the
        // target's real actionable menu/popover control to be exposed by AppKit.
        return targetAction() != nil
    }
    guard let action = targetAction(), let actionFrame = frame(action) else {
        throw JourneyError.failed("target_interface_action_unavailable")
    }
    print("{\"stage\":\"visible_target_action_resolved\"}")
    guard !shelfVisible() else {
        throw JourneyError.failed("shelf_reopened_over_target_interface")
    }
    _ = try checkedReceipt()
    print("{\"stage\":\"before_target_action_click\"}")
    try click(actionFrame)
    try wait("target_action_or_close_not_observed") {
        guard let current = try checkedReceipt() else { return false }
        return exactlyOneCompletedJourney(current)
    }
    // macOS can compact hidden status-item slots after a drag. The production
    // contract is that the same fixture window returns behind Barline's hidden
    // divider, not that its offscreen pixel coordinate remains identical.
    func restorationCommitted() throws -> Bool {
        guard let current = try checkedReceipt(), exactlyOneCompletedJourney(current),
              let restored = targetFrame(), let hidden = hiddenFixtureFrame() else { return false }
        return sameFrame(restored, hidden) &&
            abs(restored.midY - original.midY) <= 2 &&
            abs(restored.width - original.width) <= 2 &&
            journalEmpty(allowMissing: isGoldenGate) && !shelfVisible()
    }
    try wait("item_not_rehidden_and_journal_not_cleared", seconds: 25) {
        try restorationCommitted()
    }
    // A transient native hide is not completion: give the coordinator time to
    // compensate before accepting the durable journal and layout postcondition.
    Thread.sleep(forTimeInterval: 1)
    guard try restorationCommitted() else {
        throw JourneyError.failed("restoration_not_stable_after_commit")
    }
    guard let completed = try checkedReceipt(), exactlyOneCompletedJourney(completed) else {
        throw JourneyError.failed("exact_one_target_journey_not_observed")
    }
    guard !runningApp.isTerminated, !fixtureApp.isTerminated else { throw JourneyError.failed("process_changed") }
    let result: [String: Any] = try [
        "schema": 1, "verdict": shelfAXTraversalPassed ? "PASS" : "FAIL",
        "interactionVerdict": "PASS", "shelfAXTraversalPassed": shelfAXTraversalPassed,
        "fixtureHostedAliasVerified": shelfLabels.count == 2,
        "statusControlHostProof": controlHostProof,
        "targetResolution": shelfAXTraversalPassed ? "shelf_ax_tree" : "scoped_shelf_ax_hit_test",
        "target": target, "button": right ? "right" : "left",
        "physicalEventPath": true, "shelfObserved": true, "targetReceiptObserved": true,
        "targetInterfaceObserved": true, "targetActionObserved": true, "restorationObserved": true,
        "shelfStayedClosedDuringActivation": true,
        "targetActionRole": actionRole, "targetActionUniqueAndOnScreen": true,
        "exactlyOneActivationOpenActionClose": true,
        "priorTargetActivations": baseline.activations,
        "sourceSHA": required("BARLINE_SOURCE_SHA"),
        "executableSHA256": required("BARLINE_EXECUTABLE_SHA256"),
        "version": Bundle(url: runningApp.bundleURL!)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    try print(String(decoding: JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    // Completing the pointer journey must not silently clear the failed AX lane.
    if !shelfAXTraversalPassed {
        journeyExitCode = 1
    }
} catch {
    // Failure reasons are controlled tokens, never AX tree contents or app titles.
    let reason: String = if case let JourneyError.failed(code) = error {
        code
    } else {
        "harness_error"
    }
    let result = ["verdict": "FAIL", "reason": reason]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    journeyExitCode = 1
}

// Exit only after the do-scope's pointer-restoration defer has run.
exit(journeyExitCode)
