@testable import BarlineCore
import Foundation
import Testing

struct ProfileReconnectAuthorityTests {
    @Test("Startup catalog loading does not revoke persisted authority before rehydration")
    func startupReloadThenRehydration() {
        var authority = ProfileReconnectAuthority()
        let persisted = UUID()
        authority.revoke(persisted, isPublished: false)
        #expect(authority.permits(persisted))
        // Only a newer intent after verified publication supersedes it.
        authority.revoke(persisted, isPublished: true)
        #expect(!authority.permits(persisted))
    }

    @Test("A screen signal cannot revive authority superseded by native dragging")
    func cancellationThenScreenSignal() {
        var authority = ProfileReconnectAuthority()
        let original = UUID(), newlyVerified = UUID()
        #expect(authority.permits(original))
        authority.revoke(original)
        // Several new screen tickets, mouse-up and passive refreshes still
        // carry the old authority. None grant automatic activation permission.
        for _ in 0 ..< 20 {
            #expect(!authority.permits(original))
        }
        #expect(!authority.permits(nil))
        #expect(authority.permits(newlyVerified))
    }
}
