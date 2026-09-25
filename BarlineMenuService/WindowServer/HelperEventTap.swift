import CoreGraphics
import Foundation

/// Restore the source application's routing field only for this delivery's
/// exact event. Session routing may have replaced the field since posting.
/// This preserves the compatibility baseline; transport is not an activation
/// certificate and must still be checked against the target's actual interface.
enum HelperClickRouting {
    static func restoreTarget(of received: CGEvent, matching expected: CGEvent, to pid: pid_t) -> Bool {
        let fields: [CGEventField] = [
            .eventSourceUserData,
            .mouseEventWindowUnderMousePointer,
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        ]
        guard pid > 0, received.type == expected.type,
              fields.allSatisfy({ received.getIntegerValueField($0) == expected.getIntegerValueField($0) })
        else { return false }
        received.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        return true
    }
}

/// Intermediate geometry is optional; only the caller's final placement
/// postcondition can certify a drag. Transport errors still propagate.
enum HelperMoveSettlement {
    /// A geometry change alone can be an intermediate drag position. Keep
    /// retrying until the item reaches the requested physical section and
    /// display; the coordinator separately verifies the exact logical slot.
    static func reachedDestination<Section: Equatable>(
        originChanged: Bool,
        observedSection: Section,
        requestedSection: Section,
        displayMatched: Bool
    ) -> Bool {
        originChanged && observedSection == requestedSection && displayMatched
    }

    static func releaseAndObserve<Origin: Sendable>(
        initialOrigin: Origin,
        observeChange: (Origin) async throws -> Origin?,
        release: () async throws -> Void
    ) async throws {
        let intermediate = try await observeChange(initialOrigin)
        try await release()
        _ = try await observeChange(intermediate ?? initialOrigin)
    }
}

/// A helper-owned event tap used to deliver menu bar events through the
/// WindowServer event stream. Raw event routing must remain inside the XPC
/// compatibility service.
final class HelperEventTap: @unchecked Sendable {
    enum Location {
        case session
        case process(pid_t)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let tap = Unmanaged<HelperEventTap>.fromOpaque(refcon).takeUnretainedValue()
        return withExtendedLifetime(tap) {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                tap.enable()
                return nil
            }
            guard tap.isEnabled else {
                return Unmanaged.passUnretained(event)
            }
            return tap.handler(tap, event).map(Unmanaged.passUnretained)
        }
    }

    private let runLoop = CFRunLoopGetMain()
    private let handler: (HelperEventTap, CGEvent) -> CGEvent?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isEnabled: Bool {
        port.map(CGEvent.tapIsEnabled) ?? false
    }

    var isValid: Bool {
        port.map(CFMachPortIsValid) ?? false
    }

    init(
        type: CGEventType,
        location: Location,
        placement: CGEventTapPlacement,
        options: CGEventTapOptions,
        handler: @escaping (HelperEventTap, CGEvent) -> CGEvent?
    ) {
        self.handler = handler
        let mask = CGEventMask(1) << type.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let port: CFMachPort? = switch location {
        case .session:
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: placement,
                options: options,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: refcon
            )
        case let .process(pid):
            CGEvent.tapCreateForPid(
                pid: pid,
                place: placement,
                options: options,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: refcon
            )
        }
        guard let port,
              let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        else {
            return
        }
        self.port = port
        self.source = source
    }

    deinit {
        disable()
        if let port {
            CFMachPortInvalidate(port)
        }
    }

    func enable() {
        guard let port, let source else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        if !CFRunLoopContainsSource(runLoop, source, .commonModes) {
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }
    }

    func disable() {
        guard let port, let source else { return }
        if CFRunLoopContainsSource(runLoop, source, .commonModes) {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: port, enable: false)
    }
}

/// Serializes completion, timeout, and cancellation for one event delivery.
final class HelperEventDelivery: @unchecked Sendable {
    enum DispatchStage: Hashable {
        case session
        case process
    }

    enum DeliveryError: Error {
        case unavailable(stage: Int)
        case timedOut
    }

    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var taps = [HelperEventTap]()
        var completed = false
        var terminalError: (any Error)?
        var dispatchedStages = Set<DispatchStage>()
    }

    private let state = NSLock()
    private var storage = State()

    /// Order a single real-event post against cancellation/timeout completion.
    /// A late barrier callback must never enqueue down after cleanup enqueues up.
    func dispatchOnceWhilePending(stage: DispatchStage = .session, _ post: () -> Void) {
        state.lock()
        defer { state.unlock() }
        guard !storage.completed, storage.dispatchedStages.insert(stage).inserted else { return }
        post()
    }

    func run(
        taps: [HelperEventTap],
        timeout: Duration,
        start: () -> Void
    ) async throws {
        if let index = taps.firstIndex(where: { !$0.isValid }) {
            throw DeliveryError.unavailable(stage: index + 1)
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.lock()
                if storage.completed {
                    let error = storage.terminalError ?? CancellationError()
                    state.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                storage.continuation = continuation
                storage.taps = taps
                state.unlock()

                taps.forEach { $0.enable() }
                if let index = taps.firstIndex(where: { !$0.isEnabled }) {
                    taps.forEach { $0.disable() }
                    complete(throwing: DeliveryError.unavailable(stage: index + 1))
                    return
                }

                state.lock()
                let shouldStart = !storage.completed
                state.unlock()
                guard shouldStart else {
                    taps.forEach { $0.disable() }
                    return
                }
                start()

                Task.detached { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.complete(throwing: DeliveryError.timedOut)
                }
            }
        } onCancel: {
            complete(throwing: CancellationError())
        }
    }

    func finish() {
        complete(throwing: nil)
    }

    private func complete(throwing error: (any Error)?) {
        state.lock()
        guard !storage.completed else {
            state.unlock()
            return
        }
        storage.completed = true
        storage.terminalError = error
        let continuation = storage.continuation
        let taps = storage.taps
        storage.continuation = nil
        storage.taps.removeAll()
        state.unlock()

        taps.forEach { $0.disable() }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
