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
        let item = sourceItem.waitForExistence(timeout: 3) ? sourceItem : hostedItem
        guard item.waitForExistence(timeout: 3) else {
            XCTFail("The exact fixture source/host status control is unavailable; no click attempted")
            return
        }
        let displayFrames = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        let onScreen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = item.frame
            return frame.width > 0 && frame.height > 0 && displayFrames.contains { $0.contains(frame) }
        }, object: nil)
        _ = XCTWaiter.wait(for: [onScreen], timeout: 3)
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
        let delivered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: receiptURL),
                  let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return receipt["session"] as? String == session &&
                (receipt["activations"] as? Int ?? 0) > 0
        }, object: nil)
        guard XCTWaiter.wait(for: [delivered], timeout: 3) == .completed else {
            XCTFail("Host XCTest status-item event produced no target-process receipt. Event-delivery gate failed; menu behavior is not established.")
            return
        }
        let action = target == "BF Popover"
            ? app.buttons["fixture-journey-action"] : app.menuItems["Fixture Receipt Action"]
        let completedReceipt = {
            guard let data = try? Data(contentsOf: receiptURL),
                  let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return receipt["session"] as? String == session &&
                receipt["button"] as? String == "left" &&
                receipt["actions"] as? Int == 1 &&
                receipt["opens"] as? Int == 1 &&
                receipt["closes"] as? Int == 1 &&
                receipt["visible"] as? Bool == false
        }
        guard action.waitForExistence(timeout: 5) else {
            XCTFail("The fixture did not expose its actual menu/popover action")
            return
        }
        action.click()
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            completedReceipt()
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 5), .completed)
    }
}
