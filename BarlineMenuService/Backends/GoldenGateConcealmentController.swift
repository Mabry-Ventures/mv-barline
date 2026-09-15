import BarlineCore
import Foundation
import OSLog

@available(macOS 27.0, *)
final class GoldenGateConcealmentController: @unchecked Sendable {
    private let logger = Logger(category: "GoldenGateConcealmentController")
    private let opaqueController: UnsafeMutableRawPointer?
    private var desiredConfiguration = MenuBarConcealmentConfiguration(
        visibleItemIDs: [], concealedItemIDs: []
    )
    private var temporaryRevealCounts = [MenuBarItemID: Int]()
    private var appliedResolution: GoldenGateResolvedConcealment?

    init() {
        opaqueController = BLNGoldenGateAssessmentCreate()
    }

    deinit {
        if let opaqueController {
            BLNGoldenGateAssessmentInvalidate(opaqueController)
            BLNGoldenGateAssessmentDestroy(opaqueController)
        }
    }

    var isAvailable: Bool {
        opaqueController != nil
    }

    func configure(_ configuration: MenuBarConcealmentConfiguration) throws {
        let previousConfiguration = desiredConfiguration
        desiredConfiguration = configuration
        do {
            try applyCurrentState()
        } catch {
            desiredConfiguration = previousConfiguration
            throw error
        }
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
        BLNGoldenGateAssessmentInvalidate(opaqueController)
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
        guard BLNGoldenGateAssessmentApply(opaqueController, bundles, systemItems) else {
            throw MenuBarBackendError.unavailableCapability("Golden Gate native concealment")
        }
        appliedResolution = resolved
    }
}
