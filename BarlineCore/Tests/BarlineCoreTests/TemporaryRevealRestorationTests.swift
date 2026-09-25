@testable import BarlineCore
import Foundation
import Testing

@Suite("Temporary reveal restoration")
struct TemporaryRevealRestorationTests {
    private let primary = MenuBarDisplayID("primary")
    private let secondary = MenuBarDisplayID("secondary")

    @Test("Missing immediate neighbor falls back to the next original neighbor")
    func missingNeighbor() throws {
        let checkpoint = try capture([item("a"), item("target"), item("b"), item("c")])
        #expect(checkpoint.precedingIDs == [id("a")])
        #expect(checkpoint.followingIDs == [id("b"), id("c")])
        expectMove(checkpoint, [item("a"), item("c"), item("target", section: .visible)], index: 1)
    }

    @Test("Preceding anchors survive all following anchors disappearing")
    func precedingNeighbor() throws {
        let checkpoint = try capture([item("a"), item("b"), item("target"), item("c")])
        #expect(checkpoint.precedingIDs == [id("b"), id("a")])
        expectMove(checkpoint, [item("a"), item("target", section: .visible)], index: 1)
    }

    @Test("Moved anchors cannot redirect restoration to visible or another display")
    func movedAnchors() throws {
        let checkpoint = try capture([item("a"), item("target"), item("b"), item("c")])
        expectMove(checkpoint, [
            item("b", section: .visible), item("c", display: secondary),
            item("a"), item("target", section: .visible),
        ], index: 2)
    }

    @Test("All original neighbors gone uses a clamped ordinal among new neighbors")
    func ordinalFallback() throws {
        let checkpoint = try capture([item("a"), item("target"), item("b")])
        expectMove(checkpoint, [item("x"), item("y"), item("target", section: .visible)], index: 1)
        expectMove(checkpoint, [item("x"), item("target", section: .visible)], index: 1)
        #expect(checkpoint.resolve(in: snapshot([item("target", section: .visible)])) == .unavailable)
        #expect(checkpoint.resolve(in: snapshot([
            item("target", section: .visible), item("other", display: secondary),
        ])) == .unavailable)
    }

    @Test("Global section index accounts for other displays and a pre-removal source")
    func globalIndex() throws {
        let checkpoint = try capture([item("other", display: secondary), item("a"), item("target"), item("b")])
        #expect(checkpoint.originalIndex == 1)
        expectMove(checkpoint, [item("other", display: secondary), item("a"), item("b"),
                                item("target", section: .visible)], index: 2)
        expectMove(checkpoint, [item("other", display: secondary), item("target"), item("a"), item("b")], index: 3)
    }

    @Test("Stable identity survives owner process restart")
    func ownerRestart() throws {
        let checkpoint = try capture([item("target", owner: 1), item("anchor", owner: 2)])
        expectMove(checkpoint, [item("anchor", owner: 200), item("target", section: .visible, owner: 100)], index: 0)
    }

    @Test("Absent items, disconnected displays and superseding edits are distinct")
    func terminalAndDeferredStates() throws {
        let checkpoint = try capture([item("target"), item("anchor")])
        #expect(checkpoint.resolve(in: snapshot([item("anchor")])) == .itemAbsent)
        #expect(checkpoint.resolve(in: snapshot([item("target", display: secondary)], displays: [secondary]))
            == .displayUnavailable)
        #expect(checkpoint.resolve(in: snapshot([item("target", display: secondary)])) == .superseded)
        #expect(checkpoint.resolve(in: snapshot([item("target", section: .alwaysHidden)])) == .superseded)
    }

    @Test("Untrusted or unsafe snapshots never authorize restoration or checkpoint removal")
    func invalidSnapshots() throws {
        let checkpoint = try capture([item("target"), item("anchor")])
        for invalid in [
            snapshot([]), snapshot([item("target"), item("target")]),
            snapshot([item("target")], validSpace: false),
            snapshot([item("target")], tracking: true),
            snapshot([item("target")], date: Date().addingTimeInterval(-60)),
        ] {
            #expect(checkpoint.resolve(in: invalid) == .unavailable)
            #expect(TemporaryRevealRestoration(itemID: id("target"), in: invalid) == nil)
        }
    }

    @Test("Physically obscured visible-section items preserve their original section")
    func visibleSection() throws {
        let checkpoint = try capture([
            item("a", section: .visible), item("target", section: .visible), item("b", section: .visible),
        ])
        #expect(checkpoint.originalSection == .visible)
        let moved = snapshot([
            item("target", section: .visible), item("a", section: .visible), item("b", section: .visible),
        ])
        #expect(checkpoint.resolve(in: moved) == .move(MenuBarMoveOperation(
            itemID: id("target"), section: .visible, index: 2, destinationDisplayID: primary
        )))
    }

    @Test("Codable checkpoints round-trip and reject oversized or contradictory payloads")
    func codableValidation() throws {
        let checkpoint = try capture([item("a"), item("target"), item("b")])
        let data = try JSONEncoder().encode(checkpoint)
        #expect(try JSONDecoder().decode(TemporaryRevealRestoration.self, from: data) == checkpoint)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["originalIndex"] = 512
        let decoded = try JSONDecoder().decode(
            TemporaryRevealRestoration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!decoded.isValid)
        #expect(decoded.resolve(in: snapshot([item("target")])) == .unavailable)
    }

    private func capture(_ items: [MenuBarItemDescriptor]) throws -> TemporaryRevealRestoration {
        try #require(TemporaryRevealRestoration(itemID: id("target"), in: snapshot(items)))
    }

    private func expectMove(_ checkpoint: TemporaryRevealRestoration, _ items: [MenuBarItemDescriptor], index: Int) {
        #expect(checkpoint.resolve(in: snapshot(items)) == .move(MenuBarMoveOperation(
            itemID: id("target"), section: .hidden, index: index, destinationDisplayID: primary
        )))
    }

    private func id(_ value: String) -> MenuBarItemID {
        MenuBarItemID(bundleIdentifier: "test.restoration", accessibilityIdentifier: value)
    }

    private func item(
        _ value: String, section: MenuBarSection = .hidden,
        display: MenuBarDisplayID? = nil, owner: Int32 = 1
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(id: id(value), section: section, order: 0,
                              displayID: display ?? primary, ownerProcessIdentifier: owner)
    }

    private func snapshot(
        _ items: [MenuBarItemDescriptor], displays: Set<MenuBarDisplayID>? = nil,
        validSpace: Bool = true, tracking: Bool = false, date: Date = Date()
    ) -> MenuBarSnapshot {
        MenuBarSnapshot(generation: 1, capturedAt: date, items: items,
                        displayIDs: displays ?? [primary, secondary], activeSpaceIsValid: validSpace,
                        menuTrackingIsActive: tracking)
    }
}

