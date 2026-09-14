#!/usr/bin/env ruby
# frozen_string_literal: true

manager = File.read('Barline/MenuBar/MenuBarItems/MenuBarItemManager.swift')
backend = File.read('Barline/MenuBar/MenuBarItems/XPCMenuBarBackend.swift')
shelf = File.read('Barline/MenuBar/BarlineShelf/BarlineShelf.swift')

abort('shelf activation bypasses the compatibility coordinator') if
  manager.include?('BarlineMenuService.Connection.shared.activate')

unless manager.match?(/compatibilityCoordinator\.perform\(\s*\.activate/m)
  abort('shelf activation is not routed through the compatibility coordinator')
end

unless backend.match?(/#available\(macOS 27\.0, \*\).*goldenGateProvider\.activate/m)
  abort('Golden Gate activation is not routed through the trusted app provider')
end

unless shelf.match?(/override func mouseUp\(with event: NSEvent\).*?leftClickAction\(\)/m) &&
       shelf.match?(/override func accessibilityPerformPress\(\) -> Bool.*?leftClickAction\(\)/m)
  abort('shelf item does not own pointer and Accessibility activation')
end

unless shelf.match?(/\.accessibilityElement\(children: \.ignore\).*?\.accessibilityLabel\(item\.displayName\)/m)
  abort('shelf item is not discoverable through its SwiftUI accessibility projection')
end

unless shelf.match?(/modifierFlags\.contains\(\.control\).*?suppressLeftMouseUp = true.*?rightClickAction\(\)/m) &&
       shelf.match?(/guard !suppressLeftMouseUp else \{.*?return/m)
  abort('control-click can fall through to duplicate left activation')
end

puts 'PASS: shelf activation has one native control and routes through the trusted app on macOS 27'
