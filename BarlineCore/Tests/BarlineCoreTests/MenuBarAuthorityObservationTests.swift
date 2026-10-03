//
//  MenuBarAuthorityObservationTests.swift
//  Barline
//

@_spi(BarlinePlatformPresence) @testable import BarlineCore
import Foundation
import Testing

@Suite("Atomic runtime observation envelopes")
struct MenuBarAuthorityObservationTests {
    static let display = MenuBarDisplayID("observation-fixture")
    static let item = MenuBarItemID(bundleIdentifier: "com.example.fixture", accessibilityIdentifier: "item")

    static func snapshot(generation: UInt64 = 1, section: MenuBarSection = .visible, time: Date = Date()) -> MenuBarSnapshot {
        MenuBarSnapshot(
            generation: generation, capturedAt: time,
            items: [MenuBarItemDescriptor(id: item, section: section, order: 0, displayID: display)],
            displayIDs: [display], activeSpaceIsValid: true
        )
    }

    static func receipt(session: UUID = UUID(), phase: NativeConcealmentReceipt.Phase = .deasserted) -> NativeConcealmentReceipt {
        NativeConcealmentReceipt(
            helperSessionID: session, assertionRevision: 1, configurationRevision: 1,
            configurationDigest: String(repeating: "a", count: 64), effectiveStateDigest: String(repeating: "b", count: 64), phase: phase
        )
    }

    static func environment(_ receipt: NativeConcealmentReceipt?, space: Int = 1, tracking: Bool = false,
                            display: MenuBarDisplayID = display) -> MenuBarEnvironmentSnapshot
    {
        MenuBarEnvironmentSnapshot(
            activeDisplayID: 1, activeStableDisplayID: display, activeSpaceToken: space,
            activeSpaceIsFullscreen: false, menuTrackingIsActive: tracking, nativeConcealmentReceipt: receipt
        )
    }

    static func scan(_ snapshot: MenuBarSnapshot, id: UUID = UUID(), start: UInt64 = 1, end: UInt64 = 2,
                     initial: MenuBarEnvironmentSnapshot? = nil, final: MenuBarEnvironmentSnapshot? = nil) -> MenuBarObservationScan
    {
        let scene = environment(receipt())
        return MenuBarObservationScan(
            scanID: id, startedAtUptimeNanoseconds: start, completedAtUptimeNanoseconds: end,
            observedSnapshot: snapshot, initialEnvironment: initial ?? scene, finalEnvironment: final ?? initial ?? scene
        )
    }

    static func nativePresence(
        scanID: UUID,
        started: UInt64 = 10,
        completed: UInt64 = 20,
        focus: MenuBarPlatformFocusPresence
    ) -> MenuBarPlatformPresenceObservation {
        MenuBarPlatformPresenceObservation(
            scanID: scanID,
            startedAtUptimeNanoseconds: started,
            completedAtUptimeNanoseconds: completed,
            publisherBundleIdentifier: "com.apple.MenuBarAgent",
            publisherProcessIdentifier: 42,
            publisherStartSeconds: 10,
            publisherStartMicroseconds: 11,
            publisherSealedIdentifier: "com.apple.MenuBarAgent",
            publisherCodeIdentityDigest: String(repeating: "a", count: 64),
            scopeIsClosed: true,
            clockAnchorIdentifier: "com.apple.menuextra.clock",
            controlCenterAnchorIdentifier: "com.apple.menuextra.controlcenter",
            focusPresence: focus
        )
    }

    static func focusDescriptor(order: Int = 20) -> MenuBarItemDescriptor {
        let bounds = MenuBarRect(x: 100, y: 0, width: 22, height: 22)
        return MenuBarItemDescriptor(
            id: MenuBarPlatformPresenceIdentity.focusItemID,
            section: .visible,
            order: order,
            displayID: display,
            isSystemItem: true,
            sourceOwnership: .system,
            title: "Focus",
            displayName: "Focus",
            ownerProcessIdentifier: 42,
            sourceProcessIdentifier: 42,
            bounds: bounds,
            isOnScreen: true,
            isMovable: false,
            canBeHidden: false
        )
    }

