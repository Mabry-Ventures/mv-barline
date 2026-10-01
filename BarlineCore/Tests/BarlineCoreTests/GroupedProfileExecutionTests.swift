@testable import BarlineCore
import Foundation
import Testing

@Suite("Stateful grouped profile execution")
struct GroupedProfileExecutionTests {
    @Test("Native Focus suppression fails activation but recovers the original complete inventory")
    func restoresSuppressedFocus() async throws {
        let backend = GroupedProfileBackend(section: .visible, suppressesFocusAfterMove: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let prior = BarlineProfile(name: "Prior", layout: ProfileLayout(visible: backend.siblings))
        _ = try await coordinator.activate(profile: prior)
        let target = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        await #expect(throws: SnapshotRejectionReason.implausibleSystemItemCollapse(previous: 1, candidate: 0)) {
            try await coordinator.activate(profile: target)
        }
        #expect(await backend.nativeDeassertionCount == 1)
        #expect(await backend.visibilityMutationCount == 2)
        #expect(await coordinator.currentSnapshot?.items.count == 4)
        #expect(await coordinator.currentSnapshot?.items.allSatisfy { $0.section == .visible } == true)
        #expect(await coordinator.activeProfileID == prior.id)
    }

    @Test("An acknowledged native deassertion without Focus restoration cannot publish recovery authority")
    func rejectsIncompleteFocusRecovery() async throws {
        let backend = GroupedProfileBackend(section: .visible, suppressesFocusAfterMove: true, restoresFocus: false)
        let coordinator = MenuBarStateCoordinator(backend: backend, retryPolicy: .init(maximumAttempts: 1, baseDelay: .milliseconds(1)))
        let target = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        await #expect(throws: ProfileActivationRecoveryFailure.self) { try await coordinator.activate(profile: target) }
        #expect(await backend.nativeDeassertionCount == 1)
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == nil)
    }

    @Test("A changed inventory after native deassertion cannot authorize compensation", arguments: [
        "different_focus_id", "different_focus_display", "unrelated_section", "configuration_failure",
    ])
    func rejectsChangedDeassertionRecovery(fault: String) async throws {
        let backend = GroupedProfileBackend(
            section: .visible, suppressesFocusAfterMove: true, focusRecoveryFault: fault
        )
        let coordinator = MenuBarStateCoordinator(backend: backend, retryPolicy: .init(maximumAttempts: 1, baseDelay: .milliseconds(1)))
        let prior = BarlineProfile(name: "Prior", layout: ProfileLayout(visible: backend.siblings))
        _ = try await coordinator.activate(profile: prior)
        let target = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        await #expect(throws: ProfileActivationRecoveryFailure.self) { try await coordinator.activate(profile: target) }
        #expect(await backend.nativeDeassertionCount == 1)
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await backend.nativeReorderAttempts == 0)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == nil)
    }

    @Test("Cancellation cannot interrupt verified native Focus recovery")
    func recoversFocusAfterCancellation() async throws {
        let backend = GroupedProfileBackend(
            section: .visible, suppressesFocusAfterMove: true, cancelsAfterMove: true
        )
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let prior = BarlineProfile(name: "Prior", layout: ProfileLayout(visible: backend.siblings))
        _ = try await coordinator.activate(profile: prior)
        let target = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        let task = Task { try await coordinator.activate(profile: target) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await backend.nativeDeassertionCount == 1)
        #expect(await backend.visibilityMutationCount == 2)
        #expect(await coordinator.currentSnapshot?.items.count == 4)
        #expect(await coordinator.currentSnapshot?.items.allSatisfy { $0.section == .visible } == true)
        #expect(await coordinator.activeProfileID == prior.id)
    }

    @Test("The Focus-return wait honors the compensation deadline and withholds authority")
    func boundsFocusRecoveryWait() async throws {
        let backend = GroupedProfileBackend(
            section: .visible, suppressesFocusAfterMove: true, focusRecoveryFault: "wait_for_cancellation"
        )
        let coordinator = MenuBarStateCoordinator(backend: backend, compensationTimeout: .milliseconds(100))
        let target = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        do {
            _ = try await coordinator.activate(profile: target)
            Issue.record("A cancelled restoration observation must not authorize compensation")
        } catch let failure as ProfileActivationRecoveryFailure {
            #expect(failure.layoutRollbackError as? MenuBarBackendError == .timedOut)
        }
        #expect(await backend.nativeDeassertionCount == 1)
        #expect(await backend.cancelledRecoveryObservationCount == 1)
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot == nil)
    }

    @Test("Cancelled grouped activation compensates in its uncancelled recovery task")
    func compensatesCancellation() async throws {
        let backend = GroupedProfileBackend(section: .visible)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let prior = BarlineProfile(name: "Prior", layout: ProfileLayout(visible: backend.siblings))
        _ = try await coordinator.activate(profile: prior)
        let target = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        let task = Task {
            try await coordinator.activate(profile: target, admission: {
                if await backend.visibilityMutationCount == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await backend.visibilityMutationCount == 2)
        #expect(await backend.nativeReorderAttempts == 0)
        #expect(await coordinator.activeProfileID == prior.id)
    }

    @Test("Duplicate refreshed identities are rejected before step-validation dictionaries")
    func rejectsDuplicateRefresh() async throws {
        let backend = GroupedProfileBackend(section: .visible, duplicatesAfterMove: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        do {
            _ = try await coordinator.activate(profile: profile)
            Issue.record("Duplicate inventory must reject activation")
        } catch let failure as ProfileActivationRecoveryFailure {
            #expect(failure.activationError as? SnapshotRejectionReason == .duplicateItemIdentity(backend.siblings[0]))
        }
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("Harmless cross-display interleaving preserves each display's shelf ordering")
    func acceptsDisplayLocalShelfOrdering() async throws {
        let backend = GroupedProfileBackend(section: .visible, interleavesIndependentDisplays: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        let result = try await coordinator.activate(profile: profile)
        #expect(result.items.filter { backend.siblings.contains($0.id) }.allSatisfy { $0.section == .hidden })
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await backend.shelfMutationCount == 0)
        #expect(await coordinator.activeProfileID == profile.id)
    }

    @Test("A group member's concurrent display relocation withdraws authority without replay")
    func preservesGroupDisplayRelocation() async throws {
        let backend = GroupedProfileBackend(section: .visible, unrelatedOnOtherDisplay: true, relocatesGroupAfterMove: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        await #expect(throws: MenuBarBackendError.mutationSuperseded) {
            try await coordinator.activate(profile: profile)
        }
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await backend.shelfMutationCount == 0)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("A display-scoped grouped profile leaves the other display unchanged")
    func scopesGroupToDisplay() async throws {
        let backend = GroupedProfileBackend(section: .visible, unrelatedOnOtherDisplay: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let display = MenuBarDisplayID("test-display")
        let profile = BarlineProfile(name: "Scoped", displayOverrides: [
            DisplayProfileOverride(displayID: display, layout: ProfileLayout(hidden: backend.siblings)),
        ])
        let result = try await coordinator.activate(profile: profile, on: display)
        #expect(result.items.filter { $0.displayID == display }.allSatisfy { $0.section == .hidden })
        #expect(result.items.filter { $0.displayID != display }.allSatisfy { $0.section == .visible })
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await backend.movedUnrelated == false)
        #expect(await coordinator.activeProfileID == profile.id)
    }

    @Test("An unsafe or stale refreshed snapshot stops forward grouped execution", arguments: [false, true])
    func rejectsUnsafeRefresh(stale: Bool) async throws {
        let backend = GroupedProfileBackend(section: .visible, staleAfterMove: stale, trackingAfterMove: !stale)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        await #expect(throws: ProfileActivationRecoveryFailure.self) {
            try await coordinator.activate(profile: profile)
        }
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await backend.shelfMutationCount == 0)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("A non-progressing group backend fails within a finite move budget")
    func boundsNonconvergence() async throws {
        let backend = GroupedProfileBackend(section: .visible, stalls: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        await #expect(throws: MenuBarBackendError.operationFailed("profile layout execution did not converge")) {
            try await coordinator.activate(profile: profile)
        }
        #expect(await backend.visibilityMutationCount == 12)
        #expect(await coordinator.activeProfileID == nil)
    }

    @Test("An unrelated concurrent section change is not overwritten by replanning or compensation")
    func preservesUnrequestedSectionChange() async throws {
        let backend = GroupedProfileBackend(section: .visible, hidesUnrelatedAfterMove: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        await #expect(throws: MenuBarBackendError.mutationSuperseded) {
            try await coordinator.activate(profile: profile)
        }
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await backend.shelfMutationCount == 0)
        #expect(await backend.movedUnrelated == false)
        #expect(await coordinator.activeProfileID == nil)
        #expect(await coordinator.currentSnapshot?.items.allSatisfy { $0.section == .hidden } == true)
    }

    @Test("Grouped reveal does not replay an already revealed sibling")
    func revealsGroupOnce() async throws {
        let backend = GroupedProfileBackend(section: .hidden)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Visible", layout: ProfileLayout(visible: backend.siblings))
        let result = try await coordinator.activate(profile: profile)
        #expect(result.items.allSatisfy { $0.section == .visible })
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await backend.nativeReorderAttempts == 0)
        #expect(await coordinator.activeProfileID == profile.id)
    }

    @Test("Grouped compensation preserves the original admission error and prior authority")
    func compensatesGroupOnce() async throws {
        let backend = GroupedProfileBackend(section: .visible)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let prior = BarlineProfile(name: "Prior", layout: ProfileLayout(visible: backend.siblings))
        _ = try await coordinator.activate(profile: prior)
        let target = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        let injected = MenuBarBackendError.operationFailed("injected admission failure")
        await #expect(throws: injected) {
            try await coordinator.activate(profile: target, admission: {
                if await backend.visibilityMutationCount == 1 {
                    throw injected
                }
            })
        }
        #expect(await backend.visibilityMutationCount == 2)
        #expect(await backend.nativeReorderAttempts == 0)
        #expect(await coordinator.currentSnapshot?.items.allSatisfy { $0.section == .visible } == true)
        #expect(await coordinator.activeProfileID == prior.id)
    }

    @Test("Group hiding still applies the saved shelf ordering")
    func preservesReversedShelfOrder() async throws {
        let backend = GroupedProfileBackend(section: .visible)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let expected = Array(backend.siblings.reversed())
        let profile = BarlineProfile(name: "Reversed", layout: ProfileLayout(hidden: expected))
        let result = try await coordinator.activate(profile: profile)
        #expect(result.items.filter { $0.section == .hidden }.sorted { $0.order < $1.order }.map(\.id) == expected)
        #expect(await backend.visibilityMutationCount == 1)
        #expect(await backend.shelfMutationCount == 1)
        #expect(await backend.nativeReorderAttempts == 0)
    }

    @Test("Changed inventory after a group mutation cannot publish profile authority")
    func rejectsChangedInventory() async throws {
        let backend = GroupedProfileBackend(section: .visible, dropsUnrelatedAfterMove: true)
        let coordinator = MenuBarStateCoordinator(backend: backend)
        let profile = BarlineProfile(name: "Hidden", layout: ProfileLayout(hidden: backend.siblings))
        do {
            _ = try await coordinator.activate(profile: profile)
            Issue.record("Changed inventory must reject activation")
        } catch {
            #expect(await coordinator.activeProfileID == nil)
            #expect(await backend.nativeReorderAttempts == 0)
        }
    }
}

