//
//  BarlineMenuServiceConnection.swift
//  Barline
//

import BarlineCore
import CoreGraphics
import Foundation
import OSLog
import Security
#if BARLINE_SESSION_TRANSPORT_TESTING
    import BarlineTestXPC

    typealias XPCSession = BarlineTestXPC.XPCSession
    typealias XPCDictionary = BarlineTestXPC.XPCDictionary
    typealias XPCPeerRequirement = BarlineTestXPC.XPCPeerRequirement
#else
    import XPC
#endif

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
            session = Session(logger: logger, requestQueue: queue)
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
                .configureConcealment(configuration, deadlineUptimeNanoseconds: mutationDeadline())
            ) else {
                throw MenuBarBackendError.interrupted
            }
            _ = try result.value()
        }

        /// A failed durable commit revokes the proposal's recovery authority
        /// even if restoring the prior native assertion also fails. Keep this
        /// ordered with all requests, before another recovery can replay it.
        func restoreConcealmentAfterRejectedPersistence(
            _ previous: MenuBarConcealmentConfiguration
        ) async throws {
            let request = Request.configureConcealment(previous, deadlineUptimeNanoseconds: mutationDeadline())
            let lease = session.makeLease(for: request)
            let response = await withCheckedContinuation { continuation in
                queue.async { [session] in
                    session.restoreAcceptedConcealmentForRecovery(previous)
                    continuation.resume(returning: session.send(request: request, lease: lease))
                }
            }
            guard case let .activation(result) = response else { throw MenuBarBackendError.interrupted }
            _ = try result.value()
        }

        func nativeDrag(
            _ transaction: MenuBarNativeDragTransaction
        ) async throws -> MenuBarNativeDragReceipt {
            guard case let .nativeDragReceipt(result) = await send(
                .nativeDrag(
                    transaction,
                    deadlineUptimeNanoseconds: mutationDeadline()
                )
            ) else {
                throw MenuBarBackendError.interrupted
            }
            return try result.value()
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

        /// See `MenuBarBackend.pressSystemClockIfConcealed(at:)`. The point is in
        /// WindowServer (top-left origin) coordinates.
        func pressSystemClockIfConcealed(
            at point: CGPoint,
            deadlineUptimeNanoseconds: UInt64,
            eventUptimeNanoseconds: UInt64,
            pointerStamp: MenuBarPointerEventStamp
        ) async throws -> Bool {
            guard case let .boolean(result) = await send(
                .pressSystemClockIfConcealed(
                    MenuBarPoint(x: point.x, y: point.y),
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                    eventUptimeNanoseconds: eventUptimeNanoseconds,
                    pointerStamp: pointerStamp
                )
            ) else {
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
            let lease = session.makeLease(for: request)
            return await withCheckedContinuation { continuation in
                queue.async { [session] in
                    continuation.resume(returning: session.send(request: request, lease: lease))
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
    final class Session: @unchecked Sendable {
        private struct State: @unchecked Sendable {
            var session: XPCSession?
            var generation: UInt64 = 0
            // Session allocation changes generation, not admission epoch.
            // Requests queued before a healthy allocation remain admissible.
            var admissionEpoch: UInt64 = 0
            var ready = false
            var initializationLock = NSLock()
        }

        private struct Recovery {
            var epoch: UInt64 = 0
            var scheduled = false
        }

        private let name: String
        private let peerRequirement: @Sendable () -> XPCPeerRequirement
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
        private let latestConcealmentConfiguration = OSAllocatedUnfairLock<MenuBarConcealmentConfiguration?>(initialState: nil)
        private let recovery = OSAllocatedUnfairLock(initialState: Recovery())
        private let requestQueue: DispatchQueue
        private let logger: Logger
        // Caller timeouts do not necessarily release a synchronous XPC worker.
        // Bound transport occupancy even if the OS fails to acknowledge cancel.
        private let outstandingWorkers = OSAllocatedUnfairLock(initialState: 0)
        private let readCompletionGrace: DispatchTimeInterval
        private static let maximumOutstandingWorkers = 8

        init(
            logger: Logger,
            requestQueue: DispatchQueue,
            serviceName: String? = nil,
            readCompletionGrace: DispatchTimeInterval = .seconds(6),
            peerRequirement: @escaping @Sendable () -> XPCPeerRequirement = {
                BarlineMenuService.Connection.servicePeerRequirement()
            }
        ) {
            self.logger = logger
            self.requestQueue = requestQueue
            self.readCompletionGrace = readCompletionGrace
            name = serviceName ?? BarlineMenuService.name
            self.peerRequirement = peerRequirement
        }

        deinit {
            cancel(reason: "Session deinitialized")
        }

        func cancel(reason: String) {
            let oldSession = state.withLock { state -> XPCSession? in
                state.generation &+= 1
                state.admissionEpoch &+= 1
                state.ready = false
                state.initializationLock = NSLock()
                recovery.withLock { value in
                    value.epoch &+= 1
                    value.scheduled = false
                }
                return state.session.take()
            }
            oldSession?.cancel(reason: reason)
        }

        /// Reads leave no native state behind when they run out of time.
        private static func isReadOnly(_ request: Request) -> Bool {
            switch request {
            case .capabilities, .snapshot, .health, .shelfPresentationObservation:
                true
            default:
                false
            }
        }

        /// Privacy-safe request label for diagnostics.
        private static func requestCode(_ request: Request) -> String {
            switch request {
            case .start: "start"
            case .capabilities: "capabilities"
            case .snapshot: "snapshot"
            case .health: "health"
            case .restart: "restart"
            case .shelfPresentationObservation: "shelf_presentation_observation"
            default: "mutation"
            }
        }

        func makeLease(for request: Request) -> MenuBarRequestLease {
            let budget: UInt64 = switch request {
            case .health, .restart: 1_000_000_000
            case .shelfPresentationObservation: 100_000_000
            default: 5_000_000_000
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let (deadline, overflowed) = now.addingReportingOverflow(budget)
            return MenuBarRequestLease(
                admittedEpoch: state.withLock { $0.admissionEpoch },
                deadline: overflowed ? .max : deadline
            )
        }

        /// Call on the owning serial request queue. The prior configuration
        /// was already accepted; the failed durable proposal must not survive
        /// as startup state if the following native rollback is interrupted.
        func restoreAcceptedConcealmentForRecovery(_ configuration: MenuBarConcealmentConfiguration) {
            latestConcealmentConfiguration.withLock { $0 = configuration }
        }

        /// A bounded fence for qualification of retired transport workers.
        /// Does not send messages or modify session/recovery state.
        func drainTransport(timeout: DispatchTime) -> Bool {
            let completion = DispatchSemaphore(value: 0)
            transportQueue.async(flags: .barrier) { completion.signal() }
            return completion.wait(timeout: timeout) == .success
        }

        func send(request: Request, lease: MenuBarRequestLease) -> Response? {
            guard lease.isLive(now: DispatchTime.now().uptimeNanoseconds) else { return nil }
            let admittedGeneration = state.withLock { value -> UInt64? in
                value.admissionEpoch == lease.admittedEpoch ? value.generation : nil
            }
            guard let admittedGeneration else { return nil }
            guard outstandingWorkers.withLock({ value in
                guard value < Self.maximumOutstandingWorkers else { return false }
                value += 1
                return true
            }) else {
                _ = lease.revoke()
                retire(generation: admittedGeneration, reason: "Transport worker limit", recover: true)
                return nil
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = OSAllocatedUnfairLock<Response?>(initialState: nil)
            let completed = OSAllocatedUnfairLock(initialState: false)
            transportQueue.async { [self] in
                let response = performSend(request: request, lease: lease)
                result.withLock { $0 = response }
                completed.withLock { $0 = true }
                outstandingWorkers.withLock { $0 -= 1 }
                semaphore.signal()
            }
            // A Mac with many menu bar items spends over a second building
            // one Accessibility inventory, so the reads that carry it cannot
            // share the one-second budget of the cheap lifecycle requests.
            // Under-waiting here reports the helper as incapable and cancels
            // concealment work that was about to succeed.
            guard semaphore.wait(timeout: DispatchTime(uptimeNanoseconds: lease.deadline)) == .success else {
                logger.error(
                    "Compatibility request timed out: \(Self.requestCode(request), privacy: .public)"
                )
                // A read that ran out of time leaves no partial native state,
                // so tearing down the session only interrupts unrelated work
                // that is still in flight. Only a mutation whose outcome is
                // unknown requires the session to be replaced.
                let generation = lease.revoke()
                if let generation, shouldRetireExpired(request, generation: generation) {
                    retire(generation: generation, reason: "Request timed out", recover: true)
                } else if let generation {
                    // Healthy slow reads may finish within the helper watchdog
                    // plus cancellation grace. Only an unfinished worker past
                    // that budget may retire its own session, never a successor.
                    callbackQueue.asyncAfter(deadline: .now() + readCompletionGrace) { [weak self] in
                        guard !completed.withLock({ $0 }) else { return }
                        self?.retire(generation: generation, reason: "Read worker did not finish", recover: true)
                    }
                }
                return nil
            }
            guard lease.isLive(now: DispatchTime.now().uptimeNanoseconds) else {
                let generation = lease.revoke()
                if let generation, shouldRetireExpired(request, generation: generation) {
                    retire(generation: generation, reason: "Request expired", recover: true)
                }
                return nil
            }
            let response = result.withLock { $0.take() }
            if case let .configureConcealment(configuration, _) = request,
               case .activation(.success) = response
            {
                // Recovery may only replay a configuration the helper
                // actually accepted. A rejected request must not become the
                // next process's startup state.
                latestConcealmentConfiguration.withLock { $0 = configuration }
            }
            return response
        }

        private func shouldRetireExpired(_ request: Request, generation: UInt64) -> Bool {
            if !Self.isReadOnly(request) {
                return true
            }
            // A cold read owns handshake/configuration replay while holding
            // the epoch's initialization lock. Retire that epoch on timeout,
            // otherwise a paused initializing read blocks every replacement.
            // Already-ready reads still preserve unrelated healthy work.
            return state.withLock { $0.generation == generation && !$0.ready }
        }

        private func performSend(request: Request, lease: MenuBarRequestLease) -> Response? {
            var capturedGeneration: UInt64?
            do {
                // Only initialization is locked. Expensive timed-out reads may
                // finish independently without blocking cheap observation work.
                let initializationLock = state.withLock { $0.initializationLock }
                initializationLock.lock()
                let session: XPCSession
                let generation: UInt64
                let handshake: Response?
                do {
                    (session, generation) = try getOrCreateSession(lease: lease)
                    capturedGeneration = generation
                    let isRestart = if case .restart = request {
                        true
                    } else {
                        false
                    }
                    if !isRestart, state.withLock({ !$0.ready }) {
                        let configuration = latestConcealmentConfiguration.withLock { $0 }
                        handshake = MenuBarRecoveryHandshake.run(
                            isCurrent: { self.isCurrent(lease: lease, generation: generation) },
                            handshake: { self.sendBound(.start, session: session, generation: generation, lease: lease) },
                            isHandshake: {
                                if case .start = $0 {
                                    return true
                                }
                                return false
                            },
                            replay: {
                                guard let configuration else { return true }
                                if case .activation(.success)? = self.sendBound(
                                    .configureConcealment(configuration, deadlineUptimeNanoseconds: lease.deadline),
                                    session: session,
                                    generation: generation,
                                    lease: lease
                                ) {
                                    return true
                                }
                                return false
                            }
                        )
                        guard handshake != nil else { throw MenuBarBackendError.interrupted }
                        state.withLock { value in
                            if value.generation == generation {
                                value.ready = true
                            }
                        }
                    } else {
                        handshake = nil
                    }
                    initializationLock.unlock()
                } catch {
                    initializationLock.unlock()
                    throw error
                }
                if case .start = request, let handshake {
                    return handshake
                }
                let response = sendBound(request, session: session, generation: generation, lease: lease)
                if case .restart = request {
                    // Restart clears the helper's assertion and desired state.
                    // Its acknowledgement is not a restored ready handshake.
                    state.withLock { value in
                        if value.generation == generation {
                            value.ready = false
                        }
                    }
                }
                return response
            } catch {
                logger.error("Session failed with error \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
                if let generation = capturedGeneration ?? lease.revoke() {
                    retire(generation: generation, reason: "Send failed", recover: true)
                }
                return nil
            }
        }

        private func isCurrent(lease: MenuBarRequestLease, generation: UInt64) -> Bool {
            lease.admits(generation: generation, now: DispatchTime.now().uptimeNanoseconds) &&
                state.withLock { $0.generation == generation && $0.session != nil }
        }

        private func sendBound(
            _ request: Request, session: XPCSession, generation: UInt64, lease: MenuBarRequestLease
        ) -> Response? {
            guard isCurrent(lease: lease, generation: generation) else { return nil }
            do {
                let response = try session.sendSync(request).decode(as: Response.self)
                return isCurrent(lease: lease, generation: generation) ? response : nil
            } catch {
                retire(generation: generation, reason: "Bound send failed", recover: true)
                return nil
            }
        }

        private func retire(generation: UInt64, reason: String, recover: Bool) {
            let retired = state.withLock { value -> (XPCSession, UInt64)? in
                guard value.generation == generation else { return nil }
                value.generation &+= 1
                value.admissionEpoch &+= 1
                value.ready = false
                value.initializationLock = NSLock()
                guard let session = value.session.take() else { return nil }
                return (session, value.admissionEpoch)
            }
            guard let retired else { return }
            retired.0.cancel(reason: reason)
            if recover {
                scheduleRecovery(admittedEpoch: retired.1)
            }
        }

        private func getOrCreateSession(lease: MenuBarRequestLease) throws -> (XPCSession, UInt64) {
            let allocation = state.withLock { state -> (XPCSession?, UInt64)? in
                guard lease.isLive(now: DispatchTime.now().uptimeNanoseconds),
                      state.admissionEpoch == lease.admittedEpoch
                else { return nil }
                if let existing = state.session {
                    return (existing, state.generation)
                }
                state.generation &+= 1
                state.ready = false
                return (nil, state.generation)
            }
            guard let (existing, generation) = allocation else { throw MenuBarBackendError.interrupted }
            guard lease.bind(generation: generation, now: DispatchTime.now().uptimeNanoseconds) else {
                throw MenuBarBackendError.timedOut
            }
            if let existing {
                return (existing, generation)
            }
            let session = try XPCSession(xpcService: name, options: .inactive) { [weak self] error in
                guard let self else { return }
                logger.warning("Session was cancelled with error \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
                let ownedEpoch = state.withLock { state -> UInt64? in
                    guard state.generation == generation else { return nil }
                    state.generation &+= 1
                    state.admissionEpoch &+= 1
                    state.session = nil
                    state.ready = false
                    state.initializationLock = NSLock()
                    return state.admissionEpoch
                }
                if let ownedEpoch {
                    scheduleRecovery(admittedEpoch: ownedEpoch)
                }
            }
            session.setPeerRequirement(peerRequirement())
            session.setTargetQueue(callbackQueue)
            try session.activate()
            let installed = state.withLock { state -> Bool in
                guard state.generation == generation, state.session == nil,
                      lease.admits(generation: generation, now: DispatchTime.now().uptimeNanoseconds)
                else {
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

        private func scheduleRecovery(admittedEpoch: UInt64) {
            // Retirement and its callback can race an explicit cancellation
            // before they enqueue recovery. Admit scheduling against the same
            // lifecycle epoch, with the same state -> recovery lock order as
            // cancel, so obsolete work cannot create a fresh retry afterward.
            let epoch = state.withLock { state -> UInt64? in
                guard state.admissionEpoch == admittedEpoch else { return nil }
                return recovery.withLock { value -> UInt64? in
                    guard !value.scheduled else { return nil }
                    value.scheduled = true
                    value.epoch &+= 1
                    return value.epoch
                }
            }
            guard let epoch else { return }
            performRecoveryAttempt(0, epoch: epoch)
        }

        private func performRecoveryAttempt(_ attempt: Int, epoch: UInt64) {
            let boundedAttempt = min(max(attempt, 0), 3)
            let delay = 0.1 * pow(2, Double(boundedAttempt))
            let lease = makeLease(for: .start)
            requestQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, recovery.withLock({ $0.scheduled && $0.epoch == epoch }) else { return }
                if case .start? = send(request: .start, lease: lease) {
                    recovery.withLock {
                        if $0.epoch == epoch {
                            $0.scheduled = false
                        }
                    }
                    logger.notice("Compatibility service recovered after interruption")
                } else if boundedAttempt < 3 {
                    performRecoveryAttempt(boundedAttempt + 1, epoch: epoch)
                } else {
                    recovery.withLock {
                        if $0.epoch == epoch {
                            $0.scheduled = false
                        }
                    }
                    logger.error("Compatibility service recovery attempts were exhausted")
                }
            }
        }
    }
}