    static func legacyFocusDescriptor(order: Int = 20) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: MenuBarItemID(
                bundleIdentifier: MenuBarPlatformPresenceIdentity.focusItemID.bundleIdentifier,
                accessibilityIdentifier: MenuBarPlatformPresenceIdentity.focusItemID.accessibilityIdentifier,
                title: "Focus",
                alias: "occurrence-0",
                fallbackFingerprint: "legacy-focus-fingerprint"
            ),
            section: .visible,
            order: order,
            displayID: display,
            isSystemItem: true,
            sourceOwnership: .system,
            tagNamespace: "com.apple.MenuBarAgent",
            title: "Focus",
            ownerProcessIdentifier: 42,
            sourceProcessIdentifier: 42,
            bounds: MenuBarRect(x: 100, y: 0, width: 22, height: 22),
            isOnScreen: true,
            isMovable: false,
            canBeHidden: false
        )
    }

    static func continuitySnapshot(
        generation: UInt64,
        ordinaryItemCount: Int,
        includeFocus: Bool,
        capturedAt: Date
    ) -> MenuBarSnapshot {
        var items = (0 ..< ordinaryItemCount).map { index in
            MenuBarItemDescriptor(
                id: MenuBarItemID(bundleIdentifier: "com.example.continuity", accessibilityIdentifier: "item-\(index)"),
                section: .visible,
                order: index,
                displayID: display
            )
        }
        if includeFocus {
            items.append(focusDescriptor(order: items.count))
        }
        return MenuBarSnapshot(
            generation: generation,
            capturedAt: capturedAt,
            items: items,
            displayIDs: [display],
            activeSpaceIsValid: true
        )
    }

    @Test("Generation rebasing preserves the actual scan, inventory and observation time")
    func rebasePreservesScan() {
        let raw = Self.snapshot()
        let context = Self.scan(raw)
        let envelope = MenuBarAuthorityObservation(snapshot: raw, scan: context)
        let rebased = envelope.rebasingGeneration(to: 100)
        #expect(rebased.snapshot.generation == 100)
        #expect(rebased.snapshot.items == raw.items)
        #expect(rebased.snapshot.capturedAt == raw.capturedAt)
        #expect(rebased.scan == context)
        #expect(rebased.scan?.observedSnapshot.generation == 1)
    }

    @Test("Changed native receipt, scene or tracking state never inherits context")
    func rejectsUnstableScope() {
        let raw = Self.snapshot()
        let receipt = Self.receipt()
        let initial = Self.environment(receipt)
        let finals = [
            Self.environment(Self.receipt()),
            Self.environment(receipt, space: 2),
            Self.environment(receipt, tracking: true),
            Self.environment(receipt, display: MenuBarDisplayID("elsewhere")),
            Self.environment(nil),
        ]
        for final in finals {
            #expect(MenuBarAuthorityObservation(snapshot: raw, scan: Self.scan(raw, initial: initial, final: final)).scan == nil)
        }
        for phase in [NativeConcealmentReceipt.Phase.transient, .unknown] {
            let scene = Self.environment(Self.receipt(phase: phase))
            #expect(MenuBarAuthorityObservation(snapshot: raw, scan: Self.scan(raw, initial: scene)).scan == nil)
        }
        #expect(MenuBarAuthorityObservation(snapshot: raw, scan: Self.scan(raw, start: 0)).scan == nil)
        #expect(MenuBarAuthorityObservation(snapshot: raw, scan: Self.scan(raw, start: 3, end: 2)).scan == nil)
    }

    @Test("A scan cannot be attached to changed layout, captured time or safety fields")
    func rejectsDifferentSnapshotAssociation() {
        let raw = Self.snapshot()
        let context = Self.scan(raw)
        let different = [
            Self.snapshot(section: .hidden, time: raw.capturedAt),
            Self.snapshot(time: raw.capturedAt.addingTimeInterval(1)),
            MenuBarSnapshot(generation: 1, capturedAt: raw.capturedAt, items: [], displayIDs: raw.displayIDs, activeSpaceIsValid: true),
            MenuBarSnapshot(generation: 1, capturedAt: raw.capturedAt, items: raw.items, displayIDs: raw.displayIDs,
                            activeSpaceIsValid: true, menuTrackingIsActive: true),
            MenuBarSnapshot(generation: 1, capturedAt: raw.capturedAt, items: raw.items, displayIDs: raw.displayIDs,
                            activeSpaceIsValid: false),
        ]
        for snapshot in different {
            #expect(MenuBarAuthorityObservation(snapshot: snapshot, scan: context).scan == nil)
        }
    }

    @Test("Runtime envelope and context are non-Codable; snapshot schema does not gain trust")
    func persistenceCannotReconstructContext() throws {
        let raw = Self.snapshot()
        let context = Self.scan(raw)
        let envelope = MenuBarAuthorityObservation(snapshot: raw, scan: context)
        #expect(!((envelope as Any) is any Encodable))
        #expect(!((context as Any) is any Encodable))
        let encoded = try JSONEncoder().encode(raw)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("scanID"))
        let decoded = try JSONDecoder().decode(MenuBarSnapshot.self, from: encoded)
        #expect(MenuBarAuthorityObservation(snapshot: decoded).scan == nil)
        #expect(decoded == raw)
    }

    @Test("Protocol default dynamically dispatches ordinary/fresh operations and supplies no context")
    func legacyDefaultDispatch() async throws {
        let legacy = LegacyObservationBackend()
        let backend: any MenuBarBackend = legacy
        #expect(try await backend.authorityObservation(freshness: .cachedAllowed).scan == nil)
        #expect(try await backend.authorityObservation(freshness: .freshRequired).scan == nil)
        #expect(await legacy.ordinaryCalls == 1)
        #expect(await legacy.freshCalls == 1)
    }

    @Test("Refresh admits an atomic override, while bare move publication clears context")
    func overrideAndConservativeMovePublication() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        let observed = await coordinator.currentAuthorityObservation
        #expect(observed?.scan != nil)
        #expect(await observed?.snapshot == (coordinator.currentSnapshot))
        #expect(await backend.observationCalls == 1)
        _ = try await coordinator.perform(.move(MenuBarMoveOperation(itemID: Self.item, section: .hidden, index: 0)))
        #expect(await coordinator.currentSnapshot?.items.first?.section == .hidden)
        #expect(await coordinator.currentAuthorityObservation == nil)
        #expect(await backend.freshCalls > 0)
    }

    @Test("A not-started mutation preserves fresh admission for the next attempt")
    func mutationNotStartedPreservesQualifiedAdmission() async throws {
        let validationNow = Date()
        let backend = QualifiedFocusPresenceBackend(
            snapshot: Self.snapshot(time: validationNow.addingTimeInterval(-10))
        )
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh(now: validationNow)
        let initialScanID = await coordinator.currentAuthorityObservation?.scan?.scanID

        await #expect(throws: MenuBarBackendError.mutationNotStarted) {
            try await coordinator.perform(
                .move(MenuBarMoveOperation(itemID: Self.item, section: .hidden, index: 0)),
                now: validationNow
            )
        }
        let firstAdmission = await coordinator.currentAuthorityObservation
        #expect(firstAdmission?.scan?.scanID != initialScanID)
        #expect(await firstAdmission?.snapshot == coordinator.currentSnapshot)
        #expect(await backend.observationCalls == 2)

        await #expect(throws: MenuBarBackendError.mutationNotStarted) {
            try await coordinator.perform(
                .move(MenuBarMoveOperation(itemID: Self.item, section: .visible, index: 0)),
                now: validationNow
            )
        }
        let retryAdmission = await coordinator.currentAuthorityObservation
        #expect(retryAdmission?.scan?.scanID != firstAdmission?.scan?.scanID)
        #expect(await backend.observationCalls == 3)
        #expect(await backend.moveCalls == 2)
    }

    @Test("A rejected provider observation never synchronizes native hiding at cold start or from cache",
          arguments: [false, true])
    func rejectedProviderObservationCannotSynchronize(hasPriorSnapshot: Bool) async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend, retryPolicy: RetryPolicy(maximumAttempts: 1))
        if hasPriorSnapshot {
            _ = try await coordinator.refresh()
        }
        let original = await coordinator.lastKnownGoodSnapshot
        await backend.failObservations()
        await #expect(throws: MenuBarBackendError.operationFailed("fixture observation failed")) {
            try await coordinator.synchronizeConcealment(concealedSections: [.hidden, .alwaysHidden])
        }
        #expect(await backend.configureCalls == 0)
        #expect(await coordinator.lastKnownGoodSnapshot == original)
    }

    @Test("A superseded recovery without a qualified scan cannot admit a cached retry")
    func supersededRecoveryRequiresQualifiedRetryAdmission() async throws {
        let validationNow = Date()
        let backend = QualifiedFocusPresenceBackend(
            snapshot: Self.snapshot(time: validationNow.addingTimeInterval(-10)),
            mutationErrors: [.mutationSuperseded],
            unqualifiedObservationCalls: [3, 4]
        )
        let coordinator = MenuBarStateCoordinator(
            backend: backend,
            retryPolicy: RetryPolicy(maximumAttempts: 1)
        )
        _ = try await coordinator.refresh(now: validationNow)

        await #expect(throws: MenuBarBackendError.mutationSuperseded) {
            try await coordinator.perform(
                .move(MenuBarMoveOperation(itemID: Self.item, section: .hidden, index: 0)),
                now: validationNow
            )
        }
        #expect(await coordinator.currentSnapshot == nil)
        #expect(await coordinator.currentAuthorityObservation == nil)

        await #expect(throws: MenuBarBackendError.invalidSnapshot(.platformPresenceContractChanged)) {
            try await coordinator.perform(
                .move(MenuBarMoveOperation(itemID: Self.item, section: .hidden, index: 0)),
                now: validationNow
            )
        }
        #expect(await backend.moveCalls == 1)
        #expect(await backend.observationCalls == 4)
    }

    @Test("Restart revokes old context; checked generation normalization preserves the new scan")
    func restartRebaseAndCacheIdentity() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        let before = await coordinator.currentAuthorityObservation
        _ = try await coordinator.recover()
        let recovered = await coordinator.currentAuthorityObservation
        #expect(recovered?.scan != nil)
        #expect(recovered?.scan?.scanID != before?.scan?.scanID)
        #expect(recovered?.scan?.initialEnvironment.nativeConcealmentReceipt?.helperSessionID !=
            before?.scan?.initialEnvironment.nativeConcealmentReceipt?.helperSessionID)
        #expect(recovered?.snapshot.generation == 2)
        #expect(recovered?.scan?.observedSnapshot.generation == 1)
        _ = try await coordinator.refresh()
        let cached = await coordinator.currentAuthorityObservation
        #expect(cached?.snapshot.generation == 3)
        #expect(cached?.scan == recovered?.scan)
    }

    @Test("An empty response with context still fails strict snapshot validation")
    func contextDoesNotExemptMissingInventory() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend, retryPolicy: RetryPolicy(maximumAttempts: 1))
        let baseline = try await coordinator.refresh()
        await backend.dropInventory()
        await #expect(throws: MenuBarBackendError.invalidSnapshot(.emptySnapshot)) {
            try await coordinator.refresh()
        }
        #expect(await coordinator.currentSnapshot == baseline)
        #expect(await coordinator.currentAuthorityObservation?.snapshot == baseline)
    }

    @Test("A failed restart observation leaves no old runtime context")
    func failedRestartRevokesContext() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        #expect(await coordinator.currentAuthorityObservation?.scan != nil)
        await backend.failObservations()
        await #expect(throws: MenuBarBackendError.operationFailed("fixture observation failed")) {
            try await coordinator.recover()
        }
        #expect(await coordinator.currentAuthorityObservation == nil)
        #expect(await coordinator.currentSnapshot == nil)
        #expect(await coordinator.backendHealth.state == .degraded)
    }

    @Test("Generation overflow cannot publish a newly supplied runtime context")
    func generationOverflowDoesNotPublish() async throws {
        let backend = AtomicObservationBackend()
        let coordinator = MenuBarStateCoordinator(backend: backend)
        _ = try await coordinator.refresh()
        _ = try await coordinator.recover()
        let before = await coordinator.currentAuthorityObservation
        await backend.forceGeneration(UInt64.max)
        await #expect(throws: MenuBarBackendError.operationFailed("helper generation normalization overflow")) {
            try await coordinator.refresh()
        }
        #expect(await coordinator.currentAuthorityObservation == before)
        #expect(await coordinator.currentSnapshot == before?.snapshot)
    }

    @Test("Closed MenuBarAgent absence removes only the exact Focus item from collapse denominators")
    func attestedFocusAbsenceDoesNotMaskUnrelatedCollapse() {
        let now = Date()
        let previous = Self.continuitySnapshot(
            generation: 1, ordinaryItemCount: 20, includeFocus: true, capturedAt: now
        )
        let candidate = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 7, includeFocus: false, capturedAt: now
        )
        let scanID = UUID()
        let scene = Self.environment(Self.receipt())
        let scan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: Self.nativePresence(scanID: scanID, focus: .absent)
        )
        let observation = MenuBarAuthorityObservation(snapshot: candidate, scan: scan)
        let validator = SnapshotValidator()

        #expect(observation.scan != nil)
        #expect(validator.validate(candidate, previous: previous, now: now)
            == .failure(.platformPresenceContractChanged))
        #expect(validator.validate(observation, previous: previous, now: now) == .success(candidate))

        let smaller = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 6, includeFocus: false, capturedAt: now
        )
        let smallerScan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: smaller,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: Self.nativePresence(scanID: scanID, focus: .absent)
        )
        #expect(validator.validate(
            MenuBarAuthorityObservation(snapshot: smaller, scan: smallerScan),
            previous: previous,
            now: now
        ) == .failure(.implausibleItemCountCollapse(previous: 20, candidate: 6)))
    }

    @Test("Legacy WindowServer Control Center identities retain system continuity")
    func legacyControlCenterIdentityCannotBypassSystemContinuity() {
        let now = Date()
        let ordinary = Self.continuitySnapshot(
            generation: 1, ordinaryItemCount: 20, includeFocus: false, capturedAt: now
        )
        let legacyControlCenterItem = MenuBarItemDescriptor(
            id: MenuBarItemID(
                bundleIdentifier: "barline.hosted-menu-item",
                title: "Wi-Fi",
                fallbackFingerprint: "Control Center:Wi-Fi:25"
            ),
            section: .visible,
            order: ordinary.items.count,
            displayID: Self.display,
            isSystemItem: true,
            sourceOwnership: .system,
            tagNamespace: "com.apple.controlcenter",
            title: "Wi-Fi",
            isMovable: false,
            canBeHidden: false
        )
        let previous = MenuBarSnapshot(
            generation: ordinary.generation,
            capturedAt: now,
            items: ordinary.items + [legacyControlCenterItem],
            displayIDs: ordinary.displayIDs,
            activeSpaceIsValid: true
        )
        let candidate = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 20, includeFocus: false, capturedAt: now
        )

        #expect(!MenuBarPlatformPresenceIdentity.isFocusItem(legacyControlCenterItem.id))
        #expect(SnapshotValidator().validate(candidate, previous: previous, now: now) ==
            .failure(.implausibleSystemItemCollapse(previous: 1, candidate: 0)))
    }

    @Test("AX-identified Control Center items remain system continuity anchors")
    func axIdentifiedControlCenterItemCannotUseLegacyException() {
        let now = Date()
        let ordinary = Self.continuitySnapshot(
            generation: 1, ordinaryItemCount: 20, includeFocus: false, capturedAt: now
        )
        let wifi = MenuBarItemDescriptor(
            id: MenuBarItemID(
                bundleIdentifier: "com.apple.controlcenter",
                accessibilityIdentifier: "com.apple.menuextra.wifi"
            ),
            section: .visible,
            order: ordinary.items.count,
            displayID: Self.display,
            isSystemItem: true,
            sourceOwnership: .system,
            tagNamespace: "com.apple.controlcenter",
            title: "Wi-Fi"
        )
        let previous = MenuBarSnapshot(
            generation: ordinary.generation,
            capturedAt: now,
            items: ordinary.items + [wifi],
            displayIDs: ordinary.displayIDs,
            activeSpaceIsValid: true
        )
        let candidate = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 20, includeFocus: false, capturedAt: now
        )

        #expect(SnapshotValidator().validate(candidate, previous: previous, now: now) ==
            .failure(.implausibleSystemItemCollapse(previous: 1, candidate: 0)))
    }

    @Test("Qualified platform observations retain continuity for other Control Center items")
    func qualifiedObservationRetainsOtherControlCenterContinuity() {
        let now = Date()
        let ordinary = Self.continuitySnapshot(
            generation: 1, ordinaryItemCount: 20, includeFocus: false, capturedAt: now
        )
        let focus = Self.focusDescriptor(order: ordinary.items.count)
        let legacyShapedControl = MenuBarItemDescriptor(
            id: MenuBarItemID(bundleIdentifier: "com.apple.controlcenter", title: "Wi-Fi", fallbackFingerprint: "legacy-wifi"),
            section: .visible,
            order: ordinary.items.count + 1,
            displayID: Self.display,
            isSystemItem: true,
            sourceOwnership: .system,
            tagNamespace: "com.apple.controlcenter",
            title: "Wi-Fi"
        )
        let previous = MenuBarSnapshot(
            generation: 1,
            capturedAt: now,
            items: ordinary.items + [focus, legacyShapedControl],
            displayIDs: ordinary.displayIDs,
            activeSpaceIsValid: true
        )
        let candidate = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 20, includeFocus: false, capturedAt: now
        )
        let scanID = UUID()
        let scene = Self.environment(Self.receipt())
        let scan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: Self.nativePresence(scanID: scanID, focus: .absent)
        )
        let observation = MenuBarAuthorityObservation(snapshot: candidate, scan: scan)

        #expect(MenuBarPlatformPresenceContract.admitting(observation) != nil)
        #expect(SnapshotValidator().validate(observation, previous: previous, now: now) ==
            .failure(.implausibleSystemItemCollapse(previous: 1, candidate: 0)))
    }

    @Test("Legacy metadata for exact Focus identity is excluded semantically")
    func legacyExactFocusMetadataDoesNotCountAsSystemItemLoss() {
        let now = Date()
        let ordinary = Self.continuitySnapshot(
            generation: 1, ordinaryItemCount: 2, includeFocus: false, capturedAt: now
        )
        let previous = MenuBarSnapshot(
            generation: ordinary.generation,
            capturedAt: now,
            items: ordinary.items + [Self.legacyFocusDescriptor(order: ordinary.items.count)],
            displayIDs: ordinary.displayIDs,
            activeSpaceIsValid: true
        )
        let candidate = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 2, includeFocus: false, capturedAt: now
        )
        let scanID = UUID()
        let scene = Self.environment(Self.receipt())
        let scan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: Self.nativePresence(scanID: scanID, focus: .absent)
        )

        #expect(SnapshotValidator().validate(
            MenuBarAuthorityObservation(snapshot: candidate, scan: scan),
            previous: previous,
            now: now
        ) == .success(candidate))
    }

    @Test("Focus presence evidence must be exact, closed, and associated with its observed descriptor")
    func nativePresenceAssociationIsExact() {
        let now = Date()
        let candidate = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 3, includeFocus: true, capturedAt: now
        )
        let scanID = UUID()
        let scene = Self.environment(Self.receipt())
        let valid = Self.nativePresence(scanID: scanID, focus: .present(
            MenuBarPlatformFocusItem(
                itemID: MenuBarPlatformPresenceIdentity.focusItemID,
                bounds: Self.focusDescriptor().bounds,
                displayID: Self.display,
                ownerProcessIdentifier: 42
            )
        ))
        let validScan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: valid
        )
        #expect(MenuBarAuthorityObservation(snapshot: candidate, scan: validScan).scan != nil)

        let forged = Self.nativePresence(scanID: scanID, focus: .present(
            MenuBarPlatformFocusItem(
                itemID: MenuBarItemID(bundleIdentifier: "com.apple.MenuBarAgent", title: "Focus"),
                bounds: Self.focusDescriptor().bounds,
                displayID: Self.display,
                ownerProcessIdentifier: 42
            )
        ))
        let forgedScan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: forged
        )
        #expect(MenuBarAuthorityObservation(snapshot: candidate, scan: forgedScan).scan == nil)

        let openScope = MenuBarPlatformPresenceObservation(
            scanID: scanID,
            startedAtUptimeNanoseconds: 10,
            completedAtUptimeNanoseconds: 20,
            publisherBundleIdentifier: "com.apple.MenuBarAgent",
            publisherProcessIdentifier: 42,
            publisherStartSeconds: 10,
            publisherStartMicroseconds: 11,
            publisherSealedIdentifier: "com.apple.MenuBarAgent",
            publisherCodeIdentityDigest: String(repeating: "a", count: 64),
            scopeIsClosed: false,
            clockAnchorIdentifier: "com.apple.menuextra.clock",
            controlCenterAnchorIdentifier: "com.apple.menuextra.controlcenter",
            focusPresence: .present(.init(
                itemID: MenuBarPlatformPresenceIdentity.focusItemID,
                bounds: Self.focusDescriptor().bounds,
                displayID: Self.display,
                ownerProcessIdentifier: 42
            ))
        )
        let openScan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: openScope
        )
        #expect(MenuBarAuthorityObservation(snapshot: candidate, scan: openScan).scan == nil)
    }

    @Test("The admitted Focus contract rejects publisher or helper-session changes")
    func platformPresenceContractCannotChangePublisherOrSession() throws {
        let now = Date()
        let previous = Self.continuitySnapshot(
            generation: 1, ordinaryItemCount: 20, includeFocus: true, capturedAt: now
        )
        let candidate = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 7, includeFocus: false, capturedAt: now
        )
        let scanID = UUID()
        let scene = Self.environment(Self.receipt())
        let admittedScan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: Self.nativePresence(scanID: scanID, focus: .absent)
        )
        let admittedObservation = MenuBarAuthorityObservation(snapshot: candidate, scan: admittedScan)
        let contract = try #require(MenuBarPlatformPresenceContract.admitting(admittedObservation))
        let validator = SnapshotValidator()

        #expect(validator.validate(
            admittedObservation,
            previous: previous,
            platformContract: contract,
            now: now
        ) == .success(candidate))

        let changedPublisher = MenuBarPlatformPresenceObservation(
            scanID: scanID,
            startedAtUptimeNanoseconds: 10,
            completedAtUptimeNanoseconds: 20,
            publisherBundleIdentifier: "com.apple.MenuBarAgent",
            publisherProcessIdentifier: 43,
            publisherStartSeconds: 10,
            publisherStartMicroseconds: 11,
            publisherSealedIdentifier: "com.apple.MenuBarAgent",
            publisherCodeIdentityDigest: String(repeating: "a", count: 64),
            scopeIsClosed: true,
            clockAnchorIdentifier: "com.apple.menuextra.clock",
            controlCenterAnchorIdentifier: "com.apple.menuextra.controlcenter",
            focusPresence: .absent
        )
        let changedPublisherScan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: changedPublisher
        )
        #expect(validator.validate(
            MenuBarAuthorityObservation(snapshot: candidate, scan: changedPublisherScan),
            previous: previous,
            platformContract: contract,
            now: now
        ) == .failure(.platformPresenceContractChanged))

        let changedSession = UUID()
        let changedSessionScene = Self.environment(Self.receipt(session: changedSession))
        let changedSessionScan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: changedSessionScene,
            finalEnvironment: changedSessionScene,
            platformPresenceObservation: Self.nativePresence(scanID: scanID, focus: .absent)
        )
        #expect(validator.validate(
            MenuBarAuthorityObservation(snapshot: candidate, scan: changedSessionScan),
            previous: previous,
            platformContract: contract,
            now: now
        ) == .failure(.platformPresenceContractChanged))
    }

    @Test("Legacy Focus profile references project only from visible assignments")
    func legacyFocusProfileProjectionIsVisibleOnly() throws {
        let now = Date()
        let candidate = Self.continuitySnapshot(
            generation: 2, ordinaryItemCount: 7, includeFocus: false, capturedAt: now
        )
        let scanID = UUID()
        let scene = Self.environment(Self.receipt())
        let scan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: candidate,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: Self.nativePresence(scanID: scanID, focus: .absent)
        )
        let observation = MenuBarAuthorityObservation(snapshot: candidate, scan: scan)
        let contract = try #require(MenuBarPlatformPresenceContract.admitting(observation))
        // This is the full identity written by the pre-contract inventory
        // builder, before Focus received its canonical runtime-only identity.
        let legacyFocusID = MenuBarItemID(
            bundleIdentifier: "com.apple.MenuBarAgent",
            accessibilityIdentifier: "com.apple.menuextra.focusmode",
            title: "Focus",
            alias: "occurrence-0",
            fallbackFingerprint: String(repeating: "a", count: 64)
        )
        let ordinaryLiveID = try #require(candidate.items.first?.id)

        let legacyVisible = ProfileLayout(visible: [ordinaryLiveID, legacyFocusID])
        let projected = try #require(contract.projecting(legacyVisible))
        #expect(projected.visible == [ordinaryLiveID])
        #expect(legacyVisible.visible == [ordinaryLiveID, legacyFocusID])
        #expect(contract.projecting(ProfileLayout(hidden: [legacyFocusID])) == nil)
        #expect(contract.projecting(ProfileLayout(alwaysHidden: [legacyFocusID])) == nil)

        let legacyPresentation = ResolvedProfilePresentation(
            source: .base,
            destinationDisplayID: nil,
            layout: legacyVisible,
            groups: [
                ProfileGroup(name: "Mixed", itemIDs: [ordinaryLiveID, legacyFocusID]),
                ProfileGroup(name: "Focus only", itemIDs: [legacyFocusID]),
            ],
            spacers: [
                ProfileSpacer(placement: .after(legacyFocusID)),
                ProfileSpacer(placement: .after(ordinaryLiveID)),
            ]
        )
        let projectedPresentation = try #require(contract.projecting(legacyPresentation))
        #expect(projectedPresentation.layout.visible == [ordinaryLiveID])
        #expect(projectedPresentation.groups.map(\.itemIDs) == [[ordinaryLiveID]])
        #expect(projectedPresentation.spacers.map(\.placement) == [.after(ordinaryLiveID)])
        let projectedSnapshot = contract.projecting(candidate)
        let resolvedForActivation = try projectedPresentation.resolvingItemIdentities(in: projectedSnapshot)
        #expect(resolvedForActivation.layout.visible == [ordinaryLiveID])

        let presentSnapshot = Self.continuitySnapshot(
            generation: 3, ordinaryItemCount: 7, includeFocus: true, capturedAt: now
        )
        let positiveLegacyResolution = try legacyPresentation.resolvingItemIdentities(in: presentSnapshot)
        #expect(positiveLegacyResolution.layout.visible == [ordinaryLiveID, MenuBarPlatformPresenceIdentity.focusItemID])
        #expect(try #require(presentSnapshot.resolvedItemID(for: legacyFocusID)) == MenuBarPlatformPresenceIdentity.focusItemID)
        #expect(presentSnapshot.resolvedItemID(for: MenuBarItemID(
            bundleIdentifier: "com.apple.MenuBarAgent",
            accessibilityIdentifier: "com.apple.menuextra.unknown",
            title: "Focus",
            alias: "occurrence-0",
            fallbackFingerprint: String(repeating: "a", count: 64)
        )) == nil)

        let unqualifiedScan = MenuBarObservationScan(
            scanID: UUID(),
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: presentSnapshot,
            initialEnvironment: scene,
            finalEnvironment: scene
        )
        #expect(MenuBarPlatformPresenceContract.admitting(
            MenuBarAuthorityObservation(snapshot: presentSnapshot, scan: unqualifiedScan)
        ) == nil)

        #expect(legacyPresentation.groups[0].itemIDs == [ordinaryLiveID, legacyFocusID])
        #expect(legacyPresentation.spacers.map(\.placement) == [
            .after(legacyFocusID), .after(ordinaryLiveID),
        ])

        #expect(!MenuBarPlatformPresenceIdentity.isFocusItem(MenuBarItemID(
            bundleIdentifier: "com.apple.MenuBarAgent",
            accessibilityIdentifier: "com.apple.menuextra.clock",
            title: "Focus"
        )))
    }

    @Test("Unattested Focus disappearance is not accepted by generic continuity thresholds")
    func genericContinuityRejectsUnattestedFocusLoss() {
        let now = Date()
        let ordinaryItems = (0 ..< 12).map { index in
            MenuBarItemDescriptor(
                id: MenuBarItemID(bundleIdentifier: "com.example.application", accessibilityIdentifier: "item-\(index)"),
                section: .visible,
                order: index,
                displayID: Self.display
            )
        }
        let otherSystemItems = (0 ..< 3).map { index in
            MenuBarItemDescriptor(
                id: MenuBarItemID(bundleIdentifier: "com.apple.system", accessibilityIdentifier: "control-\(index)"),
                section: .visible,
                order: ordinaryItems.count + index,
                displayID: Self.display,
                isSystemItem: true,
                sourceOwnership: .system
            )
        }
        let focus = Self.focusDescriptor(order: ordinaryItems.count + otherSystemItems.count)
        let previous = MenuBarSnapshot(
            generation: 1,
            capturedAt: now,
            items: ordinaryItems + otherSystemItems + [focus],
            displayIDs: [Self.display],
            activeSpaceIsValid: true
        )
        let candidate = MenuBarSnapshot(
            generation: 2,
            capturedAt: now,
            items: ordinaryItems + otherSystemItems,
            displayIDs: [Self.display],
            activeSpaceIsValid: true
        )

        #expect(SnapshotValidator().validate(candidate, previous: previous, now: now) == .failure(.platformPresenceContractChanged))
    }

    @Test("macOS 27 cache reuse requires associated qualified platform presence")
    func cacheReuseRequiresAssociatedPlatformPresence() {
        let snapshot = Self.snapshot()
        let scanID = UUID()
        let scene = Self.environment(Self.receipt())
        let unqualified = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: snapshot,
            initialEnvironment: scene,
            finalEnvironment: scene
        )
        #expect(!MenuBarPlatformPresenceContract.permitsCacheReuse(
            scan: unqualified,
            snapshot: snapshot,
            requiresQualifiedPresence: true
        ))
        #expect(MenuBarPlatformPresenceContract.permitsCacheReuse(
            scan: unqualified,
            snapshot: snapshot,
            requiresQualifiedPresence: false
        ))

        let qualified = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: snapshot,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: Self.nativePresence(scanID: scanID, focus: .absent)
        )
        #expect(MenuBarPlatformPresenceContract.permitsCacheReuse(
            scan: qualified,
            snapshot: snapshot,
            requiresQualifiedPresence: true
        ))
        #expect(!MenuBarPlatformPresenceContract.permitsCacheReuse(
            scan: qualified,
            snapshot: Self.snapshot(generation: 2, time: snapshot.capturedAt.addingTimeInterval(1)),
            requiresQualifiedPresence: true
        ))
    }

    @Test("Profile authority survives benign refreshes and defers during menu tracking")
    func profileAuthoritySurvivesRefreshAndDefersDuringMenuTracking() async throws {
        let now = Date()
        let snapshot = Self.continuitySnapshot(
            generation: 1, ordinaryItemCount: 2, includeFocus: false, capturedAt: now
        )
        let capabilityReadGate = CapabilityReadGate()
        let backend = QualifiedFocusPresenceBackend(snapshot: snapshot, capabilityReadGate: capabilityReadGate)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let liveSnapshot = try await coordinator.refresh(now: now)
        let ordinaryIDs = liveSnapshot.items.map(\.id)
        let profile = BarlineProfile(
            name: "Work",
            layout: ProfileLayout(
                visible: ordinaryIDs + [MenuBarPlatformPresenceIdentity.focusItemID]
            )
        )
        var workspace = ProfileWorkspaceState(profile: profile)
        workspace.presentation = ResolvedProfilePresentation(
            source: .base,
            destinationDisplayID: nil,
            layout: ProfileLayout(visible: ordinaryIDs),
            groups: [],
            spacers: []
        )
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: liveSnapshot,
            activeProfileID: profile.id,
            activeDisplayID: nil,
            workspace: workspace
        )

        #expect(!ProfileAuthorityMatcher.matches(
            profile: profile,
            checkpoint: checkpoint,
            destinationSupport: .emptySectionAllowed
        ))
        let assessmentTask = Task {
            await coordinator.assessProfileAuthority(profile: profile, checkpoint: checkpoint)
        }
        await capabilityReadGate.waitUntilBlocked()
        let refreshedSnapshot = try await coordinator.refresh(now: now.addingTimeInterval(1))
        #expect(refreshedSnapshot.generation > checkpoint.snapshot.generation)
        #expect(refreshedSnapshot.capturedAt != checkpoint.snapshot.capturedAt)
        await capabilityReadGate.release()
        #expect(await assessmentTask.value == .matches)

        await backend.setMenuTrackingIsActive(true)
        _ = try await coordinator.refresh(now: now.addingTimeInterval(2))
        #expect(await coordinator.assessProfileAuthority(profile: profile, checkpoint: checkpoint) == .temporarilyUnavailable)

        await backend.setMenuTrackingIsActive(false)
        await backend.setFirstItemSection(.hidden)
        _ = try await coordinator.refresh(now: now.addingTimeInterval(3))
        #expect(await coordinator.assessProfileAuthority(profile: profile, checkpoint: checkpoint) == .mismatch)
    }

    @Test("Profile authority ignores display identity enumeration order but detects remapping")
    func profileAuthorityUsesDisplayIdentityMappingRatherThanEnumerationOrder() async throws {
        let now = Date()
        let secondDisplay = MenuBarDisplayID("observation-fixture-secondary")
        let firstIdentity = MenuBarDisplayIdentity(
            runtimeID: Self.display,
            hardwareFingerprint: MenuBarDisplayHardwareFingerprint("v1:\(String(repeating: "a", count: 64))")
        )
        let secondIdentity = MenuBarDisplayIdentity(
            runtimeID: secondDisplay,
            hardwareFingerprint: MenuBarDisplayHardwareFingerprint("v1:\(String(repeating: "b", count: 64))")
        )
        let base = Self.continuitySnapshot(
            generation: 1, ordinaryItemCount: 2, includeFocus: false, capturedAt: now
        )
        let snapshot = MenuBarSnapshot(
            generation: base.generation,
            capturedAt: base.capturedAt,
            items: base.items,
            displayIDs: [Self.display, secondDisplay],
            displayIdentities: [firstIdentity, secondIdentity],
            activeSpaceIsValid: true
        )
        let backend = QualifiedFocusPresenceBackend(snapshot: snapshot)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let liveSnapshot = try await coordinator.refresh(now: now)
        let profile = BarlineProfile(
            name: "Work",
            layout: ProfileLayout(visible: liveSnapshot.items.map(\.id))
        )
        var workspace = ProfileWorkspaceState(profile: profile)
        workspace.presentation = ResolvedProfilePresentation(
            source: .base,
            destinationDisplayID: nil,
            layout: ProfileLayout(visible: liveSnapshot.items.map(\.id)),
            groups: [],
            spacers: []
        )
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: liveSnapshot,
            activeProfileID: profile.id,
            activeDisplayID: nil,
            workspace: workspace
        )

        await backend.setDisplayIdentities([secondIdentity, firstIdentity])
        _ = try await coordinator.refresh(now: now.addingTimeInterval(1))
        #expect(await coordinator.assessProfileAuthority(profile: profile, checkpoint: checkpoint) == .matches)

        let changedIdentity = MenuBarDisplayIdentity(
            runtimeID: Self.display,
            hardwareFingerprint: MenuBarDisplayHardwareFingerprint("v1:\(String(repeating: "c", count: 64))")
        )
        await backend.setDisplayIdentities([secondIdentity, changedIdentity])
        _ = try await coordinator.refresh(now: now.addingTimeInterval(2))
        #expect(await coordinator.assessProfileAuthority(profile: profile, checkpoint: checkpoint) == .mismatch)
    }
}

