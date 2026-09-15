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

unless helper_backend.match?(/GoldenGateAXInventory\.resolve\(item\).*?beginRevealObservation\(sourcePID: resolved\.ownerPID\)/m) &&
       helper_inventory.match?(/static func resolve\(_ itemID: MenuBarItemID\).*?GoldenGateMenuBarIdentityResolver\.resolve/m)
  abort('Golden Gate reveal observation is not bound to the Accessibility item owner')
end

unless helper_backend.match?(/func activate\(_ item: MenuBarItemID.*?client\.activateGoldenGate\(item/m) &&
       helper_client.match?(/func activateGoldenGate\(.*?moved\.post\(tap: \.cghidEventTap\).*?down\.post\(tap: \.cghidEventTap\).*?up\.post\(tap: \.cghidEventTap\)/m)
  abort('Golden Gate activation falls back to the retired per-window item lookup')
end

unless concealment.include?('BLNGoldenGateAssessmentCreate()') &&
       concealment.include?('BLNGoldenGateAssessmentApply(') &&
       concealment.include?('BLNGoldenGateAssessmentActivationState(') &&
       bridge_header.include?('BLNGoldenGateAssessmentCreate') &&
       bridge_header.include?('BLNGoldenGateAssessmentApply') &&
       bridge_header.include?('BLNGoldenGateAssessmentActivationState') &&
       !concealment.include?('resolve("BLNGoldenGateAssessment')
  abort('Golden Gate concealment bridge is not compile-time linked')
end

if assessment_bridge.include?('dispatch_semaphore_wait')
  abort('Golden Gate assertion activation blocks the callback executor')
end

unless assessment_bridge.include?('strongSelf.activationState = -1;') &&
       assessment_bridge.include?('strongSelf.assertion = candidate;') &&
       assessment_bridge.include?('strongSelf.activationState = 1;') &&
       assessment_bridge.match?(/if \(error\).*?candidate, invalidationSelector.*?else if \(previous\).*?previous, invalidationSelector/m) &&
       !assessment_bridge.match?(/Activation completion.*?self\.assertion = candidate/m)
  abort('Golden Gate assertion replacement is not callback-acknowledged and atomic')
end

unless golden_gate_provider.include?('verifyNativeAssignments') &&
       golden_gate_provider.include?('GoldenGateRetainedInventoryPolicy.merging(') &&
       golden_gate_provider.match?(/applyNativeConfiguration\(.*?configureConcealment\(.*?candidateConfiguration.*?catch.*?verifyNativeAssignments\(expectations\).*?catch.*?configureConcealment\(.*?previousConfiguration.*?catch.*?native concealment rollback failed/m) &&
       service_connection.match?(/case \.configureConcealment = request,.*?case \.activation\(\.success\) = response/m)
  abort('Golden Gate concealment is not verified, rolled back, and replayed transactionally')
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
