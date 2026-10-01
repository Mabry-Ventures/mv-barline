import Foundation

/// Runtime facts are not proof. Only the Security adapter can construct its
/// trusted witness after live checks; persisted bytes never acquire that type.
struct RuntimePublisherFacts: Equatable, Sendable {
    let requestedPID: Int32
    let kernelPID: UInt32
    let kernelBytesRead: Int32
    let expectedKernelBytes: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let applicationCount: Int
    let applicationPID: Int32
    let bundleIdentifier: String?
    let isTerminated: Bool
    let sealedSigningIdentifier: String?
    let uniqueCodeIdentity: [UInt8]?
    let fixedAppleRequirementStatus: Int32
}

struct RuntimePublisherSigningFacts: Equatable, Sendable {
    let sealedIdentifier: String
    let uniqueIdentity: [UInt8]
}

enum RuntimePublisherAttestationSupport {
    // Qualified only as a publisher identity on 27.0.1/26A434. This does not
    // qualify a Focus AX tuple or a platform-presence exception.
    static let menuAgentBundleIdentifier = "com.apple.MenuBarAgent"
    static let menuAgentSealedIdentifier = "com.apple.MenuBarAgent"
    static let menuAgentRequirement = #"anchor apple and identifier "com.apple.MenuBarAgent""#

    static func acceptsMenuAgentFacts(_ facts: RuntimePublisherFacts) -> Bool {
        guard acceptsMenuAgentProcessFacts(facts),
              facts.fixedAppleRequirementStatus == 0,
              facts.sealedSigningIdentifier == menuAgentSealedIdentifier,
              let digest = facts.uniqueCodeIdentity,
              (16 ... 64).contains(digest.count) else { return false }
        return true
    }

    private static func acceptsMenuAgentProcessFacts(_ facts: RuntimePublisherFacts) -> Bool {
        guard facts.requestedPID > 0,
              facts.kernelPID == UInt32(facts.requestedPID),
              facts.expectedKernelBytes > 0,
              facts.kernelBytesRead == facts.expectedKernelBytes,
              facts.startSeconds > 0, facts.startMicroseconds < 1_000_000,
              facts.applicationCount == 1,
              facts.applicationPID == facts.requestedPID,
              facts.bundleIdentifier == menuAgentBundleIdentifier,
              !facts.isTerminated else { return false }
        return true
    }

    static func decodeSigningFacts(identifier: CFTypeRef?, uniqueIdentity: CFTypeRef?) -> RuntimePublisherSigningFacts? {
        guard let identifier, CFGetTypeID(identifier) == CFStringGetTypeID() else { return nil }
        let raw = unsafeDowncast(identifier, to: CFString.self)
        guard CFStringGetLength(raw) <= 128, let string = identifier as? String,
              string == menuAgentSealedIdentifier,
              let uniqueIdentity, CFGetTypeID(uniqueIdentity) == CFDataGetTypeID() else { return nil }
        let rawData = unsafeDowncast(uniqueIdentity, to: CFData.self)
        let count = CFDataGetLength(rawData)
        // This is a conservative application bound, not an SDK size promise.
        guard (16 ... 64).contains(count), let pointer = CFDataGetBytePtr(rawData) else { return nil }
        return RuntimePublisherSigningFacts(sealedIdentifier: string, uniqueIdentity: Array(UnsafeBufferPointer(start: pointer, count: count)))
    }

    /// Pure orchestration used by the actual adapter. Caller-supplied facts
    /// here are testable inputs, not an externally constructible trusted type.
    static func attestMenuAgent<Code>(
        admitted: () -> Bool,
        readProcess: () -> RuntimePublisherFacts?,
        copyCode: () -> Code?,
        validateCode: (Code) -> Int32,
        readSigning: (Code) -> RuntimePublisherSigningFacts?
    ) -> RuntimePublisherFacts? {
        guard admitted(), let before = readProcess(), acceptsMenuAgentProcessFacts(before), admitted(),
              let code = copyCode(), admitted(), validateCode(code) == 0, admitted(),
              let signing = readSigning(code), admitted(),
              let after = readProcess(), acceptsMenuAgentProcessFacts(after),
              sameProcessLifetime(before, after), admitted(),
              validateCode(code) == 0, admitted(),
              let final = readProcess(), acceptsMenuAgentProcessFacts(final),
              sameProcessLifetime(before, final), admitted() else { return nil }
        let facts = RuntimePublisherFacts(
            requestedPID: final.requestedPID, kernelPID: final.kernelPID,
            kernelBytesRead: final.kernelBytesRead, expectedKernelBytes: final.expectedKernelBytes,
            startSeconds: final.startSeconds, startMicroseconds: final.startMicroseconds,
            applicationCount: final.applicationCount, applicationPID: final.applicationPID,
            bundleIdentifier: final.bundleIdentifier, isTerminated: final.isTerminated,
            sealedSigningIdentifier: signing.sealedIdentifier, uniqueCodeIdentity: signing.uniqueIdentity,
            fixedAppleRequirementStatus: 0
        )
        return acceptsMenuAgentFacts(facts) ? facts : nil
    }

    private static func sameProcessLifetime(_ first: RuntimePublisherFacts, _ second: RuntimePublisherFacts) -> Bool {
        first.requestedPID == second.requestedPID && first.startSeconds == second.startSeconds &&
            first.startMicroseconds == second.startMicroseconds
    }

    static func sameMenuAgentLifetimeAndCode(before: RuntimePublisherFacts, after: RuntimePublisherFacts) -> Bool {
        acceptsMenuAgentFacts(before) && acceptsMenuAgentFacts(after) &&
            before.requestedPID == after.requestedPID &&
            before.startSeconds == after.startSeconds &&
            before.startMicroseconds == after.startMicroseconds &&
            before.uniqueCodeIdentity == after.uniqueCodeIdentity
    }
}