private actor LegacyObservationBackend: MenuBarBackend {
    let capabilities = MenuBarCapabilities.fallback
    private(set) var ordinaryCalls = 0
    private(set) var freshCalls = 0
    func snapshot() -> MenuBarSnapshot {
        ordinaryCalls += 1; return MenuBarAuthorityObservationTests.snapshot()
    }

    func snapshotForVerification() -> MenuBarSnapshot {
        freshCalls += 1; return MenuBarAuthorityObservationTests.snapshot()
    }

    func move(_: MenuBarMoveOperation) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func reveal(_: MenuBarItemID) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func activate(_: MenuBarItemID, button _: MenuBarMouseButton) {}
    func restore(_: MenuBarSnapshot) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "Legacy", state: .healthy)
    }

    func restart() {}
}

private actor QualifiedFocusPresenceBackend: MenuBarBackend {
    private let capabilityReadGate: CapabilityReadGate?
    private let observedSnapshot: MenuBarSnapshot
    private let unqualifiedObservationCalls: Set<Int>
    private let sessionID = UUID()
    private var observationSequence: UInt64 = 0
    private var menuTrackingIsActive: Bool
    private var firstItemSection: MenuBarSection?
    private var currentDisplayIdentities: [MenuBarDisplayIdentity]?
    private var mutationErrors: [MenuBarBackendError]
    private(set) var observationCalls = 0
    private(set) var moveCalls = 0

    var capabilities: MenuBarCapabilities {
        get async {
            if let capabilityReadGate {
                await capabilityReadGate.suspendFirstRead()
            }
            return MenuBarCapabilities(
                canSnapshot: true,
                canMove: true,
                canReveal: false,
                canActivate: true,
                canRestore: true,
                moveDestinationSupport: .emptySectionAllowed
            )
        }
    }

    init(
        snapshot: MenuBarSnapshot,
        capabilityReadGate: CapabilityReadGate? = nil,
        mutationErrors: [MenuBarBackendError] = [],
        unqualifiedObservationCalls: Set<Int> = []
    ) {
        observedSnapshot = snapshot
        self.capabilityReadGate = capabilityReadGate
        self.mutationErrors = mutationErrors
        self.unqualifiedObservationCalls = unqualifiedObservationCalls
        menuTrackingIsActive = snapshot.menuTrackingIsActive
        currentDisplayIdentities = snapshot.displayIdentities
    }

    func setMenuTrackingIsActive(_ isActive: Bool) {
        menuTrackingIsActive = isActive
    }

    func setFirstItemSection(_ section: MenuBarSection?) {
        firstItemSection = section
    }

    func setDisplayIdentities(_ identities: [MenuBarDisplayIdentity]?) {
        currentDisplayIdentities = identities
    }

    func snapshot() async throws -> MenuBarSnapshot {
        observedSnapshot
    }

    func authorityObservation(
        freshness _: MenuBarObservationFreshness
    ) async throws -> MenuBarAuthorityObservation {
        observationCalls += 1
        let call = observationCalls
        observationSequence += 1
        let snapshot = MenuBarSnapshot(
            generation: observedSnapshot.generation + observationSequence,
            capturedAt: observedSnapshot.capturedAt.addingTimeInterval(TimeInterval(observationSequence)),
            items: observedSnapshot.items.enumerated().map { index, item in
                index == 0 ? item.replacingSection(firstItemSection ?? item.section) : item
            },
            displayIDs: observedSnapshot.displayIDs,
            displayIdentities: currentDisplayIdentities,
            activeSpaceIsValid: observedSnapshot.activeSpaceIsValid,
            menuTrackingIsActive: menuTrackingIsActive
        )
        let scanID = UUID()
        let receipt = MenuBarAuthorityObservationTests.receipt(session: sessionID)
        let scene = MenuBarAuthorityObservationTests.environment(receipt, tracking: menuTrackingIsActive)
        let scan = MenuBarObservationScan(
            scanID: scanID,
            startedAtUptimeNanoseconds: 1,
            completedAtUptimeNanoseconds: 30,
            observedSnapshot: snapshot,
            initialEnvironment: scene,
            finalEnvironment: scene,
            platformPresenceObservation: unqualifiedObservationCalls.contains(call)
                ? nil
                : MenuBarAuthorityObservationTests.nativePresence(scanID: scanID, focus: .absent)
        )
        return MenuBarAuthorityObservation(snapshot: snapshot, scan: scan)
    }

    func move(_: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
        moveCalls += 1
        if mutationErrors.isEmpty {
            throw MenuBarBackendError.mutationNotStarted
        }
        throw mutationErrors.removeFirst()
    }

    func reveal(_: MenuBarItemID) async throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func activate(_: MenuBarItemID, button _: MenuBarMouseButton) async throws {}

    func restore(_: MenuBarSnapshot) async throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func health() async -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "Qualified Presence Fixture", state: .healthy)
    }

    func restart() async {}
}

