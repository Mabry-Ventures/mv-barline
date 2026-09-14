//
//  Listener.swift
//  BarlineMenuService
//

import BarlineCore
import Darwin
import Foundation
import OSLog
import Security
import XPC

/// A wrapper around an XPC listener object.
final class Listener: @unchecked Sendable {
    /// The shared listener.
    static let shared = Listener()

    /// The service name.
    private let name = BarlineMenuService.name

    /// The underlying XPC listener object.
    private var listener: XPCListener?

    /// Probe-selected compatibility backend. Construct it only after the
    /// lightweight start handshake so backend capability probes cannot make
    /// the containing app mistake service startup for a dead connection.
    private lazy var backend: any MenuBarBackend = MenuBarBackendFactory.make()

    /// Returns a strict peer requirement for the containing Barline app.
    /// Certificate-signed builds require the same team and exact app signing
    /// identifier. Local gates use ad-hoc signing, so they require the exact app
    /// signing identifier and the local/ad-hoc validation category.
    @available(macOS 26.0, *)
    private static func appPeerRequirement() -> XPCPeerRequirement {
        let signingIdentifier = BarlineMenuService.requiredIdentity(
            forInfoKey: "BarlineAppSigningIdentifier"
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

    /// Creates the shared listener.
    private init() {}

    deinit {
        cancel()
    }

    /// Handles a received message.
    private func handleMessage(
        _ message: XPCReceivedMessage,
        sessionCancellation: SessionCancellation
    ) -> BarlineMenuService.Response? {
        do {
            let request = try message.decode(as: BarlineMenuService.Request.self)
            switch request {
            case .start:
                Logger.default.debug("Listener received start request")
                return .start
            case .capabilities:
                guard let capabilities = AsyncRequestBridge.run({ await self.backend.capabilities }) else {
                    return .capabilities(.failure(.timedOut))
                }
                return .capabilities(.success(capabilities))
            case .snapshot:
                let result: BarlineMenuService.ServiceResult<MenuBarSnapshot>? = AsyncRequestBridge.run {
                    do {
                        return try await .success(self.backend.snapshot())
                    } catch let error as MenuBarBackendError {
                        return .failure(error)
                    } catch {
                        return .failure(.operationFailed(error.localizedDescription))
                    }
                }
                return .snapshot(result ?? .failure(.timedOut))
            case let .move(operation, deadlineUptimeNanoseconds: deadline):
                return .mutation(runMutation(
                    deadlineUptimeNanoseconds: deadline,
                    sessionCancellation: sessionCancellation
                ) {
                    try await self.backend.move(operation)
                })
            case let .reveal(item, deadlineUptimeNanoseconds: deadline):
                return .mutation(runMutation(
                    deadlineUptimeNanoseconds: deadline,
                    sessionCancellation: sessionCancellation
                ) {
                    try await self.backend.reveal(item)
                })
            case let .activate(
                item: item,
                button: button,
                deadlineUptimeNanoseconds: deadline
            ):
                let result: BarlineMenuService.ServiceResult<BarlineMenuService.EmptyResult>? =
                    runOperation(
                        deadlineUptimeNanoseconds: deadline,
                        sessionCancellation: sessionCancellation
                    ) {
                        do {
                            try await self.backend.activate(item, button: button)
                            return .success(BarlineMenuService.EmptyResult())
                        } catch let error as MenuBarBackendError {
                            return .failure(error)
                        } catch {
                            return .failure(.operationFailed(error.localizedDescription))
                        }
                    }
                return .activation(result ?? .failure(.timedOut))
            case let .capture(items):
                let result: BarlineMenuService.ServiceResult<[MenuBarCapturedImage]>? =
                    AsyncRequestBridge.run {
                        do {
                            return try await .success(self.backend.capture(items))
                        } catch let error as MenuBarBackendError {
                            return .failure(error)
                        } catch {
                            return .failure(.operationFailed(error.localizedDescription))
                        }
                    }
                return .capturedImages(result ?? .failure(.timedOut))
            case let .captureBackground(displayID, sampleHeight):
                let result: BarlineMenuService.ServiceResult<MenuBarBackgroundCapture>? =
                    AsyncRequestBridge.run {
                        do {
                            return try await .success(
                                self.backend.captureBackground(
                                    displayID: displayID,
                                    sampleHeight: sampleHeight
                                )
                            )
                        } catch let error as MenuBarBackendError {
                            return .failure(error)
                        } catch {
                            return .failure(.operationFailed(error.localizedDescription))
                        }
                    }
                return .background(result ?? .failure(.timedOut))
            case .environment:
                let result: BarlineMenuService.ServiceResult<MenuBarEnvironmentSnapshot>? =
                    AsyncRequestBridge.run {
                        do {
                            return try await .success(self.backend.environment())
                        } catch let error as MenuBarBackendError {
                            return .failure(error)
                        } catch {
                            return .failure(.operationFailed(error.localizedDescription))
                        }
                    }
                return .environment(result ?? .failure(.timedOut))
            case let .configureCursorInBackground(enabled):
                Bridging.setConnectionProperty(enabled, forKey: "SetsCursorInBackground")
                return .start
            case let .configureConcealment(configuration):
                let result: BarlineMenuService.ServiceResult<BarlineMenuService.EmptyResult>? =
                    AsyncRequestBridge.run {
                        do {
                            try await self.backend.configureConcealment(configuration)
                            return .success(BarlineMenuService.EmptyResult())
                        } catch let error as MenuBarBackendError {
                            return .failure(error)
                        } catch {
                            return .failure(.operationFailed(error.localizedDescription))
                        }
                    }
                return .activation(result ?? .failure(.timedOut))
            case let .pointContext(point):
                let result: BarlineMenuService.ServiceResult<MenuBarPointContext>? =
                    AsyncRequestBridge.run {
                        do {
                            return try await .success(self.backend.pointContext(point))
                        } catch let error as MenuBarBackendError {
                            return .failure(error)
                        } catch {
                            return .failure(.operationFailed(error.localizedDescription))
                        }
                    }
                return .pointContext(result ?? .failure(.timedOut))
            case let .shelfPresentationObservation(probe):
                return .shelfPresentationObservation(
                    .success(WindowServerClient.shelfPresentationObservation(probe))
                )
            case let .beginRevealObservation(item):
                let result: BarlineMenuService.ServiceResult<MenuBarRevealObservationToken>? =
                    AsyncRequestBridge.run {
                        do {
                            return try await .success(self.backend.beginRevealObservation(item))
                        } catch let error as MenuBarBackendError {
                            return .failure(error)
                        } catch {
                            return .failure(.operationFailed(error.localizedDescription))
                        }
                    }
                return .revealObservation(result ?? .failure(.timedOut))
            case let .revealObservationIsVisible(token):
                let result: BarlineMenuService.ServiceResult<Bool>? = AsyncRequestBridge.run {
                    do {
                        return try await .success(self.backend.revealObservationIsVisible(token))
                    } catch let error as MenuBarBackendError {
                        return .failure(error)
                    } catch {
                        return .failure(.operationFailed(error.localizedDescription))
                    }
                }
                return .boolean(result ?? .failure(.timedOut))
            case let .endRevealObservation(token):
                _ = AsyncRequestBridge.run { await self.backend.endRevealObservation(token) }
                return .start
            case let .restore(snapshot, deadlineUptimeNanoseconds: deadline):
                return .mutation(runMutation(
                    deadlineUptimeNanoseconds: deadline,
                    sessionCancellation: sessionCancellation
                ) {
                    try await self.backend.restore(snapshot)
                })
            case .health:
                let health = AsyncRequestBridge.run { await self.backend.health() } ?? MenuBarBackendHealth(
                    backendName: "XPC",
                    state: .unavailable,
                    message: "Compatibility request timed out"
                )
                return .health(health)
            case .restart:
                _ = AsyncRequestBridge.run { await self.backend.restart() }
                return .restart
            }
        } catch {
            Logger.default.error("Listener failed to handle message with error \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
            return nil
        }
    }

    private func runMutation(
        deadlineUptimeNanoseconds: UInt64,
        sessionCancellation: SessionCancellation,
        _ operation: @escaping @Sendable () async throws -> MenuBarMutationResult
    ) -> BarlineMenuService.ServiceResult<MenuBarMutationResult> {
        runOperation(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            sessionCancellation: sessionCancellation
        ) {
            do {
                return try await .success(operation())
            } catch let error as MenuBarBackendError {
                return .failure(error)
            } catch {
                return .failure(.operationFailed(error.localizedDescription))
            }
        } ?? .failure(.timedOut)
    }

    private func runOperation<Value: Sendable>(
        deadlineUptimeNanoseconds: UInt64,
        sessionCancellation: SessionCancellation,
        _ operation: @escaping @Sendable () async -> Value
    ) -> Value? {
        let now = DispatchTime.now().uptimeNanoseconds
        let maximumBudgetNanoseconds: UInt64 = 4_000_000_000
        let (maximumDeadline, overflowed) = now.addingReportingOverflow(
            maximumBudgetNanoseconds
        )
        let boundedMaximumDeadline = overflowed ? UInt64.max : maximumDeadline
        let effectiveDeadline = min(
            deadlineUptimeNanoseconds,
            boundedMaximumDeadline
        )
        guard effectiveDeadline > now else { return nil }
        return AsyncRequestBridge.run(
            deadlineUptimeNanoseconds: effectiveDeadline,
            sessionCancellation: sessionCancellation,
            operation
        )
    }

    /// Activates the listener without checking if it is already active, using
    /// the strict certificate-signed or local ad-hoc peer requirement.
    @available(macOS 26.0, *)
    private func uncheckedActivateWithPeerRequirement() throws {
        listener = try XPCListener(service: name, requirement: Self.appPeerRequirement()) { request in
            let sessionCancellation = SessionCancellation()
            return request.accept { message in
                self.handleMessage(message, sessionCancellation: sessionCancellation)
            } cancellationHandler: { _ in
                sessionCancellation.cancelAll()
            }
        }
    }

    /// Activates the listener without checking if it is already active.
    private func uncheckedActivate() throws {
        listener = try XPCListener(service: name) { request in
            let sessionCancellation = SessionCancellation()
            return request.accept { message in
                self.handleMessage(message, sessionCancellation: sessionCancellation)
            } cancellationHandler: { _ in
                sessionCancellation.cancelAll()
            }
        }
    }

    /// Activates the listener.
    func activate() {
        guard listener == nil else {
            Logger.default.notice("Listener is already active")
            return
        }

        Logger.default.debug("Activating listener")

        do {
            if #available(macOS 26.0, *) {
                try uncheckedActivateWithPeerRequirement()
            } else {
                try uncheckedActivate()
            }
        } catch {
            Logger.default.error("Failed to activate listener with error \(PrivacySafeDiagnostics.errorCode(error), privacy: .public)")
        }
    }

    /// Cancels the listener.
    func cancel() {
        Logger.default.debug("Canceling listener")
        listener.take()?.cancel()
    }
}

private final class SessionCancellation: @unchecked Sendable {
    private struct ActiveOperation: Sendable {
        let task: Task<Void, Never>
        let completion: DispatchGroup
    }

    private struct State: Sendable {
        var isCancelled = false
        var activeOperations = [UUID: ActiveOperation]()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(
        _ task: Task<Void, Never>,
        completion: DispatchGroup,
        token: UUID
    ) -> Bool {
        state.withLock { state in
            guard !state.isCancelled else { return false }
            state.activeOperations[token] = ActiveOperation(task: task, completion: completion)
            return true
        }
    }

    func remove(token: UUID) {
        state.withLock { $0.activeOperations[token] = nil }
    }

    func cancelAll() {
        let operations = state.withLock { state in
            state.isCancelled = true
            return Array(state.activeOperations.values)
        }
        let deadline = DispatchTime.now() + AsyncRequestBridge.cancellationGrace
        for operation in operations {
            operation.task.cancel()
        }
        for operation in operations where operation.completion.wait(timeout: deadline) != .success {
            AsyncRequestBridge.failStop()
        }
    }
}

private enum AsyncRequestBridge {
    static let cancellationGrace: TimeInterval = 0.5

    static func run<Value: Sendable>(
        timeout: TimeInterval = 5,
        deadlineUptimeNanoseconds: UInt64? = nil,
        sessionCancellation: SessionCancellation? = nil,
        _ operation: @escaping @Sendable () async -> Value
    ) -> Value? {
        let completion = DispatchGroup()
        completion.enter()
        let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
        let (startGate, startGateContinuation) = AsyncStream<Void>.makeStream()
        let task = Task.detached {
            defer { completion.leave() }
            for await _ in startGate {
                guard !Task.isCancelled else { return }
                let resolved = await operation()
                result.withLock { $0 = resolved }
                return
            }
        }
        let token = UUID()
        if let sessionCancellation,
           !sessionCancellation.register(task, completion: completion, token: token)
        {
            task.cancel()
            startGateContinuation.yield()
            startGateContinuation.finish()
            guard completion.wait(timeout: .now() + cancellationGrace) == .success else {
                failStop()
            }
            return nil
        }
        startGateContinuation.yield()
        startGateContinuation.finish()
        defer { sessionCancellation?.remove(token: token) }
        let deadline = deadlineUptimeNanoseconds.map(DispatchTime.init(uptimeNanoseconds:))
            ?? .now() + timeout
        guard completion.wait(timeout: deadline) == .success else {
            task.cancel()
            guard completion.wait(timeout: .now() + cancellationGrace) == .success else {
                failStop()
            }
            return nil
        }
        return result.withLock { $0.take() }
    }

    static func failStop() -> Never {
        Logger.default.fault(
            "Compatibility operation ignored cancellation; terminating helper"
        )
        Darwin._exit(70)
    }
}
