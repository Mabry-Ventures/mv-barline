//
//  XPCMenuBarBackend.swift
//  Barline
//

import BarlineCore
import Foundation
import OSLog

actor XPCMenuBarBackend: MenuBarBackend {
    private static let logger = Logger(subsystem: "com.mabryventures.Barline", category: "ConcealmentBoundary")
    private let connection = BarlineMenuService.Connection.shared
    private let goldenGateProvider = GoldenGateAXSnapshotProvider()

    var capabilities: MenuBarCapabilities {
        get async {
            if #available(macOS 27.0, *) {
                return await goldenGateProvider.capabilities
            }
            return await (try? connection.capabilities()) ?? .fallback
        }
    }

    func snapshot() async throws -> MenuBarSnapshot {
        if #available(macOS 27.0, *) {
            return try await goldenGateProvider.snapshot()
        }
        return try await connection.snapshot()
    }

    func move(_ operation: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
        if #available(macOS 27.0, *) {
            return try await goldenGateProvider.move(operation)
        }
        return try await connection.move(operation)
    }

    func reveal(_ item: MenuBarItemID) async throws -> MenuBarMutationResult {
        try await connection.reveal(item)
    }

    func activate(_ item: MenuBarItemID, button: MenuBarMouseButton) async throws {
        if #available(macOS 27.0, *), button == .left {
            try Task.checkCancellation()
            try await goldenGateProvider.activate(item, button: button)
        } else {
            try await connection.activate(item, button: button)
        }
    }

    func capture(_ items: [MenuBarItemID]) async throws -> [MenuBarCapturedImage] {
        try await connection.capture(items)
    }

    func captureBackground(
        displayID: UInt32,
        sampleHeight: Double?
    ) async throws -> MenuBarBackgroundCapture {
        try await connection.captureBackground(
            displayID: displayID,
            sampleHeight: sampleHeight.map { CGFloat($0) }
        )
    }

    func environment() async throws -> MenuBarEnvironmentSnapshot {
        try await connection.environment()
    }

    func pointContext(_ point: MenuBarPoint) async throws -> MenuBarPointContext {
        try await connection.pointContext(at: CGPoint(x: point.x, y: point.y))
    }

    func configureConcealment(
        _ configuration: MenuBarConcealmentConfiguration
    ) async throws {
        if #available(macOS 27.0, *) {
            // Accessibility inventory belongs to the signed application, while
            // the native assessment assertion belongs to the helper. Validate
            // and retain the complete inventory before the helper can remove
            // concealed items from the AX tree.
            let snapshot = try await goldenGateProvider.snapshot()
            let liveItemIDs = snapshot.items.filter { !$0.isBarlineControlItem }.map(\.id)
            // Applications that render live values in their menu bar title
            // (processor load, transfer rates, battery state) change item
            // identity between the snapshot this configuration was computed
            // from and the one validating it. Such an item is simply not
            // present to conceal, so drop it instead of rejecting every other
            // assignment along with it.
            let configuration = configuration.retainingOnly(Set(liveItemIDs))
            let resolution = GoldenGateConcealmentPolicy.resolve(
                configuration,
                barlineBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.mabryventures.Barline"
            )
            Self.logger.notice(
                "Concealment boundary: live=\(liveItemIDs.count, privacy: .public) visible=\(configuration.visibleItemIDs.count, privacy: .public) hidden=\(configuration.concealedItemIDs.count, privacy: .public) concealedBundles=\(resolution.concealedBundleIdentifiers.count, privacy: .public)"
            )
            guard GoldenGateConcealmentPolicy.supports(
                configuration,
                allItems: liveItemIDs,
                barlineBundleIdentifier: Bundle.main.bundleIdentifier
                    ?? "com.mabryventures.Barline"
            ) else {
                throw MenuBarBackendError.operationFailed(
                    "menu bar visibility assignment is not supported"
                )
            }
            try await connection.configureConcealment(configuration)
            await goldenGateProvider.concealmentDidChange()
        } else {
            try await connection.configureConcealment(configuration)
        }
    }

    func beginRevealObservation(_ item: MenuBarItemID) async throws -> MenuBarRevealObservationToken {
        try await connection.beginRevealObservation(for: item)
    }

    func revealObservationIsVisible(_ token: MenuBarRevealObservationToken) async throws -> Bool {
        try await connection.revealObservationIsVisible(token)
    }

    func endRevealObservation(_ token: MenuBarRevealObservationToken) async {
        await connection.endRevealObservation(token)
    }

    func restore(_ snapshot: MenuBarSnapshot) async throws -> MenuBarMutationResult {
        if #available(macOS 27.0, *) {
            return try await goldenGateProvider.restore(snapshot)
        }
        return try await connection.restore(snapshot)
    }

    func health() async -> MenuBarBackendHealth {
        if #available(macOS 27.0, *) {
            return await goldenGateProvider.health()
        }
        return await connection.health()
    }

    func restart() async {
        if #available(macOS 27.0, *) {
            await goldenGateProvider.restart()
        }
        await connection.restart()
    }
}
