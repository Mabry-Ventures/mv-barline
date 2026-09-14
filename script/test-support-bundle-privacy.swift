import BarlineCore
import Foundation

enum PrivacyTestFailure: Error, CustomStringConvertible {
    case expectedUnsafeCodeRejection
    case privateValueLeaked(String)
    case invalidShape
    case expectedDestinationRejection
    case invalidFilename

    var description: String {
        switch self {
        case .expectedUnsafeCodeRejection: "unsafe diagnostic code was accepted"
        case let .privateValueLeaked(value): "private sentinel leaked into bundle: \(value)"
        case .invalidShape: "support bundle shape or error bound is invalid"
        case .expectedDestinationRejection: "non-JSON destination was accepted"
        case .invalidFilename: "support bundle filename does not contain the expected UTC date"
        }
    }
}

@main
struct SupportBundlePrivacyTests {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("error: support-bundle privacy test failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let exporter = SupportBundleExporter()
        let permissions = DiagnosticBundle.Permissions(accessibility: true, screenRecording: false)
        let capabilities = MenuBarCapabilities(
            canSnapshot: true,
            canMove: false,
            canReveal: false,
            canActivate: false,
            canRestore: false
        )
        let privatePath = "/Users/private-person/Documents/secret.txt"
        let privateName = "private-person"

        do {
            _ = try await exporter.preview(
                permissions: permissions,
                compatibility: .init(backendName: "Tahoe", state: .degraded),
                capabilities: capabilities,
                itemDiscovery: .init(),
                lastSnapshotAt: nil,
                lastSnapshotRejectionCode: nil,
                searchAvailabilityCode: "fallback",
                recentErrorCodes: [privatePath]
            )
            throw PrivacyTestFailure.expectedUnsafeCodeRejection
        } catch SupportBundleError.unsafeDiagnosticCode {
            // Expected fail-closed behavior.
        }

        let preview = try await exporter.preview(
            permissions: permissions,
            compatibility: .init(
                backendName: "Tahoe",
                state: .degraded,
                message: "failed while reading \(privatePath) for \(privateName)"
            ),
            capabilities: capabilities,
            itemDiscovery: .init(),
            lastSnapshotAt: Date(timeIntervalSince1970: 90),
            lastSnapshotRejectionCode: "snapshot.stale",
            searchAvailabilityCode: "fallback",
            recentErrorCodes: (0 ..< 40).map { "error_\($0)" },
            now: Date(timeIntervalSince1970: 100)
        )

        guard preview.suggestedFilename == "Barline-Support-1970-01-01.json" else {
            throw PrivacyTestFailure.invalidFilename
        }

        let encoded = String(decoding: preview.data, as: UTF8.self)
        for sentinel in [privatePath, privateName, "Documents/secret.txt"] where encoded.contains(sentinel) {
            throw PrivacyTestFailure.privateValueLeaked(sentinel)
        }
        guard
            let object = try JSONSerialization.jsonObject(with: preview.data) as? [String: Any],
            object["schemaVersion"] as? Int == 2,
            object["itemDiscovery"] as? [String: Any] != nil,
            (object["recentErrorCodes"] as? [String])?.count == 25,
            preview.data.count < 64 * 1024
        else {
            throw PrivacyTestFailure.invalidShape
        }

        do {
            try await exporter.write(preview, to: URL(fileURLWithPath: "/tmp/barline-private-bundle.txt"))
            throw PrivacyTestFailure.expectedDestinationRejection
        } catch SupportBundleError.invalidDestination {
            // Expected extension boundary.
        }

        print("PASS: support bundle rejects unsafe codes, redacts private health text, bounds errors, and enforces JSON output")
    }
}
