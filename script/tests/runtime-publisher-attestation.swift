import Foundation

@main
enum RuntimePublisherAttestationTests {
    static func facts(
        pid: Int32 = 1081, kernelPID: UInt32 = 1081, bytesRead: Int32 = 136, expectedBytes: Int32 = 136,
        seconds: UInt64 = 123, microseconds: UInt64 = 45, applicationCount: Int = 1, applicationPID: Int32 = 1081,
        bundle: String? = "com.apple.MenuBarAgent", terminated: Bool = false,
        sealed: String? = "com.apple.MenuBarAgent", digest: [UInt8]? = Array(repeating: 7, count: 32), status: Int32 = 0
    ) -> RuntimePublisherFacts {
        RuntimePublisherFacts(
            requestedPID: pid, kernelPID: kernelPID, kernelBytesRead: bytesRead, expectedKernelBytes: expectedBytes,
            startSeconds: seconds, startMicroseconds: microseconds, applicationCount: applicationCount,
            applicationPID: applicationPID, bundleIdentifier: bundle, isTerminated: terminated,
            sealedSigningIdentifier: sealed, uniqueCodeIdentity: digest, fixedAppleRequirementStatus: status
        )
    }

    static func main() {
        let baseline = facts()
        var checks = 0
        func expect(_ value: Bool, _ code: String) {
            guard value else { print("FAIL: \(code)"); exit(1) }
            checks += 1
        }
        expect(RuntimePublisherAttestationSupport.acceptsMenuAgentFacts(baseline), "exact_qualified_publisher_facts")
        let invalid = [
            facts(pid: 0), facts(pid: -1), facts(kernelPID: 1082), facts(bytesRead: 135), facts(expectedBytes: 0),
            facts(seconds: 0), facts(microseconds: 1_000_000), facts(applicationCount: 0), facts(applicationCount: 2),
            facts(applicationPID: 1082), facts(bundle: nil), facts(bundle: "com.apple.menubaragent"),
            facts(bundle: "com.apple.MenuBarAgent.fake"), facts(terminated: true), facts(sealed: nil),
            facts(sealed: "com.apple.controlcenter"), facts(sealed: "com.apple.MenuBarAgent.fake"),
            facts(digest: nil), facts(digest: []), facts(digest: Array(repeating: 7, count: 15)),
            facts(digest: Array(repeating: 7, count: 65)), facts(status: -67050),
        ]
        for (index, invalid) in invalid.enumerated() {
            expect(!RuntimePublisherAttestationSupport.acceptsMenuAgentFacts(invalid), "untrusted_facts_rejected_\(index)")
            expect(!RuntimePublisherAttestationSupport.sameMenuAgentLifetimeAndCode(before: baseline, after: invalid), "replaced_invalid_after_\(index)")
        }
        expect(RuntimePublisherAttestationSupport.sameMenuAgentLifetimeAndCode(before: baseline, after: baseline), "same_exact_lifetime_code")
        expect(!RuntimePublisherAttestationSupport.sameMenuAgentLifetimeAndCode(before: baseline, after: facts(seconds: 124)), "pid_reuse_seconds")
        expect(!RuntimePublisherAttestationSupport.sameMenuAgentLifetimeAndCode(before: baseline, after: facts(microseconds: 46)), "pid_reuse_microseconds")
        expect(!RuntimePublisherAttestationSupport.sameMenuAgentLifetimeAndCode(before: baseline, after: facts(digest: Array(repeating: 8, count: 32))),
               "same_pid_lifetime_different_executable")
        expect(!RuntimePublisherAttestationSupport.sameMenuAgentLifetimeAndCode(before: facts(status: -1), after: baseline), "untrusted_before")
        expect(RuntimePublisherAttestationSupport.menuAgentRequirement == #"anchor apple and identifier "com.apple.MenuBarAgent""#,
               "fixed_apple_requirement_not_generic_or_derived")
        let identifier = "com.apple.MenuBarAgent" as CFString
        let digest = Data(repeating: 7, count: 32) as CFData
        expect(RuntimePublisherAttestationSupport.decodeSigningFacts(identifier: identifier, uniqueIdentity: digest)
            == RuntimePublisherSigningFacts(sealedIdentifier: "com.apple.MenuBarAgent", uniqueIdentity: Array(repeating: 7, count: 32)),
            "typed_signing_metadata")
        let malformedIdentifiers: [CFTypeRef?] = [nil, kCFNull, NSNumber(value: 1), [] as CFArray,
                                                  "com.apple.menubaragent" as CFString, String(repeating: "a", count: 129) as CFString]
        for (index, raw) in malformedIdentifiers.enumerated() {
            expect(RuntimePublisherAttestationSupport.decodeSigningFacts(identifier: raw, uniqueIdentity: digest) == nil,
                   "malformed_or_wrong_sealed_identifier_\(index)")
        }
        let malformedDigests: [CFTypeRef?] = [nil, kCFNull, NSNumber(value: 1), "wrong" as CFString,
                                              Data() as CFData, Data(repeating: 7, count: 15) as CFData,
                                              Data(repeating: 7, count: 65) as CFData]
        for (index, raw) in malformedDigests.enumerated() {
            expect(RuntimePublisherAttestationSupport.decodeSigningFacts(identifier: identifier, uniqueIdentity: raw) == nil,
                   "malformed_or_unbounded_code_identity_\(index)")
        }
        func exercise(_ fault: String? = nil) -> (RuntimePublisherFacts?, [String]) {
            let code = UUID()
            var operations: [String] = []
            var processReads = 0
            var validations = 0
            var revoked = fault == "initial_cancel"
            let result = RuntimePublisherAttestationSupport.attestMenuAgent(
                admitted: { !revoked },
                readProcess: {
                    processReads += 1; operations.append("process\(processReads)")
                    if fault == "missing_process" {
                        return nil
                    }
                    if fault == "bad_before" {
                        return facts(bytesRead: 1)
                    }
                    if fault == "changed_after", processReads == 2 {
                        return facts(seconds: 124)
                    }
                    if fault == "changed_final", processReads == 3 {
                        return facts(microseconds: 46)
                    }
                    if fault == "cancel_after_process", processReads == 2 {
                        revoked = true
                    }
                    return baseline
                },
                copyCode: {
                    operations.append("copy_code")
                    if fault == "cancel_after_code" {
                        revoked = true
                    }
                    return fault == "missing_code" ? nil : code
                },
                validateCode: { observed in
                    expect(observed == code, "same_code_handle_for_validation")
                    validations += 1; operations.append("validate\(validations)")
                    if fault == "cancel_after_validation" {
                        revoked = true
                    }
                    if fault == "bad_validation\(validations)" {
                        return -67050
                    }
                    if fault == "late_final_validation", validations == 2 {
                        revoked = true
                    }
                    return 0
                },
                readSigning: { observed in
                    expect(observed == code, "same_validated_code_for_metadata")
                    operations.append("metadata")
                    if fault == "cancel_after_metadata" {
                        revoked = true
                    }
                    return fault == "missing_metadata" ? nil : RuntimePublisherAttestationSupport.decodeSigningFacts(
                        identifier: identifier, uniqueIdentity: digest
                    )
                }
            )
            return (result, operations)
        }
        let successful = exercise()
        expect(successful.0 == baseline && successful.1 == ["process1", "copy_code", "validate1", "metadata", "process2", "validate2", "process3"],
               "actual_adapter_orchestration_order")
        for fault in ["initial_cancel", "missing_process", "bad_before", "missing_code", "bad_validation1", "bad_validation2",
                      "missing_metadata", "changed_after", "changed_final", "cancel_after_process", "cancel_after_code",
                      "cancel_after_validation", "cancel_after_metadata", "late_final_validation"]
        {
            expect(exercise(fault).0 == nil, "orchestration_rejected_\(fault)")
        }
        expect(exercise("initial_cancel").1.isEmpty, "revoked_before_any_operation")
        expect(exercise("cancel_after_code").1 == ["process1", "copy_code"], "revoked_no_later_security_calls")
        expect(exercise("bad_validation1").1 == ["process1", "copy_code", "validate1"], "invalid_code_metadata_not_read")
        print("PASS: \(checks) publisher facts, CF metadata and actual-adapter orchestration checks; mocked process/Security calls")
    }
}