private actor CapabilityReadGate {
    private var hasSuspendedFirstRead = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters = [CheckedContinuation<Void, Never>]()

    func suspendFirstRead() async {
        guard !hasSuspendedFirstRead else { return }
        hasSuspendedFirstRead = true
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
            requestWaiters.forEach { $0.resume() }
            requestWaiters.removeAll()
        }
    }

    func waitUntilBlocked() async {
        guard blockedContinuation == nil else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func release() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor AtomicObservationBackend: MenuBarBackend {
    let capabilities = MenuBarCapabilities(canSnapshot: true, canMove: true, canReveal: false, canActivate: true, canRestore: true,
                                           moveDestinationSupport: .emptySectionAllowed)
    private var generation: UInt64 = 0
    private var section = MenuBarSection.visible
    private var sessionID = UUID()
    private var cached: MenuBarAuthorityObservation?
    private var inventoryDropped = false
    private var observationFailure = false
    private var forcedGeneration: UInt64?
    private(set) var observationCalls = 0
    private(set) var freshCalls = 0
    private(set) var configureCalls = 0

    func configureConcealment(_: MenuBarConcealmentConfiguration) {
        configureCalls += 1
    }

    func snapshot() throws -> MenuBarSnapshot {
        throw MenuBarBackendError.operationFailed("legacy path unexpectedly called")
    }

    func snapshotForVerification() throws -> MenuBarSnapshot {
        throw MenuBarBackendError.operationFailed("legacy fresh path unexpectedly called")
    }

    func authorityObservation(freshness: MenuBarObservationFreshness) throws -> MenuBarAuthorityObservation {
        guard !observationFailure else { throw MenuBarBackendError.operationFailed("fixture observation failed") }
        observationCalls += 1
        if let forcedGeneration {
            generation = forcedGeneration
        } else {
            generation += 1
        }
        if freshness == .freshRequired {
            freshCalls += 1
        }
        if freshness == .cachedAllowed, let cached, !inventoryDropped {
            return cached.rebasingGeneration(to: generation)
        }
        var raw = MenuBarAuthorityObservationTests.snapshot(generation: generation, section: section)
        if inventoryDropped {
            raw = MenuBarSnapshot(generation: generation, capturedAt: raw.capturedAt, items: [], displayIDs: raw.displayIDs, activeSpaceIsValid: true)
        }
        let scene = MenuBarAuthorityObservationTests.environment(MenuBarAuthorityObservationTests.receipt(session: sessionID))
        let context = MenuBarAuthorityObservationTests.scan(raw, initial: scene)
        let observed = MenuBarAuthorityObservation(snapshot: raw, scan: context)
        cached = observed
        return observed
    }

    func dropInventory() {
        inventoryDropped = true
    }

    func failObservations() {
        observationFailure = true
    }

    func forceGeneration(_ value: UInt64) {
        forcedGeneration = value; cached = nil
    }

    func move(_ operation: MenuBarMoveOperation) -> MenuBarMutationResult {
        section = operation.section; cached = nil
        return MenuBarMutationResult(generation: generation, changedItemIDs: [operation.itemID])
    }

    func restore(_ snapshot: MenuBarSnapshot) -> MenuBarMutationResult {
        section = snapshot.items.first?.section ?? .visible; cached = nil
        return MenuBarMutationResult(generation: generation, changedItemIDs: [])
    }

    func reveal(_: MenuBarItemID) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.mutationNotStarted
    }

    func activate(_: MenuBarItemID, button _: MenuBarMouseButton) {}
    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "Atomic", state: .healthy)
    }

    func restart() {
        generation = 0; sessionID = UUID(); cached = nil
    }
}
