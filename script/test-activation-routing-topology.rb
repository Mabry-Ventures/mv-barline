#!/usr/bin/env ruby
# frozen_string_literal: true

manager = File.read('Barline/MenuBar/MenuBarItems/MenuBarItemManager.swift')
backend = File.read('Barline/MenuBar/MenuBarItems/XPCMenuBarBackend.swift')
shelf = File.read('Barline/MenuBar/BarlineShelf/BarlineShelf.swift')
helper_backend = File.read('BarlineMenuService/Backends/CompatibilityBackends.swift')
helper_inventory = File.read('BarlineMenuService/WindowServer/GoldenGateAXInventory.swift')
item_projection = shelf.split('private struct BarlineShelfItemView', 2).last
  .split('// MARK: - BarlineShelfItemClickView', 2).first

abort('shelf activation bypasses the compatibility coordinator') if
  manager.include?('BarlineMenuService.Connection.shared.activate')

unless manager.match?(/compatibilityCoordinator\.perform\(\s*\.activate/m)
  abort('shelf activation is not routed through the compatibility coordinator')
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

if item_projection.include?('.accessibilityElement(children: .ignore)')
  abort('SwiftUI accessibility projection shadows the native shelf item control')
end

unless helper_backend.match?(/GoldenGateAXInventory\.resolve\(item\).*?beginRevealObservation\(sourcePID: resolved\.ownerPID\)/m) &&
       helper_inventory.match?(/static func resolve\(_ itemID: MenuBarItemID\).*?GoldenGateMenuBarIdentityResolver\.resolve/m)
  abort('Golden Gate reveal observation is not bound to the Accessibility item owner')
end

unless shelf.match?(/modifierFlags\.contains\(\.control\).*?suppressLeftMouseUp = true.*?rightClickAction\(\)/m) &&
       shelf.match?(/guard !suppressLeftMouseUp else \{.*?return/m)
  abort('control-click can fall through to duplicate left activation')
end

puts 'PASS: shelf activation topology routes native input and Accessibility controls through the trusted app on macOS 27'
