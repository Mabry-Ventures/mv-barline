//
//  SupportBundleExporter.swift
//  Barline
//

import BarlineCore
import Foundation

/// A deliberately small, review-before-sharing diagnostics document.
///
/// It contains no screen content, item/profile names, process inventories,
/// paths, environment values, credentials, or unbounded unified logs.
struct DiagnosticBundle: Codable, Sendable {
    struct GoldenGateAXInventory: Codable, Equatable, Sendable {
        let runningApplicationCount: Int
        let applicationElementCount: Int
        let extrasMenuBarReadCounts: [String: Int]
        let extrasMenuBarCount: Int
        let rawChildCount: Int
        let acceptedEntryCount: Int
        let terminalCode: String
        let activeDisplayCount: Int
        let activeScreenAvailable: Bool
        let activeScreenInDisplayList: Bool
        let hiddenControlCount: Int
        let alwaysHiddenControlCount: Int
        let snapshotTerminalCode: String
    }

    struct Application: Codable, Sendable {
        let version: String
        let build: String
    }

    struct System: Codable, Sendable {
        let operatingSystem: String
        let architecture: String
    }

    struct Permissions: Codable, Sendable {
        let accessibility: Bool
        let screenRecording: Bool
    }

    struct Compatibility: Codable, Sendable {
        let backendCode: String
        let state: MenuBarBackendState
    }

    let schemaVersion: Int
    let generatedAt: Date
    let application: Application
    let system: System
    let permissions: Permissions
    let compatibility: Compatibility
    let capabilityFlags: MenuBarCapabilities
    let itemDiscovery: MenuBarItemDiscoveryDiagnostics
    let goldenGateAXInventory: GoldenGateAXInventory?
    let lastSnapshotAgeSeconds: Int?
    let lastSnapshotRejectionCode: String?
    let searchAvailabilityCode: String
    let recentErrorCodes: [String]
}

struct SupportBundlePreview: Sendable {
    let suggestedFilename: String
    let data: Data
    let summary: String
}

enum SupportBundleError: Error, Equatable {
    case unsafeDiagnosticCode
    case invalidDestination
}

/// Performs encoding and file I/O away from the main actor. Callers must show
/// the returned preview and obtain an explicit save destination from the user.
actor SupportBundleExporter {
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    func preview(
        permissions: DiagnosticBundle.Permissions,
        compatibility: MenuBarBackendHealth,
        capabilities: MenuBarCapabilities,
        itemDiscovery: MenuBarItemDiscoveryDiagnostics,
        goldenGateAXInventory: DiagnosticBundle.GoldenGateAXInventory? = nil,
        lastSnapshotAt: Date?,
        lastSnapshotRejectionCode: String?,
        searchAvailabilityCode: String,
        recentErrorCodes: [String],
        now: Date = Date()
    ) throws -> SupportBundlePreview {
        let rejection = try sanitizedCode(lastSnapshotRejectionCode)
        let search = try sanitizedCode(searchAvailabilityCode) ?? "unknown"
        let backendCode = try sanitizedCode(compatibility.backendName) ?? "unknown"
        let errors = try recentErrorCodes.prefix(25).map { code in
            guard let value = try sanitizedCode(code) else {
                throw SupportBundleError.unsafeDiagnosticCode
            }
            return value
        }
        let bundle = DiagnosticBundle(
            schemaVersion: 4,
            generatedAt: now,
            application: .init(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            ),
            system: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: "arm64"
            ),
            permissions: permissions,
            compatibility: .init(backendCode: backendCode, state: compatibility.state),
            capabilityFlags: capabilities,
            itemDiscovery: itemDiscovery,
            goldenGateAXInventory: goldenGateAXInventory,
            lastSnapshotAgeSeconds: lastSnapshotAt.map {
                max(0, Int(now.timeIntervalSince($0).rounded()))
            },
            lastSnapshotRejectionCode: rejection,
            searchAvailabilityCode: search,
            recentErrorCodes: errors
        )
        let data = try encoder.encode(bundle)
        return SupportBundlePreview(
            suggestedFilename: "Barline-Support-\(Self.filenameDate(now)).json",
            data: data,
            summary: "Barline and macOS versions, permission state, compatibility health, discovery counters, and bounded error codes"
        )
    }

    func write(_ preview: SupportBundlePreview, to destination: URL) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "json" else {
            throw SupportBundleError.invalidDestination
        }
        try preview.data.write(to: destination, options: [.atomic, .completeFileProtection])
    }

    private func sanitizedCode(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let bounded = String(value.prefix(96))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:"))
        guard !bounded.isEmpty, bounded.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SupportBundleError.unsafeDiagnosticCode
        }
        return bounded
    }

    private static func filenameDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return formatter.string(from: date)
    }
}
