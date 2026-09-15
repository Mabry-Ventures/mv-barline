//
//  BarlineMenuServiceConnection.swift
//  Barline
//

import BarlineCore
import CoreGraphics
import Foundation
import OSLog
import Security
import XPC

@available(macOS 26.0, *)
extension BarlineMenuService {
    final class Connection: Sendable {
        static let shared = Connection()

        private static let restoreTimeout: Duration = .seconds(30)
        private static let mutationBudgetNanoseconds: UInt64 = 4_000_000_000

        private let session: Session
        private let queue: DispatchQueue
        private let logger: Logger

        /// Returns a strict peer requirement for the embedded compatibility service.
        ///
        /// Apple-issued development and distribution signatures have a team
        /// identifier, so production uses the strongest same-team plus exact
        /// signing-identifier check. Local gates intentionally use ad-hoc signing,
        /// which has no team identifier; those builds remain constrained to the
        /// service's exact signing identifier and the local/ad-hoc validation
        /// category instead of disabling peer validation.
        fileprivate static func servicePeerRequirement() -> XPCPeerRequirement {
            let signingIdentifier = BarlineMenuService.requiredIdentity(
                forInfoKey: "BarlineMenuServiceSigningIdentifier"
            )
            if currentProcessHasTeamIdentifier() {
                return .isFromSameTeam(andMatchesSigningIdentifier: signingIdentifier)
            }
            var requirement = XPCDictionary()
            requirement["signing-identifier"] = signingIdentifier
            requirement["validation-category"] = 10
            return XPCPeerRequirement(lightweightCodeRequirements: requirement)
        }

