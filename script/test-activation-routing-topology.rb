#!/usr/bin/env ruby
# frozen_string_literal: true

manager = File.read('Barline/MenuBar/MenuBarItems/MenuBarItemManager.swift')
search = File.read('Barline/MenuBar/Search/MenuBarSearchPanel.swift')
coordinator = File.read('BarlineCore/Sources/BarlineCore/StateCoordinator.swift')
backend = File.read('Barline/MenuBar/MenuBarItems/XPCMenuBarBackend.swift')
shelf = File.read('Barline/MenuBar/BarlineShelf/BarlineShelf.swift')
helper_backend = File.read('BarlineMenuService/Backends/CompatibilityBackends.swift')
helper_inventory = File.read('BarlineMenuService/WindowServer/GoldenGateAXInventory.swift')
helper_client = File.read('BarlineMenuService/WindowServer/WindowServerClient.swift')
concealment = File.read('BarlineMenuService/Backends/GoldenGateConcealmentController.swift')
assessment_bridge = File.read('BarlineMenuService/GoldenGateAssessmentModeBridge.m')
golden_gate_provider = File.read('Barline/MenuBar/MenuBarItems/GoldenGateAXSnapshotProvider.swift')
golden_gate_positions = File.read('Barline/MenuBar/MenuBarItems/GoldenGatePositionTableStore.swift')
service_connection = File.read('Barline/MenuBar/MenuBarItems/BarlineMenuServiceConnection.swift')
layout_bar = File.read('Barline/MenuBar/LayoutBar/LayoutBar.swift')
bridge_header = File.read('BarlineMenuService/BarlineMenuService-Bridging-Header.h')
click_delivery = helper_client.split('private func deliverClick', 2).last
  .split('private enum MovePlacement', 2).first
session_delivery = click_delivery.split('let sessionTap', 2).last
  .split('do {', 2).first
item_projection = shelf.split('private struct BarlineShelfItemView', 2).last
  .split('// MARK: - BarlineShelfItemClickView', 2).first

abort('shelf activation bypasses the compatibility coordinator') if
  manager.include?('BarlineMenuService.Connection.shared.activate')

