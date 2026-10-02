/// A failed close must never be accepted as a successful sample: the next click
/// would close the previous shelf and be misreported as an opening failure.
enum ShelfProbeCycle {
    enum Failure: Error, Equatable {
        case baselineStillOpen
        case closeTimedOut
    }

    /// A delayed-feedback retry is allowed only after a fresh, known-closed
    /// observation. Unknown is an error, and an opening that arrived after the
    /// deadline must not be cancelled by an automatic second click.
    static func retryIfClosed(isVisible: () throws -> Bool, click: () throws -> Void) throws -> Bool {
        guard try !isVisible() else { return false }
        try click()
        return true
    }

    static func run(
        baselineClosed: () throws -> Bool,
        click: () throws -> Void,
        waitForOpen: () throws -> Double?,
        waitForClose: () throws -> Bool
    ) throws -> Double? {
        guard try baselineClosed() else { throw Failure.baselineStillOpen }
        try click()
        guard let latency = try waitForOpen() else { return nil }
        try click()
        guard try waitForClose() else { throw Failure.closeTimedOut }
        return latency
    }
}
