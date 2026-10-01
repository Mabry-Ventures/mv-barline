//
//  ProfileAuthorityPersistenceTests.swift
//  Barline
//

@testable import BarlineCore
import Foundation
import Testing

struct ProfileAuthorityPersistenceTests {
    @Test("A refused promotion preserves the pending checkpoint byte for byte")
    func refusedPromotionPreservesPendingCheckpoint() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            defaults.arm([.refuse])

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(promoting(pending))
            }

            #expect(defaults.data(forKey: Self.key) == original)
            let reloaded = ProfileAuthorityEnvelopeStore(defaults: defaults, key: Self.key).load()
            #expect(reloaded == pending)
            #expect(reloaded?.checkpoint == pending.checkpoint)
            #expect(reloaded?.priorAuthority == pending.priorAuthority)
            #expect(reloaded?.activeAuthority == nil)
        }
    }

    @Test("A corrupt promotion rolls back to the exact pending envelope")
    func corruptPromotionRestoresPendingBytes() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            defaults.arm([.corrupt])

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(promoting(pending))
            }

            #expect(defaults.writeAttempts == 2)
            #expect(defaults.data(forKey: Self.key) == original)
            #expect(ProfileAuthorityEnvelopeStore(defaults: defaults, key: Self.key).load() == pending)
        }
    }

    @Test("A failed replacement retains the prior active authority")
    func failedReplacementPreservesActiveAuthority() throws {
        try withDefaults { defaults, store in
            let active = ProfileAuthorityEnvelope(active: makePriorAuthority())
            try store.save(active)
            let original = try #require(defaults.data(forKey: Self.key))
            defaults.arm([.corrupt])

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(makePending())
            }

            #expect(defaults.data(forKey: Self.key) == original)
            #expect(store.load()?.activeAuthority == active.activeAuthority)
            #expect(store.load()?.phase == .active)
        }
    }

    @Test("Rollback preserves a preexisting non-Data defaults object")
    func failedWritePreservesPriorObject() throws {
        try withDefaults { defaults, store in
            defaults.set("unrecognized legacy value", forKey: Self.key)
            defaults.arm([.corrupt])

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(makePending())
            }

            #expect(defaults.object(forKey: Self.key) as? String == "unrecognized legacy value")
            #expect(defaults.writeAttempts == 2)
        }
    }

    @Test("A failed first write restores absence instead of leaving corrupt authority")
    func failedFirstWriteRestoresAbsentKey() throws {
        try withDefaults { defaults, store in
            #expect(defaults.object(forKey: Self.key) == nil)
            defaults.arm([.corrupt])

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(makePending())
            }

            #expect(defaults.object(forKey: Self.key) == nil)
            #expect(defaults.removalAttempts == 1)
            #expect(store.load() == nil)
        }
    }

    @Test("A refused rollback reports loss of verified recovery state")
    func failedRollbackIsDistinguishedFromRejectedWrite() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            defaults.arm([.corrupt, .refuse])

            #expect(throws: ProfileAuthorityPersistenceError.rollbackNotVerified) {
                try store.save(promoting(pending))
            }

            #expect(defaults.writeAttempts == 2)
            #expect(defaults.data(forKey: Self.key) != original)
            #expect(store.load() == nil)
        }
    }

    @Test("Unencodable authority fails before any defaults mutation")
    func encodingFailurePreservesExistingAuthority() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            var invalidProfile = try #require(pending.pendingProfile)
            invalidProfile.autoRehide.delaySeconds = .infinity
            defaults.arm([])

            #expect(throws: ProfileAuthorityPersistenceError.encodingFailed) {
                try store.save(makePending(profile: invalidProfile))
            }

            #expect(defaults.writeAttempts == 0)
            #expect(defaults.removalAttempts == 0)
            #expect(defaults.data(forKey: Self.key) == original)
        }
    }

    @Test("An oversized encoded envelope fails before any defaults mutation")
    func oversizedEnvelopePreservesExistingAuthority() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            var oversizedProfile = try #require(pending.pendingProfile)
            oversizedProfile.name = String(repeating: "x", count: ProfileCodec.maximumArchiveByteCount)
            let oversized = makePending(profile: oversizedProfile)
            #expect(try JSONEncoder().encode(oversized).count > ProfileCodec.maximumArchiveByteCount)
            defaults.arm([])

            #expect(throws: ProfileAuthorityPersistenceError.archiveTooLarge) {
                try store.save(oversized)
            }

            #expect(defaults.writeAttempts == 0)
            #expect(defaults.removalAttempts == 0)
            #expect(defaults.data(forKey: Self.key) == original)
        }
    }

    @Test("A successful promotion replaces pending recovery with active authority")
    func successfulReplacementPersistsActiveAuthority() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            let active = promoting(pending)
            defaults.arm([])

            try store.save(active)

            #expect(defaults.writeAttempts == 1)
            #expect(defaults.removalAttempts == 0)
            #expect(defaults.data(forKey: Self.key) != original)
            let reloaded = ProfileAuthorityEnvelopeStore(defaults: defaults, key: Self.key).load()
            #expect(reloaded == active)
            #expect(reloaded?.activeAuthority?.token == pending.token)
            #expect(reloaded?.checkpoint == nil)
            #expect(reloaded?.pendingProfile == nil)
        }
    }

    @Test("Rejected active promotion preserves pending recovery and the prior token")
    func rejectedPromotionPreservesEnvelopeAndToken() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            let priorToken = try #require(pending.priorAuthority?.token.uuidString)
            defaults.set(priorToken, forKey: Self.tokenKey)
            defaults.arm([.refuse])

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(promoting(pending), activeTokenKey: Self.tokenKey)
            }

            #expect(defaults.data(forKey: Self.key) == original)
            #expect(defaults.string(forKey: Self.tokenKey) == priorToken)
            #expect(store.load() == pending)
        }
    }

    @Test("A rejected token mirror rolls back both persisted values", arguments: [false, true])
    func rejectedTokenWriteRollsBackEnvelopeAndToken(_ corrupt: Bool) throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            let priorToken = try #require(pending.priorAuthority?.token.uuidString)
            defaults.set(priorToken, forKey: Self.tokenKey)
            defaults.arm([corrupt ? .corrupt : .refuse], forKey: Self.tokenKey)

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(promoting(pending), activeTokenKey: Self.tokenKey)
            }

            #expect(defaults.data(forKey: Self.key) == original)
            #expect(defaults.string(forKey: Self.tokenKey) == priorToken)
            #expect(store.load()?.checkpoint == pending.checkpoint)
            #expect(store.load()?.activeAuthority == nil)
        }
    }

    @Test("Successful active publication replaces both authority and its token mirror")
    func successfulPromotionPersistsEnvelopeAndToken() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            defaults.set(pending.priorAuthority?.token.uuidString, forKey: Self.tokenKey)
            let active = promoting(pending)

            try store.save(active, activeTokenKey: Self.tokenKey)

            #expect(ProfileAuthorityEnvelopeStore(defaults: defaults, key: Self.key).load() == active)
            #expect(defaults.string(forKey: Self.tokenKey) == active.token.uuidString)
        }
    }

    @Test("Active promotion writes its token mirror before publishing the envelope")
    func tokenMirrorPrecedesEnvelopePublication() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            defaults.set(pending.priorAuthority?.token.uuidString, forKey: Self.tokenKey)
            defaults.arm([], forKey: Self.tokenKey)
            let active = promoting(pending)

            try store.save(active, activeTokenKey: Self.tokenKey)

            #expect(defaults.attemptedWriteKeys == [Self.tokenKey, Self.key])
            #expect(store.load() == active)
            #expect(defaults.string(forKey: Self.tokenKey) == active.token.uuidString)
        }
    }

    @Test("Interruption immediately after the token write retains pending Focus recovery")
    func interruptionAfterTokenWritePreservesPendingRecovery() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            let priorToken = try #require(pending.priorAuthority?.token.uuidString)
            defaults.set(priorToken, forKey: Self.tokenKey)
            defaults.interruptAfterWriting(Self.tokenKey)

            // Freeze mutations at the write boundary. The call continues and
            // detects that rollback cannot write, but the stored state models
            // interruption before envelope publication, not crash/fsync durability.
            #expect(throws: ProfileAuthorityPersistenceError.rollbackNotVerified) {
                try store.save(promoting(pending), activeTokenKey: Self.tokenKey)
            }

            #expect(defaults.mutationsInterrupted)
            #expect(defaults.attemptedWriteKeys.first == Self.tokenKey)
            #expect(defaults.string(forKey: Self.tokenKey) == pending.token.uuidString)
            #expect(defaults.string(forKey: Self.tokenKey) != priorToken)
            #expect(defaults.data(forKey: Self.key) == original)
            let recovered = ProfileAuthorityEnvelopeStore(defaults: defaults, key: Self.key).load()
            #expect(recovered == pending)
            #expect(recovered?.phase == .pendingFocus)
            #expect(recovered?.checkpoint == pending.checkpoint)
            #expect(recovered?.priorAuthority == pending.priorAuthority)
            #expect(recovered?.activeAuthority == nil)
        }
    }

    @Test("Token rollback restores an originally absent mirror")
    func rejectedFirstTokenWriteRestoresAbsence() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            #expect(defaults.object(forKey: Self.tokenKey) == nil)
            defaults.arm([.corrupt], forKey: Self.tokenKey)

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(promoting(pending), activeTokenKey: Self.tokenKey)
            }

            #expect(defaults.data(forKey: Self.key) == original)
            #expect(defaults.object(forKey: Self.tokenKey) == nil)
            #expect(defaults.removalAttempts == 1)
            #expect(store.load() == pending)
        }
    }

    @Test("The token mirror cannot overwrite the authority key")
    func collidingTokenKeyIsRejectedBeforeWriting() throws {
        try withDefaults { defaults, store in
            let pending = makePending()
            try store.save(pending)
            let original = try #require(defaults.data(forKey: Self.key))
            defaults.arm([])

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(promoting(pending), activeTokenKey: Self.key)
            }

            #expect(defaults.writeAttempts == 0)
            #expect(defaults.data(forKey: Self.key) == original)
        }
    }

    @Test("A pending envelope cannot publish an active token mirror")
    func pendingEnvelopeRejectsTokenPublicationBeforeWriting() throws {
        try withDefaults { defaults, store in
            let prior = ProfileAuthorityEnvelope(active: makePriorAuthority())
            try store.save(prior)
            let original = try #require(defaults.data(forKey: Self.key))
            defaults.set(prior.token.uuidString, forKey: Self.tokenKey)
            defaults.arm([], forKey: Self.tokenKey)

            #expect(throws: ProfileAuthorityPersistenceError.writeNotVerified) {
                try store.save(makePending(), activeTokenKey: Self.tokenKey)
            }

            #expect(defaults.writeAttempts == 0)
            #expect(defaults.removalAttempts == 0)
            #expect(defaults.data(forKey: Self.key) == original)
            #expect(defaults.string(forKey: Self.tokenKey) == prior.token.uuidString)
        }
    }

    @Test("Authority persistence failures require user review", arguments: [
        ProfileAuthorityPersistenceError.encodingFailed,
        .archiveTooLarge,
        .writeNotVerified,
        .rollbackNotVerified,
    ])
    func persistenceFailuresRequireUserReview(_ error: ProfileAuthorityPersistenceError) {
        #expect(IntentCommandFailurePolicy.requiresUserReview(error))
    }

    private static let key = "profileAuthority"
    private static let tokenKey = "activeProfileToken"

    private func withDefaults(
        _ body: (FaultInjectingAuthorityDefaults, ProfileAuthorityEnvelopeStore) throws -> Void
    ) throws {
        let suiteName = "BarlineTests.ProfileAuthority.\(UUID().uuidString)"
        let defaults = try #require(FaultInjectingAuthorityDefaults(suiteName: suiteName, targetKey: Self.key))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults, ProfileAuthorityEnvelopeStore(defaults: defaults, key: Self.key))
    }

    private func makePriorAuthority() -> ProfileActiveAuthority {
        let profile = BarlineProfile(name: "Original")
        return ProfileActiveAuthority(
            profileID: profile.id,
            token: UUID(),
            presentation: profile.resolvedPresentation(using: nil)
        )
    }

    private func makePending(profile: BarlineProfile = BarlineProfile(name: "Focus")) -> ProfileAuthorityEnvelope {
        let prior = makePriorAuthority()
        let display = MenuBarDisplayID("fixture-display")
        let item = MenuBarItemDescriptor(
            id: MenuBarItemID(bundleIdentifier: "test.fixture", accessibilityIdentifier: "item"),
            section: .hidden,
            order: 0,
            displayID: display
        )
        let checkpoint = MenuBarWorkspaceCheckpoint(
            snapshot: MenuBarSnapshot(
                generation: 7,
                capturedAt: Date(timeIntervalSince1970: 1),
                items: [item],
                displayIDs: [display],
                activeSpaceIsValid: true
            ),
            activeProfileID: prior.profileID,
            activeDisplayID: display,
            workspace: ProfileWorkspaceState(profile: BarlineProfile(name: "Original"))
        )
        return ProfileAuthorityEnvelope(
            pendingFocusProfile: profile,
            token: UUID(),
            presentation: profile.resolvedPresentation(using: nil),
            checkpoint: checkpoint,
            priorAuthority: prior
        )
    }

    private func promoting(_ pending: ProfileAuthorityEnvelope) -> ProfileAuthorityEnvelope {
        ProfileAuthorityEnvelope(active: ProfileActiveAuthority(
            profileID: pending.profileID,
            token: pending.token,
            presentation: pending.presentation
        ))
    }
}

