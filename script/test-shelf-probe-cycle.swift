import Foundation

@main
struct ShelfProbeCycleTests {
    enum ObservationError: Error, Sendable { case foregroundInterrupted }

    static func main() throws {
        var clicks = 0
        let success = try ShelfProbeCycle.run(
            baselineClosed: { true }, click: { clicks += 1 },
            waitForOpen: { 42 }, waitForClose: { true }
        )
        precondition(success == 42 && clicks == 2)

        clicks = 0
        do {
            _ = try ShelfProbeCycle.run(
                baselineClosed: { throw ObservationError.foregroundInterrupted }, click: { clicks += 1 },
                waitForOpen: { fatalError("unknown baseline must not start observation") },
                waitForClose: { fatalError("unknown baseline must not close") }
            )
            fatalError("unreadable baseline must throw without clicking")
        } catch ObservationError.foregroundInterrupted {
            precondition(clicks == 0)
        }
        clicks = 0
        let openFailure = try ShelfProbeCycle.run(
            baselineClosed: { true }, click: { clicks += 1 },
            waitForOpen: { nil }, waitForClose: { fatalError("must not close an unopened shelf") }
        )
        precondition(openFailure == nil && clicks == 1)

        clicks = 0
        do {
            _ = try ShelfProbeCycle.run(
                baselineClosed: { true }, click: { clicks += 1 },
                waitForOpen: { 42 }, waitForClose: { false }
            )
            fatalError("a missed close must fail the current cycle")
        } catch ShelfProbeCycle.Failure.closeTimedOut {
            precondition(clicks == 2)
        }
        clicks = 0
        do {
            _ = try ShelfProbeCycle.run(
                baselineClosed: { false }, click: { clicks += 1 },
                waitForOpen: { 42 }, waitForClose: { true }
            )
            fatalError("an unclosed baseline cannot start the next cycle")
        } catch ShelfProbeCycle.Failure.baselineStillOpen {
            precondition(clicks == 0)
        }
        clicks = 0
        do {
            _ = try ShelfProbeCycle.run(
                baselineClosed: { true }, click: { clicks += 1 },
                waitForOpen: { throw ObservationError.foregroundInterrupted },
                waitForClose: { fatalError("must not click again after interrupted observation") }
            )
            fatalError("interrupted opening must propagate separately from timeout")
        } catch ObservationError.foregroundInterrupted {
            precondition(clicks == 1)
        }
        clicks = 0
        do {
            _ = try ShelfProbeCycle.run(
                baselineClosed: { true }, click: { clicks += 1 },
                waitForOpen: { 42 }, waitForClose: { throw ObservationError.foregroundInterrupted }
            )
            fatalError("interrupted closing must propagate separately from timeout")
        } catch ObservationError.foregroundInterrupted {
            precondition(clicks == 2)
        }
        print("PASS: seven shelf cycle cases: success, open timeout, close timeout, baseline, unreadable baseline, interrupted open/close")

        clicks = 0
        do {
            _ = try ShelfProbeCycle.retryIfClosed(
                isVisible: { throw ObservationError.foregroundInterrupted }, click: { clicks += 1 }
            )
            fatalError("unknown retry state must throw")
        } catch ObservationError.foregroundInterrupted { precondition(clicks == 0) }
        let alreadyOpen = try ShelfProbeCycle.retryIfClosed(isVisible: { true }, click: { clicks += 1 })
        precondition(!alreadyOpen && clicks == 0)
        let knownClosed = try ShelfProbeCycle.retryIfClosed(isVisible: { false }, click: { clicks += 1 })
        precondition(knownClosed && clicks == 1)
        print("PASS: delayed-feedback retry aborts on unknown, preserves late opening, clicks once only when known closed")

        let successfulObservation = ConcurrentObservation<Int> { _ in 42 }
        let successfulValue = try successfulObservation.value()
        let repeatedValue = try successfulObservation.value()
        precondition(successfulValue == 42)
        precondition(repeatedValue == 42)

        let failedObservation = ConcurrentObservation<Int> { _ in
            throw ObservationError.foregroundInterrupted
        }
        do {
            _ = try failedObservation.value()
            fatalError("a concurrent observation error must propagate")
        } catch ObservationError.foregroundInterrupted {}

        let cancellationStart = ContinuousClock.now
        let cancelledObservation = ConcurrentObservation<Bool> { isCancelled in
            while !isCancelled() {
                usleep(5000)
            }
            return true
        }
        cancelledObservation.cancel()
        let observedCancellation = try cancelledObservation.value()
        precondition(observedCancellation)
        precondition(cancellationStart.duration(to: .now) < .seconds(2))

        let dispatchGate = DispatchSemaphore(value: 0)
        let beganPolling = DispatchSemaphore(value: 0)
        let overlappingObservation = ConcurrentObservation<Bool> { _ in
            beganPolling.signal()
            dispatchGate.wait()
            return true
        }
        precondition(beganPolling.wait(timeout: .now() + .seconds(2)) == .success)
        dispatchGate.signal()
        let observedOverlap = try overlappingObservation.value()
        precondition(observedOverlap)

        print("PASS: concurrent observation value, error, cancellation, idempotency, and pre-dispatch overlap")
    }
}
