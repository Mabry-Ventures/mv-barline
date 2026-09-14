import Foundation

public enum GoldenGateAXActivationDisposition: Equatable, Sendable {
    case delivered
    case deliveredIndeterminately
    case failed
}

/// AX can report `kAXErrorCannotComplete` after the target has already handled
/// an action. Retrying that result can toggle a menu closed or perform an
/// action twice, so it is deliberately treated as an indeterminate delivery.
public enum GoldenGateAXActivationPolicy {
    public static func disposition(forAXError rawValue: Int32) -> GoldenGateAXActivationDisposition {
        switch rawValue {
        case 0:
            .delivered
        case -25204:
            .deliveredIndeterminately
        default:
            .failed
        }
    }
}