@Suite("Temporary reveal absence policy")
struct TemporaryRevealAbsencePolicyTests {
    @Test("An item whose application has quit is released immediately")
    func quitOwnerReleases() {
        #expect(
            TemporaryRevealAbsencePolicy.decision(ownerIsRunning: false, consecutiveAbsences: 1)
                == .release
        )
    }

    @Test("A brief absence while the application runs is deferred")
    func briefAbsenceDefers() {
        for count in 1 ..< TemporaryRevealAbsencePolicy.maximumDeferrals {
            #expect(
                TemporaryRevealAbsencePolicy.decision(ownerIsRunning: true, consecutiveAbsences: count)
                    == .deferRestoration
            )
        }
    }

    @Test("A persistent absence is released so it cannot block later edits")
    func persistentAbsenceReleases() {
        #expect(
            TemporaryRevealAbsencePolicy.decision(
                ownerIsRunning: true,
                consecutiveAbsences: TemporaryRevealAbsencePolicy.maximumDeferrals
            ) == .release
        )
        #expect(
            TemporaryRevealAbsencePolicy.decision(
                ownerIsRunning: nil,
                consecutiveAbsences: TemporaryRevealAbsencePolicy.maximumDeferrals
            ) == .release
        )
    }

    @Test("An unknown owner is deferred like a running one")
    func unknownOwnerDefers() {
        #expect(
            TemporaryRevealAbsencePolicy.decision(ownerIsRunning: nil, consecutiveAbsences: 1)
                == .deferRestoration
        )
    }
}
