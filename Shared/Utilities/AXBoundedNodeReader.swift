import ApplicationServices
import Foundation

/// Handle-bearing reads stay in one actor-local synchronous scan. This reader
/// performs no dispatch hop, input, signature check or identity authorization.
/// Its caller must revoke cancellation directly from onCancel.
struct AXBoundedNodeReader {
    let deadline: UInt64
    let cancellation: AXReadCancellation

    private var cancelled: Bool {
        cancellation.isCancelled || Task.isCancelled
    }

    private var now: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private func read<T>(on node: AXUIElement, _ operation: () -> T) -> Result<T, AXReadFailure> {
        defer { _ = AXUIElementSetMessagingTimeout(node, 0.25) }
        return AXIdentityReadSupport.perform(
            deadline: deadline, now: { now }, cancelled: { cancelled },
            setTimeout: { AXUIElementSetMessagingTimeout(node, $0) }, operation: operation
        )
    }

    func extras(on application: AXUIElement) -> AXElementRead {
        defer { _ = AXUIElementSetMessagingTimeout(application, 0.25) }
        return AXIdentityReadSupport.element(
            deadline: deadline, now: { now }, cancelled: { cancelled },
            setTimeout: { AXUIElementSetMessagingTimeout(application, $0) },
            copy: {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(application, kAXExtrasMenuBarAttribute as CFString, &value)
                return (status, value)
            },
            adopt: { AXUIElementSetMessagingTimeout($0, 0.25) }
        )
    }

    func identity(on node: AXUIElement) -> AXIdentityRead {
        switch read(on: node, {
            var values: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(
                node, [kAXIdentifierAttribute, kAXRoleAttribute, kAXSubroleAttribute] as CFArray, [], &values
            )
            return AXIdentityReadSupport.decodeIdentity(status: status, values: values)
        }) {
        case let .success(value): value
        case let .failure(error): .failure(error)
        }
    }

    func processIdentifier(on node: AXUIElement) -> AXProcessIdentifierRead {
        switch read(on: node, {
            var pid: pid_t = 0
            let status = AXUIElementGetPid(node, &pid)
            return AXIdentityReadSupport.decodeProcessIdentifier(status: status, value: pid)
        }) {
        case let .success(value): value
        case let .failure(error): .failure(error)
        }
    }

    func geometry(on node: AXUIElement) -> AXGeometryRead {
        switch read(on: node, {
            var values: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(
                node, [kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &values
            )
            return AXIdentityReadSupport.decodeGeometry(status: status, values: values)
        }) {
        case let .success(value): value
        case let .failure(error): .failure(error)
        }
    }

    func children(on node: AXUIElement, maximumCount: Int) -> AXChildrenRead {
        defer { _ = AXUIElementSetMessagingTimeout(node, 0.25) }
        let result = AXIdentityReadSupport.children(
            maximumCount: maximumCount, deadline: deadline, now: { now }, cancelled: { cancelled },
            setTimeout: { AXUIElementSetMessagingTimeout(node, $0) },
            count: {
                var count: CFIndex = 0
                let status = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count)
                return (status, count)
            },
            copy: { count in
                var values: CFArray?
                let status = AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &values)
                return (status, values)
            }
        )
        if case let .elements(children) = result {
            for child in children {
                guard !cancelled else { return .failure(AXReadFailure(.cancelled)) }
                guard now < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
                let status = AXUIElementSetMessagingTimeout(child, 0.25)
                guard !cancelled else { return .failure(AXReadFailure(.cancelled)) }
                guard now < deadline else { return .failure(AXReadFailure(.deadlineExceeded)) }
                guard status == .success else { return .failure(AXIdentityReadSupport.failure(status)) }
            }
        }
        return result
    }
}
