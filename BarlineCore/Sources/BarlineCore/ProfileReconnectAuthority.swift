import Foundation

/// A newer manual intent permanently revokes automatic reconnect permission
/// from its old authority token. Cancelling one task is insufficient: a later
/// screen signal must not mint another task from that superseded authority.
public struct ProfileReconnectAuthority: Sendable {
    private var revoked = Set<UUID>()
    public init() {}
    public mutating func revoke(_ token: UUID?, isPublished: Bool = true) {
        if isPublished, let token {
            revoked.insert(token)
        }
    }

    public func permits(_ token: UUID?) -> Bool {
        token.map { !revoked.contains($0) } ?? false
    }
}
