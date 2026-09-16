import AppKit
import CoreGraphics
import Foundation

enum SmokeFailure: Error, CustomStringConvertible {
    case invalidArguments
    case appNotRunning
    case wrongBundleURL(URL?)
    case noVisibleSurface
    case setupDidNotBecomeReady
    case menuBarAutoHideEnabled
    case noShelfWindow
    case noShelfAccessibilityWindow
    case unavailableShelfAccessibilityWindows
    case shelfDidNotClose
    case shelfActivatedApplication
    case shelfClaimedKeyboardFocus

    var description: String {
        switch self {
        case .invalidArguments:
            "expected app bundle path and bundle identifier"
        case .appNotRunning:
            "Barline process is not running"
        case .wrongBundleURL:
            "running process did not originate from the expected local build"
        case .noVisibleSurface:
            "Barline exposed neither a visible standard window nor its status item"
        case .setupDidNotBecomeReady:
            "Barline did not complete its runtime-smoke setup boundary"
        case .menuBarAutoHideEnabled:
            "system menu bar auto-hide is enabled, so shelf presentation is intentionally unavailable"
        case .noShelfWindow:
            "Barline did not order its cold-launch shelf surface"
        case .noShelfAccessibilityWindow:
            "Barline ordered its shelf without publishing it in the app Accessibility window list"
        case .unavailableShelfAccessibilityWindows:
            "Barline's Accessibility window list could not be observed"
        case .shelfDidNotClose:
            "Barline retained its shelf surface or Accessibility window after closing"
        case .shelfActivatedApplication:
            "Barline activated or became frontmost while presenting its nonactivating shelf"
        case .shelfClaimedKeyboardFocus:
            "Barline's pointer-opened shelf claimed keyboard focus"
        }
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute),
          let size = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(),
          CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
    else { return nil }
    return CGRect(origin: point, size: extent)
}

func identifiesShelf(_ element: AXUIElement) -> Bool {
    let namedShelf = [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier"].contains {
        (attribute(element, $0) as? String) == "Barline Bar"
    }
    return namedShelf &&
        (attribute(element, kAXRoleAttribute) as? String) == kAXWindowRole
}

