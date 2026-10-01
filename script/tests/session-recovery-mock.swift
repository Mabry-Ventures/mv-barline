import Dispatch

// Test-only XPC module. Never link this file into the application or helper.
import Foundation

public struct XPCMockError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public struct XPCDictionary: @unchecked Sendable {
    private var values: [String: Any] = [:]
    private var payload: Data?
    public init() {}
    public init(encoding value: some Encodable) throws {
        payload = try JSONEncoder().encode(value)
    }

    public subscript(key: String) -> Any? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public func decode<Value: Decodable>(as type: Value.Type) throws -> Value {
        guard let payload else { throw XPCMockError("mock reply has no encoded payload") }
        return try JSONDecoder().decode(type, from: payload)
    }
}

public struct XPCPeerRequirement: Sendable {
    public init(lightweightCodeRequirements _: XPCDictionary) {}
    public static func isFromSameTeam(andMatchesSigningIdentifier _: String) -> Self {
        Self(lightweightCodeRequirements: XPCDictionary())
    }
}

public struct XPCMockRequest: Sendable {
    public let serviceName: String
    public let sessionID: Int
    public let data: Data
    public func decode<Value: Decodable>(as type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

public struct XPCMockEvent: Sendable {
    public let serviceName: String
    public let sessionID: Int
    public let kind: String
}

private final class WeakSession: @unchecked Sendable {
    weak var value: XPCSession?
    init(_ value: XPCSession) {
        self.value = value
    }
}

private final class MockRegistry: @unchecked Sendable {
    let condition = NSCondition()
    var nextID = 0
    var handlers: [String: XPCMock.Handler] = [:]
    var sessions: [Int: WeakSession] = [:]
    var events: [XPCMockEvent] = []
    var cancellationHooks: [String: @Sendable () -> Void] = [:]
}

public enum XPCMock {
    public typealias Handler = @Sendable (XPCMockRequest) throws -> XPCDictionary
    private static let registry = MockRegistry()

    public static func install(serviceName: String, handler: @escaping Handler) {
        registry.condition.lock()
        defer { registry.condition.unlock() }
        registry.handlers[serviceName] = handler
    }

    public static func remove(serviceName: String) {
        registry.condition.lock()
        defer { registry.condition.unlock() }
        registry.handlers[serviceName] = nil
        registry.cancellationHooks[serviceName] = nil
    }

    public static func holdCancellation(serviceName: String, hook: @escaping @Sendable () -> Void) {
        registry.condition.lock()
        registry.cancellationHooks[serviceName] = hook
        registry.condition.unlock()
    }

    fileprivate static func beforeCancellation(serviceName: String) {
        registry.condition.lock()
        let hook = registry.cancellationHooks.removeValue(forKey: serviceName)
        registry.condition.unlock()
        hook?()
    }

    fileprivate static func allocate(serviceName: String) throws -> (Int, Handler) {
        registry.condition.lock()
        defer { registry.condition.unlock() }
        guard let handler = registry.handlers[serviceName] else {
            throw XPCMockError("unregistered mock service")
        }
        registry.nextID += 1
        return (registry.nextID, handler)
    }

    fileprivate static func retainWeakly(_ session: XPCSession) {
        registry.condition.lock()
        registry.sessions[session.identifier] = WeakSession(session)
        registry.condition.unlock()
        record(serviceName: session.serviceName, sessionID: session.identifier, kind: "created")
    }

    fileprivate static func record(serviceName: String, sessionID: Int, kind: String) {
        registry.condition.lock()
        registry.events.append(XPCMockEvent(serviceName: serviceName, sessionID: sessionID, kind: kind))
        registry.condition.broadcast()
        registry.condition.unlock()
    }

    public static func events(serviceName: String) -> [XPCMockEvent] {
        registry.condition.lock()
        defer { registry.condition.unlock() }
        return registry.events.filter { $0.serviceName == serviceName }
    }

    public static func waitForEvent(
        serviceName: String, sessionID: Int? = nil, kind: String, timeout: TimeInterval = 3
    ) -> XPCMockEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        registry.condition.lock()
        defer { registry.condition.unlock() }
        while true {
            if let event = registry.events.first(where: {
                $0.serviceName == serviceName && $0.kind == kind &&
                    (sessionID == nil || $0.sessionID == sessionID)
            }) {
                return event
            }
            guard registry.condition.wait(until: deadline) else { return nil }
        }
    }

    public static func interrupt(sessionID: Int) {
        registry.condition.lock()
        let session = registry.sessions[sessionID]?.value
        registry.condition.unlock()
        session?.cancel(reason: "injected external interruption")
    }

    /// Deliver an explicitly late callback from an obsolete session.
    public static func deliverLateCancellation(sessionID: Int) {
        registry.condition.lock()
        let session = registry.sessions[sessionID]?.value
        registry.condition.unlock()
        session?.deliverCancellation(XPCMockError("injected late cancellation"), kind: "late-cancellation-delivered")
    }
}

public final class XPCSession: @unchecked Sendable {
    public struct Options: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let inactive = Self(rawValue: 1)
    }

    public let identifier: Int
    public let serviceName: String
    private let handler: XPCMock.Handler
    private let cancellationHandler: @Sendable (XPCMockError) -> Void
    private let lock = NSLock()
    private var callbackQueue = DispatchQueue.global()
    private var active = false
    private var cancelled = false

    public init(
        xpcService: String, options _: Options,
        cancellationHandler: @escaping @Sendable (XPCMockError) -> Void
    ) throws {
        let (identifier, handler) = try XPCMock.allocate(serviceName: xpcService)
        self.identifier = identifier
        serviceName = xpcService
        self.handler = handler
        self.cancellationHandler = cancellationHandler
        XPCMock.retainWeakly(self)
    }

    public func setPeerRequirement(_: XPCPeerRequirement) {}
    public func setTargetQueue(_ queue: DispatchQueue) {
        lock.lock()
        callbackQueue = queue
        lock.unlock()
    }

    public func activate() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw XPCMockError("activation after cancellation") }
        active = true
    }

    public func cancel(reason _: String) {
        lock.lock()
        let shouldNotify = !cancelled
        cancelled = true
        lock.unlock()
        guard shouldNotify else { return }
        XPCMock.beforeCancellation(serviceName: serviceName)
        XPCMock.record(serviceName: serviceName, sessionID: identifier, kind: "cancelled")
        deliverCancellation(XPCMockError("mock session cancelled"))
    }

    fileprivate func deliverCancellation(_ error: XPCMockError, kind: String = "cancellation-delivered") {
        lock.lock()
        let queue = callbackQueue
        lock.unlock()
        queue.async { [self] in
            cancellationHandler(error)
            XPCMock.record(serviceName: serviceName, sessionID: identifier, kind: kind)
        }
    }

    public func sendSync(_ request: some Encodable) throws -> XPCDictionary {
        lock.lock()
        let admitted = active && !cancelled
        lock.unlock()
        guard admitted else { throw XPCMockError("send on inactive or cancelled session") }
        let encoded = try JSONEncoder().encode(request)
        XPCMock.record(serviceName: serviceName, sessionID: identifier, kind: "send")
        do {
            // Intentionally permit an in-flight handler to return after cancel.
            // The production lease must reject that late response/replay.
            let reply = try handler(XPCMockRequest(serviceName: serviceName, sessionID: identifier, data: encoded))
            XPCMock.record(serviceName: serviceName, sessionID: identifier, kind: "reply")
            return reply
        } catch {
            XPCMock.record(serviceName: serviceName, sessionID: identifier, kind: "send-threw")
            throw error
        }
    }
}
