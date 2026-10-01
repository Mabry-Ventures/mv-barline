//
//  GoldenGateRuntimePublisherVerifier.swift
//  Barline
//

@preconcurrency import AppKit
import Darwin
import Foundation
import Security

/// No Codable conformance or externally constructible memberwise initializer.
/// The AX publisher and re-vending AX owner must each obtain a live witness.
struct GoldenGateTrustedPublisher: Equatable, Sendable {
    let facts: RuntimePublisherFacts

    fileprivate init(facts: RuntimePublisherFacts) {
        self.facts = facts
    }
}

enum GoldenGateRuntimePublisherVerifier {
    private static func admitted(deadline: UInt64, cancellation: AXReadCancellation) -> Bool {
        !cancellation.isCancelled && DispatchTime.now().uptimeNanoseconds < deadline
    }

    /// Dynamic signature validation is synchronous, not preemptible. Bound
    /// admission/publication, reject late results, and never claim an IPC hard
    /// timeout. This method performs no AX reads, input or filesystem access.
    static func menuAgent(
        processIdentifier: pid_t, deadline: UInt64, cancellation: AXReadCancellation
    ) -> GoldenGateTrustedPublisher? {
        guard processIdentifier > 0, admitted(deadline: deadline, cancellation: cancellation) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            RuntimePublisherAttestationSupport.menuAgentRequirement as CFString, [], &requirement
        ) == errSecSuccess, let requirement,
                                admitted(deadline: deadline, cancellation: cancellation) else { return nil }
        // The fixed requirement is not derived from untrusted metadata, and
        // anchor apple generic is deliberately not an equivalent substitute.
        let facts = RuntimePublisherAttestationSupport.attestMenuAgent(
            admitted: { admitted(deadline: deadline, cancellation: cancellation) },
            readProcess: { processFacts(processIdentifier) },
            copyCode: {
                var code: SecCode?
                guard SecCodeCopyGuestWithAttributes(
                    nil, [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary, [], &code
                ) == errSecSuccess else { return nil }
                return code
            },
            validateCode: { SecCodeCheckValidity($0, [], requirement) },
            readSigning: { code in
                var staticCode: SecStaticCode?
                guard admitted(deadline: deadline, cancellation: cancellation),
                      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                      admitted(deadline: deadline, cancellation: cancellation) else { return nil }
                var information: CFDictionary?
                guard SecCodeCopySigningInformation(
                    staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
                ) == errSecSuccess, let information,
                                        admitted(deadline: deadline, cancellation: cancellation) else { return nil }
                let values = information as NSDictionary
                return RuntimePublisherAttestationSupport.decodeSigningFacts(
                    identifier: values[kSecCodeInfoIdentifier] as CFTypeRef?,
                    uniqueIdentity: values[kSecCodeInfoUnique] as CFTypeRef?
                )
            }
        )
        guard let facts else { return nil }
        return GoldenGateTrustedPublisher(facts: facts)
    }

    static func unchanged(_ before: GoldenGateTrustedPublisher, deadline: UInt64, cancellation: AXReadCancellation) -> Bool {
        guard let after = menuAgent(processIdentifier: before.facts.requestedPID, deadline: deadline, cancellation: cancellation) else {
            return false
        }
        return RuntimePublisherAttestationSupport.sameMenuAgentLifetimeAndCode(before: before.facts, after: after.facts)
    }

    private struct KernelIdentity: Equatable {
        let pid: UInt32
        let bytesRead: Int32
        let seconds: UInt64
        let microseconds: UInt64
    }

    private static func processFacts(_ pid: pid_t) -> RuntimePublisherFacts? {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: RuntimePublisherAttestationSupport.menuAgentBundleIdentifier
        )
        guard applications.count == 1, let app = applications.first,
              let kernel = kernelIdentity(pid) else { return nil }
        return RuntimePublisherFacts(
            requestedPID: pid,
            kernelPID: kernel.pid,
            kernelBytesRead: kernel.bytesRead,
            expectedKernelBytes: Int32(MemoryLayout<proc_bsdinfo>.size),
            startSeconds: kernel.seconds,
            startMicroseconds: kernel.microseconds,
            applicationCount: applications.count,
            applicationPID: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            isTerminated: app.isTerminated,
            sealedSigningIdentifier: nil,
            uniqueCodeIdentity: nil,
            fixedAppleRequirementStatus: -1
        )
    }

    private static func kernelIdentity(_ pid: pid_t) -> KernelIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let received = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, expected) }
        guard received == expected, info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        return KernelIdentity(pid: info.pbi_pid, bytesRead: received, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}
