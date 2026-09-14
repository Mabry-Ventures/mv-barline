@testable import BarlineCore
import Foundation
import Testing

@Suite("Golden Gate menu bar snapshot builder")
struct GoldenGateMenuBarSnapshotBuilderTests {
    private let displayID = MenuBarDisplayID("display-a")
    private let displayBounds = MenuBarRect(x: 0, y: 0, width: 1800, height: 1200)
    private let appID = "com.mabryventures.Barline"

    @Test("Classifies items around Barline's section controls")
    func classifiesSections() throws {
        let snapshot = try build([
            observation(bundle: "com.example.always", title: "Always", x: 1400),
            observation(bundle: appID, title: "Barline.ControlItem.AlwaysHidden", x: 1450),
            observation(bundle: "com.example.hidden", title: "Hidden", x: 1500),
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1550),
            observation(bundle: "com.example.visible", title: "Visible", x: 1600),
            observation(bundle: appID, title: "Barline.ControlItem.Visible", x: 1650),
        ])

        #expect(snapshot.items.map(\.section) == [
            .alwaysHidden, .alwaysHidden, .hidden, .hidden, .visible, .visible,
        ])
        #expect(snapshot.items.filter(\.isBarlineControlItem).count == 3)
        #expect(snapshot.items.allSatisfy { !$0.isMovable })
    }

    @Test("Fails closed without the hidden section control")
    func missingHiddenControl() {
        #expect(throws: MenuBarBackendError.self) {
            try build([
                observation(bundle: "com.example.item", title: "Item", x: 1600),
                observation(bundle: appID, title: "Barline.ControlItem.Visible", x: 1650),
            ])
        }
    }

    @Test("Creates stable occurrence aliases for duplicate semantic items")
    func duplicateAliases() throws {
        let snapshot = try build([
            observation(bundle: appID, title: "Barline.ControlItem.Hidden", x: 1500),
            observation(bundle: "com.example.duplicate", title: "Duplicate", x: 1560),
            observation(bundle: "com.example.duplicate", title: "Duplicate", x: 1600),
        ])
        let duplicates = snapshot.items.filter {
            $0.id.bundleIdentifier == "com.example.duplicate"
        }
        #expect(duplicates.map(\.id.alias) == ["occurrence-0", "occurrence-1"])
    }

    private func build(
        _ observations: [GoldenGateMenuBarObservation]
    ) throws -> MenuBarSnapshot {
        try GoldenGateMenuBarSnapshotBuilder.build(
            observations: observations,
            displayIdentities: [MenuBarDisplayIdentity(runtimeID: displayID)],
            activeDisplayID: displayID,
            activeDisplayBounds: displayBounds,
            appSigningIdentifier: appID,
            generation: 7
        )
    }

    private func observation(
        bundle: String,
        title: String,
        x: Double
    ) -> GoldenGateMenuBarObservation {
        GoldenGateMenuBarObservation(
            bundleIdentifier: bundle,
            localizedApplicationName: nil,
            identifier: title,
            displayTitle: title,
            stableTitle: title,
            fallbackFingerprint: "fingerprint-\(bundle)-\(title)",
            bounds: MenuBarRect(x: x, y: 3, width: 30, height: 24),
            ownerProcessIdentifier: 42
        )
    }
}
