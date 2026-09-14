//
//  BarlineMenuService.swift
//  Shared
//

import BarlineCore
import Foundation

enum BarlineMenuService {
    static var name: String {
        requiredIdentity(forInfoKey: "BarlineMenuServiceName")
    }

    static func requiredIdentity(forInfoKey key: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            preconditionFailure("Required product identity is missing")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else {
            preconditionFailure("Required product identity is unresolved")
        }
        return value
    }
}

extension BarlineMenuService {
    enum Request: Codable, Sendable {
        case start
        case capabilities
        case snapshot
        case move(MenuBarMoveOperation, deadlineUptimeNanoseconds: UInt64)
        case reveal(MenuBarItemID, deadlineUptimeNanoseconds: UInt64)
        case activate(
            item: MenuBarItemID,
            button: MenuBarMouseButton,
            deadlineUptimeNanoseconds: UInt64
        )
        case capture([MenuBarItemID])
        case captureBackground(displayID: UInt32, sampleHeight: Double?)
        case environment
        case configureCursorInBackground(Bool)
        case configureConcealment(MenuBarConcealmentConfiguration)
        case pointContext(MenuBarPoint)
        case shelfPresentationObservation(MenuBarShelfPresentationProbe)
        case beginRevealObservation(MenuBarItemID)
        case revealObservationIsVisible(MenuBarRevealObservationToken)
        case endRevealObservation(MenuBarRevealObservationToken)
        case restore(MenuBarSnapshot, deadlineUptimeNanoseconds: UInt64)
        case health
        case restart
    }

    enum Response: Codable, Sendable {
        case start
        case capabilities(ServiceResult<MenuBarCapabilities>)
        case snapshot(ServiceResult<MenuBarSnapshot>)
        case mutation(ServiceResult<MenuBarMutationResult>)
        case activation(ServiceResult<EmptyResult>)
        case capturedImages(ServiceResult<[MenuBarCapturedImage]>)
        case background(ServiceResult<MenuBarBackgroundCapture>)
        case environment(ServiceResult<MenuBarEnvironmentSnapshot>)
        case pointContext(ServiceResult<MenuBarPointContext>)
        case shelfPresentationObservation(ServiceResult<MenuBarShelfPresentationObservation>)
        case revealObservation(ServiceResult<MenuBarRevealObservationToken>)
        case boolean(ServiceResult<Bool>)
        case health(MenuBarBackendHealth)
        case restart
    }

    enum ServiceResult<Value: Codable & Sendable>: Codable, Sendable {
        case success(Value)
        case failure(MenuBarBackendError)
    }

    struct EmptyResult: Codable, Sendable {}
}
