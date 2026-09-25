//
//  AXHelpers.swift
//  Shared
//

@preconcurrency import AXSwift
import Cocoa

enum AXHelpers {
    enum ElementAttributeReadDisposition: String, CaseIterable, Codable, Sendable {
        case success
        case noValue = "no_value"
        case unsupported
        case cannotComplete = "cannot_complete"
        case invalidElement = "invalid_element"
        case apiDisabled = "api_disabled"
        case wrongType = "wrong_type"
        case otherError = "other_error"
    }

    /// A privacy-safe result category for a single AX string attribute read.
    /// Callers must never log the underlying value.
    enum StringAttributeReadDisposition: String, CaseIterable {
        case nonemptyString = "nonempty_string"
        case emptyString = "empty_string"
        case noValue = "no_value"
        case unsupported
        case cannotComplete = "cannot_complete"
        case invalidElement = "invalid_element"
        case wrongType = "wrong_type"
        case otherError = "other_error"
    }

    /// A privacy-safe result category for the bounded direct-children read.
    enum ChildrenReadDisposition: String, CaseIterable {
        case success
        case unsupported
        case transientError = "transient_error"
        case invalidElement = "invalid_element"
        case otherError = "other_error"
    }

    private static let queue = DispatchQueue.targetingGlobal(
        label: "AXHelpers.queue",
        qos: .userInteractive,
        attributes: .concurrent
    )

    private static let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    /// Accessibility requests for an element in Barline's own process are not
    /// IPC: HIServices calls AppKit's accessibility implementation directly on
    /// the calling thread, and AppKit is not thread-safe. Answering our own
    /// menu bar items from this background queue raced the main thread while
    /// the shelf opened and closed, and crashed inside AppKit
    /// (`ConvertOutgoingValueForAttribute` on this queue, and an over-release
    /// while the main thread served a hit test). Run those requests on the main
    /// thread; every other process keeps the background queue. The process is
    /// checked before taking the queue, so no thread holds this queue while it
    /// waits for the main thread.
    private static func run<T>(on element: AXUIElement, _ body: () -> T) -> T {
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
              owner == ownProcessIdentifier
        else {
            return queue.sync(execute: body)
        }
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    @discardableResult
    static func isProcessTrusted(prompt: Bool = false) -> Bool {
        queue.sync { checkIsProcessTrusted(prompt: prompt) }
    }

    static func element(at point: CGPoint) -> UIElement? {
        queue.sync { try? systemWideElement.elementAtPosition(Float(point.x), Float(point.y)) }
    }

    static func application(for runningApp: NSRunningApplication) -> Application? {
        queue.sync {
            let application = Application(runningApp)
            // Every AX query is synchronous IPC into the target process. A
            // wedged menu-bar app must not be able to strand Barline's entire
            // inventory refresh for the system default timeout.
            application?.messagingTimeout = 0.25
            return application
        }
    }

    static func extrasMenuBar(for app: Application) -> UIElement? {
        run(on: app.element) {
            guard let element: UIElement = try? app.attribute(.extrasMenuBar) else {
                return nil
            }
            return boundedMenuBarElement(element)
        }
    }

    /// Reads the extras-menu-bar attribute without erasing the AX error. The
    /// disposition contains no application, item, path, or process metadata.
    static func extrasMenuBarResult(
        for app: Application
    ) -> (element: UIElement?, disposition: ElementAttributeReadDisposition) {
        run(on: app.element) {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(
                app.element,
                kAXExtrasMenuBarAttribute as CFString,
                &value
            )
            switch error {
            case .success:
                guard let raw = value as! AXUIElement? else {
                    return (nil, .wrongType)
                }
                return (boundedMenuBarElement(UIElement(raw)), .success)
            case .noValue:
                return (nil, .noValue)
            case .attributeUnsupported:
                return (nil, .unsupported)
            case .cannotComplete:
                return (nil, .cannotComplete)
            case .invalidUIElement:
                return (nil, .invalidElement)
            case .apiDisabled:
                return (nil, .apiDisabled)
            default:
                return (nil, .otherError)
            }
        }
    }

    static func children(for element: UIElement) -> [UIElement] {
        run(on: element.element) {
            let children: [UIElement] = (try? element.arrayAttribute(.children)) ?? []
            return children.map(boundedMenuBarElement)
        }
    }

    /// An app-level AX timeout does not carry over to the menu-bar descendants
    /// returned by another AX request. Bound those elements individually on
    /// macOS 27 so a stalled item cannot hold an inventory for the system
    /// default timeout. Older menu-bar discovery keeps its existing behavior.
    private static func boundedMenuBarElement(_ element: UIElement) -> UIElement {
        if #available(macOS 27.0, *) {
            _ = AXUIElementSetMessagingTimeout(element.element, 0.25)
        }
        return element
    }

    static func isEnabled(_ element: UIElement) -> Bool {
        run(on: element.element) { try? element.attribute(.enabled) } ?? false
    }

    static func frame(for element: UIElement) -> CGRect? {
        run(on: element.element) { try? element.attribute(.frame) }
    }

    static func role(for element: UIElement) -> Role? {
        run(on: element.element) { try? element.role() }
    }

    static func title(for element: UIElement) -> String? {
        run(on: element.element) { try? element.attribute(.title) }
    }

    static func identifier(for element: UIElement) -> String? {
        run(on: element.element) { try? element.attribute(.identifier) }
    }

    static func accessibilityDescription(for element: UIElement) -> String? {
        run(on: element.element) { try? element.attribute(.description) }
    }

    /// Reads only an AX result category, never returning the value. This
    /// distinguishes a genuinely missing identity attribute from an IPC or
    /// stale-element failure that the convenience accessors intentionally
    /// collapse to `nil`.
    static func stringAttributeReadDisposition(
        for element: UIElement,
        attribute: Attribute
    ) -> StringAttributeReadDisposition {
        run(on: element.element) {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(
                element.element,
                attribute.rawValue as CFString,
                &value
            )
            switch error {
            case .success:
                guard let string = value as? String else {
                    return .wrongType
                }
                return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .emptyString
                    : .nonemptyString
            case .noValue:
                return .noValue
            case .attributeUnsupported:
                return .unsupported
            case .cannotComplete:
                return .cannotComplete
            case .invalidUIElement:
                return .invalidElement
            default:
                return .otherError
            }
        }
    }

    /// Checks whether asking the already-collected element for its direct
    /// children is currently viable, without returning any child metadata.
    static func childrenReadDisposition(for element: UIElement) -> ChildrenReadDisposition {
        run(on: element.element) {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(
                element.element,
                Attribute.children.rawValue as CFString,
                &value
            )
            switch error {
            case .success, .noValue:
                return .success
            case .attributeUnsupported:
                return .unsupported
            case .cannotComplete:
                return .transientError
            case .invalidUIElement:
                return .invalidElement
            default:
                return .otherError
            }
        }
    }

    /// AXUIElementGetPid is a bounded, value-free validity probe for an
    /// already-collected element. It never reveals the PID.
    static func isElementValid(_ element: UIElement) -> Bool {
        run(on: element.element) {
            var processIdentifier: pid_t = 0
            return AXUIElementGetPid(element.element, &processIdentifier) == .success
        }
    }

    static func pid(for element: UIElement) -> pid_t? {
        queue.sync { try? element.pid() }
    }
}
