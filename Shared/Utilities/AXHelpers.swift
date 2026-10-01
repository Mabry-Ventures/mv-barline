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
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    return (nil, .wrongType)
                }
                let raw = unsafeDowncast(value, to: AXUIElement.self)
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

    /// Authority scans use this typed path, not the coarse legacy inventory
    /// disposition. Unsupported and no-value cannot prove complete coverage.
    static func boundedExtrasMenuBar(
        for app: Application, deadline: UInt64, cancellation: AXReadCancellation
    ) -> AXElementRead {
        guard !Task.isCancelled, !cancellation.isCancelled else { return .failure(AXReadFailure(.cancelled)) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        let observed: AXElementRead = run(on: app.element) {
            defer { _ = AXUIElementSetMessagingTimeout(app.element, 0.25) }
            return AXIdentityReadSupport.element(
                deadline: deadline,
                now: { DispatchTime.now().uptimeNanoseconds },
                cancelled: { cancellation.isCancelled },
                setTimeout: { AXUIElementSetMessagingTimeout(app.element, $0) },
                copy: {
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app.element, kAXExtrasMenuBarAttribute as CFString, &value)
                    return (status, value)
                },
                adopt: { AXUIElementSetMessagingTimeout($0, 0.25) }
            )
        }
        guard !Task.isCancelled, !cancellation.isCancelled else { return .failure(AXReadFailure(.cancelled)) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        return observed
    }

    /// Reads one node's exact identity tuple without combining descendants,
    /// normalizing strings or converting a failed read into an absent value.
    static func identityAttributes(
        for element: UIElement, deadline: UInt64, cancellation: AXReadCancellation
    ) -> AXIdentityRead {
        guard !Task.isCancelled, !cancellation.isCancelled else { return .failure(AXReadFailure(.cancelled)) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        let observed: AXIdentityRead = run(on: element.element) {
            defer { _ = AXUIElementSetMessagingTimeout(element.element, 0.25) }
            let result = AXIdentityReadSupport.perform(
                deadline: deadline,
                now: { DispatchTime.now().uptimeNanoseconds },
                cancelled: { cancellation.isCancelled },
                setTimeout: { AXUIElementSetMessagingTimeout(element.element, $0) }
            ) {
                var values: CFArray?
                let status = AXUIElementCopyMultipleAttributeValues(
                    element.element,
                    [kAXIdentifierAttribute, kAXRoleAttribute, kAXSubroleAttribute] as CFArray,
                    [], &values
                )
                return AXIdentityReadSupport.decodeIdentity(status: status, values: values)
            }
            switch result {
            case let .success(attributes): return attributes
            case let .failure(error): return .failure(error)
            }
        }
        guard !Task.isCancelled, !cancellation.isCancelled else { return .failure(AXReadFailure(.cancelled)) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        return observed
    }

    /// Unknown/unsupported is distinct from a successful empty sibling list.
    /// The reader never fetches an unbounded array and truncates it afterward.
    /// Matching counts do not attest membership; the scan must bind exact
    /// identities, lifetimes and the observation receipt separately.
    static func boundedChildren(
        for element: UIElement, maximumCount: Int, deadline: UInt64, cancellation: AXReadCancellation
    ) -> AXChildrenRead {
        guard !Task.isCancelled, !cancellation.isCancelled else { return .failure(AXReadFailure(.cancelled)) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        let observed: AXChildrenRead = run(on: element.element) {
            defer { _ = AXUIElementSetMessagingTimeout(element.element, 0.25) }
            let result = AXIdentityReadSupport.children(
                maximumCount: maximumCount, deadline: deadline,
                now: { DispatchTime.now().uptimeNanoseconds },
                cancelled: { cancellation.isCancelled },
                setTimeout: { AXUIElementSetMessagingTimeout(element.element, $0) },
                count: {
                    var count: CFIndex = 0
                    let status = AXUIElementGetAttributeValueCount(element.element, kAXChildrenAttribute as CFString, &count)
                    return (status, count)
                },
                copy: { maximum in
                    var values: CFArray?
                    let status = AXUIElementCopyAttributeValues(
                        element.element, kAXChildrenAttribute as CFString, 0, maximum, &values
                    )
                    return (status, values)
                }
            )
            if case let .elements(children) = result {
                for child in children {
                    guard !cancellation.isCancelled else { return .failure(AXReadFailure(.cancelled)) }
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
                    let status = AXUIElementSetMessagingTimeout(child, 0.25)
                    guard status == .success else { return .failure(AXIdentityReadSupport.failure(status)) }
                }
            }
            return result
        }
        guard !Task.isCancelled, !cancellation.isCancelled else { return .failure(AXReadFailure(.cancelled)) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        return observed
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

    static func parent(of element: UIElement) -> UIElement? {
        run(on: element.element) { try? element.attribute(.parent) }
    }

    static func press(_ element: UIElement) -> Bool {
        run(on: element.element) { (try? element.performAction(.press)) != nil }
    }

    /// The clock bridge must not inherit the system's multi-second AX timeout.
    /// Each operation is admitted against the remaining click budget. A timeout
    /// set on a system-wide handle is process-global, so scope that query on the
    /// shared barrier and restore the default before admitting other AX work.
    static func clockElement(at point: CGPoint, deadline: UInt64) -> UIElement? {
        systemRead(deadline: deadline, maximumTimeout: 0.05) { system in
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                system.element, Float(point.x), Float(point.y), &hit
            ) == .success, let hit else { return nil }
            return UIElement(hit)
        }
    }

    static func focusedElement() -> AXUIElement? {
        systemRead(maximumTimeout: 0.05) { system in
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                system.element, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
            else { return nil }
            return unsafeDowncast(focused, to: AXUIElement.self)
        }
    }

    private static func systemRead<T>(
        deadline: UInt64 = .max,
        maximumTimeout: Double,
        _ operation: (UIElement) -> T?
    ) -> T? {
        queue.sync(flags: .barrier) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard !Task.isCancelled, now < deadline else { return nil }
            let system = UIElement(AXUIElementCreateSystemWide())
            let timeout = Float(min(Double(deadline - now) / 1_000_000_000, maximumTimeout))
            guard AXUIElementSetMessagingTimeout(system.element, timeout) == .success else { return nil }
            defer { _ = AXUIElementSetMessagingTimeout(system.element, 0) }
            let value = operation(system)
            return DispatchTime.now().uptimeNanoseconds < deadline ? value : nil
        }
    }

    static func clockIdentifier(for element: UIElement, deadline: UInt64) -> String? {
        clockRead(on: element, deadline: deadline) { try? element.attribute(.identifier) }
    }

    static func clockParent(of element: UIElement, deadline: UInt64) -> UIElement? {
        clockRead(on: element, deadline: deadline) { try? element.attribute(.parent) }
    }

    static func pressClock(
        _ element: UIElement,
        deadline: UInt64,
        isCurrent: () -> Bool
    ) -> Bool {
        clockRead(on: element, deadline: deadline, rejectLateResult: false) {
            // Resolution may have consumed the remaining budget or a newer
            // physical click may have arrived. Check at the action, not before
            // the potentially blocking live hit-test.
            guard isCurrent(), !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            return (try? element.performAction(.press)) != nil
        } ?? false
    }

    private static func clockRead<T>(
        on element: UIElement,
        deadline: UInt64,
        rejectLateResult: Bool = true,
        _ operation: () -> T?
    ) -> T? {
        run(on: element.element) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard !Task.isCancelled, now < deadline else { return nil }
            let timeout = Float(min(Double(deadline - now) / 1_000_000_000, 0.05))
            guard AXUIElementSetMessagingTimeout(element.element, timeout) == .success else { return nil }
            let value = operation()
            guard !rejectLateResult || DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            return value
        }
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
