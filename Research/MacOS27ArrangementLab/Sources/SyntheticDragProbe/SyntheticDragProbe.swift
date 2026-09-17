import AppKit
@preconcurrency import ApplicationServices
import ArrangementLabCore
import Foundation

public enum SyntheticDragProbeRunner {
    public static func run(
        sourceReceiptURL: URL,
        sourceToken: String,
        destinationReceiptURL: URL,
        destinationToken: String,
        placement: SyntheticMovePlacement
    ) -> SyntheticMoveReport {
        var stages: [SyntheticMoveStage] = [.idle, .preflighting]
        var beforeOrder = [String]()
        var afterOrder = [String]()
        var eventReceipt = EventPostReceipt()
        var unrelatedOrderPreserved = false
        let activationDelta: Int? = nil
        var activationMethod: String?
        var sourceFrameAfter: LabRect?
        var sourceDisplayFrame: LabRect?

        func report(disposition: String, reason: String? = nil) -> SyntheticMoveReport {
            SyntheticMoveReport(
                sourceToken: sourceToken,
                destinationToken: destinationToken,
                placement: placement,
                stages: stages,
                disposition: disposition,
                reason: reason,
                beforeOrder: beforeOrder,
                afterOrder: afterOrder,
                mouseDownConstructed: eventReceipt.mouseDownConstructed,
                mouseDownPosted: eventReceipt.mouseDownPosted,
                mouseUpConstructed: eventReceipt.mouseUpConstructed,
                mouseUpPosted: eventReceipt.mouseUpPosted,
                buttonCleanupVerified: eventReceipt.buttonCleanupVerified,
                unrelatedOrderPreserved: unrelatedOrderPreserved,
                activationDelta: activationDelta,
                activationMethod: activationMethod,
                sourceFrameAfter: sourceFrameAfter,
                sourceDisplayFrame: sourceDisplayFrame
            )
        }

        do {
            guard AXIsProcessTrusted() else {
                throw ProbeError.rejected("accessibility-untrusted")
            }
            guard sourceToken != destinationToken else {
                throw ProbeError.rejected("source-equals-destination")
            }
            guard !UserDefaults.standard.bool(forKey: "_HIHideMenuBar") else {
                throw ProbeError.rejected("menu-bar-auto-hide-enabled")
            }
            guard waitForQuietPointer() else {
                throw ProbeError.rejected("pointer-never-became-quiet")
            }
            let topology = displayTopology()
            let receiptURLs = uniqueReceiptURLs(sourceReceiptURL, destinationReceiptURL)
            let receipts = try receiptURLs.map(loadReceipt)
            let resolved = try receipts.flatMap(resolve)
            guard let source = resolved.first(where: { $0.token == sourceToken }),
                  let destination = resolved.first(where: { $0.token == destinationToken })
            else {
                throw ProbeError.rejected("source-or-destination-unresolved")
            }
            guard source.processIdentifier != destination.processIdentifier ||
                !CFEqual(source.element, destination.element)
            else {
                throw ProbeError.rejected("shared-host-elements-not-distinct")
            }
            guard hitTest(x: source.frame.centerX, y: source.frame.centerY, relatedTo: source.element),
                  hitTest(x: destination.frame.centerX, y: destination.frame.centerY, relatedTo: destination.element)
            else {
                throw ProbeError.rejected("source-or-destination-hit-test-failed")
            }
            guard abs(source.frame.centerY - destination.frame.centerY) <= 2 else {
                throw ProbeError.rejected("source-and-destination-not-co-linear")
            }
            sourceDisplayFrame = accessibilityDisplayFrame(containing: CGPoint(
                x: source.frame.centerX,
                y: source.frame.centerY
            ))
            guard sourceDisplayFrame != nil else {
                throw ProbeError.rejected("source-display-unresolved")
            }
            beforeOrder = resolved.sorted(by: screenOrder).map(\.token)
            guard FixtureOrderVerifier.satisfiesPlacement(
                order: beforeOrder,
                source: sourceToken,
                destination: destinationToken,
                placement: placement
            ) == false
            else {
                throw ProbeError.rejected("requested-placement-already-satisfied")
            }
            guard topology == displayTopology() else {
                throw ProbeError.rejected("display-topology-changed-before-mouse-down")
            }
            stages.append(.sourceValidated)

            let destinationPoint = dragDestination(
                source: source.frame,
                destination: destination.frame,
                placement: placement
            )
            eventReceipt = DispatchQueue.global(qos: .userInitiated).sync {
                postCommandDrag(
                    from: CGPoint(x: source.frame.centerX, y: source.frame.centerY),
                    to: destinationPoint
                )
            }
            eventReceipt.buttonCleanupVerified = waitForLeftButtonRelease()
            if eventReceipt.mouseDownPosted {
                stages.append(.mouseDownPosted)
                stages.append(.dragging)
            }
            if eventReceipt.mouseUpPosted {
                stages.append(.mouseUpPosted)
            }
            guard eventReceipt.mouseDownConstructed,
                  eventReceipt.mouseDownPosted,
                  eventReceipt.mouseUpConstructed,
                  eventReceipt.mouseUpPosted,
                  eventReceipt.buttonCleanupVerified
            else {
                stages.append(.indeterminate)
                return report(disposition: "cleanupIndeterminate", reason: "incomplete-event-cleanup")
            }
            guard !eventReceipt.pointerInterferenceDetected else {
                stages.append(.indeterminate)
                return report(disposition: "interferenceDetected", reason: "pointer-deviated-during-drag")
            }

            stages.append(.observing)
            Thread.sleep(forTimeInterval: 0.4)
            _ = try refresh(receiptURLs: receiptURLs, priorReceipts: receipts)
            let refreshed = try reobserveLive(resolved)
            afterOrder = refreshed.sorted(by: screenOrder).map(\.token)
            unrelatedOrderPreserved = FixtureOrderVerifier.preservesRelativeOrder(
                before: beforeOrder,
                after: afterOrder,
                excluding: sourceToken
            )
            guard FixtureOrderVerifier.satisfiesPlacement(
                order: afterOrder,
                source: sourceToken,
                destination: destinationToken,
                placement: placement
            ), unrelatedOrderPreserved
            else {
                stages.append(.rejected)
                return report(disposition: "moveNotObserved", reason: "relative-order-postcondition-failed")
            }

            guard let refreshedSource = refreshed.first(where: { $0.token == sourceToken }) else {
                stages.append(.indeterminate)
                return report(disposition: "cleanupIndeterminate", reason: "moved-source-unresolved")
            }
            sourceFrameAfter = refreshedSource.frame
            activationMethod = "hostForwardedPhysicalPending"
            stages.append(.verified)
            return report(disposition: "movePlacementVerified")
        } catch let error as ProbeError {
            stages.append(.rejected)
            return report(disposition: "preflightRejected", reason: error.description)
        } catch {
            stages.append(.indeterminate)
            return report(disposition: "cleanupIndeterminate", reason: "unexpected-error")
        }
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case rejected(String)
    case invalidReceipt
    case fixtureInaccessible

    var description: String {
        switch self {
        case let .rejected(reason): reason
        case .invalidReceipt: "invalid-fixture-receipt"
        case .fixtureInaccessible: "fixture-accessibility-inventory-unavailable"
        }
    }
}

private struct ResolvedFixtureItem {
    let token: String
    let generation: Int
    let activations: Int
    let processIdentifier: Int32
    let frame: LabRect
    let element: AXUIElement
}

private struct DisplayDescriptor: Equatable {
    let identifier: UInt32
    let frame: LabRect
    let scale: Double
}

private struct EventPostReceipt: Sendable {
    var mouseDownConstructed = false
    var mouseDownPosted = false
    var mouseUpConstructed = false
    var mouseUpPosted = false
    var buttonCleanupVerified = false
    var pointerInterferenceDetected = false
}

private func uniqueReceiptURLs(_ first: URL, _ second: URL) -> [URL] {
    first.standardizedFileURL == second.standardizedFileURL ? [first] : [first, second]
}

private func loadReceipt(from url: URL) throws -> FixtureReceipt {
    guard let data = try? Data(contentsOf: url),
          let receipt = try? JSONDecoder().decode(FixtureReceipt.self, from: data),
          receipt.schema == 1,
          receipt.processIdentifier > 0,
          !receipt.items.isEmpty,
          receipt.items.allSatisfy({ $0.frame != nil })
    else { throw ProbeError.invalidReceipt }
    return receipt
}

private func resolve(receipt: FixtureReceipt) throws -> [ResolvedFixtureItem] {
    let application = AXUIElementCreateApplication(receipt.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.25)
    guard let extrasMenuBar = elementAttribute(application, kAXExtrasMenuBarAttribute as CFString) else {
        throw ProbeError.fixtureInaccessible
    }
    let candidates = descendants(of: extrasMenuBar, maximumDepth: 3, maximumCount: 64)
    let menuExtras = candidates.compactMap { element -> (AXUIElement, LabRect)? in
        guard stringAttribute(element, kAXRoleAttribute as CFString) == "AXMenuBarItem",
              stringAttribute(element, kAXSubroleAttribute as CFString) == "AXMenuExtra",
              let actual = frame(of: element)
        else { return nil }
        return (element, actual)
    }
    func resolved(
        item: FixtureItemReceipt,
        match: (element: AXUIElement, frame: LabRect)
    ) -> ResolvedFixtureItem {
        ResolvedFixtureItem(
            token: item.token,
            generation: item.generation,
            activations: item.activations,
            processIdentifier: receipt.processIdentifier,
            frame: match.frame,
            element: match.element
        )
    }
    if receipt.items.count == 1, menuExtras.count == 1, let match = menuExtras.first {
        return [resolved(item: receipt.items[0], match: (match.0, match.1))]
    }

    let expectedItems = try receipt.items.map { item -> (FixtureItemReceipt, LabRect) in
        guard let appKitFrame = item.frame,
              let expected = accessibilityFrame(for: appKitFrame)
        else { throw ProbeError.rejected("fixture-frame-unavailable") }
        return (item, expected)
    }
    let directlyResolved = expectedItems.compactMap { item, expected -> ResolvedFixtureItem? in
        let matches = menuExtras.filter { _, actual in
            actual.approximatelySharesCenter(with: expected)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return resolved(item: item, match: (match.0, match.1))
    }
    if directlyResolved.count == receipt.items.count {
        return directlyResolved
    }

    guard receipt.variant == .dynamicTitles,
          expectedItems.count == menuExtras.count,
          expectedItems.count > 1
    else { throw ProbeError.rejected("fixture-element-ambiguous-or-missing") }
    let orderedExpected = expectedItems.sorted { $0.1.centerX < $1.1.centerX }
    let orderedActual = menuExtras.sorted { $0.1.centerX < $1.1.centerX }
    guard orderedActual.allSatisfy({ element, frame in
        abs(frame.centerY - orderedActual[0].1.centerY) <= 2 &&
            hitTest(x: frame.centerX, y: frame.centerY, relatedTo: element)
    }), zip(orderedActual, orderedActual.dropFirst()).allSatisfy({ left, right in
        let centerSeparation = right.1.centerX - left.1.centerX
        return left.1.x < right.1.x &&
            centerSeparation > min(left.1.width, right.1.width) / 2
    })
    else { throw ProbeError.rejected("dynamic-fixture-order-fallback-rejected") }
    return zip(orderedExpected, orderedActual).map { expected, actual in
        resolved(item: expected.0, match: (actual.0, actual.1))
    }
}

private func reobserveLive(_ items: [ResolvedFixtureItem]) throws -> [ResolvedFixtureItem] {
    try items.map { item in
        guard stringAttribute(item.element, kAXRoleAttribute as CFString) == "AXMenuBarItem",
              stringAttribute(item.element, kAXSubroleAttribute as CFString) == "AXMenuExtra",
              let currentFrame = frame(of: item.element),
              hitTest(x: currentFrame.centerX, y: currentFrame.centerY, relatedTo: item.element)
        else {
            throw ProbeError.rejected("live-element-invalidated-after-drag")
        }
        return ResolvedFixtureItem(
            token: item.token,
            generation: item.generation,
            activations: item.activations,
            processIdentifier: item.processIdentifier,
            frame: currentFrame,
            element: item.element
        )
    }
}

private func descendants(
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

private func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let array = value as? [AXUIElement]
    else { return [] }
    return array
}

private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

private func frame(of element: AXUIElement) -> LabRect? {
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

private func accessibilityFrame(for appKitFrame: LabRect) -> LabRect? {
    let center = CGPoint(x: appKitFrame.centerX, y: appKitFrame.centerY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
          let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return nil }
    let bounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
    return CoordinateSpaceTransformer.appKitToAccessibility(
        item: appKitFrame,
        appKitScreen: LabRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: screen.frame.height
        ),
        accessibilityScreen: LabRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: bounds.height
        )
    )
}

private func hitTest(x: Double, y: Double, relatedTo expected: AXUIElement) -> Bool {
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

private func displayTopology() -> [DisplayDescriptor] {
    NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return DisplayDescriptor(
            identifier: number.uint32Value,
            frame: LabRect(
                x: screen.frame.minX,
                y: screen.frame.minY,
                width: screen.frame.width,
                height: screen.frame.height
            ),
            scale: screen.backingScaleFactor
        )
    }.sorted { $0.identifier < $1.identifier }
}

private func accessibilityDisplayFrame(containing point: CGPoint) -> LabRect? {
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else {
        return nil
    }
    let bounds = CGDisplayBounds(display)
    return LabRect(
        x: bounds.minX,
        y: bounds.minY,
        width: bounds.width,
        height: bounds.height
    )
}

private func waitForQuietPointer() -> Bool {
    let deadline = Date().addingTimeInterval(2)
    repeat {
        let buttonsUp = !CGEventSource.buttonState(.combinedSessionState, button: .left) &&
            !CGEventSource.buttonState(.combinedSessionState, button: .right) &&
            !CGEventSource.buttonState(.combinedSessionState, button: .center)
        let quietFor = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .mouseMoved
        )
        if buttonsUp, quietFor >= 0.35 {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return false
}

private func dragDestination(
    source: LabRect,
    destination: LabRect,
    placement: SyntheticMovePlacement
) -> CGPoint {
    let offset = max(4, min(destination.width / 4, source.width / 4))
    return CGPoint(
        x: destination.centerX + (placement == .before ? -offset : offset),
        y: destination.centerY
    )
}

private func postCommandDrag(from start: CGPoint, to end: CGPoint) -> EventPostReceipt {
    var receipt = EventPostReceipt()
    guard let source = CGEventSource(stateID: .hidSystemState) else { return receipt }
    source.localEventsSuppressionInterval = 0
    guard let mouseDown = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseDown,
        mouseCursorPosition: start,
        mouseButton: .left
    ) else { return receipt }
    receipt.mouseDownConstructed = true
    guard let mouseUp = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseUp,
        mouseCursorPosition: end,
        mouseButton: .left
    ) else { return receipt }
    receipt.mouseUpConstructed = true
    mouseDown.flags = .maskCommand
    mouseUp.flags = .maskCommand

