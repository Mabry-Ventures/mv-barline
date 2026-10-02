//
//  GoldenGatePlatformPresenceObserver.swift
//  Barline
//

@preconcurrency import AppKit
import ApplicationServices
import Darwin
import Foundation

/// A live, closed AX scope, not yet an item exception. The provider must bind
/// this capture to its helper receipt, scene and actual inventory contribution.
/// No AX handles cross the observer's actor, and no serialized bytes can obtain
/// this privately constructed type.
struct GoldenGateNativeScopeCapture: Equatable, Sendable {
    let scanID: UUID
    let startedAtUptimeNanoseconds: UInt64
    let completedAtUptimeNanoseconds: UInt64
    let publisher: GoldenGateTrustedPublisher
    let scope: AXNativeClosedScope
    let nodes: [AXNativeScopeNode]

    fileprivate init(
        scanID: UUID,
        started: UInt64,
        completed: UInt64,
        publisher: GoldenGateTrustedPublisher,
        scope: AXNativeClosedScope,
        nodes: [AXNativeScopeNode]
    ) {
        self.scanID = scanID
        startedAtUptimeNanoseconds = started
        completedAtUptimeNanoseconds = completed
        self.publisher = publisher
        self.scope = scope
        self.nodes = nodes
    }
}

enum GoldenGateNativeScopeFailure: Equatable, Sendable {
    case unqualifiedLane, publisherUnavailable, extrasUnavailable, membershipChanged
    case cancelled, deadlineExceeded, publisherChanged
    case tree(AXNativeScopeFailure)
    case read(AXReadFailure)
}

enum GoldenGateNativeScopeObservation: Equatable, Sendable {
    case captured(GoldenGateNativeScopeCapture)
    case unknown(GoldenGateNativeScopeFailure)
}

