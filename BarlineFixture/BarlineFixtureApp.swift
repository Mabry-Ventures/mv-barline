//
//  BarlineFixtureApp.swift
//  Barline
//

import AppKit
import SwiftUI

@main
struct BarlineFixtureApp: App {
    @NSApplicationDelegateAdaptor(BarlineFixtureAppDelegate.self) private var appDelegate
    private let mode = ProcessInfo.processInfo.environment["BARLINE_FIXTURE_MODE"] ?? "default"
    @StateObject private var statusItems = FixtureStatusItemController()

    var body: some Scene {
        WindowGroup("Barline Fixture") {
            FixtureView(mode: mode)
                .environmentObject(statusItems)
        }
    }
}

@MainActor
private final class BarlineFixtureAppDelegate: NSObject, NSApplicationDelegate {
    private var auditPanel: NSPanel?
    private var auditStatusItems: FixtureStatusItemController?

    func applicationDidFinishLaunching(_: Notification) {
        if ProcessInfo.processInfo.environment["BARLINE_FIXTURE_MODE"] == "journey" {
            if ProcessInfo.processInfo.environment["BARLINE_FIXTURE_QUALIFICATION_WINDOW"] != "1" {
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows {
                    window.orderOut(nil)
                }
            }
            return
        }
        guard CommandLine.arguments.contains("--barline-fixture-accessibility-audit") else {
            return
        }
        let statusItems = FixtureStatusItemController()
        let panel = NSPanel(
            contentRect: NSRect(x: 80, y: 80, width: 480, height: 220),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Barline Fixture Accessibility Audit"
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(
            rootView: FixtureView(mode: "accessibility-audit")
                .environmentObject(statusItems)
        )
        panel.orderFrontRegardless()
        auditStatusItems = statusItems
        auditPanel = panel
    }
}

private struct FixtureView: View {
    @EnvironmentObject var statusItems: FixtureStatusItemController
    let mode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Barline Fixture", systemImage: "menubar.rectangle")
                .font(.title2.bold())
                .accessibilityIdentifier("fixture-title")
            Text("Mode: \(mode)")
                .accessibilityIdentifier("fixture-mode")
            HStack {
                fixtureItem("Network", identifier: "fixture-network")
                fixtureItem("Battery", identifier: "fixture-battery")
                fixtureItem("Clock", identifier: "fixture-clock")
            }
            Text("Status item clicks: \(statusItems.activationCount)")
                .accessibilityIdentifier("fixture-activation-count")
            Button("Apply Presentation Profile") {}
                .accessibilityIdentifier("fixture-apply-profile")
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 220)
    }

    private func fixtureItem(_ title: String, identifier: String) -> some View {
        Text(title)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: Capsule())
            .accessibilityIdentifier(identifier)
    }
}

@MainActor
private final class FixtureStatusItemController: NSObject, ObservableObject {
    @Published private(set) var activationCount = 0
    private var statusItems = [NSStatusItem]()
    private var journey: FixtureJourneyController?

    override init() {
        super.init()
        if ProcessInfo.processInfo.environment["BARLINE_FIXTURE_MODE"] == "journey" {
            journey = FixtureJourneyController()
            return
        }
        let configured = ProcessInfo.processInfo.environment["BARLINE_FIXTURE_ITEMS"]?
            .split(separator: ",")
            .map(String.init) ?? ["Network", "Battery", "Clock"]
        for (index, title) in configured.enumerated() {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = "BarlineFixture.\(index).\(title)"
            statusItem.button?.title = title
            statusItem.button?.setAccessibilityIdentifier("barline-fixture-status-\(index)")
            statusItem.button?.target = self
            statusItem.button?.action = #selector(activateStatusItem)
            statusItems.append(statusItem)
        }
    }

    @objc private func activateStatusItem() {
        activationCount += 1
    }
}

