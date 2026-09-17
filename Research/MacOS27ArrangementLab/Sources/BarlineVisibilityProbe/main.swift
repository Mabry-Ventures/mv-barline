import AppKit
import ArrangementLabCore
import AssessmentModeBridge
import Foundation

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case runtimeUnavailable
    case activationRejected
    case activationTimedOut
    case commitFailed

    var description: String {
        switch self {
        case .usage:
            "usage: BarlineVisibilityProbe hold READY STOP ENDED [concealed-bundle-id ...]"
        case .runtimeUnavailable: "assessment runtime unavailable"
        case .activationRejected: "assessment activation rejected"
        case .activationTimedOut: "assessment activation timed out"
        case .commitFailed: "assessment commit failed"
        }
    }
}

@main
struct VisibilityProbeMain {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5,
              arguments[1] == "hold",
              arguments[2].hasPrefix("/"),
              arguments[3].hasPrefix("/"),
              arguments[4].hasPrefix("/")
        else { throw ProbeError.usage }
        let readyURL = URL(fileURLWithPath: arguments[2])
        let stopURL = URL(fileURLWithPath: arguments[3])
        let endedURL = URL(fileURLWithPath: arguments[4])
        let concealed = arguments.dropFirst(5).map { $0.lowercased() }
        guard Set(concealed).count == concealed.count,
              concealed.allSatisfy({ !$0.isEmpty })
        else { throw ProbeError.usage }

        guard let controller = BLNLabAssessmentCreate() else {
            throw ProbeError.runtimeUnavailable
        }
        defer {
            BLNLabAssessmentInvalidate(controller)
            BLNLabAssessmentDestroy(controller)
        }

        let token = BLNLabAssessmentBegin(controller, concealed as CFArray)
        guard token != 0 else { throw ProbeError.activationRejected }
        var didCommit = false
        defer {
            if !didCommit {
                _ = BLNLabAssessmentAbort(controller, token)
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        activationLoop: while ContinuousClock.now < deadline {
            switch BLNLabAssessmentState(controller, token) {
            case 1:
                guard BLNLabAssessmentCommit(controller, token) else {
                    throw ProbeError.commitFailed
                }
                didCommit = true
                break activationLoop
            case -1:
                throw ProbeError.activationRejected
            case -2:
                throw ProbeError.activationRejected
            default:
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        guard didCommit else { throw ProbeError.activationTimedOut }

        try writeReceipt(
            to: readyURL,
            sequence: 1,
            concealed: concealed,
            active: true
        )
        while !FileManager.default.fileExists(atPath: stopURL.path) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        BLNLabAssessmentInvalidate(controller)
        try writeReceipt(
            to: endedURL,
            sequence: 2,
            concealed: concealed,
            active: false
        )
    }

    private static func writeReceipt(
        to url: URL,
        sequence: Int,
        concealed: [String],
        active: Bool
    ) throws {
        let receipt = VisibilityProbeReceipt(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            sequence: sequence,
            concealedBundleIdentifiers: concealed,
            active: active
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }
}
