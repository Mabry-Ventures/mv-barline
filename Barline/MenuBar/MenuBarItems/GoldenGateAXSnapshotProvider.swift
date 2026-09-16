//
//  GoldenGateAXSnapshotProvider.swift
//  Barline
//

@preconcurrency import AppKit
@preconcurrency import AXSwift
import BarlineCore
import CoreGraphics
import CryptoKit
import Foundation
import os
import Security

/// macOS grants Accessibility to the signed application identity, not to its
/// embedded XPC service. Keep public AX inventory here in the trusted app and
/// leave all private WindowServer access isolated in BarlineMenuService.
actor GoldenGateAXSnapshotProvider {
    private struct ExplicitLayout: Codable {
        let version: Int
        let assignments: [GoldenGateLogicalAssignment]
    }

    private struct RememberedAssignment: Codable {
        let itemID: MenuBarItemID
        let section: BarlineCore.MenuBarSection
    }

    private struct RememberedAssignments: Codable {
        let version: Int
        let assignments: [RememberedAssignment]
    }

    private struct RetainedInventory: Codable {
        let version: Int
        let descriptors: [MenuBarItemDescriptor]
    }

    private struct PreparedPersistence {
        let assignments: [GoldenGateLogicalAssignment]
        let assignmentData: Data
        let descriptors: [MenuBarItemDescriptor]
        let descriptorData: Data
    }

    private enum RecoveryPersistenceError: Error {
        case invalidCompanion
        case synchronizeFailed
    }

    private struct ElementMetadata {
        let identifier: String?
        let accessibilityDescription: String?
        let title: String?
        let bounds: CGRect?
    }

    private struct Entry {
        let observation: GoldenGateMenuBarObservation
        let element: AXUIElement
        /// The root plus the direct children already inspected during this
        /// inventory pass. Used only by an explicit, bounded diagnostic.
        let identityElements: [AXUIElement]
        /// AX candidates are transaction-local and are used only by the
        /// read-only macOS 27 key-schema diagnostic. They are never persisted
        /// or written to logs.
        let positionKeyCandidates: PositionKeyCandidates
        /// The application that published this menu-bar item. Its bundle ID and
        /// signing identity must be derived from the same process.
        let publisherProcessIdentifier: Int32
        /// The process reported by the AX element. On macOS 27 this can be a
        /// MenuBarAgent re-vend, so it is not suitable for publisher signing
        /// identity resolution.
        let axElementProcessIdentifier: Int32?
    }

    private struct PositionKeyCandidates {
        let identifier: String?
        let accessibilityDescription: String?
        let title: String?
        let titleIsRootValue: Bool
        let currentIdentityOrigin: IdentityOrigin
    }

    private enum IdentityOrigin: String {
        case identifier
        case accessibilityDescription = "accessibility_description"
        case title
        case generatedFallback = "generated_fallback"
    }

    private enum IdentityAttribute: CaseIterable {
        case identifier
        case accessibilityDescription
        case title

        var axAttribute: Attribute {
            switch self {
            case .identifier: .identifier
            case .accessibilityDescription: .description
            case .title: .title
            }
        }

        var diagnosticName: String {
            switch self {
            case .identifier: "identifier"
            case .accessibilityDescription: "description"
            case .title: "title"
            }
        }
    }

    private struct IdentityReadAudit {
        private let rootResults: [IdentityAttribute: AXHelpers.StringAttributeReadDisposition]
        private let childResults: [IdentityAttribute: [AXHelpers.StringAttributeReadDisposition]]

        init(root: AXUIElement, children: [AXUIElement]) {
            rootResults = Dictionary(uniqueKeysWithValues: IdentityAttribute.allCases.map { attribute in
                (
                    attribute,
                    AXHelpers.stringAttributeReadDisposition(
                        for: UIElement(root),
                        attribute: attribute.axAttribute
                    )
                )
            })
            childResults = Dictionary(uniqueKeysWithValues: IdentityAttribute.allCases.map { attribute in
                (
                    attribute,
                    children.map {
                        AXHelpers.stringAttributeReadDisposition(
                            for: UIElement($0),
                            attribute: attribute.axAttribute
                        )
                    }
                )
            })
        }

        func rootStatus(for attribute: IdentityAttribute) -> String {
            rootResults[attribute]?.rawValue ?? "other_error"
        }

        func childCounts(for attribute: IdentityAttribute) -> String {
            let values = childResults[attribute] ?? []
            return AXHelpers.StringAttributeReadDisposition.allCases.map { disposition in
                "\(disposition.rawValue):\(values.count(where: { $0 == disposition }))"
            }.joined(separator: "|")
        }
    }

    /// A deliberately narrow follow-up to the direct-element audit. Some
    /// macOS 27 status items publish an unlabeled container followed by a
    /// labeled descendant. This audit inspects at most one additional level
    /// of the AX tree, only during a requested native move, and keeps every
    /// discovered value in-memory for matching only. Its log output is counts
    /// and result categories, never an accessibility value or position key.
    private struct DescendantIdentityReadAudit {
        private let childReadResults: [AXHelpers.ChildrenReadDisposition]
        private let valueResults: [IdentityAttribute: [AXHelpers.StringAttributeReadDisposition]]
        let candidates: [GoldenGatePositionKeyCandidate]
        let nodeCount: Int

        init(directParents: [AXUIElement], maximumNodes: Int) {
            var childReadResults: [AXHelpers.ChildrenReadDisposition] = []
            var descendants: [AXUIElement] = []

            for parent in directParents where descendants.count < maximumNodes {
                let parentElement = UIElement(parent)
                let disposition = AXHelpers.childrenReadDisposition(for: parentElement)
                childReadResults.append(disposition)
                guard disposition == .success else { continue }

                let remainingCapacity = maximumNodes - descendants.count
                descendants.append(contentsOf: AXHelpers.children(for: parentElement)
                    .prefix(remainingCapacity)
                    .map(\.element))
            }

            self.childReadResults = childReadResults
            nodeCount = descendants.count
            valueResults = Dictionary(uniqueKeysWithValues: IdentityAttribute.allCases.map { attribute in
                (
                    attribute,
                    descendants.map {
                        AXHelpers.stringAttributeReadDisposition(
                            for: UIElement($0),
                            attribute: attribute.axAttribute
                        )
                    }
                )
            })
            candidates = descendants.flatMap { descendant in
                let element = UIElement(descendant)
                return [
                    GoldenGatePositionKeyCandidate(
                        kind: .accessibilityIdentifier,
                        value: AXHelpers.identifier(for: element)
                    ),
                    GoldenGatePositionKeyCandidate(
                        kind: .accessibilityDescription,
                        value: AXHelpers.accessibilityDescription(for: element)
                    ),
                    GoldenGatePositionKeyCandidate(
                        kind: .accessibilityTitle,
                        value: AXHelpers.title(for: element)
                    ),
                ]
            }
        }

        func childReadCounts() -> String {
            AXHelpers.ChildrenReadDisposition.allCases.map { disposition in
                "\(disposition.rawValue):\(childReadResults.count(where: { $0 == disposition }))"
            }.joined(separator: "|")
        }

        func valueReadCounts(for attribute: IdentityAttribute) -> String {
            let values = valueResults[attribute] ?? []
            return AXHelpers.StringAttributeReadDisposition.allCases.map { disposition in
                "\(disposition.rawValue):\(values.count(where: { $0 == disposition }))"
            }.joined(separator: "|")
        }

        func candidateCount(for kind: GoldenGatePositionKeyCandidateKind) -> Int {
            candidates.count(where: { candidate in
                candidate.kind == kind && candidate.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            })
        }
    }

    private static let maximumItemHeight: CGFloat = 40
    private static let duplicateTolerance: CGFloat = 1
    private static let menuBarAgentBundleIdentifier = "com.apple.MenuBarAgent"
    private static let rememberedSectionsKey = "GoldenGateRememberedMenuBarSections"
    private static let explicitLayoutKey = "GoldenGateExplicitMenuBarLayout"
    private static let retainedInventoryKey = "GoldenGateRetainedMenuBarInventory"
    private static let maximumRememberedBytes = 256 * 1024
    private static let maximumRememberedAssignments = 512

    private let logger = Logger(category: "GoldenGateAXSnapshotProvider")
    private var generation: UInt64 = 0
    private var cachedAt: UInt64?
    private var cachedSnapshot: MenuBarSnapshot?
    private var rememberedSections = GoldenGateAXSnapshotProvider.loadRememberedSections()
    private var explicitAssignments = GoldenGateAXSnapshotProvider.loadExplicitAssignments()
    private var retainedDescriptors = GoldenGateAXSnapshotProvider.loadRetainedInventory()
    /// Proposed assignments are visible only to the bounded post-write
    /// verifier. They are never written to UserDefaults or retained inventory
    /// until the native position transaction is durably verified.
    private var verificationAssignments: [MenuBarItemID: GoldenGateLogicalAssignment]?
    private var verificationAffectedItemIDs: Set<MenuBarItemID> = []
    private var verificationAxisDirection: GoldenGatePositionTablePlanner.AxisDirection?
    private let logicalLayoutPlanner = GoldenGateLogicalLayoutPlanner()
    private let positionTableStore = GoldenGatePositionTableStore()
    private var didAttemptInterruptedTransactionRecovery = false

    var capabilities: MenuBarCapabilities {
        get async {
            let canSnapshot = await (try? snapshot()) != nil
            return MenuBarCapabilities(
                canSnapshot: canSnapshot,
                canMove: canSnapshot,
                canReveal: false,
                canActivate: canSnapshot,
                canRestore: canSnapshot,
                canCapture: false,
                moveDestinationSupport: .emptySectionAllowed
            )
        }
    }

    func snapshot() async throws -> MenuBarSnapshot {
        try await snapshot(forceRefresh: false)
    }

    private func snapshot(forceRefresh: Bool) async throws -> MenuBarSnapshot {
        if !didAttemptInterruptedTransactionRecovery {
            do {
                try await reconcileInterruptedPositionTransaction()
            } catch {
                // Access can be granted later by the first explicit move. Do
                // not permanently suppress recovery because an early passive
                // snapshot could not open the scoped position table.
                logger.debug(
                    "Golden Gate deferred interrupted-transaction recovery: code=\(PrivacySafeDiagnostics.errorCode(error), privacy: .public)"
                )
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if !forceRefresh,
           let cachedAt,
           let cachedSnapshot,
           now >= cachedAt,
           now - cachedAt < GoldenGateTiming.snapshotCacheLifetimeNanoseconds
        {
            return cachedSnapshot
        }

        guard AXHelpers.isProcessTrusted() else {
            throw MenuBarBackendError.unavailableCapability("Accessibility menu bar inventory")
        }
        let entries = collectEntries()
        let observations = entries.map(\.observation)
        guard !observations.isEmpty else {
            throw MenuBarBackendError.unavailableCapability("Accessibility menu bar inventory")
        }
        let activeDisplays = activeDisplayIDs()
        let displayIdentities = activeDisplays.map { displayID in
            MenuBarDisplayIdentity(
                runtimeID: stableDisplayID(displayID),
                hardwareFingerprint: hardwareFingerprint(for: displayID)
            )
        }
        guard let activeScreen = NSScreen.screenWithActiveMenuBar,
              activeDisplays.contains(activeScreen.displayID)
        else {
            throw MenuBarBackendError.unavailableCapability("active menu bar display")
        }
        generation &+= 1
        let activeBounds = CGDisplayBounds(activeScreen.displayID)
        let signingIdentifier = Bundle.main.bundleIdentifier
            ?? "com.mabryventures.Barline"
        let hiddenControlUsesLiveGeometry = observations.contains { observation in
            observation.bundleIdentifier.caseInsensitiveCompare(signingIdentifier) == .orderedSame &&
                observation.stableTitle == "Barline.ControlItem.Hidden" &&
                activeBounds.intersects(CGRect(
                    x: observation.bounds.x,
                    y: observation.bounds.y,
                    width: observation.bounds.width,
                    height: observation.bounds.height
                ))
        }
        let built = try GoldenGateMenuBarSnapshotBuilder.build(
            observations: observations,
            displayIdentities: displayIdentities,
            activeDisplayID: stableDisplayID(activeScreen.displayID),
            activeDisplayBounds: MenuBarRect(
                x: activeBounds.minX,
                y: activeBounds.minY,
                width: activeBounds.width,
                height: activeBounds.height
            ),
            appSigningIdentifier: signingIdentifier,
            rememberedSections: hiddenControlUsesLiveGeometry ? [:] : rememberedSections,
            assignedSections: [:],
            generation: generation
        )
        let effectiveAssignments = explicitAssignments.merging(
            verificationAssignments ?? [:],
            uniquingKeysWith: { _, proposed in proposed }
        )
        var result = GoldenGateRetainedInventoryPolicy.merging(
            live: built,
            retainedDescriptors: retainedDescriptors,
            assignments: effectiveAssignments,
            runningBundleIdentifiers: Set(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            ),
            barlineBundleIdentifier: signingIdentifier
        )
        let positions = try? await positionTableStore.readPositions(
            requestAccessIfNeeded: false
        )
        result = try applyingPositionTableCapabilities(
            to: result,
            observations: observations,
            positions: positions
        )
        if hiddenControlUsesLiveGeometry, explicitAssignments.isEmpty {
            rememberSections(from: result)
        }
        if verificationAssignments == nil,
           let prepared = try? prepareRetainedInventory(from: result, requiredItemIDs: [])
        {
            commitRetainedInventory(prepared)
        }
        cachedAt = now
        cachedSnapshot = result
        logger.info(
            "Main-process Golden Gate inventory completed: items=\(result.items.count, privacy: .public), controls=\(result.items.count(where: \.isBarlineControlItem), privacy: .public)"
        )
        return result
    }

    func move(_ operation: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
        let preparation: (
            before: MenuBarSnapshot,
            source: MenuBarItemDescriptor,
            persistence: PreparedPersistence,
            mutation: GoldenGatePositionMutation,
            stableAxisDirection: GoldenGatePositionTablePlanner.AxisDirection,
            changedItemIDs: [MenuBarItemID]
        )
        do {
            let initial = try await snapshot()
            _ = try await positionTableStore.readPositions(
                requestAccessIfNeeded: true
            )
            // A passive startup snapshot cannot prompt. Once this explicit
            // user action grants access, drain any durable transaction before
            // planning from a fresh authoritative table.
            try await reconcileInterruptedPositionTransaction()
            let positions = try await positionTableStore.readPositions(
                requestAccessIfNeeded: false
            )
            let entries = collectEntries()
            let teamIdentifiersByItemID = signingTeamIdentifiers(for: entries)
            let before = try applyingPositionTableCapabilities(
                to: initial,
                observations: entries.map(\.observation),
                positions: positions,
                teamIdentifiersByItemID: teamIdentifiersByItemID
            )
            guard let source = before.items.first(where: { $0.id == operation.itemID }) else {
                throw MenuBarBackendError.staleItem(operation.itemID)
            }
            guard Self.isPositionTableEligible(source) else {
                throw MenuBarBackendError.operationFailed("menu bar item cannot be assigned independently")
            }
            if operation.section != .visible, !source.canBeHidden {
                throw MenuBarBackendError.operationFailed("menu bar item cannot be hidden")
            }

            let candidate = try physicalCandidate(applying: operation, to: before)
            let persistence = try preparePersistence(
                from: candidate,
                requiredItemIDs: [source.id]
            )
            let keysByItemID = positionKeys(
                observations: entries.map(\.observation),
                positions: positions,
                snapshot: before,
                teamIdentifiersByItemID: teamIdentifiersByItemID
            )
            logIdentityResolutionAudit(
                source: source,
                entries: entries,
                positions: positions,
                teamIdentifiersByItemID: teamIdentifiersByItemID,
                resolvedKeys: keysByItemID
            )
            guard keysByItemID[source.id] != nil else {
                throw MenuBarBackendError.positionTableIdentityUnresolved
            }
            let mutation = try GoldenGatePositionTablePlanner.planMove(
                operation,
                in: before,
                positions: positions,
                keysByItemID: keysByItemID
            )
            let stableAxisDirection = try GoldenGatePositionTablePlanner.resolvedAxisDirection(
                snapshot: before,
                positions: positions,
                keysByItemID: keysByItemID
            )
            let changedPositionKeys = Set(mutation.changes.map(\.key))
            var changedItemIDs = before.items.compactMap { item -> MenuBarItemID? in
                guard !item.isBarlineControlItem,
                      item.isMovable,
                      let positionKey = keysByItemID[item.id],
                      changedPositionKeys.contains(positionKey)
                else { return nil }
                return item.id
            }
            if !changedItemIDs.contains(source.id) {
                changedItemIDs.append(source.id)
            }
            guard changedItemIDs.count <= 256 else {
                throw MenuBarBackendError.operationFailed("move plan exceeds the safe operation limit")
            }
            preparation = (
                before,
                source,
                persistence,
                mutation,
                stableAxisDirection,
                changedItemIDs
            )
        } catch {
            didAttemptInterruptedTransactionRecovery = false
            logger.error(
                "Golden Gate move preflight rejected: \(Self.preflightDiagnosticCode(error), privacy: .public)"
            )
            throw translatedPreflightError(error)
        }
        let before = preparation.before
        let source = preparation.source
        let persistence = preparation.persistence
        let mutation = preparation.mutation
        logger.notice(
            "Golden Gate move planned: section=\(String(describing: operation.section), privacy: .public), index=\(operation.index, privacy: .public), changes=\(mutation.changes.count, privacy: .public), sourceX=\(source.bounds.x, privacy: .public)"
        )
        verificationAssignments = Dictionary(uniqueKeysWithValues: persistence.assignments.map {
            ($0.itemID, $0)
        })
        verificationAffectedItemIDs = Set(preparation.changedItemIDs)
        verificationAxisDirection = preparation.stableAxisDirection
        var didApply = false
        do {
            try await positionTableStore.apply(mutation)
            didApply = true
            cachedAt = nil
            cachedSnapshot = nil
            let verified = try await verifyPositionMutation(
                operation,
                previousSnapshot: before,
                timeout: .seconds(3)
            )
            logger.notice("Golden Gate position table reached its verified AX postcondition")
            let verifiedPersistence = try preparePersistence(
                from: verified,
                requiredItemIDs: [source.id]
            )
            generation = verified.generation
            try await positionTableStore.markVerified(
                mutation,
                companionState: companionState(for: verifiedPersistence)
            )
            verificationAssignments = nil
            verificationAffectedItemIDs = []
            verificationAxisDirection = nil
            let didPersist = commitPersistence(verifiedPersistence)
            do {
                guard didPersist else {
                    throw MenuBarBackendError.operationFailed(
                        "verified menu bar state could not be synchronized"
                    )
                }
                try await positionTableStore.finishTransaction()
            } catch {
                // A verified journal is intentionally recoverable as committed
                // native state. Never roll back after local state is committed.
                didAttemptInterruptedTransactionRecovery = false
                logger.error(
                    "Golden Gate verified journal cleanup deferred: code=\(PrivacySafeDiagnostics.errorCode(error), privacy: .public)"
                )
            }
            cachedAt = DispatchTime.now().uptimeNanoseconds
            cachedSnapshot = verified
        } catch {
            verificationAssignments = nil
            verificationAffectedItemIDs = []
            verificationAxisDirection = nil
            cachedAt = nil
            cachedSnapshot = nil
            didAttemptInterruptedTransactionRecovery = false
            guard didApply else {
                throw translatedApplyError(error)
            }
            do {
                _ = try await positionTableStore.rollback(mutation)
                // Whether the original proposal was restored or a concurrent
                // native value won, the provider has removed its journal and
                // the coordinator must observe native state instead of issuing
                // a stale second restore.
                throw MenuBarBackendError.mutationSuperseded
            } catch let backendError as MenuBarBackendError {
                throw backendError
            } catch {
                throw MenuBarBackendError.mutationRecoveryFailed
            }
        }
        return MenuBarMutationResult(
            generation: generation,
            changedItemIDs: preparation.changedItemIDs
        )
    }

    func restore(_ target: MenuBarSnapshot) async throws -> MenuBarMutationResult {
        let preparation: (
            mutation: GoldenGatePositionMutation,
            changedItemIDs: [MenuBarItemID],
            stableAxisDirection: GoldenGatePositionTablePlanner.AxisDirection,
            requiredItemIDs: Set<MenuBarItemID>,
            verificationPersistence: PreparedPersistence
        )
        do {
            let initial = try await snapshot()
            _ = try await positionTableStore.readPositions(requestAccessIfNeeded: true)
            try await reconcileInterruptedPositionTransaction()
            let positions = try await positionTableStore.readPositions(requestAccessIfNeeded: false)
            let entries = collectEntries()
            let teamIdentifiersByItemID = signingTeamIdentifiers(for: entries)
            let current = try applyingPositionTableCapabilities(
                to: initial,
                observations: entries.map(\.observation),
                positions: positions,
                teamIdentifiersByItemID: teamIdentifiersByItemID
            )
            let currentIDs = Set(current.items.map(\.id))
            let keysByItemID = positionKeys(
                observations: entries.map(\.observation),
                positions: positions,
                snapshot: current,
                teamIdentifiersByItemID: teamIdentifiersByItemID
            )
            let mutation = try GoldenGatePositionTablePlanner.planRestore(
                target: target,
                current: current,
                positions: positions,
                keysByItemID: keysByItemID
            )
            if mutation.changes.isEmpty {
                return MenuBarMutationResult(
                    generation: current.generation,
                    changedItemIDs: []
                )
            }
            let changedPositionKeys = Set(mutation.changes.map(\.key))
            let changedItemIDs = current.items.compactMap { item -> MenuBarItemID? in
                guard !item.isBarlineControlItem,
                      item.isMovable,
                      let positionKey = keysByItemID[item.id],
                      changedPositionKeys.contains(positionKey)
                else { return nil }
                return item.id
            }
            guard changedItemIDs.count <= 256 else {
                throw MenuBarBackendError.operationFailed(
                    "restore plan exceeds the safe operation limit"
                )
            }
            let stableAxisDirection = try GoldenGatePositionTablePlanner.resolvedAxisDirection(
                snapshot: current,
                positions: positions,
                keysByItemID: keysByItemID
            )
            let requiredItemIDs = Set(target.items.compactMap { item -> MenuBarItemID? in
                guard !item.isBarlineControlItem, currentIDs.contains(item.id) else { return nil }
                return item.id
            })
            let verificationPersistence = try preparePersistence(
                from: target,
                requiredItemIDs: requiredItemIDs
            )
            preparation = (
                mutation,
                changedItemIDs,
                stableAxisDirection,
                requiredItemIDs,
                verificationPersistence
            )
        } catch {
            didAttemptInterruptedTransactionRecovery = false
            throw translatedPreflightError(error)
        }
        let mutation = preparation.mutation
        let changedItemIDs = preparation.changedItemIDs
        let requiredItemIDs = preparation.requiredItemIDs
        let verificationPersistence = preparation.verificationPersistence
        verificationAssignments = Dictionary(uniqueKeysWithValues: verificationPersistence.assignments.map {
            ($0.itemID, $0)
        })
        verificationAffectedItemIDs = Set(changedItemIDs)
        verificationAxisDirection = preparation.stableAxisDirection
        var didApply = false
        do {
            try await positionTableStore.apply(mutation)
            didApply = true
            cachedAt = nil
            cachedSnapshot = nil
            let verified = try await verifyRestore(
                target,
                requiredItemIDs: requiredItemIDs,
                timeout: .seconds(5)
            )
            let persistence = try preparePersistence(
                from: verified,
                requiredItemIDs: requiredItemIDs
            )
            generation = verified.generation
            try await positionTableStore.markVerified(
                mutation,
                companionState: companionState(for: persistence)
            )
            verificationAssignments = nil
            verificationAffectedItemIDs = []
            verificationAxisDirection = nil
            let didPersist = commitPersistence(persistence)
            do {
                guard didPersist else {
                    throw MenuBarBackendError.operationFailed(
                        "verified menu bar restore state could not be synchronized"
                    )
                }
                try await positionTableStore.finishTransaction()
            } catch {
                didAttemptInterruptedTransactionRecovery = false
                logger.error(
                    "Golden Gate verified restore journal cleanup deferred: code=\(PrivacySafeDiagnostics.errorCode(error), privacy: .public)"
                )
            }
            cachedAt = DispatchTime.now().uptimeNanoseconds
            cachedSnapshot = verified
        } catch {
            verificationAssignments = nil
            verificationAffectedItemIDs = []
            verificationAxisDirection = nil
            cachedAt = nil
            cachedSnapshot = nil
            didAttemptInterruptedTransactionRecovery = false
            guard didApply else {
                throw translatedApplyError(error)
            }
            do {
                _ = try await positionTableStore.rollback(mutation)
                throw MenuBarBackendError.mutationSuperseded
            } catch let backendError as MenuBarBackendError {
                throw backendError
            } catch {
                throw MenuBarBackendError.mutationRecoveryFailed
            }
        }
        return MenuBarMutationResult(
            generation: generation,
            changedItemIDs: changedItemIDs
        )
    }

    func health() async -> MenuBarBackendHealth {
        let available = await (try? snapshot()) != nil
        return MenuBarBackendHealth(
            backendName: "GoldenGateMainProcessAX",
            state: available ? .healthy : .unavailable,
            message: available ? nil : "Accessibility inventory is unavailable"
        )
    }

    /// Presentation-only synchronization shares this actor with logical moves
    /// and records the last helper-acknowledged complete configuration. A later
    /// failed mutation can therefore restore the actual native presentation,
    /// not a logical-layout approximation.
    func configureConcealment(
        _: MenuBarConcealmentConfiguration
    ) async throws {}

    func activate(_ itemID: MenuBarItemID, button: MenuBarMouseButton) throws {
        guard button == .left else {
            throw MenuBarBackendError.unavailableCapability(
                "Golden Gate Accessibility activation for non-left click"
            )
        }
        guard AXHelpers.isProcessTrusted() else {
            throw MenuBarBackendError.unavailableCapability(
                "Accessibility menu bar activation"
            )
        }
        let entries = collectEntries()
        let identifiers = GoldenGateMenuBarSnapshotBuilder.identifiers(
            for: entries.map(\.observation)
        )
        guard let resolvedID = GoldenGateMenuBarIdentityResolver.resolve(
            itemID,
            among: identifiers
        ),
            let entry = zip(entries, identifiers).first(where: { $0.1 == resolvedID })?.0
        else {
            throw MenuBarBackendError.staleItem(itemID)
        }
        AXUIElementSetMessagingTimeout(entry.element, 0.25)
        let result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
        switch GoldenGateAXActivationPolicy.disposition(forAXError: result.rawValue) {
        case .delivered, .deliveredIndeterminately:
            // `cannotComplete` can arrive after the target handled the action.
            // Never retry it; the caller independently observes the interface.
            return
        case .failed:
            throw MenuBarBackendError.operationFailed(
                "Golden Gate Accessibility activation failed"
            )
        }
    }

    func restart() {
        cachedAt = nil
        cachedSnapshot = nil
    }

    private static func loadRememberedSections() -> [MenuBarItemID: BarlineCore.MenuBarSection] {
        guard let data = UserDefaults.standard.data(forKey: rememberedSectionsKey),
              data.count <= maximumRememberedBytes,
              let document = try? JSONDecoder().decode(RememberedAssignments.self, from: data),
              document.version == 1,
              document.assignments.count <= maximumRememberedAssignments
        else {
            return [:]
        }
        var result = [MenuBarItemID: BarlineCore.MenuBarSection]()
        for assignment in document.assignments {
            guard assignment.itemID.isPlausiblyStable,
                  result.updateValue(assignment.section, forKey: assignment.itemID) == nil
            else {
                return [:]
            }
        }
        return result
    }

    private static func loadExplicitAssignments() -> [MenuBarItemID: GoldenGateLogicalAssignment] {
        guard let data = UserDefaults.standard.data(forKey: explicitLayoutKey),
              data.count <= maximumRememberedBytes,
              let document = try? JSONDecoder().decode(ExplicitLayout.self, from: data),
              document.version == 1,
              document.assignments.count <= maximumRememberedAssignments
        else { return [:] }
        var result = [MenuBarItemID: GoldenGateLogicalAssignment]()
        for assignment in document.assignments {
            guard assignment.itemID.isPlausiblyStable,
                  assignment.rank >= 0,
                  result.updateValue(assignment, forKey: assignment.itemID) == nil
            else { return [:] }
        }
        return result
    }

    private static func loadRetainedInventory() -> [MenuBarItemID: MenuBarItemDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: retainedInventoryKey),
              data.count <= maximumRememberedBytes,
              let document = try? JSONDecoder().decode(RetainedInventory.self, from: data),
              document.version == 1,
              document.descriptors.count <= maximumRememberedAssignments
        else { return [:] }
        var result = [MenuBarItemID: MenuBarItemDescriptor]()
        for descriptor in document.descriptors {
            guard descriptor.id.isPlausiblyStable,
                  result.updateValue(sanitizedDescriptor(descriptor), forKey: descriptor.id) == nil
            else { return [:] }
        }
        return result
    }

    private func preparePersistence(
        from snapshot: MenuBarSnapshot,
        requiredItemIDs: Set<MenuBarItemID>
    ) throws -> PreparedPersistence {
        let assignmentCandidates = logicalLayoutPlanner.assignmentsForPersistence(
            from: snapshot,
            preserving: explicitAssignments,
            barlineBundleIdentifier: Bundle.main.bundleIdentifier
                ?? "com.mabryventures.Barline",
            maximumCount: Self.maximumRememberedAssignments * 2
        )
        .sorted(by: Self.persistencePriority)
        let requiredAssignmentIndices = Set(assignmentCandidates.indices.filter { index in
            let assignment = assignmentCandidates[index]
            return requiredItemIDs.contains(assignment.itemID) || assignment.section != .visible
        })
        let assignmentSelection: (elements: [GoldenGateLogicalAssignment], data: Data)
        do {
            assignmentSelection = try BoundedPersistenceSelection.select(
                from: assignmentCandidates,
                requiredIndices: requiredAssignmentIndices,
                maximumCount: Self.maximumRememberedAssignments,
                maximumBytes: Self.maximumRememberedBytes,
                encode: { try JSONEncoder().encode(ExplicitLayout(version: 1, assignments: $0)) }
            )
        } catch {
            throw MenuBarBackendError.operationFailed("menu bar layout cannot be saved safely")
        }
        let retained = try prepareRetainedInventory(
            from: snapshot,
            requiredItemIDs: requiredItemIDs
        )
        return PreparedPersistence(
            assignments: assignmentSelection.elements,
            assignmentData: assignmentSelection.data,
            descriptors: retained.elements,
            descriptorData: retained.data
        )
    }

    @discardableResult
    private func commitPersistence(_ prepared: PreparedPersistence) -> Bool {
        explicitAssignments = Dictionary(uniqueKeysWithValues: prepared.assignments.map {
            ($0.itemID, $0)
        })
        retainedDescriptors = Dictionary(uniqueKeysWithValues: prepared.descriptors.map {
            ($0.id, $0)
        })
        UserDefaults.standard.set(prepared.assignmentData, forKey: Self.explicitLayoutKey)
        UserDefaults.standard.set(prepared.descriptorData, forKey: Self.retainedInventoryKey)
        return UserDefaults.standard.synchronize()
    }

    private func companionState(
        for prepared: PreparedPersistence
    ) -> GoldenGatePositionCompanionState {
        GoldenGatePositionCompanionState(
            assignmentData: prepared.assignmentData,
            descriptorData: prepared.descriptorData
        )
    }

    private func reconcileInterruptedPositionTransaction() async throws {
        let recovery = try await positionTableStore.recoverInterruptedTransaction()
        if case let .committed(companionState) = recovery {
            do {
                try recoverCommittedPersistence(companionState)
            } catch RecoveryPersistenceError.invalidCompanion {
                try await positionTableStore.quarantineRecoveryJournal()
                didAttemptInterruptedTransactionRecovery = true
                logger.fault("Golden Gate invalid recovery companion was quarantined")
                throw RecoveryPersistenceError.invalidCompanion
            } catch {
                // Transient persistence failures retain the valid verified
                // journal for another bounded recovery pass.
                throw error
            }
            try await positionTableStore.finishTransaction()
        }
        didAttemptInterruptedTransactionRecovery = true
        cachedAt = nil
        cachedSnapshot = nil
    }

    private func recoverCommittedPersistence(
        _ companionState: GoldenGatePositionCompanionState
    ) throws {
        guard companionState.assignmentData.count <= Self.maximumRememberedBytes,
              companionState.descriptorData.count <= Self.maximumRememberedBytes,
              let layout = try? JSONDecoder().decode(
                  ExplicitLayout.self,
                  from: companionState.assignmentData
              ),
              layout.version == 1,
              layout.assignments.count <= Self.maximumRememberedAssignments,
              let inventory = try? JSONDecoder().decode(
                  RetainedInventory.self,
                  from: companionState.descriptorData
              ),
              inventory.version == 1,
              inventory.descriptors.count <= Self.maximumRememberedAssignments,
              layout.assignments.allSatisfy({
                  $0.itemID.isPlausiblyStable && $0.rank >= 0
              }),
              inventory.descriptors.allSatisfy({ descriptor in
                  descriptor.id.isPlausiblyStable
              }),
              Set(layout.assignments.map(\.itemID)).count == layout.assignments.count,
              Set(inventory.descriptors.map(\.id)).count == inventory.descriptors.count
        else {
            throw RecoveryPersistenceError.invalidCompanion
        }
        let prepared = PreparedPersistence(
            assignments: layout.assignments,
            assignmentData: companionState.assignmentData,
            descriptors: inventory.descriptors.map(Self.sanitizedDescriptor),
            descriptorData: companionState.descriptorData
        )
        guard commitPersistence(prepared) else {
            throw RecoveryPersistenceError.synchronizeFailed
        }
    }

    private func prepareRetainedInventory(
        from snapshot: MenuBarSnapshot,
        requiredItemIDs: Set<MenuBarItemID>
    ) throws -> (elements: [MenuBarItemDescriptor], data: Data) {
        var merged = retainedDescriptors
        for (id, descriptor) in merged {
            merged[id] = Self.sanitizedDescriptor(descriptor)
        }
        for descriptor in snapshot.items where descriptor.id.isPlausiblyStable {
            // Barline controls are retained only as sanitized global-order
            // anchors; the merge policy never fabricates a missing control.
            merged[descriptor.id] = Self.sanitizedDescriptor(descriptor)
        }
        let descriptorCandidates = merged.values.sorted(by: Self.persistencePriority)
        let requiredDescriptorIndices = Set(descriptorCandidates.indices.filter { index in
            let descriptor = descriptorCandidates[index]
            return requiredItemIDs.contains(descriptor.id) ||
                descriptor.isBarlineControlItem ||
                descriptor.section != .visible
        })
        do {
            return try BoundedPersistenceSelection.select(
                from: descriptorCandidates,
                requiredIndices: requiredDescriptorIndices,
                maximumCount: Self.maximumRememberedAssignments,
                maximumBytes: Self.maximumRememberedBytes,
                encode: { try JSONEncoder().encode(RetainedInventory(version: 1, descriptors: $0)) }
            )
        } catch {
            throw MenuBarBackendError.operationFailed("menu bar inventory cannot be saved safely")
        }
    }

    private func commitRetainedInventory(
        _ prepared: (elements: [MenuBarItemDescriptor], data: Data)
    ) {
        retainedDescriptors = Dictionary(uniqueKeysWithValues: prepared.elements.map {
            ($0.id, $0)
        })
        UserDefaults.standard.set(prepared.data, forKey: Self.retainedInventoryKey)
    }

    private static func persistencePriority(
        _ lhs: GoldenGateLogicalAssignment,
        _ rhs: GoldenGateLogicalAssignment
    ) -> Bool {
        let lhsPriority = lhs.section == .visible ? 1 : 0
        let rhsPriority = rhs.section == .visible ? 1 : 0
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.section != rhs.section {
            return lhs.section.rawValue < rhs.section.rawValue
        }
        if lhs.rank != rhs.rank {
            return lhs.rank < rhs.rank
        }
        return lhs.itemID.description < rhs.itemID.description
    }

    private static func persistencePriority(
        _ lhs: MenuBarItemDescriptor,
        _ rhs: MenuBarItemDescriptor
    ) -> Bool {
        let lhsPriority = lhs.isBarlineControlItem ? 0 : (lhs.section == .visible ? 2 : 1)
        let rhsPriority = rhs.isBarlineControlItem ? 0 : (rhs.section == .visible ? 2 : 1)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        return lhs.id.description < rhs.id.description
    }

    private static func sanitizedDescriptor(_ descriptor: MenuBarItemDescriptor) -> MenuBarItemDescriptor {
        MenuBarItemDescriptor(
            id: descriptor.id,
            section: descriptor.section,
            order: descriptor.order,
            displayID: descriptor.displayID,
            isSystemItem: descriptor.isSystemItem,
            sourceOwnership: descriptor.sourceOwnership,
            isBarlineControlItem: descriptor.isBarlineControlItem,
            tagNamespace: descriptor.tagNamespace,
            title: descriptor.title,
            displayName: descriptor.displayName,
            bounds: .zero,
            isOnScreen: false,
            isMovable: descriptor.isMovable,
            canBeHidden: descriptor.canBeHidden,
            isBentoBox: descriptor.isBentoBox,
            isSystemClone: descriptor.isSystemClone,
            isResponsive: descriptor.isResponsive
        )
    }

    private func physicalCandidate(
        applying operation: MenuBarMoveOperation,
        to snapshot: MenuBarSnapshot
    ) throws -> MenuBarSnapshot {
        try GoldenGatePositionTablePlanner.candidateSnapshot(
            applying: operation,
            to: snapshot
        )
    }

    private func positionKeys(
        observations: [GoldenGateMenuBarObservation],
        positions: [String: Int],
        snapshot: MenuBarSnapshot? = nil,
        teamIdentifiersByItemID: [MenuBarItemID: String] = [:]
    ) -> [MenuBarItemID: String] {
        let identifiers = GoldenGateMenuBarSnapshotBuilder.identifiers(for: observations)
        let liveCandidates = zip(observations, identifiers).compactMap { observation, itemID in
            GoldenGatePositionTablePlanner.resolvedKey(
                for: itemID,
                localizedApplicationName: observation.localizedApplicationName,
                signingTeamIdentifier: teamIdentifiersByItemID[itemID],
                existingKeys: positions.keys
            ).map { (itemID, $0) }
        }
        let liveIDs = Set(identifiers)
        let retainedCandidates = snapshot?.items.compactMap { item -> (MenuBarItemID, String)? in
            guard !liveIDs.contains(item.id), item.id.isPlausiblyStable else { return nil }
            return GoldenGatePositionTablePlanner.resolvedKey(
                for: item.id,
                localizedApplicationName: NSRunningApplication
                    .runningApplications(withBundleIdentifier: item.id.bundleIdentifier)
                    .first?
                    .localizedName,
                signingTeamIdentifier: teamIdentifiersByItemID[item.id],
                existingKeys: positions.keys
            ).map { (item.id, $0) }
        } ?? []
        let candidates = liveCandidates + retainedCandidates
        let counts = Dictionary(grouping: candidates, by: { $0.1 }).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: candidates.compactMap { itemID, key in
            counts[key] == 1 ? (itemID, key) : nil
        })
    }

    private func applyingPositionTableCapabilities(
        to snapshot: MenuBarSnapshot,
        observations: [GoldenGateMenuBarObservation],
        positions: [String: Int]?,
        teamIdentifiersByItemID: [MenuBarItemID: String] = [:]
    ) throws -> MenuBarSnapshot {
        let resolvedKeys: [MenuBarItemID: String]? = positions.map {
            positionKeys(
                observations: observations,
                positions: $0,
                snapshot: snapshot,
                teamIdentifiersByItemID: teamIdentifiersByItemID
            )
        }
        let positioned: MenuBarSnapshot
        if let positions, let resolvedKeys {
            do {
                positioned = try GoldenGatePositionTablePlanner.applyingPositions(
                    to: snapshot,
                    positions: positions,
                    keysByItemID: resolvedKeys,
                    excludingFromAxis: verificationAffectedItemIDs,
                    usingKnownAxis: verificationAxisDirection
                )
            } catch {
                guard verificationAssignments == nil else { throw error }
                positioned = snapshot
            }
        } else {
            guard verificationAssignments == nil else {
                throw GoldenGatePositionTableError.unresolvedItem
            }
            positioned = snapshot
        }
        let items = positioned.items.map { item in
            let isThirdParty = Self.isPositionTableEligible(item)
            // A passive snapshot never opens a permission panel. Before scoped
            // access exists, eligible third-party items remain actionable only
            // so an explicit user drag can request that access. `move` and
            // `restore` immediately re-read the authorized table and require an
            // exact position key before planning or writing anything.
            return item.replacing(
                isMovable: isThirdParty
            )
        }
        return MenuBarSnapshot(
            generation: positioned.generation,
            capturedAt: positioned.capturedAt,
            items: items,
            displayIDs: positioned.displayIDs,
            displayIdentities: positioned.displayIdentities,
            activeSpaceIsValid: positioned.activeSpaceIsValid,
            menuTrackingIsActive: positioned.menuTrackingIsActive
        )
    }

    /// Eligibility is deliberately separate from key resolution. A live,
    /// third-party status item may request a position-table move even before
    /// its private table record has been matched. The move path then either
    /// resolves an exact record after authorization or fails without writing;
    /// disabling the control here would make that recovery impossible.
    private static func isPositionTableEligible(_ item: MenuBarItemDescriptor) -> Bool {
        GoldenGatePositionTableCapability.isCandidate(item)
    }

    /// Planning is observational: no native proposal has been staged. Keep
    /// access denial actionable, but tell the coordinator that every other
    /// preflight rejection is safe to surface without a stale restore.
    private func translatedPreflightError(_ error: Error) -> Error {
        if let storeError = error as? GoldenGatePositionTableStore.StoreError {
            if case .accessNotGranted = storeError {
                return MenuBarBackendError.positionTableAccessNotGranted
            }
        }
        if let positionError = error as? GoldenGatePositionTableError,
           positionError == .unresolvedItem
        {
            return MenuBarBackendError.positionTableIdentityUnresolved
        }
        return MenuBarBackendError.mutationNotStarted
    }

    /// Preflight failures occur before a native write. Emit a closed code that
    /// distinguishes the transaction stage without recording item identities,
    /// preference values, file paths, or underlying error descriptions.
    private static func preflightDiagnosticCode(_ error: Error) -> String {
        guard let storeError = error as? GoldenGatePositionTableStore.StoreError else {
            return PrivacySafeDiagnostics.errorCode(error)
        }
        return switch storeError {
        case .accessNotGranted: "position_access_not_granted"
        case .unexpectedFile: "position_unexpected_file"
        case .invalidDocument: "position_invalid_document"
        case .concurrentModification: "position_concurrent_modification"
        case .externalStateWon: "position_external_state_won"
        case .transactionPending: "position_transaction_pending"
        case .writeFailed: "position_write_failed"
        case .invalidJournal: "position_invalid_journal"
        }
    }

    /// Once `apply` has been entered, a persistence failure can mean a staged
    /// proposal or durable journal exists. Preserve recovery-required errors;
    /// the store maps verified rollback and external winners separately.
    private func translatedApplyError(_ error: Error) -> Error {
        guard let storeError = error as? GoldenGatePositionTableStore.StoreError else {
            return error
        }
        return switch storeError {
        case .writeFailed:
            MenuBarBackendError.mutationRecoveryFailed
        case .accessNotGranted:
            MenuBarBackendError.positionTableAccessNotGranted
        case .unexpectedFile:
            MenuBarBackendError.mutationNotStarted
        case .invalidDocument:
            MenuBarBackendError.mutationNotStarted
        case .concurrentModification:
            MenuBarBackendError.mutationSuperseded
        case .externalStateWon:
            MenuBarBackendError.mutationSuperseded
        case .transactionPending:
            MenuBarBackendError.mutationRecoveryRequired
        case .invalidJournal:
            MenuBarBackendError.mutationNotStarted
        }
    }

    private func verifyPositionMutation(
        _ operation: MenuBarMoveOperation,
        previousSnapshot: MenuBarSnapshot,
        timeout: Duration
    ) async throws -> MenuBarSnapshot {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var poll = 0
        repeat {
            try Task.checkCancellation()
            do {
                let current = try await snapshot(forceRefresh: true)
                poll += 1
                if let source = current.items.first(where: { $0.id == operation.itemID }) {
                    logger.debug(
                        "Golden Gate verification poll: poll=\(poll, privacy: .public), section=\(String(describing: source.section), privacy: .public), x=\(source.bounds.x, privacy: .public), items=\(current.items.count, privacy: .public)"
                    )
                } else {
                    logger.debug(
                        "Golden Gate verification poll: poll=\(poll, privacy: .public), source=missing, items=\(current.items.count, privacy: .public)"
                    )
                }
                if MenuBarMovePlanner().resultMatches(
                    operation,
                    in: current,
                    from: previousSnapshot,
                    destinationSupport: .emptySectionAllowed
                ) {
                    logger.info("Golden Gate position transaction reached its AX postcondition")
                    return current
                }
            } catch {
                // The owning status-item process can rebuild its AX element
                // while the system is applying a move. Keep polling only
                // within the bounded deadline.
                poll += 1
                logger.debug(
                    "Golden Gate verification poll failed: poll=\(poll, privacy: .public), code=\(PrivacySafeDiagnostics.errorCode(error), privacy: .public)"
                )
            }
            try await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        throw MenuBarBackendError.operationFailed(
            "menu bar position did not reach the requested section"
        )
    }

    private func verifyRestore(
        _ target: MenuBarSnapshot,
        requiredItemIDs: Set<MenuBarItemID>,
        timeout: Duration
    ) async throws -> MenuBarSnapshot {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            if let current = try? await snapshot(forceRefresh: true),
               GoldenGatePositionTablePlanner.restoreMatches(
                   target: target,
                   current: current,
                   requiredItemIDs: requiredItemIDs
               )
            {
                return current
            }
            try await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        throw MenuBarBackendError.operationFailed(
            "saved menu bar layout did not reach its requested order"
        )
    }

    private func rememberSections(from snapshot: MenuBarSnapshot) {
        let assignments = snapshot.items
            .filter { !$0.isBarlineControlItem && $0.id.isPlausiblyStable }
            .prefix(Self.maximumRememberedAssignments)
            .map { RememberedAssignment(itemID: $0.id, section: $0.section) }
        let document = RememberedAssignments(version: 1, assignments: assignments)
        guard let data = try? JSONEncoder().encode(document),
              data.count <= Self.maximumRememberedBytes
        else {
            return
        }
        rememberedSections = Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.itemID, $0.section)
        })
        UserDefaults.standard.set(data, forKey: Self.rememberedSectionsKey)
    }

    private func collectEntries() -> [Entry] {
        var entries = [Entry]()
        for runningApplication in NSWorkspace.shared.runningApplications
            where !runningApplication.isTerminated
        {
            guard
                let application = AXHelpers.application(for: runningApplication),
                let extrasMenuBar = AXHelpers.extrasMenuBar(for: application)
            else {
                continue
            }

            let bundleIdentifier = runningApplication.bundleIdentifier
                ?? "barline.unknown-menu-owner"
            var unnamedIndex = 0
            for child in AXHelpers.children(for: extrasMenuBar) {
                guard let bounds = AXHelpers.frame(for: child),
                      bounds.height > 0,
                      bounds.height <= Self.maximumItemHeight,
                      bounds.width > 0
                else {
                    continue
                }

                let candidates = [child] + AXHelpers.children(for: child)
                let metadata = candidates.map { element in
                    ElementMetadata(
                        identifier: nonempty(AXHelpers.identifier(for: element)),
                        accessibilityDescription: nonempty(
                            AXHelpers.accessibilityDescription(for: element)
                        ),
                        title: nonempty(AXHelpers.title(for: element)),
                        bounds: AXHelpers.frame(for: element)
                    )
                }
                let identifier = metadata.compactMap(\.identifier).first
                let accessibilityDescription = metadata.compactMap(
                    \.accessibilityDescription
                ).first
                let title = metadata.compactMap(\.title).first
                let currentIdentityOrigin: IdentityOrigin = if identifier != nil {
                    .identifier
                } else if accessibilityDescription != nil {
                    .accessibilityDescription
                } else if title != nil {
                    .title
                } else {
                    .generatedFallback
                }
                let fallbackTitle = "Item-\(unnamedIndex)"
                let displayTitle = title ?? accessibilityDescription ?? identifier ?? fallbackTitle
                if title == nil, accessibilityDescription == nil, identifier == nil {
                    unnamedIndex += 1
                }
                let stableTitle = identifier ?? accessibilityDescription ?? displayTitle
                let semanticBounds = semanticBounds(
                    in: metadata,
                    identifier: identifier,
                    accessibilityDescription: accessibilityDescription,
                    title: title
                ) ?? bounds
                guard !isNativeOverflowPlaceholder(
                    bundleIdentifier: bundleIdentifier,
                    title: stableTitle
                ) else {
                    continue
                }
                let axElementProcessIdentifier = AXHelpers.pid(for: child)

                entries.append(
                    Entry(
                        observation: GoldenGateMenuBarObservation(
                            bundleIdentifier: bundleIdentifier,
                            localizedApplicationName: runningApplication.localizedName,
                            identifier: identifier,
                            displayTitle: displayTitle,
                            stableTitle: stableTitle,
                            fallbackFingerprint: fallbackFingerprint(
                                bundleIdentifier: bundleIdentifier,
                                stableTitle: stableTitle
                            ),
                            bounds: MenuBarRect(
                                x: semanticBounds.minX,
                                y: semanticBounds.minY,
                                width: semanticBounds.width,
                                height: semanticBounds.height
                            ),
                            ownerProcessIdentifier: axElementProcessIdentifier
                                ?? runningApplication.processIdentifier
                        ),
                        element: child.element,
                        identityElements: candidates.map(\.element),
                        positionKeyCandidates: PositionKeyCandidates(
                            identifier: identifier,
                            accessibilityDescription: accessibilityDescription,
                            title: title,
                            titleIsRootValue: metadata.first?.title == title && title != nil,
                            currentIdentityOrigin: currentIdentityOrigin
                        ),
                        publisherProcessIdentifier: runningApplication.processIdentifier,
                        axElementProcessIdentifier: axElementProcessIdentifier
                    )
                )
            }
        }
        return deduplicatingMenuBarAgentRevends(entries).sorted {
            if abs($0.observation.bounds.y - $1.observation.bounds.y) > Self.duplicateTolerance {
                return $0.observation.bounds.y < $1.observation.bounds.y
            }
            return $0.observation.bounds.x < $1.observation.bounds.x
        }
    }

    /// Resolve process signing teams only while an explicit native mutation is
    /// in flight. Passive inventory stays lightweight, and a failed lookup is
    /// intentionally treated as unresolved rather than guessing an owner.
    private func signingTeamIdentifiers(for entries: [Entry]) -> [MenuBarItemID: String] {
        let itemIDs = GoldenGateMenuBarSnapshotBuilder.identifiers(for: entries.map(\.observation))
        let resolved = zip(entries, itemIDs).compactMap { entry, itemID in
            Self.signingTeamIdentifier(for: entry.publisherProcessIdentifier).map { (itemID, $0) }
        }
        return Dictionary(uniqueKeysWithValues: resolved)
    }

    /// Produces only booleans about the currently selected source item. It is
    /// deliberately confined to an explicit mutation and never records a
    /// menu-item name, preference key, signing identity, process ID, or path.
    private func logIdentityResolutionAudit(
        source: MenuBarItemDescriptor,
        entries: [Entry],
        positions: [String: Int],
        teamIdentifiersByItemID: [MenuBarItemID: String],
        resolvedKeys: [MenuBarItemID: String]
    ) {
        let itemIDs = GoldenGateMenuBarSnapshotBuilder.identifiers(for: entries.map(\.observation))
        guard let index = itemIDs.firstIndex(of: source.id) else {
            logger.notice("Golden Gate identity audit: source_entry_found=false")
            return
        }
        let entry = entries[index]
        let publisherTeam = teamIdentifiersByItemID[source.id]
        let axTeam = entry.axElementProcessIdentifier.flatMap(Self.signingTeamIdentifier(for:))
        let candidates = entry.positionKeyCandidates
        let identityReadAudit = IdentityReadAudit(
            root: entry.element,
            children: Array(entry.identityElements.dropFirst())
        )
        let descendantIdentityReadAudit = DescendantIdentityReadAudit(
            directParents: Array(entry.identityElements.dropFirst()),
            maximumNodes: 8
        )
        let childrenReadStatus = AXHelpers.childrenReadDisposition(
            for: UIElement(entry.element)
        )
        let sourceElementStillValid = AXHelpers.isElementValid(UIElement(entry.element))
        let publisherStillRunning = NSRunningApplication(
            processIdentifier: entry.publisherProcessIdentifier
        )?.isTerminated == false
        let evidence = GoldenGatePositionTablePlanner.resolutionEvidence(
            bundleIdentifier: source.id.bundleIdentifier,
            localizedApplicationName: entry.observation.localizedApplicationName,
            signingTeamIdentifier: publisherTeam,
            candidates: [
                GoldenGatePositionKeyCandidate(
                    kind: .accessibilityIdentifier,
                    value: candidates.identifier
                ),
                GoldenGatePositionKeyCandidate(
                    kind: .accessibilityDescription,
                    value: candidates.accessibilityDescription
                ),
                GoldenGatePositionKeyCandidate(
                    kind: .accessibilityTitle,
                    value: candidates.title
                ),
            ],
            existingKeys: positions.keys
        )
        let identifierEvidence = evidence.evidence(for: .accessibilityIdentifier)
        let descriptionEvidence = evidence.evidence(for: .accessibilityDescription)
        let titleEvidence = evidence.evidence(for: .accessibilityTitle)
        let descendantIdentifierEvidence = GoldenGatePositionTablePlanner.resolutionEvidence(
            bundleIdentifier: source.id.bundleIdentifier,
            localizedApplicationName: entry.observation.localizedApplicationName,
            signingTeamIdentifier: publisherTeam,
            candidates: descendantIdentityReadAudit.candidates.filter {
                $0.kind == .accessibilityIdentifier
            },
            existingKeys: positions.keys
        )
        let descendantDescriptionEvidence = GoldenGatePositionTablePlanner.resolutionEvidence(
            bundleIdentifier: source.id.bundleIdentifier,
            localizedApplicationName: entry.observation.localizedApplicationName,
            signingTeamIdentifier: publisherTeam,
            candidates: descendantIdentityReadAudit.candidates.filter {
                $0.kind == .accessibilityDescription
            },
            existingKeys: positions.keys
        )
        let descendantTitleEvidence = GoldenGatePositionTablePlanner.resolutionEvidence(
            bundleIdentifier: source.id.bundleIdentifier,
            localizedApplicationName: entry.observation.localizedApplicationName,
            signingTeamIdentifier: publisherTeam,
            candidates: descendantIdentityReadAudit.candidates.filter {
                $0.kind == .accessibilityTitle
            },
            existingKeys: positions.keys
        )
        let publisherLiveEntryCount = entries.count(where: {
            $0.publisherProcessIdentifier == entry.publisherProcessIdentifier
        })
        let titleEqualsCurrentIdentity = candidates.title.map {
            $0.caseInsensitiveCompare(source.id.title ?? "") == .orderedSame
        } ?? false
        let publisherKeyResolved = GoldenGatePositionTablePlanner.resolvedKey(
            for: source.id,
            localizedApplicationName: entry.observation.localizedApplicationName,
            signingTeamIdentifier: publisherTeam,
            existingKeys: positions.keys
        ) != nil
        let axKeyResolved = GoldenGatePositionTablePlanner.resolvedKey(
            for: source.id,
            localizedApplicationName: entry.observation.localizedApplicationName,
            signingTeamIdentifier: axTeam,
            existingKeys: positions.keys
        ) != nil
        logger.notice(
            "Golden Gate identity audit: table_read_status=readable, source_entry_found=true, ax_pid_matches_publisher=\(entry.axElementProcessIdentifier == entry.publisherProcessIdentifier, privacy: .public), publisher_team_resolved=\(publisherTeam != nil, privacy: .public), ax_team_resolved=\(axTeam != nil, privacy: .public), publisher_still_running=\(publisherStillRunning, privacy: .public), source_element_still_valid=\(sourceElementStillValid, privacy: .public), children_read_status=\(childrenReadStatus.rawValue, privacy: .public), publisher_live_entry_count=\(publisherLiveEntryCount, privacy: .public), publisher_key_resolved=\(publisherKeyResolved, privacy: .public), ax_key_resolved=\(axKeyResolved, privacy: .public), globally_unique_source_key=\(resolvedKeys[source.id] != nil, privacy: .public), status_record_count=\(evidence.statusRecordCount, privacy: .public), bundle_record_count=\(evidence.bundleRecordCount, privacy: .public), bundle_record_suffix_parse_status=\(evidence.directBundleSuffixParseStatus.rawValue, privacy: .public), recognized_owner_record_count=\(evidence.recognizedOwnerRecordCount, privacy: .public), current_identity_origin=\(candidates.currentIdentityOrigin.rawValue, privacy: .public), root_identifier_read_status=\(identityReadAudit.rootStatus(for: .identifier), privacy: .public), root_description_read_status=\(identityReadAudit.rootStatus(for: .accessibilityDescription), privacy: .public), root_title_read_status=\(identityReadAudit.rootStatus(for: .title), privacy: .public), child_identifier_read_counts=\(identityReadAudit.childCounts(for: .identifier), privacy: .public), child_description_read_counts=\(identityReadAudit.childCounts(for: .accessibilityDescription), privacy: .public), child_title_read_counts=\(identityReadAudit.childCounts(for: .title), privacy: .public), descendant_node_count=\(descendantIdentityReadAudit.nodeCount, privacy: .public), descendant_children_read_counts=\(descendantIdentityReadAudit.childReadCounts(), privacy: .public), descendant_identifier_read_counts=\(descendantIdentityReadAudit.valueReadCounts(for: .identifier), privacy: .public), descendant_description_read_counts=\(descendantIdentityReadAudit.valueReadCounts(for: .accessibilityDescription), privacy: .public), descendant_title_read_counts=\(descendantIdentityReadAudit.valueReadCounts(for: .title), privacy: .public), descendant_identifier_value_count=\(descendantIdentityReadAudit.candidateCount(for: .accessibilityIdentifier), privacy: .public), descendant_identifier_accepted_key_count=\(descendantIdentifierEvidence.distinctAcceptedKeyCount, privacy: .public), descendant_description_value_count=\(descendantIdentityReadAudit.candidateCount(for: .accessibilityDescription), privacy: .public), descendant_description_accepted_key_count=\(descendantDescriptionEvidence.distinctAcceptedKeyCount, privacy: .public), descendant_title_value_count=\(descendantIdentityReadAudit.candidateCount(for: .accessibilityTitle), privacy: .public), descendant_title_accepted_key_count=\(descendantTitleEvidence.distinctAcceptedKeyCount, privacy: .public), identifier_present=\(identifierEvidence.isPresent, privacy: .public), identifier_suffix_match_count=\(identifierEvidence.suffixMatchCount, privacy: .public), identifier_owner_match_count=\(identifierEvidence.acceptedOwnerMatchCount, privacy: .public), description_present=\(descriptionEvidence.isPresent, privacy: .public), description_suffix_match_count=\(descriptionEvidence.suffixMatchCount, privacy: .public), description_owner_match_count=\(descriptionEvidence.acceptedOwnerMatchCount, privacy: .public), title_present=\(titleEvidence.isPresent, privacy: .public), title_from_root=\(candidates.titleIsRootValue, privacy: .public), title_equals_current_identity=\(titleEqualsCurrentIdentity, privacy: .public), title_suffix_match_count=\(titleEvidence.suffixMatchCount, privacy: .public), title_owner_match_count=\(titleEvidence.acceptedOwnerMatchCount, privacy: .public), distinct_accepted_key_count=\(evidence.distinctAcceptedKeyCount, privacy: .public)"
        )
    }

    private static func signingTeamIdentifier(for processIdentifier: Int32) -> String? {
        guard processIdentifier > 0 else { return nil }
        let attributes: CFDictionary = [
            kSecGuestAttributePid: NSNumber(value: processIdentifier),
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [CFString: Any],
            let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier] as? String
        else {
            return nil
        }
        let trimmed = teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return []
        }
        return Array(displays.prefix(Int(count)))
    }

    private func stableDisplayID(_ displayID: CGDirectDisplayID) -> MenuBarDisplayID {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return MenuBarDisplayID("display-\(displayID)")
        }
        return MenuBarDisplayID(
            CFUUIDCreateString(nil, unmanagedUUID.takeRetainedValue()) as String
        )
    }

    private func hardwareFingerprint(
        for displayID: CGDirectDisplayID
    ) -> MenuBarDisplayHardwareFingerprint? {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let unknownVendor: UInt32 = 0x756E_6B6E
        let genericProduct: UInt32 = 0x0717
        guard vendor != 0,
              vendor != unknownVendor,
              model != 0,
              model != genericProduct,
              serial != 0
        else { return nil }

        var payload = Data("com.mabryventures.Barline.display-fingerprint.v1\0".utf8)
        for component in [vendor, model, serial] {
            var bigEndian = component.bigEndian
            withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return MenuBarDisplayHardwareFingerprint("v1:\(digest)")
    }

    private func fallbackFingerprint(
        bundleIdentifier: String,
        stableTitle: String
    ) -> String {
        let digest = SHA256.hash(
            data: Data("\(bundleIdentifier.lowercased())|\(stableTitle.lowercased())".utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func deduplicatingMenuBarAgentRevends(
        _ entries: [Entry]
    ) -> [Entry] {
        let directOrigins = entries
            .filter { $0.observation.bundleIdentifier != Self.menuBarAgentBundleIdentifier }
            .map { ($0.observation.bounds.x, $0.observation.bounds.y) }
        guard !directOrigins.isEmpty else { return entries }

        return entries.filter { entry in
            let observation = entry.observation
            guard observation.bundleIdentifier == Self.menuBarAgentBundleIdentifier else {
                return true
            }
            return !directOrigins.contains { origin in
                abs(origin.0 - observation.bounds.x) <= Self.duplicateTolerance &&
                    abs(origin.1 - observation.bounds.y) <= Self.duplicateTolerance
            }
        }
    }

    private func isNativeOverflowPlaceholder(
        bundleIdentifier: String,
        title: String
    ) -> Bool {
        guard bundleIdentifier == Self.menuBarAgentBundleIdentifier else { return false }
        let normalized = title.filter { !$0.isWhitespace }
        if normalized.caseInsensitiveCompare("AXOverflowButton") == .orderedSame {
            return true
        }
        let glyphs = Set("<>‹›«»")
        return !normalized.isEmpty && normalized.count <= 4 &&
            normalized.allSatisfy { glyphs.contains($0) }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func semanticBounds(
        in metadata: [ElementMetadata],
        identifier: String?,
        accessibilityDescription: String?,
        title: String?
    ) -> CGRect? {
        let selected: ElementMetadata? = if let identifier {
            metadata.first { $0.identifier == identifier }
        } else if let accessibilityDescription {
            metadata.first { $0.accessibilityDescription == accessibilityDescription }
        } else if let title {
            metadata.first { $0.title == title }
        } else {
            nil
        }
        guard let bounds = selected?.bounds,
              bounds.height > 0,
              bounds.height <= Self.maximumItemHeight,
              bounds.width > 0
        else {
            return nil
        }
        return bounds
    }
}
