//
//  XPCMenuBarBackend.swift
//  Barline
//

import BarlineCore
import Foundation

actor XPCMenuBarBackend: MenuBarBackend {
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
        try await connection.move(operation)
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
        try await connection.restore(snapshot)
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
