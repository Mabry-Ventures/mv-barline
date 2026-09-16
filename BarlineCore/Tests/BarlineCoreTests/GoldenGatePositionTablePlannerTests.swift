@testable import BarlineCore
import Testing

@Suite("Golden Gate position table planner")
struct GoldenGatePositionTablePlannerTests {
    @Test("Exact bundle and item identity wins over ambiguous generic suffixes")
    func exactIdentityWins() {
        let itemID = id(bundle: "com.example.first", title: "Item-0")
        let keys = [
            "status:com.example.second::Item-0",
            "status:com.example.first::Item-0",
        ]
        #expect(GoldenGatePositionTablePlanner.resolvedKey(
            for: itemID,
            existingKeys: keys
        ) == "status:com.example.first::Item-0")
    }

    @Test("A unique display-name key resolves without guessing")
    func uniqueDisplayNameResolves() {
        let itemID = id(bundle: "com.example.first", title: "StableItem")
        #expect(GoldenGatePositionTablePlanner.resolvedKey(
            for: itemID,
            localizedApplicationName: "Example",
            existingKeys: ["status:Example::StableItem"]
        ) == "status:Example::StableItem")
    }

    @Test("Ambiguous suffixes fail closed")
    func ambiguousSuffixFailsClosed() {
        let itemID = id(bundle: "com.example.missing", title: "Item-0")
        let keys = ["status:First::Item-0", "status:Second::Item-0"]
        #expect(GoldenGatePositionTablePlanner.resolvedKey(
            for: itemID,
            existingKeys: keys
        ) == nil)
    }

    @Test("A unique suffix owned by another application fails closed")
    func uniqueForeignSuffixFailsClosed() {
        let itemID = id(bundle: "com.example.first", title: "Item-0")
        #expect(GoldenGatePositionTablePlanner.resolvedKey(
            for: itemID,
            localizedApplicationName: "First",
            existingKeys: ["status:Other::Item-0"]
        ) == nil)
    }

    @Test("Apple modules resolve through their exact module key")
    func appleModuleResolves() {
        let itemID = id(bundle: "com.apple.controlcenter", title: "Clock")
        #expect(GoldenGatePositionTablePlanner.resolvedKey(
            for: itemID,
            existingKeys: ["module:Clock", "status:Other::Clock"]
        ) == "module:Clock")
    }

    @Test("Moving into an empty hidden section assigns the source between the dividers")
    func emptyHiddenSection() throws {
        let source = item("source", section: .visible, x: 700)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let always = control(
            "Barline.ControlItem.AlwaysHidden",
            section: .alwaysHidden,
            x: 300
        ).replacing(order: 0)
        let snapshot = snapshot([always, hidden, source])
        let keys = keyMap([always, hidden, source])
        let alwaysKey = try #require(keys[always.id])
        let hiddenKey = try #require(keys[hidden.id])
        let sourceKey = try #require(keys[source.id])
        let positions = [
            alwaysKey: 400,
            hiddenKey: 200,
            sourceKey: 100,
            "status:unknown::kept": 250,
        ]

        let mutation = try GoldenGatePositionTablePlanner.planMove(
            MenuBarMoveOperation(itemID: source.id, section: .hidden, index: 0),
            in: snapshot,
            positions: positions,
            keysByItemID: keys
        )

        #expect(mutation.changes == [
            GoldenGatePositionChange(key: sourceKey, originalValue: 100, proposedValue: 300),
        ])
        #expect(positions["status:unknown::kept"] == 250)
    }

    @Test("Moving back to visible places the item right of the hidden divider")
    func restoresVisible() throws {
        let source = item("source", section: .hidden, x: 400)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let visiblePeer = item("peer", section: .visible, x: 700)
        let snapshot = snapshot([source, hidden, visiblePeer])
        let keys = keyMap([source, hidden, visiblePeer])
        let sourceKey = try #require(keys[source.id])
        let hiddenKey = try #require(keys[hidden.id])
        let visiblePeerKey = try #require(keys[visiblePeer.id])
        let positions = [
            sourceKey: 300,
            hiddenKey: 200,
            visiblePeerKey: 100,
        ]

        let mutation = try GoldenGatePositionTablePlanner.planMove(
            MenuBarMoveOperation(itemID: source.id, section: .visible, index: 0),
            in: snapshot,
            positions: positions,
            keysByItemID: keys
        )

        #expect(mutation.changes == [
            GoldenGatePositionChange(key: sourceKey, originalValue: 300, proposedValue: 150),
        ])
    }

    @Test("A concurrent position change prevents rollback")
    func conditionalRollbackProtectsConcurrentChange() {
        let key = "status:com.example::Item-0"
        let mutation = GoldenGatePositionMutation(changes: [
            GoldenGatePositionChange(key: key, originalValue: 100, proposedValue: 250),
        ])
        #expect(GoldenGatePositionTablePlanner.conditionalRollback(
            for: mutation,
            currentPositions: [key: 251]
        ) == nil)
        let rollback = GoldenGatePositionTablePlanner.conditionalRollback(
            for: mutation,
            currentPositions: [key: 250]
        )
        #expect(rollback?.changes == [
            GoldenGatePositionChange(key: key, originalValue: 250, proposedValue: 100),
        ])
    }

    @Test("A concurrent change to any key prevents a multi-key rollback")
    func multiKeyRollbackProtectsConcurrentChange() {
        let first = "status:com.example::First"
        let second = "status:com.example::Second"
        let mutation = GoldenGatePositionMutation(changes: [
            GoldenGatePositionChange(key: first, originalValue: 100, proposedValue: 200),
            GoldenGatePositionChange(key: second, originalValue: 200, proposedValue: 100),
        ])

        #expect(GoldenGatePositionTablePlanner.conditionalRollback(
            for: mutation,
            currentPositions: [first: 200, second: 101]
        ) == nil)
    }

    @Test("Rebasing preserves unrelated concurrent keys")
    func rebasingPreservesUnrelatedKeys() {
        let mutation = GoldenGatePositionMutation(changes: [
            GoldenGatePositionChange(
                key: "status:Example::Source",
                originalValue: 100,
                proposedValue: 250
            ),
        ])
        let rebased = GoldenGatePositionTablePlanner.rebasedPositions(
            applying: mutation,
            to: [
                "status:Example::Source": 100,
                "module:Clock": 900,
                "status:NewlyLaunched::Item": 777,
            ]
        )
        #expect(rebased == [
            "status:Example::Source": 250,
            "module:Clock": 900,
            "status:NewlyLaunched::Item": 777,
        ])
    }

    @Test("Rebasing rejects a concurrent change to a journaled key")
    func rebasingRejectsJournalConflict() {
        let mutation = GoldenGatePositionMutation(changes: [
            GoldenGatePositionChange(
                key: "status:Example::Source",
                originalValue: 100,
                proposedValue: 250
            ),
        ])
        #expect(GoldenGatePositionTablePlanner.rebasedPositions(
            applying: mutation,
            to: ["status:Example::Source": 101]
        ) == nil)
    }

    @Test("An unresolved item between source and destination fails closed")
    func unresolvedIntermediateItemFailsClosed() throws {
        let source = item("source", section: .visible, x: 700)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let unresolved = item("unresolved", section: .hidden, x: 400)
        let always = control("Barline.ControlItem.AlwaysHidden", section: .alwaysHidden, x: 300)
        let snapshot = snapshot([always, unresolved, hidden, source])
        var keys = keyMap([always, hidden, source])
        let alwaysKey = try #require(keys[always.id])
        let hiddenKey = try #require(keys[hidden.id])
        let sourceKey = try #require(keys[source.id])
        keys[unresolved.id] = nil

        #expect(throws: GoldenGatePositionTableError.unresolvedAffectedItem) {
            try GoldenGatePositionTablePlanner.planMove(
                MenuBarMoveOperation(itemID: source.id, section: .hidden, index: 0),
                in: snapshot,
                positions: [alwaysKey: 400, hiddenKey: 200, sourceKey: 100],
                keysByItemID: keys
            )
        }
    }

    @Test("A non-monotonic live table fails closed")
    func nonMonotonicLiveTableFailsClosed() throws {
        let source = item("source", section: .visible, x: 700)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let hiddenPeer = item("hidden-peer", section: .hidden, x: 400)
        let always = control("Barline.ControlItem.AlwaysHidden", section: .alwaysHidden, x: 300)
        let snapshot = snapshot([always, hiddenPeer, hidden, source])
        let keys = keyMap([always, hiddenPeer, hidden, source])
        let alwaysKey = try #require(keys[always.id])
        let hiddenPeerKey = try #require(keys[hiddenPeer.id])
        let hiddenKey = try #require(keys[hidden.id])
        let sourceKey = try #require(keys[source.id])

        #expect(throws: GoldenGatePositionTableError.inconsistentPositionOrder) {
            try GoldenGatePositionTablePlanner.planMove(
                MenuBarMoveOperation(itemID: source.id, section: .hidden, index: 0),
                in: snapshot,
                positions: [
                    alwaysKey: 400,
                    hiddenPeerKey: 150,
                    hiddenKey: 200,
                    sourceKey: 100,
                ],
                keysByItemID: keys
            )
        }
    }

    @Test("A pre-write axis verifies a mutation even when every live reference moved")
    func knownAxisSurvivesReferenceStarvation() throws {
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let source = item("source", section: .visible, x: 700)
        let candidate = snapshot([hidden, source])
        let keys = keyMap([hidden, source])
        let positions = try [
            #require(keys[hidden.id]): 200,
            #require(keys[source.id]): 100,
        ]
        let excluded = Set([hidden.id, source.id])

        #expect(throws: GoldenGatePositionTableError.ambiguousAxis) {
            try GoldenGatePositionTablePlanner.applyingPositions(
                to: candidate,
                positions: positions,
                keysByItemID: keys,
                excludingFromAxis: excluded
            )
        }

        let applied = try GoldenGatePositionTablePlanner.applyingPositions(
            to: candidate,
            positions: positions,
            keysByItemID: keys,
            excludingFromAxis: excluded,
            usingKnownAxis: .descendingLeftToRight
        )
        #expect(applied.items.first(where: { $0.id == source.id })?.section == .visible)
    }

    @Test("Appending within a populated hidden section rotates existing slots")
    func appendToPopulatedHiddenSection() throws {
        let source = item("source", section: .visible, x: 700)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let hiddenPeer = item("hidden-peer", section: .hidden, x: 400)
        let always = control("Barline.ControlItem.AlwaysHidden", section: .alwaysHidden, x: 300)
        let snapshot = snapshot([always, hiddenPeer, hidden, source])
        let keys = keyMap([always, hiddenPeer, hidden, source])
        let hiddenPeerKey = try #require(keys[hiddenPeer.id])
        let hiddenKey = try #require(keys[hidden.id])
        let sourceKey = try #require(keys[source.id])

        let mutation = try GoldenGatePositionTablePlanner.planMove(
            MenuBarMoveOperation(itemID: source.id, section: .hidden, index: 1),
            in: snapshot,
            positions: [
                #require(keys[always.id]): 400,
                hiddenPeerKey: 300,
                hiddenKey: 200,
                sourceKey: 100,
            ],
            keysByItemID: keys
        )

        #expect(mutation.changes == [
            GoldenGatePositionChange(key: sourceKey, originalValue: 100, proposedValue: 250),
        ])
    }

    @Test("Adjacent numeric slots re-space application items without moving the divider")
    func noGapRespacesItemsWithoutMovingDivider() throws {
        let source = item("source", section: .visible, x: 700)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let hiddenPeer = item("hidden-peer", section: .hidden, x: 400)
        let snapshot = snapshot([hiddenPeer, hidden, source])
        let keys = keyMap([hiddenPeer, hidden, source])
        let hiddenPeerKey = try #require(keys[hiddenPeer.id])
        let hiddenKey = try #require(keys[hidden.id])
        let sourceKey = try #require(keys[source.id])
        let positions = [
            hiddenPeerKey: 201,
            hiddenKey: 200,
            sourceKey: 100,
        ]
        let mutation = try GoldenGatePositionTablePlanner.planMove(
            MenuBarMoveOperation(itemID: source.id, section: .hidden, index: 1),
            in: snapshot,
            positions: positions,
            keysByItemID: keys
        )
        #expect(mutation.changes.contains {
            $0.key == hiddenPeerKey && $0.originalValue == 201 && $0.proposedValue == 202
        })
        #expect(mutation.changes.contains {
            $0.key == sourceKey && $0.originalValue == 100 && $0.proposedValue == 201
        })
        #expect(mutation.changes.allSatisfy { $0.key != hiddenKey })
    }

    @Test("Adjacent slots fail closed instead of moving a protected item")
    func noGapNeverMovesProtectedItems() throws {
        let source = item("source", section: .visible, x: 700)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let protected = MenuBarItemDescriptor(
            id: id(bundle: "com.apple.controlcenter", title: "Clock"),
            section: .hidden,
            order: 400,
            isSystemItem: true,
            sourceOwnership: .system,
            title: "Clock",
            bounds: MenuBarRect(x: 400, y: 0, width: 24, height: 22),
            isOnScreen: true,
            isMovable: false,
            canBeHidden: false
        )
        let snapshot = snapshot([protected, hidden, source])
        let keys = keyMap([protected, hidden, source])

        #expect(throws: GoldenGatePositionTableError.unresolvedAffectedItem) {
            try GoldenGatePositionTablePlanner.planMove(
                MenuBarMoveOperation(itemID: source.id, section: .hidden, index: 1),
                in: snapshot,
                positions: [
                    #require(keys[protected.id]): 201,
                    #require(keys[hidden.id]): 200,
                    #require(keys[source.id]): 100,
                ],
                keysByItemID: keys
            )
        }
    }

    @Test("Same-section reorder produces the requested physical candidate")
    func sameSectionPhysicalCandidate() throws {
        let first = item("first", section: .visible, x: 600)
        let second = item("second", section: .visible, x: 700)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let before = snapshot([hidden, first, second])

        let candidate = try GoldenGatePositionTablePlanner.candidateSnapshot(
            applying: MenuBarMoveOperation(
                itemID: second.id,
                section: .visible,
                index: 0
            ),
            to: before
        )

        #expect(candidate.items.map(\.id) == [hidden.id, second.id, first.id])
        #expect(candidate.items.first(where: { $0.id == second.id })?.section == .visible)
    }

    @Test("Forward same-section moves use the shared pre-removal insertion offset")
    func forwardSameSectionPhysicalCandidate() throws {
        let first = item("first", section: .visible, x: 600)
        let second = item("second", section: .visible, x: 700)
        let third = item("third", section: .visible, x: 800)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let before = snapshot([hidden, first, second, third])
        let operation = MenuBarMoveOperation(
            itemID: first.id,
            section: .visible,
            index: 2
        )

        let candidate = try GoldenGatePositionTablePlanner.candidateSnapshot(
            applying: operation,
            to: before
        )

        #expect(candidate.items.map(\.id) == [hidden.id, second.id, first.id, third.id])
        #expect(MenuBarMovePlanner().resultMatches(
            operation,
            in: candidate,
            from: before,
            destinationSupport: .emptySectionAllowed
        ))
    }

    @Test("An offscreen retained item cannot corrupt axis detection with stale bounds")
    func offscreenRetainedBoundsDoNotDetermineAxis() throws {
        let always = control(
            "Barline.ControlItem.AlwaysHidden",
            section: .alwaysHidden,
            x: 300
        ).replacing(order: 0)
        let retained = retainedItem(
            "retained",
            section: .hidden,
            order: 1,
            staleX: 900
        )
        let hidden = control(
            "Barline.ControlItem.Hidden",
            section: .hidden,
            x: 500
        ).replacing(order: 2)
        let source = item("source", section: .visible, x: 700).replacing(order: 3)
        let before = snapshot([always, retained, hidden, source])
        let keys = keyMap([always, retained, hidden, source])
        let sourceKey = try #require(keys[source.id])

        let mutation = try GoldenGatePositionTablePlanner.planMove(
            MenuBarMoveOperation(itemID: source.id, section: .hidden, index: 0),
            in: before,
            positions: [
                #require(keys[always.id]): 400,
                #require(keys[retained.id]): 300,
                #require(keys[hidden.id]): 200,
                sourceKey: 100,
            ],
            keysByItemID: keys
        )

        #expect(mutation.changes == [
            GoldenGatePositionChange(
                key: sourceKey,
                originalValue: 100,
                proposedValue: 350
            ),
        ])
    }

    @Test("A restore is one mutation and preserves newly launched items and dividers")
    func restorePreservesNewItemsAndDividers() throws {
        let always = control("Barline.ControlItem.AlwaysHidden", section: .alwaysHidden, x: 300)
        let first = item("first", section: .hidden, x: 400)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let newlyLaunched = item("new", section: .visible, x: 600)
        let second = item("second", section: .visible, x: 700)
        let current = snapshot([always, first, hidden, newlyLaunched, second])
        let target = snapshot([
            control("Barline.ControlItem.AlwaysHidden", section: .alwaysHidden, x: 300),
            item("second", section: .hidden, x: 400),
            control("Barline.ControlItem.Hidden", section: .hidden, x: 500),
            item("first", section: .visible, x: 700),
        ])
        let keys = keyMap([always, first, hidden, newlyLaunched, second])
        let positions = try [
            #require(keys[always.id]): 500,
            #require(keys[first.id]): 400,
            #require(keys[hidden.id]): 300,
            #require(keys[newlyLaunched.id]): 250,
            #require(keys[second.id]): 200,
        ]

        let mutation = try GoldenGatePositionTablePlanner.planRestore(
            target: target,
            current: current,
            positions: positions,
            keysByItemID: keys
        )

        let changedKeys = Set(mutation.changes.map(\.key))
        #expect(try changedKeys == Set([
            #require(keys[first.id]),
            #require(keys[second.id]),
        ]))
        #expect(try !changedKeys.contains(#require(keys[newlyLaunched.id])))
        #expect(try !changedKeys.contains(#require(keys[always.id])))
        #expect(try !changedKeys.contains(#require(keys[hidden.id])))
    }

    @Test("Restore verification ignores new items but checks shared relative order")
    func restoreVerificationPreservesNewItems() {
        let target = snapshot([
            item("second", section: .hidden, x: 400),
            control("Barline.ControlItem.Hidden", section: .hidden, x: 500),
            item("first", section: .visible, x: 700),
        ])
        let restored = snapshot([
            item("second", section: .hidden, x: 400),
            control("Barline.ControlItem.Hidden", section: .hidden, x: 500),
            item("new", section: .visible, x: 600),
            item("first", section: .visible, x: 700),
        ])
        let wrong = snapshot([
            item("first", section: .visible, x: 400),
            control("Barline.ControlItem.Hidden", section: .hidden, x: 500),
            item("second", section: .visible, x: 700),
        ])

        #expect(GoldenGatePositionTablePlanner.restoreMatches(
            target: target,
            current: restored,
            requiredItemIDs: [
                target.items[0].id,
                target.items[2].id,
            ]
        ))
        #expect(!GoldenGatePositionTablePlanner.restoreMatches(
            target: target,
            current: wrong,
            requiredItemIDs: [
                target.items[0].id,
                target.items[2].id,
            ]
        ))
    }

    @Test("Restore verification fails when a required target disappears")
    func restoreVerificationRequiresEveryTarget() {
        let first = item("first", section: .visible, x: 700)
        let second = item("second", section: .hidden, x: 400)
        let target = snapshot([second, first])
        let missing = snapshot([first])

        #expect(!GoldenGatePositionTablePlanner.restoreMatches(
            target: target,
            current: missing,
            requiredItemIDs: [first.id, second.id]
        ))
    }

    @Test("Restore leaves an unchanged protected system item fixed")
    func restoreLeavesProtectedItemsFixed() throws {
        let always = control("Barline.ControlItem.AlwaysHidden", section: .alwaysHidden, x: 300)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let system = MenuBarItemDescriptor(
            id: id(bundle: "com.apple.controlcenter", title: "Clock"),
            section: .visible,
            order: 600,
            isSystemItem: true,
            sourceOwnership: .system,
            title: "Clock",
            bounds: MenuBarRect(x: 600, y: 0, width: 24, height: 22),
            isOnScreen: true,
            isMovable: false,
            canBeHidden: false
        )
        let movable = item("movable", section: .visible, x: 700)
        let current = snapshot([always, hidden, system, movable])
        let target = snapshot([always, hidden, system, movable])
        let keys = keyMap([always, hidden, system, movable])
        let positions = try [
            #require(keys[always.id]): 400,
            #require(keys[hidden.id]): 300,
            #require(keys[system.id]): 200,
            #require(keys[movable.id]): 100,
        ]

        let mutation = try GoldenGatePositionTablePlanner.planRestore(
            target: target,
            current: current,
            positions: positions,
            keysByItemID: keys
        )

        let systemKey = try #require(keys[system.id])
        #expect(!mutation.changes.map(\.key).contains(systemKey))
        #expect(mutation.changes.isEmpty)
    }

    @Test("Restore treats a protected item as an ordering anchor")
    func restoreOrdersAroundProtectedAnchor() throws {
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let system = MenuBarItemDescriptor(
            id: id(bundle: "com.apple.controlcenter", title: "Clock"),
            section: .visible,
            order: 600,
            isSystemItem: true,
            sourceOwnership: .system,
            title: "Clock",
            bounds: MenuBarRect(x: 600, y: 0, width: 24, height: 22),
            isOnScreen: true,
            isMovable: false,
            canBeHidden: false
        )
        let movable = item("movable", section: .visible, x: 700)
        let current = snapshot([hidden, system, movable])
        let targetSystem = MenuBarItemDescriptor(
            id: system.id,
            section: .visible,
            order: 700,
            isSystemItem: true,
            sourceOwnership: .system,
            title: "Clock",
            bounds: MenuBarRect(x: 700, y: 0, width: 24, height: 22),
            isOnScreen: true,
            isMovable: false,
            canBeHidden: false
        )
        let target = snapshot([
            hidden,
            item("movable", section: .visible, x: 600),
            targetSystem,
        ])
        let keys = keyMap([hidden, system, movable])
        let hiddenKey = try #require(keys[hidden.id])
        let systemKey = try #require(keys[system.id])
        let movableKey = try #require(keys[movable.id])

        let mutation = try GoldenGatePositionTablePlanner.planRestore(
            target: target,
            current: current,
            positions: [hiddenKey: 300, systemKey: 200, movableKey: 100],
            keysByItemID: keys
        )

        #expect(mutation.changes == [
            GoldenGatePositionChange(
                key: movableKey,
                originalValue: 100,
                proposedValue: 299
            ),
        ])
    }

    @Test("Authoritative positions classify and order an AX-absent first hide")
    func authoritativePositionsClassifyFirstHide() throws {
        let always = control("Barline.ControlItem.AlwaysHidden", section: .alwaysHidden, x: 300)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let source = retainedItem("source", section: .hidden, order: 2, staleX: 700)
        let peer = item("peer", section: .visible, x: 800)
        let input = snapshot([always, hidden, source, peer])
        let keys = keyMap([always, hidden, source, peer])

        let result = try GoldenGatePositionTablePlanner.applyingPositions(
            to: input,
            positions: [
                #require(keys[always.id]): 400,
                #require(keys[source.id]): 300,
                #require(keys[hidden.id]): 200,
                #require(keys[peer.id]): 100,
            ],
            keysByItemID: keys
        )

        #expect(result.items.map(\.id) == [always.id, source.id, hidden.id, peer.id])
        #expect(result.items.first(where: { $0.id == source.id })?.section == .hidden)
    }

    @Test("A table write cannot manufacture success while live AX order is unchanged")
    func authoritativePositionsRejectLiveDisagreement() throws {
        let always = control("Barline.ControlItem.AlwaysHidden", section: .alwaysHidden, x: 300)
        let hidden = control("Barline.ControlItem.Hidden", section: .hidden, x: 500)
        let source = item("source", section: .visible, x: 700)
        let peer = item("peer", section: .visible, x: 800)
        let input = snapshot([always, hidden, source, peer])
        let keys = keyMap([always, hidden, source, peer])

        #expect(throws: GoldenGatePositionTableError.inconsistentPositionOrder) {
            try GoldenGatePositionTablePlanner.applyingPositions(
                to: input,
                positions: [
                    #require(keys[always.id]): 400,
                    #require(keys[source.id]): 300,
                    #require(keys[hidden.id]): 200,
                    #require(keys[peer.id]): 100,
                ],
                keysByItemID: keys,
                excludingFromAxis: [source.id]
            )
        }
    }

    @Test("Axis detection rejects a transient outlier instead of inverting the table")
    func axisDetectionRejectsOutlier() throws {
        let first = item("first", section: .visible, x: 300)
        let second = item("second", section: .visible, x: 400)
        let third = item("third", section: .visible, x: 500)
        let input = snapshot([first, second, third])
        let keys = keyMap([first, second, third])

        #expect(throws: GoldenGatePositionTableError.ambiguousAxis) {
            try GoldenGatePositionTablePlanner.applyingPositions(
                to: input,
                positions: [
                    #require(keys[first.id]): 300,
                    #require(keys[second.id]): 100,
                    #require(keys[third.id]): 200,
                ],
                keysByItemID: keys
            )
        }
    }

    private func id(bundle: String = "com.example.app", title: String) -> MenuBarItemID {
        MenuBarItemID(
            bundleIdentifier: bundle,
            accessibilityIdentifier: title,
            title: title,
            alias: "occurrence-0"
        )
    }

    private func item(
        _ title: String,
        section: MenuBarSection,
        x: Double
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: id(title: title),
            section: section,
            order: Int(x),
            title: title,
            bounds: MenuBarRect(x: x, y: 0, width: 24, height: 22),
            isOnScreen: true
        )
    }

    private func control(
        _ title: String,
        section: MenuBarSection,
        x: Double
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: id(bundle: "com.mabryventures.Barline", title: title),
            section: section,
            order: Int(x),
            isBarlineControlItem: true,
            title: title,
            displayName: "Barline",
            bounds: MenuBarRect(x: x, y: 0, width: 5, height: 22),
            isOnScreen: true,
            isMovable: false,
            canBeHidden: false
        )
    }

    private func retainedItem(
        _ title: String,
        section: MenuBarSection,
        order: Int,
        staleX: Double
    ) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: id(title: title),
            section: section,
            order: order,
            title: title,
            bounds: MenuBarRect(x: staleX, y: 0, width: 24, height: 22),
            isOnScreen: false
        )
    }

    private func snapshot(_ items: [MenuBarItemDescriptor]) -> MenuBarSnapshot {
        MenuBarSnapshot(
            generation: 1,
            capturedAt: .now,
            items: items,
            displayIDs: [MenuBarDisplayID("display")],
            activeSpaceIsValid: true
        )
    }

    private func keyMap(
        _ items: [MenuBarItemDescriptor]
    ) -> [MenuBarItemID: String] {
        Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, "status:\(item.id.bundleIdentifier)::\(item.title!)")
        })
    }
}
