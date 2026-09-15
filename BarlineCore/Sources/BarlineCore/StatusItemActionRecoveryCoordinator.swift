import Foundation

/// Arbitrates the native status-item target/action path with a delayed fallback.
///
/// Scene-backed status items can expose their hosted window before AppKit has
/// reconnected the button action. A global mouse-down can therefore be observed
/// even though the native action is lost. This coordinator guarantees that one
/// physical click produces at most one action while allowing a bounded fallback.
public struct StatusItemActionRecoveryCoordinator: Sendable {
    private struct PendingClick: Sendable {
        let sequence: UInt64
        let eventTimestamp: TimeInterval
    }

    private var pendingClick: PendingClick?
    private var lastNativeEventTimestamp: TimeInterval?
    private var lastFallbackEventTimestamp: TimeInterval?

    public init() {}

    /// Decides whether a global mouse-down is eligible for status-item action
    /// recovery. A shelf click is already owned by Barline and must never be
    /// reinterpreted as a missing click on the menu-bar control.
    public static func shouldSchedulePrimaryRecovery(
        eventTargetsShelf: Bool,
        eventLocationIsInsideExactButtonFrame: Bool
    ) -> Bool {
        !eventTargetsShelf && eventLocationIsInsideExactButtonFrame
    }

    /// Registers a globally observed mouse-down.
    ///
    /// Returns `true` when the caller should schedule a delayed fallback. If the
    /// native action already handled this exact event, no fallback is needed.
    public mutating func observeMouseDown(
        sequence: UInt64,
        eventTimestamp: TimeInterval
    ) -> Bool {
        if let lastNativeEventTimestamp,
           abs(lastNativeEventTimestamp - eventTimestamp) <= 0.001
        {
            self.lastNativeEventTimestamp = nil
            return false
        }
        pendingClick = PendingClick(sequence: sequence, eventTimestamp: eventTimestamp)
        return true
    }

    /// Claims delivery through AppKit's native target/action path.
    ///
    /// Returns `false` only when the fallback already handled this click.
    public mutating func claimNativeAction(eventTimestamp: TimeInterval) -> Bool {
        if pendingClick != nil {
            pendingClick = nil
            lastNativeEventTimestamp = eventTimestamp
            return true
        }
        if let lastFallbackEventTimestamp,
           abs(eventTimestamp - lastFallbackEventTimestamp) <= 2
        {
            self.lastFallbackEventTimestamp = nil
            return false
        }
        lastNativeEventTimestamp = eventTimestamp
        return true
    }

    /// Claims the delayed fallback for the matching mouse-down sequence.
    public mutating func claimFallback(sequence: UInt64) -> Bool {
        guard let pendingClick, pendingClick.sequence == sequence else {
            return false
        }
        self.pendingClick = nil
        lastFallbackEventTimestamp = pendingClick.eventTimestamp
        return true
    }
}