/// An independent target-process witness. Production Barline has no test IPC or
/// shortcut that can increment these counters: only AppKit-delivered actions can.
@MainActor
private final class FixtureJourneyController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private struct Receipt: Codable, Sendable {
        var schema = 1
        let session: String
        let processIdentifier: Int32
        var sequence = 0
        var kind = "ready"
        var button = "none"
        var activations = 0
        var opens = 0
        var closes = 0
        var actions = 0
        var visible = false
    }

    private let output: URL?
    private let writer = DispatchQueue(label: "BarlineFixture.journey.receipts")
    private var receipt: Receipt
    private var items = [NSStatusItem]()
    private let popover = NSPopover()
    private var activeMenu: NSMenu?

    override init() {
        let environment = ProcessInfo.processInfo.environment
        output = environment["BARLINE_FIXTURE_RECEIPT"].map { URL(fileURLWithPath: $0) }
        receipt = Receipt(
            session: environment["BARLINE_FIXTURE_SESSION"] ?? UUID().uuidString,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSViewController()
        let button = NSButton(title: "Fixture Receipt Action", target: self, action: #selector(receiveAction))
        button.setAccessibilityIdentifier("fixture-journey-action")
        button.frame = NSRect(x: 20, y: 20, width: 220, height: 40)
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        controller.view.addSubview(button)
        popover.contentViewController = controller

        // Bounded fixture-only late publisher. Unlike the Delayed AX case,
        // this process starts with no status items at all. Retained hidden IDs
        // can therefore outlive one process and precede its replacement's items.
        let delay = min(5000, max(0, Int(environment["BARLINE_FIXTURE_PUBLISH_DELAY_MS"] ?? "0") ?? 0))
        if delay > 0 {
            receipt.kind = "starting"
            publish()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled else { return }
                createItems(environment: environment)
            }
        } else {
            createItems(environment: environment)
        }
    }

    private func createItems(environment: [String: String]) {
        // Fixed synthetic names only. No real menu inventory is written to disk.
        let allowedNames = ["Native", "Popover", "Delayed", "Unresponsive"]
        let configuredNames = environment["BARLINE_FIXTURE_JOURNEY_ITEMS"]?
            .split(separator: ",").map(String.init) ?? ["Native", "Popover"]
        for (index, name) in configuredNames.filter({ allowedNames.contains($0) }).prefix(4).enumerated() {
            // Fixture qualification uses a fresh position; installed journeys
            // deliberately retain their position so reveal/restoration is real.
            let positionScope = environment["BARLINE_FIXTURE_FRESH_POSITION"] == "1" ? ".\(receipt.session)" : ""
            let autosaveName = "BarlineFixture.Journey.\(name)\(positionScope)"
            if !positionScope.isEmpty {
                // A new autosave name alone defaults left of a running menu-bar
                // manager's divider. Seed only this synthetic session's position
                // in the nonpersistent registration domain, before creation.
                // XCTest still requires the actual resulting frame on-screen.
                UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position \(autosaveName)": index])
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = autosaveName
            item.button?.title = "BF \(name)"
            item.button?.window?.title = "BF \(name)"
            item.button?.setAccessibilityLabel("BF \(name)")
            item.button?.setAccessibilityIdentifier("barline-fixture-journey-\(index)")
            item.button?.target = self
            item.button?.action = #selector(activate(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Model metadata becoming discoverable after the item window exists.
            if name == "Delayed" {
                item.button?.setAccessibilityElement(false)
                Task { @MainActor [weak item] in
                    try? await Task.sleep(for: .seconds(3))
                    item?.button?.setAccessibilityElement(true)
                }
            }
            items.append(item)
        }
        receipt.kind = "ready"
        publish()
    }

    @objc private func activate(_ sender: NSStatusBarButton) {
        receipt.activations += 1
        receipt.button = NSApp.currentEvent?.type == .rightMouseUp ? "right" : "left"
        receipt.kind = sender.title == "BF Popover" ? "popover" : "native"
        publish()
        if sender.title == "BF Unresponsive" {
            // Bounded fault injection; only this fixture stalls, never Barline.
            Thread.sleep(forTimeInterval: 2)
            return
        }
        if sender.title == "BF Popover", receipt.button == "left" {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        } else {
            let menu = NSMenu(title: "Barline Fixture Journey")
            menu.delegate = self
            let action = NSMenuItem(title: "Fixture Receipt Action", action: #selector(receiveAction), keyEquivalent: "")
            action.target = self
            action.setAccessibilityIdentifier("fixture-journey-action")
            menu.addItem(action)
            activeMenu = menu
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
            activeMenu = nil
        }
    }

    @objc private func receiveAction() {
        receipt.actions += 1
        publish()
        popover.performClose(nil)
    }

    func menuWillOpen(_: NSMenu) {
        opened()
    }

    func menuDidClose(_: NSMenu) {
        closed()
    }

    func popoverDidShow(_: Notification) {
        opened()
    }

    func popoverDidClose(_: Notification) {
        closed()
    }

    private func opened() {
        receipt.opens += 1
        receipt.visible = true
        publish()
    }

    private func closed() {
        receipt.closes += 1
        receipt.visible = false
        publish()
    }

    private func publish() {
        receipt.sequence += 1
        guard let output, let data = try? JSONEncoder().encode(receipt) else { return }
        writer.async {
            // Atomic replacement prevents the observer from accepting a torn receipt.
            try? data.write(to: output, options: .atomic)
        }
    }
}