unless manager.match?(/compatibilityCoordinator\.activateItem\(/) &&
       search.match?(/case \.activate:.*?compatibilityCoordinator\.activateItem\(/m) &&
       coordinator.match?(/public func activateItem\(.*?try await backend\.activate/m) &&
       !coordinator.match?(/case activate\(MenuBarItemID, MenuBarMouseButton\)/)
  abort('shelf activation is not isolated from transactional layout mutations')
end

unless backend.match?(/#available\(macOS 27\.0, \*\).*goldenGateProvider\.activate/m)
  abort('Golden Gate activation is not routed through the trusted app provider')
end

unless backend.match?(/func snapshot\(\).*?#available\(macOS 27\.0, \*\).*?goldenGateProvider\.snapshot\(\).*?connection\.snapshot\(\)/m) &&
       backend.match?(/func move\(.*?#available\(macOS 27\.0, \*\).*?goldenGateProvider\.move\(operation\).*?connection\.move\(operation\)/m) &&
       backend.match?(/func restore\(.*?#available\(macOS 27\.0, \*\).*?goldenGateProvider\.restore\(snapshot\).*?connection\.restore\(snapshot\)/m) &&
       backend.match?(/func configureConcealment\(.*?#available\(macOS 27\.0, \*\).*?goldenGateProvider\.configureConcealment\(configuration\).*?connection\.configureConcealment\(configuration\)/m)
  abort('macOS 27 position-table routing is not isolated from the macOS 26 XPC backend')
end

unless shelf.match?(/ignoresMouseEvents = false/) &&
       shelf.match?(/override func mouseUp\(with event: NSEvent\).*?leftClickAction\(\)/m) &&
       shelf.match?(/override func accessibilityPerformPress\(\) -> Bool.*?leftClickAction\(\)/m)
  abort('interactive shelf panel does not route pointer and Accessibility activation through its native item control')
end

unless shelf.match?(/override func accessibilityChildren\(\) -> \[Any\]\?.*?descendantShelfItemButtons/m) &&
       shelf.match?(/override func accessibilityHitTest\(_ point: NSPoint\) -> Any\?.*?BarlineShelfItemClickView\.Represented/m) &&
       shelf.match?(/setAccessibilityRole\(\.button\)/)
  abort('native shelf item controls are not bridged into AppKit Accessibility')
end

unless shelf.match?(/setAccessibilityElement\(true\).*?setAccessibilityRole\(\.window\).*?setAccessibilitySubrole\(\.floatingWindow\).*?setAccessibilityIdentifier\("Barline\.Bar"\)/m)
  abort('borderless shelf panel is not explicitly published as an Accessibility window')
end

if item_projection.include?('.accessibilityElement(children: .ignore)')
  abort('SwiftUI accessibility projection shadows the native shelf item control')
end

unless helper_backend.match?(/beginTemporaryReveal\(item\).*?resolveAfterNativeReveal\(item\).*?beginRevealObservation\(sourcePID: resolved\.ownerPID\)/m) &&
       helper_inventory.match?(/static func resolve\(_ itemID: MenuBarItemID\).*?GoldenGateMenuBarIdentityResolver\.resolve/m)
  abort('Golden Gate reveal does not precede fresh Accessibility owner binding')
end

unless manager.match?(/usesNativeReveal = if #available\(macOS 27\.0, \*\).*?true.*?else.*?false.*?if item\.isOnScreen \|\| usesNativeReveal.*?beginRevealObservation/m) &&
       helper_backend.include?('scheduleRestoration(for:') &&
       helper_backend.match?(/func restoreObservation\(.*?revealObservations\.reserve\(token\).*?endTemporaryReveal\(reservation\.item\)/m) &&
       helper_backend.match?(/func beginRevealObservation\(.*?guard revealObservations\.canAdmitOperations.*?lifecycleEpoch/m) &&
       helper_backend.match?(/func restart\(\) async.*?revealObservations\.beginRestart\(\).*?restartTask = task.*?await task\.value.*?restartTask = nil.*?revealObservations\.finishRestart\(\)/m)
  abort('retained Golden Gate activation can fall back to positional movement or orphan native reveal')
end

unless helper_backend.match?(/func activate\(_ item: MenuBarItemID.*?client\.activateGoldenGate\(item/m) &&
       helper_client.match?(/func activateGoldenGate\(.*?moved\.post\(tap: \.cghidEventTap\).*?down\.post\(tap: \.cghidEventTap\).*?up\.post\(tap: \.cghidEventTap\)/m)
  abort('Golden Gate activation falls back to the retired per-window item lookup')
end

unless concealment.include?('BLNGoldenGateAssessmentCreate()') &&
       concealment.include?('BLNGoldenGateAssessmentBegin(') &&
       concealment.include?('BLNGoldenGateAssessmentActivationState(') &&
       concealment.include?('BLNGoldenGateAssessmentCommit(') &&
       concealment.include?('BLNGoldenGateAssessmentAbort(') &&
       bridge_header.include?('BLNGoldenGateAssessmentCreate') &&
       bridge_header.include?('BLNGoldenGateAssessmentBegin') &&
       bridge_header.include?('BLNGoldenGateAssessmentActivationState') &&
       bridge_header.include?('BLNGoldenGateAssessmentCommit') &&
       bridge_header.include?('BLNGoldenGateAssessmentAbort') &&
       !concealment.include?('resolve("BLNGoldenGateAssessment')
  abort('Golden Gate concealment bridge is not compile-time linked')
end

unless concealment.include?('AsyncExclusiveOperationGate()') &&
       concealment.include?('TemporaryRevealLedger()') &&
       concealment.match?(/candidateLedger = temporaryRevealLedger\.beginning\(item\).*?applyCurrentState\(temporaryRevealLedger: candidateLedger\).*?temporaryRevealLedger = candidateLedger/m) &&
       concealment.match?(/candidateLedger = temporaryRevealLedger\.ending\(item\).*?applyCurrentState\(temporaryRevealLedger: candidateLedger\).*?temporaryRevealLedger = candidateLedger/m)
  abort('Golden Gate native state changes are not serialized and reference-count committed')
end

if assessment_bridge.include?('dispatch_semaphore_wait')
  abort('Golden Gate assertion activation blocks the callback executor')
end

callback = assessment_bridge.split('void (^completion)', 2).last.split('@try', 2).first
acknowledgement = assessment_bridge.split('- (void)acknowledgeCandidate:', 3).last
  .split('- (int32_t)activationStateForToken:', 2).first
commit = assessment_bridge.split('- (BOOL)commitToken:', 3).last.split('- (BOOL)abortToken:', 2).first
abort_transaction = assessment_bridge.split('- (BOOL)abortToken:', 3).last.split('- (void)invalidate', 2).first
unless callback.include?('acknowledgeCandidate:candidate token:token error:error') &&
       !callback.include?('strongSelf.assertion = candidate;') &&
       acknowledgement.include?('self.activationState = 1;') &&
       !acknowledgement.include?('self.assertion = candidate;') &&
       commit.include?('self.assertion = self.pendingClearsCurrentAssertion ? nil : self.pendingAssertion;') &&
       commit.include?('previous, NSSelectorFromString(@"invalidate")') &&
       abort_transaction.include?('self.pendingToken = 0;') &&
       abort_transaction.include?('pending, NSSelectorFromString(@"invalidate")') &&
       concealment.match?(/defer \{.*?BLNGoldenGateAssessmentAbort\(opaqueController, transaction\)/m) &&
       concealment.match?(/Task\.checkCancellation\(\).*?BLNGoldenGateAssessmentCommit\(opaqueController, transaction\)/m)
  abort('Golden Gate assertion replacement is not an explicit abortable two-phase transaction')
end

unless golden_gate_provider.include?('GoldenGatePositionTablePlanner.planMove(') &&
       golden_gate_provider.include?('GoldenGatePositionTablePlanner.planRestore(') &&
       golden_gate_provider.include?('positionTableStore.apply(mutation)') &&
       golden_gate_provider.include?('verifyPositionMutation(') &&
       golden_gate_provider.include?('verifyRestore(') &&
       golden_gate_provider.include?('positionTableStore.rollback(mutation)') &&
       golden_gate_provider.include?('positionTableStore.markVerified(') &&
       golden_gate_provider.include?('companionState: companionState(for:') &&
       golden_gate_provider.include?('verificationAssignments') &&
       golden_gate_provider.include?('await positionTableStore.finishTransaction()') &&
       golden_gate_provider.include?('positionTableStore.quarantineRecoveryJournal()') &&
       golden_gate_provider.include?('reconcileInterruptedPositionTransaction()') &&
       golden_gate_provider.include?('usingKnownAxis: verificationAxisDirection') &&
       golden_gate_provider.include?('throw translatedPreflightError(error)') &&
       golden_gate_provider.include?('throw translatedApplyError(error)') &&
       golden_gate_provider.match?(/case \.transactionPending:\s+MenuBarBackendError\.mutationRecoveryRequired/m) &&
       golden_gate_provider.match?(/func move\(.*?readPositions\(.*?requestAccessIfNeeded: true.*?guard let source/m) &&
       golden_gate_provider.match?(/func restore\(.*?readPositions\(requestAccessIfNeeded: true\).*?let currentIDs/m) &&
       !golden_gate_provider.include?('performCommandDrag') &&
       !golden_gate_provider.include?('CGEvent(') &&
       golden_gate_positions.include?('com.apple.MenuBar.plist') &&
       golden_gate_positions.include?('CFPreferencesSetValue(') &&
       golden_gate_positions.include?('CFPreferencesSynchronize(') &&
       golden_gate_positions.include?('kCFPreferencesCurrentUser') &&
       golden_gate_positions.include?('kCFPreferencesAnyHost') &&
       golden_gate_positions.include?('F_FULLFSYNC') &&
       golden_gate_positions.include?('case invalidJournal') &&
       golden_gate_positions.include?('case transactionPending') &&
       golden_gate_positions.include?('quarantineInvalidJournal()') &&
       golden_gate_positions.include?('journal.version == 3') &&
       golden_gate_positions.include?('lstat(url.path, &metadata)') &&
       golden_gate_positions.include?('S_IFLNK') &&
       golden_gate_positions.match?(/func authorizeAccess\(.*?catch \{.*?removeObject\(forKey: Self\.bookmarkKey\).*?guard requestAccessIfNeeded/m) &&
       !golden_gate_positions.include?('struct ScopedAccess') &&
       !golden_gate_positions.include?('NSFileCoordinator().coordinate(') &&
       golden_gate_provider.match?(/func configureConcealment\(.*?async throws \{\}/m)
  abort('Golden Gate position-table moves are not domain-correct, verified, rolled back, and isolated from synthetic input')
end

unless golden_gate_positions.match?(/func readPositions\(.*?authorizeAccess.*?defer \{ scopedURL\?\.stopAccessingSecurityScopedResource\(\) \}.*?readPreferences/m) &&
       golden_gate_positions.match?(/func apply\(.*?authorizeAccess.*?defer \{ scopedURL\?\.stopAccessingSecurityScopedResource\(\) \}/m) &&
       golden_gate_positions.match?(/func recoverInterruptedTransaction\(.*?authorizeAccess.*?defer \{ scopedURL\?\.stopAccessingSecurityScopedResource\(\) \}/m) &&
       golden_gate_positions.match?(/func rollback\(.*?authorizeAccess.*?defer \{ scopedURL\?\.stopAccessingSecurityScopedResource\(\) \}/m) &&
       golden_gate_positions.match?(/private func beginAccessing\(.*?startAccessingSecurityScopedResource\(\).*?isReadableFile.*?isWritableFile/m) &&
       golden_gate_positions.match?(/private func resolvedBookmarkURL\(.*?options: \[\.withSecurityScope, \.withoutUI\]/m) &&
       golden_gate_positions.match?(/private static func requestBookmark\(.*?options: \[\.withSecurityScope\]/m) &&
       golden_gate_positions.match?(/Retire it so this explicit move can present.*?removeObject\(forKey: Self\.bookmarkKey\)/m)
  abort('macOS 27 position-table access does not activate, balance, and migrate its security-scoped bookmark')
end

unless layout_bar.include?('.draggable(MenuBarLayoutTransfer(') &&
       layout_bar.include?('.dropDestination(for: MenuBarLayoutTransfer.self)')
  abort('macOS 27 layout assignment does not use typed drag and drop')
end

unless helper_client.match?(/func activate\(_ itemID:.*?synthesizeClick\(item: item, pid: resolvedEventPID/m) &&
       helper_client.include?('location: .session,') &&
       session_delivery.include?('options: .listenOnly') &&
       !session_delivery.include?('options: .defaultTap')
  abort('macOS 26 activation does not use the passive, source-bound session route')
end

unless shelf.match?(/modifierFlags\.contains\(\.control\).*?suppressLeftMouseUp = true.*?rightClickAction\(\)/m) &&
       shelf.match?(/guard !suppressLeftMouseUp else \{.*?return/m)
  abort('control-click can fall through to duplicate left activation')
end

puts 'PASS: shelf activation topology routes native input and Accessibility controls through the trusted app on macOS 27'