/// Each instance belongs to one synchronous test and one unique defaults suite.
/// Faults affect only the selected authority/token key; rollback uses real storage.
private final class FaultInjectingAuthorityDefaults: UserDefaults, @unchecked Sendable {
    enum WriteFault {
        case refuse
        case corrupt
    }

    private let targetKey: String
    private var faultKey: String
    private var faults = [WriteFault]()
    private var interruptAfterKey: String?
    private(set) var writeAttempts = 0
    private(set) var removalAttempts = 0
    private(set) var attemptedWriteKeys = [String]()
    private(set) var mutationsInterrupted = false

    init?(suiteName: String, targetKey: String) {
        self.targetKey = targetKey
        faultKey = targetKey
        super.init(suiteName: suiteName)
    }

    func arm(_ faults: [WriteFault], forKey key: String? = nil) {
        self.faults = faults
        faultKey = key ?? targetKey
        writeAttempts = 0
        removalAttempts = 0
        attemptedWriteKeys = []
        interruptAfterKey = nil
        mutationsInterrupted = false
    }

    func interruptAfterWriting(_ key: String) {
        arm([], forKey: key)
        interruptAfterKey = key
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName == targetKey || defaultName == faultKey else {
            super.set(value, forKey: defaultName)
            return
        }
        writeAttempts += 1
        attemptedWriteKeys.append(defaultName)
        guard !mutationsInterrupted else { return }
        defer {
            if defaultName == interruptAfterKey {
                mutationsInterrupted = true
            }
        }
        guard defaultName == faultKey, !faults.isEmpty else {
            super.set(value, forKey: defaultName)
            return
        }
        switch faults.removeFirst() {
        case .refuse:
            return
        case .corrupt:
            super.set(Data("invalid-authority".utf8), forKey: defaultName)
        }
    }

    override func removeObject(forKey defaultName: String) {
        if defaultName == targetKey || defaultName == faultKey {
            removalAttempts += 1
            guard !mutationsInterrupted else { return }
        }
        super.removeObject(forKey: defaultName)
    }
}
