//
//  BarlineUITests.swift
//  Barline
//

import AppKit
import XCTest

final class BarlineUITests: XCTestCase {
    @MainActor
    func testFixtureExposesDeterministicAccessibilitySurface() {
        let app = XCUIApplication()
        app.launchEnvironment["BARLINE_FIXTURE_MODE"] = "ui-test"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["fixture-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture-mode"].exists)
        XCTAssertTrue(app.buttons["fixture-apply-profile"].exists)
    }

    /// Fixture qualification only. The installed-candidate journey shell gate is
    /// separate: this test must never be reported as proof of Barline activation.
    /// The native-right installed journey owns right-click qualification because
    /// XCUI can acknowledge a status-item rightClick without delivering it.
    @MainActor
    func testNativeFixtureReportsTargetActionAndClosure() throws {
        try exerciseFixtureTarget("BF Native")
    }

    @MainActor
    func testPopoverFixtureReportsTargetActionAndClosure() throws {
        try exerciseFixtureTarget("BF Popover")
    }

    @MainActor
    private func exerciseFixtureTarget(_ target: String) throws {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            throw XCTSkip(
                "Xcode 27 does not deliver XCUITest-synthesized events to AppKit status items; " +
                    "the installed-candidate physical journey owns this macOS 27 gate"
            )
        }
        let session = UUID().uuidString
        let receiptURL = FileManager.default.temporaryDirectory.appendingPathComponent("barline-fixture-\(session).json")
        defer {
            if let data = try? Data(contentsOf: receiptURL) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "synthetic-fixture-receipt"
                attachment.lifetime = .keepAlways
                add(attachment)
                if let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("FIXTURE receipt activations=\(receipt["activations"] ?? -1) opens=\(receipt["opens"] ?? -1) actions=\(receipt["actions"] ?? -1) closes=\(receipt["closes"] ?? -1) visible=\(receipt["visible"] ?? false)")
                }
            } else {
                print("FIXTURE receipt missing")
            }
            try? FileManager.default.removeItem(at: receiptURL)
        }
        let app = XCUIApplication()
        app.launchEnvironment["BARLINE_FIXTURE_MODE"] = "journey"
        app.launchEnvironment["BARLINE_FIXTURE_SESSION"] = session
        app.launchEnvironment["BARLINE_FIXTURE_RECEIPT"] = receiptURL.path
        app.launchEnvironment["BARLINE_FIXTURE_JOURNEY_ITEMS"] = String(target.dropFirst(3))
        app.launchEnvironment["BARLINE_FIXTURE_FRESH_POSITION"] = "1"
        app.launchEnvironment["BARLINE_FIXTURE_QUALIFICATION_WINDOW"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        let sourceItem = app.descendants(matching: .any)["barline-fixture-journey-0"]
        let host = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
        let hostedItem = host.descendants(matching: .any)["barline-fixture-journey-0"]
        // Extras are not the application's ordinary Apple/File/Edit menu bar.
        // macOS 26 may expose the actual NSStatusBarButton through its host.
        _ = sourceItem.waitForExistence(timeout: 3)
        _ = hostedItem.waitForExistence(timeout: 3)
        guard sourceItem.exists || hostedItem.exists else {
            XCTFail("The exact fixture source/host status control is unavailable; no click attempted")
            return
        }
        let displayFrames = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        func onScreen(_ candidate: XCUIElement) -> Bool {
            guard candidate.exists else { return false }
            let frame = candidate.frame
            return frame.width > 0 && frame.height > 0 && displayFrames.contains { $0.contains(frame) }
        }
        let deadline = Date().addingTimeInterval(3)
        var item: XCUIElement?
        repeat {
            item = [sourceItem, hostedItem].first(where: onScreen)
            if item != nil {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        guard let item else {
            XCTFail("Synthetic fixture status controls are outside active displays \(displayFrames); no click attempted")
            return
        }
        let itemFrame = item.frame
        print("FIXTURE statusFrame=\(itemFrame) activeDisplays=\(displayFrames)")
        guard itemFrame.width > 0, itemFrame.height > 0,
              displayFrames.contains(where: { $0.contains(itemFrame) })
        else {
            XCTFail("Synthetic fixture status frame \(itemFrame) is outside active displays \(displayFrames); no click attempted")
            return
        }
        // AppKit-hosted StatusItem reports isHittable=false on some macOS 26
        // versions despite a valid on-screen frame. Use the exact discovered
        // element's coordinate, never an assumed/global location or AXPress.
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        // The fixture's receipt is the target-process witness. Every wait below
        // is on a concrete receipt or element state, never on elapsed time.
        let currentReceipt = { () -> [String: Any]? in
            guard let data = try? Data(contentsOf: receiptURL),
                  let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  receipt["session"] as? String == session
            else { return nil }
            return receipt
        }
        let describe = { (receipt: [String: Any]?) -> String in
            guard let receipt else { return "no receipt" }
            let fields = ["activations", "opens", "actions", "closes"].map { "\($0)=\(receipt[$0] as? Int ?? -1)" }
            return (fields + ["visible=\(receipt["visible"] as? Bool ?? false)"]).joined(separator: " ")
        }
        let waitForReceipt = { (timeout: TimeInterval, condition: @escaping ([String: Any]) -> Bool) -> Bool in
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                currentReceipt().map(condition) ?? false
            }, object: nil)
            return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        }
        guard waitForReceipt(3, { ($0["activations"] as? Int ?? 0) > 0 }) else {
            XCTFail("Host XCTest status-item event produced no target-process receipt. Event-delivery gate failed; menu behavior is not established.")
            return
        }
        // The fixture publishes its activation before NSMenu.popUp or
        // NSPopover.show runs. Wait for AppKit's own open delegate callback, so
        // the action is looked up only after the menu or popover is attached.
        let isOpen = { (receipt: [String: Any]) -> Bool in
            receipt["button"] as? String == "left" &&
                receipt["activations"] as? Int == 1 &&
                receipt["opens"] as? Int == 1 &&
                receipt["closes"] as? Int == 0 &&
                receipt["actions"] as? Int == 0 &&
                receipt["visible"] as? Bool == true
        }
        guard waitForReceipt(5, isOpen) else {
            XCTFail("The fixture received the status-item click but did not report its menu/popover open: \(describe(currentReceipt()))")
            return
        }
        let action = target == "BF Popover"
            ? app.buttons["fixture-journey-action"] : app.menuItems["Fixture Receipt Action"]
        let actionDeadline = Date().addingTimeInterval(5)
        while !onScreen(action), Date() < actionDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard onScreen(action) else {
            XCTFail("The fixture did not expose its actual menu/popover action on screen: \(describe(currentReceipt()))")
            return
        }
        guard let beforeAction = currentReceipt(), isOpen(beforeAction) else {
            XCTFail("The menu/popover closed before the action was clicked: \(describe(currentReceipt()))")
            return
        }
        // Click the discovered action's coordinate rather than calling
        // XCUIElement.click(). For a menu item, click() hovers the item and then
        // re-resolves it; on macOS 26 the highlighted menu can drop out of the
        // accessibility tree between the two, so XCTest either reports no
        // matching Menu or clicks after the menu is gone. A coordinate click
        // delivers move, down and up at the item, as the installed journey does.
        action.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let completed = waitForReceipt(5) { receipt in
            receipt["button"] as? String == "left" &&
                receipt["activations"] as? Int == 1 &&
                receipt["actions"] as? Int == 1 &&
                receipt["opens"] as? Int == 1 &&
                receipt["closes"] as? Int == 1 &&
                receipt["visible"] as? Bool == false
        }
        XCTAssertTrue(completed, "The action click did not produce exactly one action and closure: \(describe(currentReceipt()))")
    }
}
