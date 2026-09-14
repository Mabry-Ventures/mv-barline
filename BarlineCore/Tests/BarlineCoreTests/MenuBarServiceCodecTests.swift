//
//  MenuBarServiceCodecTests.swift
//  Barline
//

@testable import BarlineCore
import Foundation
import Testing

@Suite("Typed menu service codec")
struct MenuBarServiceCodecTests {
    private let itemID = MenuBarItemID(
        bundleIdentifier: "com.example.status",
        accessibilityIdentifier: "primary-status-item"
    )

    @Test("Every typed request survives a Codable round trip")
    func requestRoundTrips() throws {
        let snapshot = makeCodecSnapshot()
        let operation = MenuBarMoveOperation(
            itemID: itemID,
            section: .hidden,
            index: 2,
            destinationDisplayID: MenuBarDisplayID("codec-display")
        )
        let revealUUID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let revealToken = MenuBarRevealObservationToken(value: revealUUID)
        let shelfProbe = MenuBarShelfPresentationProbe(
            ownerProcessIdentifier: 42,
            targetDisplayID: 1
        )
        let requests: [MenuBarServiceRequest] = [
            .start,
            .capabilities,
            .snapshot,
            .move(operation, deadlineUptimeNanoseconds: 10000),
            .reveal(itemID, deadlineUptimeNanoseconds: 20000),
            .activate(itemID, .right, deadlineUptimeNanoseconds: 30000),
            .capture([itemID]),
            .captureBackground(displayID: 1, sampleHeight: 1),
            .environment,
            .configureCursorInBackground(true),
            .configureConcealment(.init(visibleItemIDs: [], concealedItemIDs: [itemID])),
            .pointContext(MenuBarPoint(x: 10, y: 20)),
            .shelfPresentationObservation(shelfProbe),
            .beginRevealObservation(itemID),
            .revealObservationIsVisible(revealToken),
            .endRevealObservation(revealToken),
            .restore(snapshot, deadlineUptimeNanoseconds: 40000),
            .health,
            .restart,
        ]

        for request in requests {
            let decoded = try JSONDecoder().decode(
                MenuBarServiceRequest.self,
                from: JSONEncoder().encode(request)
            )
            #expect(decoded == request)
        }
    }

    @Test("Every typed response survives a Codable round trip")
    func responseRoundTrips() throws {
        let capabilities = MenuBarCapabilities(
            canSnapshot: true,
            canMove: true,
            canReveal: false,
            canActivate: true,
            canRestore: true
        )
        let snapshot = makeCodecSnapshot()
        let capturedImage = MenuBarCapturedImage(
            itemID: itemID,
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            bounds: MenuBarRect(x: 10, y: 20, width: 24, height: 24)
        )
        let background = MenuBarBackgroundCapture(
            displayID: 1,
            menuBarBounds: MenuBarRect(x: 0, y: 0, width: 1512, height: 37),
            pngData: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let environment = MenuBarEnvironmentSnapshot(
            activeDisplayID: 1,
            activeStableDisplayID: MenuBarDisplayID("built-in"),
            activeSpaceToken: 7,
            activeSpaceIsFullscreen: false
        )
        let pointContext = MenuBarPointContext(
            isInsideMenuBarItem: true,
            applicationBundleIdentifier: "com.example.status",
            applicationIsActive: true,
            applicationUsesRegularActivationPolicy: true
        )
        let revealUUID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let revealToken = MenuBarRevealObservationToken(value: revealUUID)
        let shelfObservation = MenuBarShelfPresentationObservation(
            roleIsPresentOnscreen: true,
            ownerMatches: true,
            intersectsTargetDisplay: true
        )
        let responses: [MenuBarServiceResponse] = [
            .acknowledged,
            .capabilities(capabilities),
            .snapshot(snapshot),
            .mutation(MenuBarMutationResult(generation: 8, changedItemIDs: [itemID])),
            .capturedImages([capturedImage]),
            .background(background),
            .environment(environment),
            .pointContext(pointContext),
            .shelfPresentationObservation(shelfObservation),
            .revealObservation(revealToken),
            .boolean(true),
            .health(MenuBarBackendHealth(backendName: "Tahoe", state: .degraded, message: "probe")),
            .failure(.interrupted),
        ]

        for response in responses {
            let decoded = try JSONDecoder().decode(
                MenuBarServiceResponse.self,
                from: JSONEncoder().encode(response)
            )
            #expect(decoded == response)
        }
    }

    @Test("Every backend failure keeps its associated data across the wire")
    func errorRoundTrips() throws {
        let errors: [MenuBarBackendError] = [
            .unavailableCapability("move"),
            .staleItem(itemID),
            .unsafeMenuTracking,
            .invalidSnapshot(.nonMonotonicGeneration(previous: 9, candidate: 8)),
            .interrupted,
            .timedOut,
            .operationFailed("probe rejected"),
        ]

        for error in errors {
            let decoded = try JSONDecoder().decode(
                MenuBarBackendError.self,
                from: JSONEncoder().encode(error)
            )
            #expect(decoded == error)

            let response = MenuBarServiceResponse.failure(error)
            let decodedResponse = try JSONDecoder().decode(
                MenuBarServiceResponse.self,
                from: JSONEncoder().encode(response)
            )
            #expect(decodedResponse == response)
        }
    }

    private func makeCodecSnapshot() -> MenuBarSnapshot {
        let displayID = MenuBarDisplayID("built-in")
        return MenuBarSnapshot(
            generation: 7,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            items: [
                MenuBarItemDescriptor(
                    id: itemID,
                    section: .visible,
                    order: 0,
                    displayID: displayID
                ),
            ],
            displayIDs: [displayID],
            activeSpaceIsValid: true
        )
    }
}