        private static func currentProcessHasTeamIdentifier() -> Bool {
            var code: SecCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
                return false
            }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
                  let staticCode
            else {
                return false
            }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
                let dictionary = information as? [CFString: Any],
                let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier] as? String
            else {
                return false
            }
            return !teamIdentifier.isEmpty
        }

        private init() {
            let queue = DispatchQueue(
                label: "BarlineMenuService.Connection.queue",
                qos: .userInteractive
            )
            let logger = Logger(category: "BarlineMenuService.Connection")
            session = Session(logger: logger)
            self.queue = queue
            self.logger = logger
        }

        func start() async {
            logger.debug("Starting BarlineMenuService connection")
            guard case .start = await send(.start) else {
                logger.error("Start request returned an invalid response")
                return
            }
        }

        func capabilities() async throws -> MenuBarCapabilities {
            guard case let .capabilities(result) = await send(.capabilities) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func snapshot() async throws -> MenuBarSnapshot {
            guard case let .snapshot(result) = await send(.snapshot) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func move(_ operation: MenuBarMoveOperation) async throws -> MenuBarMutationResult {
            guard case let .mutation(result) = await send(
                .move(operation, deadlineUptimeNanoseconds: mutationDeadline())
            ) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func reveal(_ item: MenuBarItemID) async throws -> MenuBarMutationResult {
            guard case let .mutation(result) = await send(
                .reveal(item, deadlineUptimeNanoseconds: mutationDeadline())
            ) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func activate(_ item: MenuBarItemID, button: MenuBarMouseButton) async throws {
            guard case let .activation(result) = await send(
                .activate(
                    item: item,
                    button: button,
                    deadlineUptimeNanoseconds: mutationDeadline()
                )
            ) else {
                throw MenuBarBackendError.interrupted
            }
            _ = try result.value()
        }

        func capture(_ items: [MenuBarItemID]) async throws -> [MenuBarCapturedImage] {
            guard case let .capturedImages(result) = await send(.capture(items)) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func captureBackground(
            displayID: CGDirectDisplayID,
            sampleHeight: CGFloat? = nil
        ) async throws -> MenuBarBackgroundCapture {
            guard case let .background(result) = await send(
                .captureBackground(
                    displayID: displayID,
                    sampleHeight: sampleHeight.map(Double.init)
                )
            ) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func environment() async throws -> MenuBarEnvironmentSnapshot {
            guard case let .environment(result) = await send(.environment) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func configureCursorInBackground(_ enabled: Bool) async {
            _ = await send(.configureCursorInBackground(enabled))
        }

        func configureConcealment(
            _ configuration: MenuBarConcealmentConfiguration
        ) async throws {
            guard case let .activation(result) = await send(
                .configureConcealment(configuration)
            ) else {
                throw MenuBarBackendError.interrupted
            }
            _ = try result.value()
        }

        func pointContext(at point: CGPoint) async throws -> MenuBarPointContext {
            guard case let .pointContext(result) = await send(
                .pointContext(MenuBarPoint(x: point.x, y: point.y))
            ) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func shelfPresentationObservation(
            ownerProcessIdentifier: pid_t,
            targetDisplayID: CGDirectDisplayID
        ) async throws -> MenuBarShelfPresentationObservation {
            let probe = MenuBarShelfPresentationProbe(
                ownerProcessIdentifier: ownerProcessIdentifier,
                targetDisplayID: targetDisplayID
            )
            guard case let .shelfPresentationObservation(result) = await send(
                .shelfPresentationObservation(probe)
            ) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func beginRevealObservation(
            for item: MenuBarItemID
        ) async throws -> MenuBarRevealObservationToken {
            guard case let .revealObservation(result) = await send(.beginRevealObservation(item)) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func revealObservationIsVisible(
            _ token: MenuBarRevealObservationToken
        ) async throws -> Bool {
            guard case let .boolean(result) = await send(.revealObservationIsVisible(token)) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
        }

        func endRevealObservation(_ token: MenuBarRevealObservationToken) async {
            _ = await send(.endRevealObservation(token))
        }

        func restore(_ snapshot: MenuBarSnapshot) async throws -> MenuBarMutationResult {
            guard snapshot.items.count <= 256 else {
                throw MenuBarBackendError.operationFailed("restore plan exceeds the safe operation limit")
            }
            let operations = MenuBarMovePlanner().restoreOperations(for: snapshot)
            guard operations.count <= 256 else {
                throw MenuBarBackendError.operationFailed("restore plan exceeds the safe operation limit")
            }
            let deadline = ContinuousClock.now.advanced(by: Self.restoreTimeout)
            var changedItemIDs = [MenuBarItemID]()
            for operation in operations {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw MenuBarBackendError.timedOut
                }
                let result = try await move(operation)
                changedItemIDs.append(contentsOf: result.changedItemIDs)
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw MenuBarBackendError.timedOut
            }
            let updated = try await self.snapshot()
            return MenuBarMutationResult(
                generation: updated.generation,
                changedItemIDs: changedItemIDs
            )
        }

        func health() async -> MenuBarBackendHealth {
            guard case let .health(health) = await send(.health) else {
                return MenuBarBackendHealth(
                    backendName: "XPC",
                    state: .unavailable,
                    message: "Compatibility service did not respond"
                )
            }
            return health
        }

        func restart() async {
            session.cancel(reason: "Explicit compatibility restart")
            var helperRestarted = false
            for attempt in 0 ..< 6 {
                guard !Task.isCancelled else { return }
                if !helperRestarted, case .restart? = await send(.restart) {
                    helperRestarted = true
                }
                if helperRestarted, case .start? = await send(.start) {
                    return
                }
                guard attempt < 5 else { break }
                let delay = min(100 * (1 << attempt), 1600)
                try? await Task.sleep(for: .milliseconds(delay))
            }
            logger.error("Explicit compatibility restart did not reach a ready handshake")
        }

        private func send(_ request: Request) async -> Response? {
            await withCheckedContinuation { continuation in
                queue.async { [session] in
                    continuation.resume(returning: session.send(request: request))
                }
            }
        }

        private func mutationDeadline() -> UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            let (deadline, overflowed) = now.addingReportingOverflow(
                Self.mutationBudgetNanoseconds
            )
            return overflowed ? .max : deadline
        }
    }
}

private extension BarlineMenuService.ServiceResult {
    func value() throws -> Value {
        switch self {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        }
    }
}

@available(macOS 26.0, *)
extension BarlineMenuService {
    private final class Session: @unchecked Sendable {
        private struct State: @unchecked Sendable {
            var session: XPCSession?
            var generation: UInt64 = 0
        }

        private let name = BarlineMenuService.name
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let callbackQueue = DispatchQueue(
            label: "BarlineMenuService.Connection.callback",
            qos: .userInteractive,
            attributes: .concurrent
        )
        private let transportQueue = DispatchQueue(
            label: "BarlineMenuService.Connection.transport",
            qos: .userInteractive,
            attributes: .concurrent
        )
        private let latestConcealmentRequest = OSAllocatedUnfairLock<Request?>(initialState: nil)
        private let recoveryScheduled = OSAllocatedUnfairLock(initialState: false)
        private let logger: Logger

        init(logger: Logger) {
            self.logger = logger
        }

        deinit {
            cancel(reason: "Session deinitialized")
        }

        func cancel(reason: String) {
            let oldSession = state.withLock { state -> XPCSession? in
                state.generation &+= 1
                return state.session.take()
            }
            oldSession?.cancel(reason: reason)
        }

        func send(request: Request) -> Response? {
            let semaphore = DispatchSemaphore(value: 0)
            let result = OSAllocatedUnfairLock<Response?>(initialState: nil)
            transportQueue.async { [self] in
                let response = performSendReplayingConcealmentIfNeeded(request: request)
                result.withLock { $0 = response }
                semaphore.signal()
            }
            let timeout: TimeInterval = switch request {
            case .start, .capabilities, .snapshot, .health, .restart:
                1
            case .shelfPresentationObservation:
                0.1
            default:
                5
            }
            guard semaphore.wait(timeout: .now() + timeout) == .success else {
                logger.error("Compatibility request timed out")
                if case .shelfPresentationObservation = request {
                    return nil
                }
                cancel(reason: "Request timed out")
                return nil
            }
            let response = result.withLock { $0.take() }
            if case .configureConcealment = request,
               case .activation(.success) = response
            {
                // Recovery may only replay a configuration the helper
                // actually accepted. A rejected request must not become the
                // next process's startup state.
                latestConcealmentRequest.withLock { $0 = request }
            }
            return response
        }

        private func performSendReplayingConcealmentIfNeeded(request: Request) -> Response? {
            let response = performSend(request: request)
            guard case .start? = response,
                  let concealmentRequest = latestConcealmentRequest.withLock({ $0 })
            else {
                return response
            }
            // A replacement helper owns a new assessment assertion. Reapply
            // the last complete desired state before reporting recovery.
            _ = performSend(request: concealmentRequest)
            return response
        }

        private func performSend(request: Request) -> Response? {
            do {
                let (session, generation) = try getOrCreateSession()
                let reply = try session.sendSync(request)
                let response = try reply.decode(as: Response.self)
                let remainsCurrent = state.withLock { $0.generation == generation }
                return remainsCurrent ? response : nil
            } catch {
                logger.error("Session failed with error \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
                cancel(reason: "Send failed: \(error.localizedDescription)")
                return nil
            }
        }

        private func getOrCreateSession() throws -> (XPCSession, UInt64) {
            if let existing = state.withLock({ state -> (XPCSession, UInt64)? in
                state.session.map { ($0, state.generation) }
            }) {
                return existing
            }
            let generation = state.withLock { state in
                state.generation &+= 1
                return state.generation
            }
            let session = try XPCSession(xpcService: name, options: .inactive) { [weak self] error in
                guard let self else { return }
                logger.warning("Session was cancelled with error \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
                state.withLock { state in
                    guard state.generation == generation else { return }
                    state.generation &+= 1
                    state.session = nil
                }
                scheduleRecovery()
            }
            session.setPeerRequirement(BarlineMenuService.Connection.servicePeerRequirement())
            session.setTargetQueue(callbackQueue)
            try session.activate()
            let installed = state.withLock { state -> Bool in
                guard state.generation == generation, state.session == nil else {
                    return false
                }
                state.session = session
                return true
            }
            guard installed else {
                session.cancel(reason: "Superseded during activation")
                throw MenuBarBackendError.interrupted
            }
            return (session, generation)
        }

        private func scheduleRecovery() {
            let shouldSchedule = recoveryScheduled.withLock { scheduled in
                guard !scheduled else { return false }
                scheduled = true
                return true
            }
            guard shouldSchedule else { return }
            performRecoveryAttempt(0)
        }

        private func performRecoveryAttempt(_ attempt: Int) {
            let boundedAttempt = min(max(attempt, 0), 3)
            let delay = 0.1 * pow(2, Double(boundedAttempt))
            transportQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if case .start? = performSendReplayingConcealmentIfNeeded(request: .start) {
                    recoveryScheduled.withLock { $0 = false }
                    logger.notice("Compatibility service recovered after interruption")
                } else if boundedAttempt < 3 {
                    performRecoveryAttempt(boundedAttempt + 1)
                } else {
                    recoveryScheduled.withLock { $0 = false }
                    logger.error("Compatibility service recovery attempts were exhausted")
                }
            }
        }
    }
}