/// Unlike the scripted fake, this models native app-group mutation and rejects
/// unsupported same-visible operations exactly as the macOS 27 adapter does.
private actor GroupedProfileBackend: MenuBarBackend {
    nonisolated let siblings = [
        MenuBarItemID(bundleIdentifier: "com.example.group", accessibilityIdentifier: "A"),
        MenuBarItemID(bundleIdentifier: "com.example.group", accessibilityIdentifier: "B"),
    ]
    let capabilities = MenuBarCapabilities(
        canSnapshot: true, canMove: true, canReveal: false, canActivate: true, canRestore: false,
        moveDestinationSupport: .logicalSectionsPreserveNativeOrder,
        arrangement: MenuBarArrangementCapabilities(
            canReorderNativeItems: false, visibilityAssignmentGranularity: .applicationGroupAndKnownSystemItem,
            canReorderShelfItems: true, canApplySavedNativeOrder: false
        )
    )
    private var items: [MenuBarItemDescriptor]
    private var generation: UInt64 = 0
    private let display = MenuBarDisplayID("test-display")
    private let dropsUnrelatedAfterMove: Bool
    private let hidesUnrelatedAfterMove: Bool
    private let staleAfterMove: Bool
    private let trackingAfterMove: Bool
    private let stalls: Bool
    private let relocatesGroupAfterMove: Bool
    private let interleavesIndependentDisplays: Bool
    private let duplicatesAfterMove: Bool
    private let suppressesFocusAfterMove: Bool
    private let restoresFocus: Bool
    private let focusRecoveryFault: String?
    private let cancelsAfterMove: Bool
    private var suppressedFocus: MenuBarItemDescriptor?
    private(set) var nativeDeassertionCount = 0
    private(set) var cancelledRecoveryObservationCount = 0
    private(set) var visibilityMutationCount = 0
    private(set) var shelfMutationCount = 0
    private(set) var nativeReorderAttempts = 0
    private(set) var movedUnrelated = false

    init(
        section: MenuBarSection, dropsUnrelatedAfterMove: Bool = false,
        hidesUnrelatedAfterMove: Bool = false, staleAfterMove: Bool = false,
        trackingAfterMove: Bool = false, stalls: Bool = false, unrelatedOnOtherDisplay: Bool = false,
        relocatesGroupAfterMove: Bool = false, interleavesIndependentDisplays: Bool = false,
        duplicatesAfterMove: Bool = false, suppressesFocusAfterMove: Bool = false, restoresFocus: Bool = true,
        focusRecoveryFault: String? = nil, cancelsAfterMove: Bool = false
    ) {
        self.dropsUnrelatedAfterMove = dropsUnrelatedAfterMove
        self.hidesUnrelatedAfterMove = hidesUnrelatedAfterMove
        self.staleAfterMove = staleAfterMove
        self.trackingAfterMove = trackingAfterMove
        self.stalls = stalls
        self.relocatesGroupAfterMove = relocatesGroupAfterMove
        self.interleavesIndependentDisplays = interleavesIndependentDisplays
        self.duplicatesAfterMove = duplicatesAfterMove
        self.suppressesFocusAfterMove = suppressesFocusAfterMove
        self.restoresFocus = restoresFocus
        self.focusRecoveryFault = focusRecoveryFault
        self.cancelsAfterMove = cancelsAfterMove
        let localSiblings = siblings
        let localDisplay = MenuBarDisplayID("test-display")
        items = localSiblings.enumerated().map { index, id in
            MenuBarItemDescriptor(id: id, section: section, order: index, displayID: localDisplay)
        } + [MenuBarItemDescriptor(
            id: MenuBarItemID(bundleIdentifier: "com.example.unrelated", accessibilityIdentifier: "C"),
            section: .visible, order: 2,
            displayID: unrelatedOnOtherDisplay ? MenuBarDisplayID("other-display") : localDisplay
        )]
        if suppressesFocusAfterMove {
            items.append(MenuBarItemDescriptor(
                id: MenuBarItemID(bundleIdentifier: "com.apple.menubaragent", accessibilityIdentifier: "com.apple.menuextra.focusmode"),
                section: .visible, order: 3, displayID: localDisplay, isSystemItem: true, sourceOwnership: .system
            ))
        }
        if interleavesIndependentDisplays {
            items += [
                MenuBarItemDescriptor(
                    id: MenuBarItemID(bundleIdentifier: "com.example.shelf", accessibilityIdentifier: "D"),
                    section: .hidden, order: 3, displayID: localDisplay
                ),
                MenuBarItemDescriptor(
                    id: MenuBarItemID(bundleIdentifier: "com.example.shelf2", accessibilityIdentifier: "E"),
                    section: .hidden, order: 4, displayID: MenuBarDisplayID("other-display")
                ),
            ]
        }
    }

    func snapshot() async throws -> MenuBarSnapshot {
        if cancelsAfterMove {
            try Task.checkCancellation()
        }
        if focusRecoveryFault == "wait_for_cancellation", nativeDeassertionCount > 0 {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                cancelledRecoveryObservationCount += 1
                throw error
            }
        }
        generation &+= 1
        return MenuBarSnapshot(
            generation: generation, capturedAt: staleAfterMove && visibilityMutationCount > 0 ? .distantPast : Date(),
            items: items, displayIDs: Set(items.compactMap(\.displayID)), activeSpaceIsValid: true,
            menuTrackingIsActive: trackingAfterMove && visibilityMutationCount > 0
        )
    }

    func move(_ operation: MenuBarMoveOperation) throws -> MenuBarMutationResult {
        if operation.itemID.bundleIdentifier == "com.example.unrelated" {
            movedUnrelated = true
        }
        guard let source = items.first(where: { $0.id == operation.itemID }) else {
            throw MenuBarBackendError.staleItem(operation.itemID)
        }
        if source.section != operation.section {
            visibilityMutationCount += 1
            if !stalls {
                items = items.map {
                    $0.id.bundleIdentifier == source.id.bundleIdentifier ? $0.replacingSection(operation.section) : $0
                }
            }
        } else if source.section == .visible {
            nativeReorderAttempts += 1
            throw MenuBarBackendError.unavailableCapability("macOS 27 native menu bar reorder")
        } else {
            var destination = items.filter { $0.section == operation.section }.sorted { $0.order < $1.order }
            let sourceIndex = destination.firstIndex(where: { $0.id == source.id })!
            let insertion = min(operation.index, destination.count)
            destination.remove(at: sourceIndex)
            destination.insert(source, at: insertion - (sourceIndex < insertion ? 1 : 0))
            items = items.filter { $0.section != operation.section } + destination
            items = items.enumerated().map { $1.replacing(section: $1.section, order: $0) }
            shelfMutationCount += 1
        }
        if dropsUnrelatedAfterMove {
            items.removeAll { $0.id.bundleIdentifier == "com.example.unrelated" }
        }
        if hidesUnrelatedAfterMove {
            items = items.map { $0.id.bundleIdentifier == "com.example.unrelated" ? $0.replacingSection(.hidden) : $0 }
        }
        if relocatesGroupAfterMove {
            items = items.map { item in
                guard siblings.contains(item.id) else { return item }
                return MenuBarItemDescriptor(
                    id: item.id, section: item.section, order: item.order,
                    displayID: MenuBarDisplayID("other-display")
                )
            }
        }
        if interleavesIndependentDisplays {
            // Global enumeration can interleave displays without changing the
            // meaningful per-display shelf order: [A,B,D] and [E].
            items.sort { ($0.displayID?.value == "other-display" ? 0 : 1) < ($1.displayID?.value == "other-display" ? 0 : 1) }
            items = items.enumerated().map { $1.replacing(section: $1.section, order: $0) }
        }
        if duplicatesAfterMove, let first = items.first {
            items.append(first)
        }
        if suppressesFocusAfterMove, operation.section != .visible {
            suppressedFocus = items.first { $0.id.bundleIdentifier == "com.apple.menubaragent" }
            items.removeAll { $0.id.bundleIdentifier == "com.apple.menubaragent" }
        }
        if cancelsAfterMove, visibilityMutationCount == 1 {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return MenuBarMutationResult(generation: generation, changedItemIDs: siblings)
    }

    func configureConcealment(_ configuration: MenuBarConcealmentConfiguration) throws {
        guard configuration.concealedItemIDs.isEmpty else { throw MenuBarBackendError.mutationNotStarted }
        nativeDeassertionCount += 1
        if focusRecoveryFault == "configuration_failure" {
            throw MenuBarBackendError.operationFailed("injected configuration failure")
        }
        if restoresFocus, let suppressedFocus {
            switch focusRecoveryFault {
            case "different_focus_id":
                items.append(MenuBarItemDescriptor(
                    id: MenuBarItemID(bundleIdentifier: "com.apple.menubaragent", accessibilityIdentifier: "replacement.focusmode"),
                    section: .visible, order: suppressedFocus.order, displayID: suppressedFocus.displayID,
                    isSystemItem: true, sourceOwnership: .system
                ))
            case "different_focus_display":
                items.append(MenuBarItemDescriptor(
                    id: suppressedFocus.id, section: .visible, order: suppressedFocus.order,
                    displayID: MenuBarDisplayID("other-display"), isSystemItem: true, sourceOwnership: .system
                ))
            default:
                items.append(suppressedFocus)
            }
            if focusRecoveryFault == "unrelated_section" {
                items = items.map { $0.id.bundleIdentifier == "com.example.unrelated" ? $0.replacingSection(.hidden) : $0 }
            }
            self.suppressedFocus = nil
        }
    }

    func reveal(_: MenuBarItemID) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("reveal")
    }

    func activate(_: MenuBarItemID, button _: MenuBarMouseButton) {}
    func restore(_: MenuBarSnapshot) throws -> MenuBarMutationResult {
        throw MenuBarBackendError.unavailableCapability("restore")
    }

    func health() -> MenuBarBackendHealth {
        MenuBarBackendHealth(backendName: "Grouped", state: .healthy)
    }

    func restart() {}
}
