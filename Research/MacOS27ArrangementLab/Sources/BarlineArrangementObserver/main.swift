import AppKit
@preconcurrency import ApplicationServices
import ArrangementLabCore
import Darwin
import Foundation
import SyntheticDragProbe

private enum ObserverError: Error, CustomStringConvertible {
    case usage
    case untrusted
    case invalidReceipt
    case inaccessibleFixture

    var description: String {
        switch self {
        case .usage:
            "usage: BarlineArrangementObserver observe /absolute/fixture-receipt.json [/absolute/observation.json]"
        case .untrusted: "observer does not have Accessibility permission"
        case .invalidReceipt: "fixture receipt is missing or invalid"
        case .inaccessibleFixture: "fixture Accessibility inventory is unavailable"
        }
    }
}

@main
struct ArrangementObserverMain {
    static func main() {
        do {
            if CommandLine.arguments == [CommandLine.arguments[0], "request-accessibility"] {
                requestAccessibility()
                return
            }
            if try runSyntheticMoveIfRequested() {
                return
            }
            let observation = try run()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(observation)
            if let outputURL = commandOutputURL() {
                try data.write(to: outputURL, options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            if let outputURL = commandOutputURL(),
               let data = try? JSONSerialization.data(
                   withJSONObject: ["error": "\(error)"],
                   options: [.prettyPrinted, .sortedKeys]
               )
            {
                try? data.write(to: outputURL, options: .atomic)
            } else {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
            }
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func runSyntheticMoveIfRequested() throws -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, arguments[1] == "synthetic-move" else { return false }
        guard arguments.count == 8,
              arguments[2].hasPrefix("/"),
              arguments[4].hasPrefix("/"),
              arguments[7].hasPrefix("/"),
              let placement = SyntheticMovePlacement(rawValue: arguments[6])
        else { throw ObserverError.usage }
        let report = SyntheticDragProbeRunner.run(
            sourceReceiptURL: URL(fileURLWithPath: arguments[2]),
            sourceToken: arguments[3],
            destinationReceiptURL: URL(fileURLWithPath: arguments[4]),
            destinationToken: arguments[5],
            placement: placement
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: URL(fileURLWithPath: arguments[7]),
            options: .atomic
        )
        return true
    }

    private static func commandOutputURL() -> URL? {
        let arguments = CommandLine.arguments
        if arguments.count == 4,
           arguments[1] == "observe",
           arguments[3].hasPrefix("/")
        {
            return URL(fileURLWithPath: arguments[3])
        }
        if arguments.count == 8,
           arguments[1] == "synthetic-move",
           arguments[7].hasPrefix("/")
        {
            return URL(fileURLWithPath: arguments[7])
        }
        return nil
    }

    private static func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        FileHandle.standardOutput.write(Data("accessibility-trusted=\(trusted)\n".utf8))
        if !trusted {
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws -> FixtureObservation {
        let arguments = CommandLine.arguments
        guard [3, 4].contains(arguments.count),
              arguments[1] == "observe",
              arguments[2].hasPrefix("/"),
              arguments.count != 4 || arguments[3].hasPrefix("/")
        else {
            throw ObserverError.usage
        }
        guard AXIsProcessTrusted() else { throw ObserverError.untrusted }
        let receiptURL = URL(fileURLWithPath: arguments[2])
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(FixtureReceipt.self, from: data),
              receipt.schema == 1,
              receipt.processIdentifier > 0,
              !receipt.items.isEmpty,
              receipt.items.allSatisfy({ $0.frame != nil })
        else { throw ObserverError.invalidReceipt }

        let application = AXUIElementCreateApplication(receipt.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let extrasMenuBar = elementAttribute(application, kAXExtrasMenuBarAttribute as CFString) else {
            throw ObserverError.inaccessibleFixture
        }
        let candidates = descendants(of: extrasMenuBar, maximumDepth: 3, maximumCount: 64)
        let menuExtras = candidates.compactMap { element -> (AXUIElement, LabRect)? in
            guard stringAttribute(element, kAXRoleAttribute as CFString) == "AXMenuBarItem",
                  stringAttribute(element, kAXSubroleAttribute as CFString) == "AXMenuExtra",
                  let actual = frame(of: element)
            else { return nil }
            return (element, actual)
        }
        let matched = receipt.items.compactMap { item -> (FixtureItemReceipt, AXUIElement, LabRect)? in
            if receipt.items.count == 1, menuExtras.count == 1, let match = menuExtras.first {
                return (item, match.0, match.1)
            }
            guard let appKitFrame = item.frame,
                  let expected = accessibilityFrame(for: appKitFrame)
            else { return nil }
            let matches = menuExtras.filter { _, actual in
                actual.approximatelySharesCenter(with: expected)
            }
            guard matches.count == 1, let match = matches.first else { return nil }
            return (item, match.0, match.1)
        }
        let ordered = matched.sorted {
            if $0.2.y != $1.2.y {
                return $0.2.y < $1.2.y
            }
            return $0.2.x < $1.2.x
        }
        let observed = ordered.enumerated().map { index, value in
            let (item, element, actualFrame) = value
            let hit = hitTest(x: actualFrame.centerX, y: actualFrame.centerY, relatedTo: element)
            return ObservedFixtureItem(
                token: item.token,
                generation: item.generation,
                frame: actualFrame,
                relativeIndex: index,
                hitTestMatched: hit,
                role: stringAttribute(element, kAXRoleAttribute as CFString),
                subrole: stringAttribute(element, kAXSubroleAttribute as CFString)
            )
        }
        return FixtureObservation(
            session: receipt.session,
            processIdentifier: receipt.processIdentifier,
            receiptSequence: receipt.sequence,
            complete: observed.count == receipt.items.count && observed.allSatisfy(\.hitTestMatched),
            items: observed,
            candidates: candidates.map {
                ObservedCandidate(
                    frame: frame(of: $0),
                    role: stringAttribute($0, kAXRoleAttribute as CFString),
                    subrole: stringAttribute($0, kAXSubroleAttribute as CFString)
                )
            }
        )
    }

    private static func descendants(
        of root: AXUIElement,
        maximumDepth: Int,
        maximumCount: Int
    ) -> [AXUIElement] {
        var result = [AXUIElement]()
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty, result.count < maximumCount {
            let (current, depth) = queue.removeFirst()
            result.append(current)
            guard depth < maximumDepth else { continue }
            queue.append(contentsOf: children(of: current).map { ($0, depth + 1) })
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement]
        else { return [] }
        return array
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> LabRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width > 0, size.height > 0
        else { return nil }
        return LabRect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private static func accessibilityFrame(for appKitFrame: LabRect) -> LabRect? {
        let center = CGPoint(x: appKitFrame.centerX, y: appKitFrame.centerY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let accessibilityBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        return CoordinateSpaceTransformer.appKitToAccessibility(
            item: appKitFrame,
            appKitScreen: LabRect(
                x: screen.frame.minX,
                y: screen.frame.minY,
                width: screen.frame.width,
                height: screen.frame.height
            ),
            accessibilityScreen: LabRect(
                x: accessibilityBounds.minX,
                y: accessibilityBounds.minY,
                width: accessibilityBounds.width,
                height: accessibilityBounds.height
            )
        )
    }

    private static func hitTest(x: Double, y: Double, relatedTo expected: AXUIElement) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &hit) == .success, let hit else {
            return false
        }
        if CFEqual(hit, expected) {
            return true
        }
        var current = hit
        for _ in 0 ..< 4 {
            guard let parent = elementAttribute(current, kAXParentAttribute as CFString) else { break }
            if CFEqual(parent, expected) {
                return true
            }
            current = parent
        }
        current = expected
        for _ in 0 ..< 4 {
            guard let parent = elementAttribute(current, kAXParentAttribute as CFString) else { break }
            if CFEqual(parent, hit) {
                return true
            }
            current = parent
        }
        return false
    }
}