actor GoldenGatePlatformPresenceObserver {
    private struct LocalNode {
        let token: UInt32
        let element: AXUIElement
        let before: AXNativeScopeNodeRead
    }

    private enum NodeKind { case extras, wrapper, leaf }
    private struct ScanFailure: Error {
        let reason: GoldenGateNativeScopeFailure
    }

    /// Golden Gate changed native Focus assessment behavior. On macOS 27 and
    /// later, an unqualified/unknown scan cannot be treated as an ordinary
    /// complete inventory. Earlier supported systems keep their legacy scan.
    static var requiresQualifiedPresenceContract: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    /// Synchronous body on this actor: no handle can outlive the scan through
    /// an await. Origin cancellation must revoke the supplied token directly,
    /// not enqueue another message to this actor. Native IPC is not preemptible;
    /// admission and publication are bounded, and every late result is unknown.
    func capture(scanID: UUID, deadline: UInt64, cancellation: AXReadCancellation) -> GoldenGateNativeScopeObservation {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try requireAdmission(deadline: deadline, cancellation: cancellation)
            guard Self.isQualifiedLane() else { return .unknown(.unqualifiedLane) }
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: RuntimePublisherAttestationSupport.menuAgentBundleIdentifier
            )
            guard applications.count == 1, let pid = applications.first?.processIdentifier,
                  let publisher = GoldenGateRuntimePublisherVerifier.menuAgent(
                      processIdentifier: pid, deadline: deadline, cancellation: cancellation
                  ) else { return .unknown(.publisherUnavailable) }
            let reader = AXBoundedNodeReader(deadline: deadline, cancellation: cancellation)
            let application = AXUIElementCreateApplication(pid)
            guard reader.processIdentifier(on: application) == .value(pid) else {
                return .unknown(.extrasUnavailable)
            }
            guard case let .element(extras) = reader.extras(on: application) else { return .unknown(.extrasUnavailable) }
            var handles = [extras]
            var records: [LocalNode] = []

            func tokens(for elements: [AXUIElement], register: Bool) throws -> [UInt32] {
                try requireAdmission(deadline: deadline, cancellation: cancellation)
                var result: [UInt32] = []
                for element in elements {
                    if let index = handles.firstIndex(where: { CFEqual($0, element) }) {
                        guard !register else { throw ScanFailure(reason: .tree(.duplicateNode)) }
                        result.append(UInt32(index + 1))
                    } else {
                        guard register else { throw ScanFailure(reason: .membershipChanged) }
                        guard handles.count < AXNativeScopeValidationSupport.maximumNodeCount else {
                            throw ScanFailure(reason: .tree(.nodeLimit))
                        }
                        handles.append(element)
                        result.append(UInt32(handles.count))
                    }
                }
                return result
            }
            func read(_ node: AXUIElement, kind: NodeKind, register: Bool, maximum: Int) throws -> AXNativeScopeNodeRead {
                try requireAdmission(deadline: deadline, cancellation: cancellation)
                let owner = reader.processIdentifier(on: node)
                guard owner == .value(pid) else { throw ScanFailure(reason: .tree(.readUnknown)) }
                let identity = reader.identity(on: node)
                guard case .attributes = identity else { throw ScanFailure(reason: .tree(.readUnknown)) }
                let geometry: AXGeometryRead? = kind == .leaf ? reader.geometry(on: node) : nil
                if kind == .leaf, case .bounds = geometry {} else if kind == .leaf {
                    throw ScanFailure(reason: .tree(.unusableGeometry))
                }
                let membership: AXNativeScopeMembership
                switch reader.children(on: node, maximumCount: maximum) {
                case let .elements(children):
                    if kind == .leaf, !children.isEmpty {
                        throw ScanFailure(reason: .tree(.openFrontier))
                    }
                    membership = try .elements(tokens(for: children, register: register))
                case .noValue: throw ScanFailure(reason: .tree(.openFrontier))
                case .unsupported: throw ScanFailure(reason: .tree(.openFrontier))
                case let .failure(error): throw ScanFailure(reason: .read(error))
                }
                guard reader.processIdentifier(on: node) == owner else { throw ScanFailure(reason: .tree(.changedNode)) }
                try requireAdmission(deadline: deadline, cancellation: cancellation)
                return AXNativeScopeNodeRead(identity: identity, owner: owner, geometry: geometry, children: membership)
            }

            let extraRead = try read(extras, kind: .extras, register: true, maximum: 64)
            records.append(LocalNode(token: 1, element: extras, before: extraRead))
            guard case let .elements(rootTokens) = extraRead.children else { return .unknown(.tree(.readUnknown)) }
            for token in rootTokens {
                let root = handles[Int(token) - 1]
                let remaining = min(64, AXNativeScopeValidationSupport.maximumNodeCount - handles.count)
                let rootRead = try read(root, kind: .wrapper, register: true, maximum: remaining)
                records.append(LocalNode(token: token, element: root, before: rootRead))
                guard case let .elements(leafTokens) = rootRead.children else { return .unknown(.tree(.readUnknown)) }
                for leafToken in leafTokens {
                    let leaf = handles[Int(leafToken) - 1]
                    let remaining = min(64, AXNativeScopeValidationSupport.maximumNodeCount - handles.count)
                    let leafRead = try read(leaf, kind: .leaf, register: true, maximum: remaining)
                    records.append(LocalNode(token: leafToken, element: leaf, before: leafRead))
                }
            }
            var nodes: [AXNativeScopeNode] = []
            for record in records {
                let kind: NodeKind = record.token == 1 ? .extras : record.before.geometry == nil ? .wrapper : .leaf
                guard case let .elements(originalChildren) = record.before.children else { return .unknown(.tree(.readUnknown)) }
                // A count beyond the original membership fails before copying.
                // Empty leaf closure permits one counted item but never admits it.
                let after = try read(record.element, kind: kind, register: false, maximum: max(1, originalChildren.count))
                nodes.append(AXNativeScopeNode(token: record.token, before: record.before, after: after))
            }
            // Reacquire the current extras attribute from the application.
            // Re-reading an old, still-responsive extras handle alone cannot
            // prove that it remains the application's live menu-bar tree.
            try requireAdmission(deadline: deadline, cancellation: cancellation)
            guard reader.processIdentifier(on: application) == .value(pid),
                  case let .element(currentExtras) = reader.extras(on: application),
                  CFEqual(extras, currentExtras),
                  reader.processIdentifier(on: application) == .value(pid)
            else { return .unknown(.membershipChanged) }
            let scope: AXNativeClosedScope
            switch AXNativeScopeValidationSupport.validate(extrasToken: 1, nodes: nodes, ownerPID: pid) {
            case let .closed(closed): scope = closed
            case let .unknown(reason): return .unknown(.tree(reason))
            }
            guard GoldenGateRuntimePublisherVerifier.unchanged(publisher, deadline: deadline, cancellation: cancellation) else {
                return .unknown(.publisherChanged)
            }
            try requireAdmission(deadline: deadline, cancellation: cancellation)
            let completed = DispatchTime.now().uptimeNanoseconds
            guard completed < deadline, !cancellation.isCancelled, !Task.isCancelled else { return .unknown(.deadlineExceeded) }
            return .captured(GoldenGateNativeScopeCapture(
                scanID: scanID,
                started: started,
                completed: completed,
                publisher: publisher,
                scope: scope,
                nodes: nodes
            ))
        } catch let error as ScanFailure {
            return .unknown(error.reason)
        } catch {
            return .unknown(.tree(.readUnknown))
        }
    }

    private func requireAdmission(deadline: UInt64, cancellation: AXReadCancellation) throws {
        guard !Task.isCancelled, !cancellation.isCancelled else { throw ScanFailure(reason: .cancelled) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ScanFailure(reason: .deadlineExceeded) }
    }

    private static func isQualifiedLane() -> Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion == 27, version.minorVersion == 0, version.patchVersion == 1 else { return false }
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 1, length <= 64 else { return false }
        var bytes = [UInt8](repeating: 0, count: length)
        let result = bytes.withUnsafeMutableBytes { sysctlbyname("kern.osversion", $0.baseAddress, &length, nil, 0) }
        guard result == 0, length > 1, length <= bytes.count, bytes[length - 1] == 0 else { return false }
        return String(bytes: bytes.prefix(length - 1), encoding: .utf8) == "26A434"
    }
}
