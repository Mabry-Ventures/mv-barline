import AppKit
import ArrangementLabCore
import Foundation

@main
struct ArrangementFixtureMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = FixtureApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        _ = delegate
    }
}

@MainActor
private final class FixtureApplicationDelegate: NSObject, NSApplicationDelegate {
    private var controller: FixtureStatusItemController?

    func applicationDidFinishLaunching(_: Notification) {
        do {
            controller = try FixtureStatusItemController(environment: ProcessInfo.processInfo.environment)
        } catch {
            FileHandle.standardError.write(Data("fixture configuration failed\n".utf8))
            NSApp.terminate(nil)
        }
    }
}

private actor ReceiptWriter {
    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func write(_ receipt: FixtureReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        try data.write(to: outputURL, options: .atomic)
    }
}

@MainActor
private final class FixtureStatusItemController: NSObject {
    private struct ItemState {
        let token: String
        var generation: Int
        let autosaveName: String
        let creationOrdinal: Int
        var activations: Int
        var statusItem: NSStatusItem
    }

    private let session: String
    private let publisherKind: String
    private let variant: FixtureVariant
    private let writer: ReceiptWriter
    private let bundleIdentifier: String
    private var sequence = 0
    private var items = [ItemState]()
    private var dynamicTimer: Timer?
    private var distributedObservers = [NSObjectProtocol]()

    init(environment: [String: String]) throws {
        guard let output = environment["BARLINE_LAB_FIXTURE_RECEIPT"], output.hasPrefix("/"),
              let session = environment["BARLINE_LAB_SESSION"], !session.isEmpty,
              let kind = environment["BARLINE_LAB_PUBLISHER_KIND"], ["multi", "single"].contains(kind),
              let rawVariant = environment["BARLINE_LAB_FIXTURE_VARIANT"],
              let variant = FixtureVariant(rawValue: rawVariant),
              let bundleIdentifier = Bundle.main.bundleIdentifier
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.session = session
        publisherKind = kind
        self.variant = variant
        writer = ReceiptWriter(outputURL: URL(fileURLWithPath: output))
        self.bundleIdentifier = bundleIdentifier
        super.init()

        let tokens = kind == "single" ? ["solo"] : ["alpha", "beta", "gamma"]
        let creationTokens = variant == .reversedCreation ? Array(tokens.reversed()) : tokens
        for (ordinal, token) in creationTokens.enumerated() {
            items.append(makeItem(token: token, generation: 1, creationOrdinal: ordinal))
        }
        configureExternalControls()
        configureDynamicTitlesIfNeeded()
        publish()
        publishAfterPlacementSettles()
    }

    private func publishAfterPlacementSettles() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.publish()
        }
    }

    private func makeItem(token: String, generation: Int, creationOrdinal: Int) -> ItemState {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let autosaveName = "BarlineArrangementLab.\(publisherKind).\(token)"
        statusItem.autosaveName = autosaveName
        configureButton(statusItem.button, token: token, generation: generation)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(activate(_:))
        return ItemState(
            token: token,
            generation: generation,
            autosaveName: autosaveName,
            creationOrdinal: creationOrdinal,
            activations: 0,
            statusItem: statusItem
        )
    }

    private func configureButton(_ button: NSStatusBarButton?, token: String, generation: Int) {
        guard let button else { return }
        button.imagePosition = .imageLeading
        switch variant {
        case .uniqueLabels, .reversedCreation:
            button.title = token.capitalized
            button.setAccessibilityIdentifier("barline-lab-\(token)")
            button.setAccessibilityLabel("Barline lab \(token)")
        case .duplicateLabels:
            button.title = "Fixture"
            button.setAccessibilityIdentifier("barline-lab-duplicate")
            button.setAccessibilityLabel("Barline lab fixture")
        case .absentLabels:
            button.title = ""
            button.image = NSImage(systemSymbolName: symbolName(for: token), accessibilityDescription: nil)
            button.setAccessibilityIdentifier(nil)
            button.setAccessibilityLabel(nil)
        case .dynamicTitles:
            button.title = "\(token.capitalized) \(generation)"
            button.setAccessibilityIdentifier("barline-lab-\(token)")
            button.setAccessibilityLabel("Barline lab \(token)")
        }
    }

    private func symbolName(for token: String) -> String {
        switch token {
        case "alpha": "circle.fill"
        case "beta": "square.fill"
        case "gamma": "triangle.fill"
        default: "diamond.fill"
        }
    }

    private func configureExternalControls() {
        let center = DistributedNotificationCenter.default()
        distributedObservers.append(center.addObserver(
            forName: Notification.Name("\(bundleIdentifier).recreate-beta"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recreate(token: "beta") }
        })
        distributedObservers.append(center.addObserver(
            forName: Notification.Name("\(bundleIdentifier).refresh-receipt"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        })
    }

    private func configureDynamicTitlesIfNeeded() {
        guard variant == .dynamicTitles else { return }
        dynamicTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for index in self.items.indices {
                    let state = self.items[index]
                    state.statusItem.button?.title = "\(state.token.capitalized) \(self.sequence + 1)"
                }
                self.publish()
            }
        }
    }

    private func recreate(token: String) {
        guard let index = items.firstIndex(where: { $0.token == token }) else { return }
        let previous = items[index]
        NSStatusBar.system.removeStatusItem(previous.statusItem)
        items[index] = makeItem(
            token: previous.token,
            generation: previous.generation + 1,
            creationOrdinal: previous.creationOrdinal
        )
        publish()
        publishAfterPlacementSettles()
    }

    @objc private func activate(_ sender: NSStatusBarButton) {
        guard let index = items.firstIndex(where: { $0.statusItem.button === sender }) else { return }
        items[index].activations += 1
        publish()
    }

    private func publish() {
        sequence += 1
        let itemReceipts = items.map { state in
            FixtureItemReceipt(
                token: state.token,
                generation: state.generation,
                autosaveName: state.autosaveName,
                creationOrdinal: state.creationOrdinal,
                frame: state.statusItem.button?.window.map {
                    LabRect(
                        x: $0.frame.minX,
                        y: $0.frame.minY,
                        width: $0.frame.width,
                        height: $0.frame.height
                    )
                },
                activations: state.activations
            )
        }
        let receipt = FixtureReceipt(
            session: session,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            publisherKind: publisherKind,
            variant: variant,
            sequence: sequence,
            items: itemReceipts
        )
        Task {
            try? await writer.write(receipt)
        }
    }
}
