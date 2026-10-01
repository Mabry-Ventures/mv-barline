import ApplicationServices
import Foundation

@main
@MainActor
enum AXIdentityReadTests {
    static var passedChecks = 0

    static func expect(_ value: Bool, _ code: String) {
        if !value {
            print("FAIL: \(code)"); exit(1)
        }
        passedChecks += 1
    }

    static func errorValue(_ error: AXError) -> AXValue {
        var value = error
        guard let encoded = AXValueCreate(.axError, &value) else { fatalError("fixture_error_slot") }
        return encoded
    }

    static func attributes(_ result: AXIdentityRead) -> AXIdentityAttributes? {
        if case let .attributes(attributes) = result {
            return attributes
        }
        return nil
    }

    static func childrenFailure(_ result: AXChildrenRead, _ kind: AXReadFailure.Kind) -> Bool {
        if case let .failure(error) = result {
            return error.kind == kind
        }
        return false
    }

    static func main() async {
        let slots: [AnyObject] = ["exact.identifier" as NSString, "AXMenuBarItem" as NSString, "AXMenuExtra" as NSString]
        let decoded = AXIdentityReadSupport.decodeIdentity(status: .success, values: slots as CFArray)
        expect(attributes(decoded) == AXIdentityAttributes(
            identifier: .value("exact.identifier"), role: .value("AXMenuBarItem"), subrole: .value("AXMenuExtra")
        ), "exact_unmodified_tuple")
        expect(AXIdentityReadSupport.decodeIdentity(status: .cannotComplete, values: slots as CFArray)
            == .failure(AXReadFailure(.cannotComplete, error: .cannotComplete)), "outer_error_not_absence")
        expect(AXIdentityReadSupport.decodeIdentity(status: .success, values: nil)
            == .failure(AXReadFailure(.wrongType)), "missing_outer_value")
        expect(AXIdentityReadSupport.decodeIdentity(status: .success, values: "bad" as CFString)
            == .failure(AXReadFailure(.wrongType)), "wrong_outer_type")
        expect(AXIdentityReadSupport.decodeIdentity(status: .success, values: [] as CFArray)
            == .failure(AXReadFailure(.malformedResponse)), "wrong_outer_cardinality")
        for error in [AXError.noValue, .attributeUnsupported, .cannotComplete, .invalidUIElement, .apiDisabled, .success] {
            let input: [AnyObject] = [slots[0], slots[1], errorValue(error)]
            let result = attributes(AXIdentityReadSupport.decodeIdentity(status: .success, values: input as CFArray))
            let expected: AXStringRead = switch error {
            case .noValue: .noValue
            case .attributeUnsupported: .unsupported
            case .success: .failure(AXReadFailure(.malformedResponse))
            default: .failure(AXIdentityReadSupport.failure(error))
            }
            expect(result?.subrole == expected && result?.identifier == .value("exact.identifier"), "optional_subrole_typed_\(error.rawValue)")
        }
        let noSubrole: [AnyObject] = [slots[0], slots[1], kCFNull]
        expect(attributes(AXIdentityReadSupport.decodeIdentity(status: .success, values: noSubrole as CFArray))?.subrole == .noValue,
               "null_optional_subrole")
        let malformed: [AnyObject] = [NSNumber(value: 1), slots[1], slots[2]]
        expect(attributes(AXIdentityReadSupport.decodeIdentity(status: .success, values: malformed as CFArray))?.identifier
            == .failure(AXReadFailure(.wrongType)), "number_not_string")
        var point = CGPoint(x: 1, y: 2)
        guard let wrongAXValue = AXValueCreate(.cgPoint, &point) else { fatalError("fixture_point") }
        let wrongWrapped: [AnyObject] = [slots[0], slots[1], wrongAXValue]
        expect(attributes(AXIdentityReadSupport.decodeIdentity(status: .success, values: wrongWrapped as CFArray))?.subrole
            == .failure(AXReadFailure(.wrongType)), "wrong_axvalue_payload")
        let empty: [AnyObject] = ["" as NSString, slots[1], slots[2]]
        expect(attributes(AXIdentityReadSupport.decodeIdentity(status: .success, values: empty as CFArray))?.identifier == .value(""),
               "empty_string_not_absence")
        let oversized: [AnyObject] = [String(repeating: "a", count: 257) as NSString, slots[1], slots[2]]
        expect(attributes(AXIdentityReadSupport.decodeIdentity(status: .success, values: oversized as CFArray))?.identifier
            == .failure(AXReadFailure(.overLimit)), "oversize_identity_rejected_not_truncated")
        let multibyte: [AnyObject] = [String(repeating: "é", count: 129) as NSString, slots[1], slots[2]]
        expect(attributes(AXIdentityReadSupport.decodeIdentity(status: .success, values: multibyte as CFArray))?.identifier
            == .failure(AXReadFailure(.overLimit)), "oversize_utf8_identity_rejected")

        var now: UInt64 = 1
        var operations = 0
        var timeouts: [Float] = []
        func perform(deadline: UInt64, cancelled: Bool = false, status: AXError = .success, late: Bool = false) -> Result<Int, AXReadFailure> {
            AXIdentityReadSupport.perform(
                deadline: deadline, now: { now }, cancelled: { cancelled },
                setTimeout: { timeouts.append($0); return status },
                operation: {
                    operations += 1; if late {
                        now = deadline
                    }; return 7
                }
            )
        }
        expect(perform(deadline: 1) == .failure(AXReadFailure(.deadlineExceeded)) && operations == 0, "expired_before_timeout")
        expect(perform(deadline: 100_000_001, cancelled: true) == .failure(AXReadFailure(.cancelled)) && timeouts.isEmpty,
               "cancelled_before_timeout")
        expect(perform(deadline: 100_000_001, status: .invalidUIElement)
            == .failure(AXReadFailure(.invalidElement, error: .invalidUIElement)) && operations == 0, "failed_timeout_no_ipc")
        timeouts = []
        expect(perform(deadline: 2_000_000_001) == .success(7) && timeouts == [0.05], "timeout_ceiling")
        timeouts = []
        expect(perform(deadline: 10_000_001) == .success(7) && timeouts == [0.01], "remaining_timeout")
        expect(perform(deadline: 100_000_001, late: true) == .failure(AXReadFailure(.deadlineExceeded)), "late_success_rejected")
        now = 1
        expect(perform(deadline: 500_001) == .failure(AXReadFailure(.insufficientBudget)), "submillisecond_budget_no_ipc")
        var changedCancellation = false
        let cancelledAtTimeout = AXIdentityReadSupport.perform(
            deadline: 100_000_001, now: { now }, cancelled: { changedCancellation },
            setTimeout: { _ in changedCancellation = true; return .success }, operation: { 7 }
        )
        expect(cancelledAtTimeout == .failure(AXReadFailure(.cancelled)), "cancelled_after_timeout_admission")
        changedCancellation = false
        let cancelledInOperation = AXIdentityReadSupport.perform(
            deadline: 100_000_001, now: { now }, cancelled: { changedCancellation },
            setTimeout: { _ in .success }, operation: { changedCancellation = true; return 7 }
        )
        expect(cancelledInOperation == .failure(AXReadFailure(.cancelled)), "cancelled_result_withheld")

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cancellation = AXReadCancellation()
        let worker = Task.detached {
            await withTaskCancellationHandler {
                DispatchQueue.main.sync {
                    entered.signal()
                    guard release.wait(timeout: .now() + 3) == .success else { return false }
                    return cancellation.isCancelled
                }
            } onCancel: {
                cancellation.cancel()
            }
        }
        DispatchQueue.global().async {
            guard entered.wait(timeout: .now() + 3) == .success else { release.signal(); return }
            worker.cancel()
            release.signal()
        }
        let originalTaskCancellationObserved = await worker.value
        expect(originalTaskCancellationObserved, "originating_task_cancelled_across_main_sync")

        let first = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let second = AXUIElementCreateSystemWide()
        if case let .element(value) = AXIdentityReadSupport.decodeElement(status: .success, value: first) {
            expect(CFEqual(value, first), "exact_element_decoded")
        } else {
            expect(false, "element_missing")
        }
        for (status, kind) in [(AXError.cannotComplete, AXReadFailure.Kind.cannotComplete),
                               (.apiDisabled, .apiDisabled), (.invalidUIElement, .invalidElement)]
        {
            if case let .failure(error) = AXIdentityReadSupport.decodeElement(status: status, value: first) {
                expect(error == AXReadFailure(kind, error: status), "element_error_not_presence_or_absence_\(status.rawValue)")
            } else {
                expect(false, "element_error_erased")
            }
        }
        if case .noValue = AXIdentityReadSupport.decodeElement(status: .noValue, value: first) {
            expect(true, "element_no_value_distinct")
        } else {
            expect(false, "element_no_value_erased")
        }
        if case .unsupported = AXIdentityReadSupport.decodeElement(status: .attributeUnsupported, value: nil) {
            expect(true, "element_unsupported_distinct")
        } else {
            expect(false, "element_unsupported_erased")
        }
        for raw in [nil, "wrong" as CFString, kCFNull, NSNumber(value: 1), [] as CFArray, wrongAXValue] as [CFTypeRef?] {
            if case let .failure(error) = AXIdentityReadSupport.decodeElement(status: .success, value: raw) {
                expect(error.kind == .wrongType, "element_success_wrong_type")
            } else {
                expect(false, "element_type_unchecked")
            }
        }
        if case let .failure(error) = AXIdentityReadSupport.decodeElement(status: .failure, value: first) {
            expect(error == AXReadFailure(.otherAXError, error: .failure), "generic_element_error_preserved")
        } else {
            expect(false, "generic_element_error_erased")
        }

        var elementTimeouts = 0
        var elementCopies = 0
        var elementAdoptions = 0
        var elementCancelled = false
        func elementRead(status: AXError = .success, raw: CFTypeRef? = first, interruptAt: String = "",
                         adoptionStatus: AXError = .success) -> AXElementRead
        {
            elementTimeouts = 0; elementCopies = 0; elementAdoptions = 0
            elementCancelled = interruptAt == "before"
            now = interruptAt == "expired" ? 100_000_001 : 1
            return AXIdentityReadSupport.element(
                deadline: 100_000_001, now: { now }, cancelled: { elementCancelled },
                setTimeout: { _ in
                    elementTimeouts += 1
                    if interruptAt == "timeout" {
                        elementCancelled = true
                    }
                    return .success
                }, copy: {
                    elementCopies += 1
                    if interruptAt == "copy" {
                        elementCancelled = true
                    }
                    if interruptAt == "lateCopy" {
                        now = 100_000_001
                    }
                    return (status, raw)
                }, adopt: { value in
                    elementAdoptions += 1
                    expect(CFEqual(value, first), "exact_returned_root_adopted")
                    if interruptAt == "adopt" {
                        elementCancelled = true
                    }
                    if interruptAt == "lateAdopt" {
                        now = 100_000_001
                    }
                    return adoptionStatus
                }
            )
        }
        func elementFailure(_ read: AXElementRead, _ kind: AXReadFailure.Kind) -> Bool {
            if case let .failure(error) = read {
                return error.kind == kind
            }
            return false
        }
        expect(elementFailure(elementRead(interruptAt: "before"), .cancelled) && elementTimeouts == 0 && elementCopies == 0,
               "cancelled_element_not_admitted")
        expect(elementFailure(elementRead(interruptAt: "expired"), .deadlineExceeded) && elementTimeouts == 0,
               "expired_element_not_admitted")
        expect(elementFailure(elementRead(interruptAt: "timeout"), .cancelled) && elementCopies == 0 && elementAdoptions == 0,
               "cancel_at_timeout_no_element_copy")
        expect(elementFailure(elementRead(interruptAt: "copy"), .cancelled) && elementAdoptions == 0,
               "cancelled_element_copy_no_adoption")
        expect(elementFailure(elementRead(interruptAt: "lateCopy"), .deadlineExceeded) && elementAdoptions == 0,
               "late_element_copy_no_adoption")
        expect(elementFailure(elementRead(interruptAt: "adopt"), .cancelled), "cancelled_root_adoption_no_publication")
        expect(elementFailure(elementRead(interruptAt: "lateAdopt"), .deadlineExceeded), "late_root_adoption_no_publication")
        expect(elementFailure(elementRead(adoptionStatus: .invalidUIElement), .invalidElement), "invalid_root_adoption_unknown")
        expect(elementFailure(elementRead(raw: kCFNull), .wrongType) && elementAdoptions == 0,
               "malformed_element_not_adopted")
        for status in [AXError.noValue, .attributeUnsupported] {
            expect(elementFailure(elementRead(status: status, interruptAt: "lateCopy"), .deadlineExceeded) && elementAdoptions == 0,
                   "late_no_value_or_unsupported_not_admitted_\(status.rawValue)")
        }
        if case .noValue = elementRead(status: .noValue) {
            expect(elementAdoptions == 0, "no_value_not_adopted")
        } else {
            expect(false, "no_value_orchestration_erased")
        }
        if case .unsupported = elementRead(status: .attributeUnsupported) {
            expect(elementAdoptions == 0, "unsupported_not_adopted")
        } else {
            expect(false, "unsupported_orchestration_erased")
        }
        if case let .element(value) = elementRead() {
            expect(CFEqual(value, first) && elementCopies == 1 && elementAdoptions == 1, "complete_element_adoption")
        } else {
            expect(false, "element_orchestration_failed")
        }
        var copies = 0
        func children(counts: [(AXError, CFIndex)], raw: CFTypeRef?, maximum: Int = 2, late: Bool = false) -> AXChildrenRead {
            var index = 0
            return AXIdentityReadSupport.children(
                maximumCount: maximum, deadline: 100_000_001, now: { now }, cancelled: { false }, setTimeout: { _ in .success },
                count: { defer { index += 1 }; return counts[min(index, counts.count - 1)] },
                copy: { requested in
                    copies += 1
                    expect(requested <= maximum, "copy_request_bounded")
                    if late {
                        now = 100_000_001
                    }
                    return (.success, raw)
                }
            )
        }
        now = 1
        if case let .elements(values) = children(counts: [(.success, 0)], raw: nil) {
            expect(values.isEmpty && copies == 0, "genuine_zero_without_copy")
        } else {
            expect(false, "zero_not_error")
        }
        expect(childrenFailure(children(counts: [(.success, 3)], raw: nil), .overLimit) && copies == 0, "overcap_without_copy")
        expect(childrenFailure(children(counts: [(.success, 1)], raw: ["bad" as NSString] as CFArray), .wrongType), "bad_child_not_dropped")
        expect(childrenFailure(children(counts: [(.success, 2)], raw: [first] as CFArray), .changedCount), "partial_copy_rejected")
        expect(childrenFailure(children(counts: [(.success, 2)], raw: [first, first] as CFArray), .duplicateElements), "duplicate_child_rejected")
        expect(childrenFailure(children(counts: [(.success, 2), (.success, 1)], raw: [first, second] as CFArray), .changedCount),
               "count_drift_rejected")
        if case .noValue = children(counts: [(.noValue, 0)], raw: nil) {} else {
            expect(false, "no_value_not_empty")
        }
        if case .unsupported = children(counts: [(.attributeUnsupported, 0)], raw: nil) {} else {
            expect(false, "unsupported_not_empty")
        }
        expect(childrenFailure(children(counts: [(.cannotComplete, 0)], raw: nil), .cannotComplete), "children_ipc_failure_not_empty")
        expect(childrenFailure(children(counts: [(.success, 1)], raw: [first] as CFArray, late: true), .deadlineExceeded),
               "late_children_not_admitted")
        now = 1
        if case let .elements(values) = children(counts: [(.success, 2)], raw: [first, second] as CFArray) {
            expect(values.count == 2 && CFEqual(values[0], first) && CFEqual(values[1], second), "complete_ordered_children")
        } else {
            expect(false, "complete_children")
        }
        print("PASS: \(passedChecks) typed AX identity, budget and bounded-children checks; no AX IPC or app launch")
    }
}