func describeAccessibilityWindows(_ applicationElement: AXUIElement) {
    let windows = attribute(applicationElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let descriptions = windows.map { window in
        let role = attribute(window, kAXRoleAttribute) as? String ?? "nil"
        let subrole = attribute(window, kAXSubroleAttribute) as? String ?? "nil"
        let title = attribute(window, kAXTitleAttribute) as? String ?? "nil"
        let description = attribute(window, kAXDescriptionAttribute) as? String ?? "nil"
        let identifier = attribute(window, "AXIdentifier") as? String ?? "nil"
        return "role=\(role),subrole=\(subrole),title=\(title),description=\(description),identifier=\(identifier)"
    }
    fputs("AX windows (\(windows.count)): \(descriptions.joined(separator: " | "))\n", stderr)
}

struct ShelfObservation {
    let surfacePresent: Bool
    /// `nil` is intentionally distinct from an empty list. An unavailable
    /// Accessibility observation must never be mistaken for a closed shelf.
    let accessibilityWindowCount: Int?
}

/// Golden Gate can omit a nonactivating panel's owner/title from WindowServer
/// rows. Runtime smoke receives the AppKit window number only after a visible,
/// active-space presentation and then verifies it against an external row.
func runtimeSmokePanelWindowNumber(
    bundleIdentifier: String,
    processIdentifier: pid_t
) -> CGWindowID? {
    let applicationID = bundleIdentifier as CFString
    CFPreferencesAppSynchronize(applicationID)
    let received = (CFPreferencesCopyAppValue(
        "RuntimeSmokeToggleReceived" as CFString,
        applicationID
    ) as? NSNumber)?.boolValue == true
    let recordedProcessIdentifier = (CFPreferencesCopyAppValue(
        "RuntimeSmokeToggleProcessIdentifier" as CFString,
        applicationID
    ) as? NSNumber)?.int32Value
    guard received, recordedProcessIdentifier == processIdentifier else { return nil }
    let windowNumber = (CFPreferencesCopyAppValue(
        "RuntimeSmokePanelWindowNumber" as CFString,
        applicationID
    ) as? NSNumber)?.intValue ?? 0
    return windowNumber > 0 ? CGWindowID(windowNumber) : nil
}

func observeShelf(
    processIdentifier: pid_t,
    bundleIdentifier: String,
    applicationElement: AXUIElement
) -> ShelfObservation {
    let shelfRecords = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[CFString: Any]] ?? []
    let runtimeWindowNumber = runtimeSmokePanelWindowNumber(
        bundleIdentifier: bundleIdentifier,
        processIdentifier: processIdentifier
    )
    let surfacePresent = shelfRecords.contains {
        guard ($0[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier else {
            return false
        }
        let namedShelf = ($0[kCGWindowName] as? String) == "Barline Bar"
        let runtimeShelf: Bool
        if let runtimeWindowNumber,
           let recordWindowNumber = $0[kCGWindowNumber] as? NSNumber
        {
            runtimeShelf = CGWindowID(recordWindowNumber.uint32Value) == runtimeWindowNumber
        } else {
            runtimeShelf = false
        }
        return namedShelf || runtimeShelf
    }
    let accessibilityWindows = attribute(
        applicationElement,
        kAXWindowsAttribute
    ) as? [AXUIElement]
    let shelfAccessibilityWindowCount = accessibilityWindows?
        .filter(identifiesShelf)
        .count
    return ShelfObservation(
        surfacePresent: surfacePresent,
        accessibilityWindowCount: shelfAccessibilityWindowCount
    )
}

func waitForShelf(
    processIdentifier: pid_t,
    bundleIdentifier: String,
    applicationElement: AXUIElement,
    presented: Bool
) -> ShelfObservation {
    let deadline = Date().addingTimeInterval(6)
    var observation: ShelfObservation
    repeat {
        observation = observeShelf(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationElement: applicationElement
        )
        let reachedState = presented
            ? observation.surfacePresent && observation.accessibilityWindowCount == 1
            : !observation.surfacePresent && observation.accessibilityWindowCount == 0
        if reachedState {
            return observation
        }
        usleep(100_000)
    } while Date() < deadline
    return observation
}

do {
    guard CommandLine.arguments.count == 3 else { throw SmokeFailure.invalidArguments }
    let expectedURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let bundleIdentifier = CommandLine.arguments[2]
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
        throw SmokeFailure.appNotRunning
    }
    guard app.bundleURL?.standardizedFileURL == expectedURL else {
        throw SmokeFailure.wrongBundleURL(app.bundleURL)
    }
    let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(applicationElement, 0.2)

    // A running process is not a ready menu-bar agent. Pair the debug-only
    // receipt with the current PID so a stale preference from a prior launch
    // cannot be mistaken for readiness of this cold process.
    let setupDeadline = Date().addingTimeInterval(15)
    while Date() < setupDeadline {
        CFPreferencesAppSynchronize(bundleIdentifier as CFString)
        let isReady = (CFPreferencesCopyAppValue(
            "RuntimeSmokeSetupReady" as CFString,
            bundleIdentifier as CFString
        ) as? NSNumber)?.boolValue == true
        let readyProcessIdentifier = (CFPreferencesCopyAppValue(
            "RuntimeSmokeSetupReadyProcessIdentifier" as CFString,
            bundleIdentifier as CFString
        ) as? NSNumber)?.int32Value
        if isReady, readyProcessIdentifier == app.processIdentifier {
            break
        }
        usleep(100_000)
    }
    let isReady = (CFPreferencesCopyAppValue(
        "RuntimeSmokeSetupReady" as CFString,
        bundleIdentifier as CFString
    ) as? NSNumber)?.boolValue == true
    let readyProcessIdentifier = (CFPreferencesCopyAppValue(
        "RuntimeSmokeSetupReadyProcessIdentifier" as CFString,
        bundleIdentifier as CFString
    ) as? NSNumber)?.int32Value
    guard isReady, readyProcessIdentifier == app.processIdentifier else {
        throw SmokeFailure.setupDidNotBecomeReady
    }
    let globalDomain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
    guard (globalDomain?["_HIHideMenuBar"] as? Bool) != true else {
        throw SmokeFailure.menuBarAutoHideEnabled
    }

    let deadline = Date().addingTimeInterval(3)
    var windows = [CGRect]()
    var records = [[CFString: Any]]()
    repeat {
        records = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] ?? []
        windows = records.compactMap { record -> CGRect? in
            guard (record[kCGWindowOwnerPID] as? NSNumber)?.int32Value == app.processIdentifier else {
                return nil
            }
            guard (record[kCGWindowLayer] as? NSNumber)?.intValue == 0 else { return nil }
            guard let bounds = record[kCGWindowBounds] as? [String: NSNumber] else { return nil }
            guard
                let x = bounds["X"]?.doubleValue,
                let y = bounds["Y"]?.doubleValue,
                let width = bounds["Width"]?.doubleValue,
                let height = bounds["Height"]?.doubleValue
            else { return nil }
            let rectangle = CGRect(x: x, y: y, width: width, height: height)
            return rectangle.width >= 100 && rectangle.height >= 100 ? rectangle : nil
        }
        if windows.isEmpty {
            usleep(100_000)
        }
    } while windows.isEmpty && Date() < deadline

    let statusItem = records.first { record in
        guard record[kCGWindowName] as? String == "Barline.ControlItem.Visible" else { return false }
        guard let bounds = record[kCGWindowBounds] as? [String: NSNumber] else { return false }
        return (bounds["Width"]?.doubleValue ?? 0) > 0 && (bounds["Height"]?.doubleValue ?? 0) > 0
    }
    var sourceStatusItems = [AXUIElement]()
    if let extrasValue = attribute(applicationElement, "AXExtrasMenuBar"),
       CFGetTypeID(extrasValue) == AXUIElementGetTypeID()
    {
        let extras = unsafeDowncast(extrasValue, to: AXUIElement.self)
        let children = attribute(extras, kAXChildrenAttribute) as? [AXUIElement] ?? []
        sourceStatusItems = children.filter {
            (attribute($0, "AXIdentifier") as? String) == "Barline.ControlItem.Visible" &&
                (attribute($0, kAXRoleAttribute) as? String) == kAXMenuBarItemRole
        }
    }
    var compositedStatusItemVisible = false
    if sourceStatusItems.count == 1,
       let sourceFrame = frame(sourceStatusItems[0]),
       sourceFrame.width > 0,
       sourceFrame.height > 0
    {
        compositedStatusItemVisible = records.contains { record in
            guard record[kCGWindowName] as? String == "Menubar",
                  (record[kCGWindowLayer] as? NSNumber)?.intValue == 24,
                  let bounds = record[kCGWindowBounds] as? [String: NSNumber],
                  let x = bounds["X"]?.doubleValue,
                  let y = bounds["Y"]?.doubleValue,
                  let width = bounds["Width"]?.doubleValue,
                  let height = bounds["Height"]?.doubleValue
            else { return false }
            return CGRect(x: x, y: y, width: width, height: height)
                .contains(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY))
        }
    }
    guard !windows.isEmpty || statusItem != nil || compositedStatusItemVisible else {
        throw SmokeFailure.noVisibleSurface
    }
    guard !app.isActive else { throw SmokeFailure.shelfActivatedApplication }

    let shelfCycleCount = 20
    for _ in 0 ..< shelfCycleCount {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("\(bundleIdentifier).runtime-smoke.toggle-shelf"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let presented = waitForShelf(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationElement: applicationElement,
            presented: true
        )
        guard presented.surfacePresent else {
            throw SmokeFailure.noShelfWindow
        }
        guard let accessibilityWindowCount = presented.accessibilityWindowCount else {
            throw SmokeFailure.unavailableShelfAccessibilityWindows
        }
        guard accessibilityWindowCount == 1 else {
            describeAccessibilityWindows(applicationElement)
            throw SmokeFailure.noShelfAccessibilityWindow
        }
        guard !app.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier
        else {
            throw SmokeFailure.shelfActivatedApplication
        }
        if let focusedValue = attribute(applicationElement, kAXFocusedWindowAttribute),
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID(),
           identifiesShelf(unsafeDowncast(focusedValue, to: AXUIElement.self))
        {
            throw SmokeFailure.shelfClaimedKeyboardFocus
        }

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("\(bundleIdentifier).runtime-smoke.toggle-shelf"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let closed = waitForShelf(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationElement: applicationElement,
            presented: false
        )
        guard let closedAccessibilityWindowCount = closed.accessibilityWindowCount else {
            throw SmokeFailure.unavailableShelfAccessibilityWindows
        }
        guard !closed.surfacePresent, closedAccessibilityWindowCount == 0 else {
            throw SmokeFailure.shelfDidNotClose
        }
    }

    if !windows.isEmpty {
        let dimensions = windows.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ",")
        print("INFO: local Barline build also exposed \(windows.count) visible window(s): \(dimensions)")
    }
    print("PASS: local Barline build exposes its status item and \(shelfCycleCount) shelf Accessibility cycles")
} catch {
    fputs("error: UI smoke failed: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
