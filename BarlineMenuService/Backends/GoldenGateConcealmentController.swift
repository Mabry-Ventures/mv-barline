import BarlineCore
import Foundation
import OSLog

@available(macOS 27.0, *)
final class GoldenGateConcealmentController: @unchecked Sendable {
    private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Apply = @convention(c) (
        UnsafeMutableRawPointer,
        CFArray,
        CFArray
    ) -> Bool
    private typealias Invalidate = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void

    private struct Bridge: @unchecked Sendable {
        let create: Create
        let apply: Apply
        let invalidate: Invalidate
        let destroy: Destroy

        init?() {
            let resolver = DynamicSymbolResolver(libraryPaths: [], includesProcessImage: true)
            guard let create = resolver.resolve("BLNGoldenGateAssessmentCreate", as: Create.self),
                  let apply = resolver.resolve("BLNGoldenGateAssessmentApply", as: Apply.self),
                  let invalidate = resolver.resolve("BLNGoldenGateAssessmentInvalidate", as: Invalidate.self),
                  let destroy = resolver.resolve("BLNGoldenGateAssessmentDestroy", as: Destroy.self)
            else { return nil }
            self.create = create
            self.apply = apply
            self.invalidate = invalidate
            self.destroy = destroy
        }
    }

    private let logger = Logger(category: "GoldenGateConcealmentController")
    private let bridge: Bridge?
    private let opaqueController: UnsafeMutableRawPointer?
    private var desiredConfiguration = MenuBarConcealmentConfiguration(
        visibleItemIDs: [], concealedItemIDs: []
    )
    private var temporaryRevealCounts = [MenuBarItemID: Int]()
    private var appliedResolution: GoldenGateResolvedConcealment?

    init() {
        let bridge = Bridge()
        self.bridge = bridge
        opaqueController = bridge?.create()
    }

    deinit {
        if let opaqueController {
            bridge?.invalidate(opaqueController)
            bridge?.destroy(opaqueController)
        }
    }

    var isAvailable: Bool {
        opaqueController != nil
    }

    func configure(_ configuration: MenuBarConcealmentConfiguration) throws {
        desiredConfiguration = configuration
        try applyCurrentState()
    }

    func beginTemporaryReveal(_ item: MenuBarItemID) throws {
        temporaryRevealCounts[item, default: 0] += 1
        do {
            try applyCurrentState()
        } catch {
            temporaryRevealCounts[item, default: 0] -= 1
            if temporaryRevealCounts[item] == 0 {
                temporaryRevealCounts[item] = nil
            }
            throw error
        }
    }

    func endTemporaryReveal(_ item: MenuBarItemID) {
        guard let count = temporaryRevealCounts[item] else { return }
        temporaryRevealCounts[item] = count > 1 ? count - 1 : nil
        do {
            try applyCurrentState()
        } catch {
            logger.error("Failed to restore Golden Gate concealment after temporary reveal")
        }
    }

    func invalidate() {
        guard let opaqueController else { return }
        bridge?.invalidate(opaqueController)
        appliedResolution = nil
    }

    private func applyCurrentState() throws {
        guard let opaqueController else {
            throw MenuBarBackendError.unavailableCapability("Golden Gate native concealment")
        }
        let temporarilyVisible = Set(temporaryRevealCounts.keys)
        let configuration = MenuBarConcealmentConfiguration(
            visibleItemIDs: desiredConfiguration.visibleItemIDs + temporarilyVisible,
            concealedItemIDs: desiredConfiguration.concealedItemIDs.filter {
                !temporarilyVisible.contains($0)
            }
        )
        let resolved = GoldenGateConcealmentPolicy.resolve(
            configuration,
            barlineBundleIdentifier: "com.mabryventures.Barline"
        )
        let bundles = resolved.concealedBundleIdentifiers.sorted() as CFArray
        let systemItems = resolved.allowedSystemItemIdentifiers.sorted().map(NSNumber.init) as CFArray
        guard bridge?.apply(opaqueController, bundles, systemItems) == true else {
            throw MenuBarBackendError.unavailableCapability("Golden Gate native concealment")
        }
        appliedResolution = resolved
    }
}