    var lastPoint = start
    defer {
        if receipt.mouseDownPosted, !receipt.mouseUpPosted {
            mouseUp.location = lastPoint
            mouseUp.post(tap: .cghidEventTap)
            receipt.mouseUpPosted = true
        }
    }

    if let move = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: start,
        mouseButton: .left
    ) {
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
    mouseDown.post(tap: .cghidEventTap)
    receipt.mouseDownPosted = true
    Thread.sleep(forTimeInterval: 0.18)

    let distance = abs(end.x - start.x) + abs(end.y - start.y)
    let steps = min(24, max(6, Int(distance / 40)))
    for step in 1 ... steps {
        let progress = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
        guard let dragged = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { break }
        dragged.flags = .maskCommand
        dragged.post(tap: .cghidEventTap)
        lastPoint = point
        Thread.sleep(forTimeInterval: 0.03)
        if let actual = CGEvent(source: nil)?.location,
           hypot(actual.x - point.x, actual.y - point.y) > 8
        {
            receipt.pointerInterferenceDetected = true
            break
        }
    }
    Thread.sleep(forTimeInterval: 0.12)
    mouseUp.location = lastPoint
    mouseUp.post(tap: .cghidEventTap)
    receipt.mouseUpPosted = true
    return receipt
}

private func waitForLeftButtonRelease() -> Bool {
    let deadline = Date().addingTimeInterval(0.5)
    repeat {
        if !CGEventSource.buttonState(.combinedSessionState, button: .left) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return false
}

private func refresh(
    receiptURLs: [URL],
    priorReceipts: [FixtureReceipt]
) throws -> [FixtureReceipt] {
    for receipt in priorReceipts {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("\(receipt.bundleIdentifier).refresh-receipt"),
            object: nil
        )
    }
    let priorSequences = Dictionary(uniqueKeysWithValues: zip(receiptURLs, priorReceipts.map(\.sequence)))
    let deadline = Date().addingTimeInterval(1.5)
    repeat {
        let current = try receiptURLs.map(loadReceipt)
        let ready = zip(receiptURLs, current).allSatisfy { url, receipt in
            receipt.sequence > (priorSequences[url] ?? Int.max)
        }
        if ready {
            return current
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw ProbeError.rejected("fixture-refresh-timeout")
}

private func screenOrder(_ lhs: ResolvedFixtureItem, _ rhs: ResolvedFixtureItem) -> Bool {
    if lhs.frame.y != rhs.frame.y {
        return lhs.frame.y < rhs.frame.y
    }
    return lhs.frame.x < rhs.frame.x
}
