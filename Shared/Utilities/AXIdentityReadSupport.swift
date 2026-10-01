import ApplicationServices
import Foundation

/// Typed observations, not identity authorization. No value may be logged.
struct AXReadFailure: Equatable, Sendable {
    enum Kind: String, Sendable {
        case wrongType, malformedResponse, invalidElement, cannotComplete, apiDisabled
        case otherAXError, cancelled, deadlineExceeded, insufficientBudget, overLimit, changedCount, duplicateElements
    }

    let kind: Kind
    let errorCode: Int32?

    init(_ kind: Kind, error: AXError? = nil) {
        self.kind = kind
        errorCode = error?.rawValue
    }
}

enum AXStringRead: Equatable, Sendable {
    case value(String)
    case noValue
    case unsupported
    case failure(AXReadFailure)
}

struct AXIdentityAttributes: Equatable, Sendable {
    let identifier: AXStringRead
    let role: AXStringRead
    let subrole: AXStringRead
}

enum AXIdentityRead: Equatable, Sendable {
    case attributes(AXIdentityAttributes)
    case failure(AXReadFailure)
}

enum AXChildrenRead {
    case elements([AXUIElement])
    case noValue
    case unsupported
    case failure(AXReadFailure)
}

/// One scan's cancellation handler revokes this signal before queued AX work
/// is admitted. Unlike Task.isCancelled, it survives dispatch thread hops.
final class AXReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        revoked = true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }
}

enum AXIdentityReadSupport {
    static func failure(_ error: AXError) -> AXReadFailure {
        let kind: AXReadFailure.Kind = switch error {
        case .invalidUIElement: .invalidElement
        case .cannotComplete: .cannotComplete
        case .apiDisabled: .apiDisabled
        default: .otherAXError
        }
        return AXReadFailure(kind, error: error)
    }

    static func decodeIdentity(status: AXError, values: CFTypeRef?) -> AXIdentityRead {
        guard status == .success else { return .failure(failure(status)) }
        guard let values, CFGetTypeID(values) == CFArrayGetTypeID() else {
            return .failure(AXReadFailure(.wrongType))
        }
        let array = unsafeDowncast(values, to: CFArray.self)
        guard CFArrayGetCount(array) == 3 else { return .failure(AXReadFailure(.malformedResponse)) }
        let slots = array as [AnyObject]
        return .attributes(AXIdentityAttributes(
            identifier: decodeString(slots[0]), role: decodeString(slots[1]), subrole: decodeString(slots[2])
        ))
    }

    private static func decodeString(_ value: AnyObject) -> AXStringRead {
        switch CFGetTypeID(value) {
        case CFStringGetTypeID():
            let raw = unsafeDowncast(value, to: CFString.self)
            guard CFStringGetLength(raw) <= 256 else { return .failure(AXReadFailure(.overLimit)) }
            guard let string = value as? String else { return .failure(AXReadFailure(.wrongType)) }
            guard string.utf8.count <= 256 else { return .failure(AXReadFailure(.overLimit)) }
            return .value(string)
        case CFNullGetTypeID():
            return .noValue
        case AXValueGetTypeID():
            let wrapped = unsafeDowncast(value, to: AXValue.self)
            var error = AXError.success
            guard AXValueGetType(wrapped) == .axError,
                  AXValueGetValue(wrapped, .axError, &error) else { return .failure(AXReadFailure(.wrongType)) }
            switch error {
            case .noValue: return .noValue
            case .attributeUnsupported: return .unsupported
            case .success: return .failure(AXReadFailure(.malformedResponse))
            default: return .failure(failure(error))
            }
        default:
            return .failure(AXReadFailure(.wrongType))
        }
    }

    /// The checks run after queue admission and around every synchronous call.
    /// A successful late result is unknown, never proof of absence.
    static func perform<T>(
        deadline: UInt64,
        now: () -> UInt64,
        cancelled: () -> Bool,
        setTimeout: (Float) -> AXError,
        operation: () -> T
    ) -> Result<T, AXReadFailure> {
        guard !cancelled() else { return .failure(AXReadFailure(.cancelled)) }
        let admittedAt = now()
        guard admittedAt < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        // Do not risk a sub-millisecond native timeout rounding to the API's
        // default timeout, and do not round upward beyond the remaining budget.
        guard deadline - admittedAt >= 1_000_000 else { return .failure(AXReadFailure(.insufficientBudget)) }
        let timeout = Float(min(Double(deadline - admittedAt) / 1_000_000_000, 0.05))
        let timeoutStatus = setTimeout(timeout)
        guard timeoutStatus == .success else { return .failure(failure(timeoutStatus)) }
        guard !cancelled() else { return .failure(AXReadFailure(.cancelled)) }
        guard now() < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        let value = operation()
        guard !cancelled() else { return .failure(AXReadFailure(.cancelled)) }
        guard now() < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
        return .success(value)
    }

    static func children(
        maximumCount: Int,
        deadline: UInt64,
        now: () -> UInt64,
        cancelled: () -> Bool,
        setTimeout: (Float) -> AXError,
        count: () -> (AXError, CFIndex),
        copy: (CFIndex) -> (AXError, CFTypeRef?)
    ) -> AXChildrenRead {
        guard maximumCount > 0, maximumCount <= 64 else { return .failure(AXReadFailure(.overLimit)) }
        let first = perform(deadline: deadline, now: now, cancelled: cancelled, setTimeout: setTimeout, operation: count)
        let observedCount: CFIndex
        switch first {
        case let .failure(error): return .failure(error)
        case .success(let (status, value)):
            if status == .attributeUnsupported {
                return .unsupported
            }
            if status == .noValue {
                return .noValue
            }
            guard status == .success else { return .failure(failure(status)) }
            guard value >= 0, value <= maximumCount else { return .failure(AXReadFailure(.overLimit)) }
            observedCount = value
        }
        var elements: [AXUIElement] = []
        if observedCount > 0 {
            let copied = perform(deadline: deadline, now: now, cancelled: cancelled, setTimeout: setTimeout) {
                copy(observedCount)
            }
            switch copied {
            case let .failure(error): return .failure(error)
            case .success(let (status, raw)):
                guard status == .success else { return .failure(failure(status)) }
                guard let raw, CFGetTypeID(raw) == CFArrayGetTypeID() else { return .failure(AXReadFailure(.wrongType)) }
                let array = unsafeDowncast(raw, to: CFArray.self)
                guard CFArrayGetCount(array) == observedCount else { return .failure(AXReadFailure(.changedCount)) }
                let values = array as [AnyObject]
                guard values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
                    return .failure(AXReadFailure(.wrongType))
                }
                elements = values.map { unsafeDowncast($0, to: AXUIElement.self) }
                for (index, element) in elements.enumerated() {
                    guard !elements.prefix(index).contains(where: { CFEqual($0, element) }) else {
                        return .failure(AXReadFailure(.duplicateElements))
                    }
                }
            }
        }
        let final = perform(deadline: deadline, now: now, cancelled: cancelled, setTimeout: setTimeout, operation: count)
        switch final {
        case let .failure(error): return .failure(error)
        case .success(let (status, value)):
            guard status == .success else { return .failure(failure(status)) }
            guard value == observedCount else { return .failure(AXReadFailure(.changedCount)) }
            return .elements(elements)
        }
    }
}

extension AXReadFailure: Error {}
