import Foundation

/// Opaque scan-local tokens are assigned using CFEqual by the live observer.
/// These plain facts are not a signature witness, receipt or absence authority.
enum AXNativeScopeMembership: Equatable, Sendable {
    case elements([UInt32])
    case noValue
    case unsupported
    case failure(AXReadFailure)
}

struct AXNativeScopeNodeRead: Equatable, Sendable {
    let identity: AXIdentityRead
    let owner: AXProcessIdentifierRead
    let geometry: AXGeometryRead?
    let children: AXNativeScopeMembership
}

struct AXNativeScopeNode: Equatable, Sendable {
    let token: UInt32
    let before: AXNativeScopeNodeRead
    let after: AXNativeScopeNodeRead
}

enum AXNativeScopeFailure: String, Equatable, Sendable {
    case nodeLimit, duplicateNode, changedNode, readUnknown, unexpectedShape
    case openFrontier, missingAnchor, invalidIdentity, orphanNode, unusableGeometry
}

struct AXNativeClosedScope: Equatable, Sendable {
    let leafTokens: [UInt32]
    let focusToken: UInt32?
    let clockToken: UInt32
    let controlCenterToken: UInt32
}

enum AXNativeScopeValidation: Equatable, Sendable {
    case closed(AXNativeClosedScope)
    case unknown(AXNativeScopeFailure)
}

enum AXNativeScopeValidationSupport {
    static let focusIdentifier = "com.apple.menuextra.focusmode"
    static let clockIdentifier = "com.apple.menuextra.clock"
    static let controlCenterIdentifier = "com.apple.menuextra.controlcenter"
    static let maximumNodeCount = 192

    /// Validates a closed extras -> hosting wrapper -> terminal-item forest.
    /// No-value/unsupported children never become empty; every edge must have
    /// exactly one record, and before/after ordered membership must match.
    static func validate(extrasToken: UInt32, nodes: [AXNativeScopeNode], ownerPID: Int32) -> AXNativeScopeValidation {
        guard ownerPID > 0, !nodes.isEmpty, nodes.count <= maximumNodeCount else { return .unknown(.nodeLimit) }
        let tokens = nodes.map(\.token)
        guard tokens.allSatisfy({ $0 > 0 }), Set(tokens).count == tokens.count else { return .unknown(.duplicateNode) }
        let byToken = Dictionary(uniqueKeysWithValues: nodes.map { ($0.token, $0) })
        guard let extras = byToken[extrasToken] else { return .unknown(.orphanNode) }
        for node in nodes {
            guard node.before == node.after else { return .unknown(.changedNode) }
            guard node.before.owner == .value(ownerPID), case .attributes = node.before.identity else { return .unknown(.readUnknown) }
        }
        guard case let .attributes(extraIdentity) = extras.before.identity,
              extraIdentity.identifier == .noValue, extraIdentity.role == .value("AXMenuBar"), extraIdentity.subrole == .noValue,
              case let .elements(wrappers) = extras.before.children else { return .unknown(.unexpectedShape) }
        var referenced: Set<UInt32> = [extrasToken]
        var leaves: [UInt32] = []
        var identifiers: Set<String> = []
        var normalizedIdentifiers: Set<String> = []
        var clock: UInt32?
        var controlCenter: UInt32?
        var focus: UInt32?
        guard wrappers.count <= 64 else { return .unknown(.nodeLimit) }
        for wrapperToken in wrappers {
            guard referenced.insert(wrapperToken).inserted else { return .unknown(.duplicateNode) }
            guard let wrapper = byToken[wrapperToken], case let .attributes(identity) = wrapper.before.identity else {
                return .unknown(.orphanNode)
            }
            guard identity.identifier == .noValue, identity.role == .value("AXGroup"), identity.subrole == .value("AXHostingView"),
                  case let .elements(children) = wrapper.before.children else { return .unknown(.unexpectedShape) }
            guard children.count <= 64 else { return .unknown(.nodeLimit) }
            for leafToken in children {
                guard referenced.insert(leafToken).inserted else { return .unknown(.duplicateNode) }
                guard let leaf = byToken[leafToken], case let .attributes(attributes) = leaf.before.identity else { return .unknown(.orphanNode) }
                guard attributes.role == .value("AXMenuBarItem"), attributes.subrole == .value("AXMenuExtra"),
                      case let .value(identifier) = attributes.identifier,
                      !identifier.isEmpty, identifier.utf8.count <= 256 else { return .unknown(.invalidIdentity) }
                guard identifiers.insert(identifier).inserted else { return .unknown(.duplicateNode) }
                // This normalization detects domain-ID collisions only. It
                // never authorizes a case/whitespace variant as native Focus.
                let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty, normalizedIdentifiers.insert(normalized).inserted else { return .unknown(.duplicateNode) }
                guard leaf.before.children == .elements([]) else { return .unknown(.openFrontier) }
                guard case let .bounds(bounds) = leaf.before.geometry,
                      bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                      bounds.size.width.isFinite, bounds.size.height.isFinite,
                      bounds.size.width > 0, bounds.size.height > 0,
                      (bounds.origin.x + bounds.size.width).isFinite,
                      (bounds.origin.y + bounds.size.height).isFinite else { return .unknown(.unusableGeometry) }
                leaves.append(leafToken)
                switch identifier {
                case clockIdentifier: clock = leafToken
                case controlCenterIdentifier: controlCenter = leafToken
                case focusIdentifier: focus = leafToken
                default: break // A readable closed terminal sibling needs no product-name catalogue.
                }
            }
        }
        guard referenced == Set(tokens) else { return .unknown(.orphanNode) }
        guard let clock, let controlCenter else { return .unknown(.missingAnchor) }
        return .closed(AXNativeClosedScope(leafTokens: leaves, focusToken: focus, clockToken: clock, controlCenterToken: controlCenter))
    }
}
