import CoreGraphics
import Foundation

/// Exercises the production delivery state without creating a tap or posting
/// an event. These are synchronization tests, not a GUI-delivery certificate.
@main
private enum EventDeliveryTests {
    static func main() async throws {
        concurrentCallbacksDispatchOnlyOnce()
        completionSuppressesLateDispatch()
        inFlightDispatchPrecedesCompletion()
        moveStagesDispatchIndependentlyOnce()
        completionSuppressesBothMoveStages()
        matchedClickRestoresTargetWithoutChangingPayload()
        unrelatedClickIsNotRetargeted()
        try await releaseWithoutIntermediateTransition()
        try await releaseTransportFailurePropagates()
        moveRequiresRequestedPhysicalDestination()
        print("PASS: production event delivery synchronization and routing (10 tests; no taps or posted events)")
    }

    private static func matchedClickRestoresTargetWithoutChangingPayload() {
        for type: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] {
            let expected = routingEvent(type)
            let received = routingEvent(type)
            received.setIntegerValueField(.eventTargetUnixProcessID, value: 999)
            require(HelperClickRouting.restoreTarget(of: received, matching: expected, to: 123), "matched click retargets")
            require(received.getIntegerValueField(.eventTargetUnixProcessID) == 123, "source routing restored before acknowledgement")
            require(received.type == expected.type, "event type preserved")
            for field: CGEventField in [.eventSourceUserData, .mouseEventWindowUnderMousePointer,
                                        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, .mouseEventButtonNumber]
            {
                require(received.getIntegerValueField(field) == expected.getIntegerValueField(field), "payload preserved")
            }
        }
    }

    private static func unrelatedClickIsNotRetargeted() {
        let expected = routingEvent(.rightMouseUp)
        for field: CGEventField in [.eventSourceUserData, .mouseEventWindowUnderMousePointer,
                                    .mouseEventWindowUnderMousePointerThatCanHandleThisEvent]
        {
            let received = routingEvent(.rightMouseUp, mismatching: field)
            received.setIntegerValueField(.eventTargetUnixProcessID, value: 999)
            require(received.getIntegerValueField(field) != expected.getIntegerValueField(field), "test events have distinct matching fields")
            require(!HelperClickRouting.restoreTarget(of: received, matching: expected, to: 123), "unrelated marker or window rejected")
            require(received.getIntegerValueField(.eventTargetUnixProcessID) == 999, "unrelated target untouched")
        }
        let wrongType = routingEvent(.leftMouseUp)
        require(!HelperClickRouting.restoreTarget(of: wrongType, matching: expected, to: 123), "different type rejected")
        require(!HelperClickRouting.restoreTarget(of: expected, matching: expected, to: 0), "invalid PID rejected")
    }

    private static func routingEvent(_ type: CGEventType, mismatching: CGEventField? = nil) -> CGEvent {
        let button: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type,
                            mouseCursorPosition: .zero, mouseButton: button)!
        event.setIntegerValueField(.eventSourceUserData, value: mismatching == .eventSourceUserData ? 9876 : 1234)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: mismatching == .mouseEventWindowUnderMousePointer ? 9876 : 42)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: mismatching == .mouseEventWindowUnderMousePointerThatCanHandleThisEvent ? 9876 : 42)
        return event
    }

    private static func releaseWithoutIntermediateTransition() async throws {
        let events = LockedLog()
        try await HelperMoveSettlement.releaseAndObserve(initialOrigin: 0) { origin in
            require(origin == 0, "no intermediate transition retains the original observation baseline")
            events.append("observe")
            return nil
        } release: {
            events.append("release")
        }
        require(events.values == ["observe", "release", "observe"],
                "no intermediate transition still releases; final placement remains caller-owned")
    }

    private static func releaseTransportFailurePropagates() async throws {
        let events = LockedLog()
        do {
            try await HelperMoveSettlement.releaseAndObserve(initialOrigin: 0) { _ in
                events.append("observe")
                return nil
            } release: {
                throw CancellationError()
            }
            require(false, "release cancellation must propagate for caller cleanup")
        } catch is CancellationError {
            require(events.values == ["observe"], "failed release cannot be treated as settled")
        }
    }

    private static func moveRequiresRequestedPhysicalDestination() {
        func settled(_ changed: Bool, _ section: String, _ displayMatched: Bool) -> Bool {
            HelperMoveSettlement.reachedDestination(
                originChanged: changed,
                observedSection: section,
                requestedSection: "hidden",
                displayMatched: displayMatched
            )
        }
        require(!settled(true, "visible", true), "partial movement does not stop section retries")
        require(!settled(false, "hidden", true), "same-section reorder needs observed movement")
        require(!settled(true, "hidden", false), "move to another display does not settle")
        require(settled(true, "hidden", true), "requested section and display settle")
    }

    private static func moveStagesDispatchIndependentlyOnce() {
        let delivery = HelperEventDelivery()
        let posted = LockedLog()
        for _ in 0 ..< 32 {
            delivery.dispatchOnceWhilePending(stage: .session) { posted.append("session") }
            delivery.dispatchOnceWhilePending(stage: .process) { posted.append("process") }
        }
        require(posted.values == ["session", "process"], "both intentional move stages dispatch once")
        delivery.finish()
    }

    private static func completionSuppressesBothMoveStages() {
        let delivery = HelperEventDelivery()
        let posted = LockedLog()
        delivery.dispatchOnceWhilePending(stage: .session) { posted.append("session") }
        delivery.finish()
        delivery.dispatchOnceWhilePending(stage: .session) { posted.append("late-session") }
        delivery.dispatchOnceWhilePending(stage: .process) { posted.append("late-process") }
        require(posted.values == ["session"], "completion prevents a late second-stage command-down")
    }

    private static func concurrentCallbacksDispatchOnlyOnce() {
        let delivery = HelperEventDelivery()
        let posted = LockedLog()
        let callbacks = DispatchGroup()
        for _ in 0 ..< 128 {
            callbacks.enter()
            DispatchQueue.global().async {
                delivery.dispatchOnceWhilePending { posted.append("post") }
                callbacks.leave()
            }
        }
        require(callbacks.wait(timeout: .now() + 3) == .success, "concurrent callbacks finish within budget")
        require(posted.values == ["post"], "concurrent callbacks post exactly once")
        delivery.finish()
    }

    private static func completionSuppressesLateDispatch() {
        let delivery = HelperEventDelivery()
        let posted = LockedLog()
        delivery.finish()
        let callbacks = DispatchGroup()
        for _ in 0 ..< 32 {
            callbacks.enter()
            DispatchQueue.global().async {
                delivery.dispatchOnceWhilePending { posted.append("late-post") }
                callbacks.leave()
            }
        }
        require(callbacks.wait(timeout: .now() + 3) == .success, "late callbacks finish within budget")
        require(posted.values.isEmpty, "completed delivery suppresses every late post")
    }

    private static func inFlightDispatchPrecedesCompletion() {
        let delivery = HelperEventDelivery()
        let events = LockedLog()
        let enteredPost = DispatchSemaphore(value: 0)
        let releasePost = DispatchSemaphore(value: 0)
        let completionRequested = DispatchSemaphore(value: 0)
        let completionReturned = DispatchSemaphore(value: 0)
        let dispatchReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            delivery.dispatchOnceWhilePending {
                events.append("post-started")
                enteredPost.signal()
                require(releasePost.wait(timeout: .now() + 3) == .success, "post release arrives within budget")
                events.append("post-enqueued")
            }
            dispatchReturned.signal()
        }
        require(enteredPost.wait(timeout: .now() + 3) == .success, "dispatch enters the protected post")
        DispatchQueue.global().async {
            completionRequested.signal()
            delivery.finish()
            events.append("completion-returned")
            completionReturned.signal()
        }
        require(completionRequested.wait(timeout: .now() + 3) == .success, "completion attempt starts")
        // The post closure deliberately stays in flight while another thread
        // completes. A completion must not let cleanup-up overtake this down.
        require(completionReturned.wait(timeout: .now() + .milliseconds(100)) == .timedOut,
                "completion cannot return while the post closure is in flight")
        releasePost.signal()
        require(dispatchReturned.wait(timeout: .now() + 3) == .success, "dispatch returns after enqueue")
        require(completionReturned.wait(timeout: .now() + 3) == .success, "completion returns after dispatch")
        require(events.values == ["post-started", "post-enqueued", "completion-returned"],
                "post enqueue precedes completion and cleanup")
        delivery.dispatchOnceWhilePending { events.append("forbidden-replay") }
        require(events.values.count == 3, "completed dispatch cannot replay")
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAIL: \(message)")
            exit(1)
        }
    }
}

private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [String]()

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}
