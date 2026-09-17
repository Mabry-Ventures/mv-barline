import ArrangementLabCore
import Testing

struct VisibilityPolicyTests {
    @Test func singlePublisherSupportsItemAssignment() {
        let receipt = makeReceipt(tokens: ["solo"], kind: "single")
        #expect(FixtureVisibilityPolicy.granularity(for: "solo", in: receipt) == .item)
        #expect(FixtureVisibilityPolicy.acceptsAssignment(tokens: ["solo"], in: receipt))
    }

    @Test func multiPublisherRequiresWholeApplicationGroup() {
        let receipt = makeReceipt(tokens: ["alpha", "beta", "gamma"], kind: "multi")
        #expect(FixtureVisibilityPolicy.granularity(for: "beta", in: receipt) == .applicationGroup)
        #expect(!FixtureVisibilityPolicy.acceptsAssignment(tokens: ["beta"], in: receipt))
        #expect(FixtureVisibilityPolicy.acceptsAssignment(
            tokens: ["alpha", "beta", "gamma"],
            in: receipt
        ))
    }

    @Test func localShelfOrderDoesNotMutateNativeOrderValue() {
        let native = ["alpha", "beta", "gamma"]
        let shelf = LocalShelfOrder.moving(token: "gamma", to: 0, in: native)
        #expect(shelf == ["gamma", "alpha", "beta"])
        #expect(native == ["alpha", "beta", "gamma"])
    }

    private func makeReceipt(tokens: [String], kind: String) -> FixtureReceipt {
        FixtureReceipt(
            session: "visibility-test",
            processIdentifier: 1,
            bundleIdentifier: "com.example.\(kind)",
            publisherKind: kind,
            variant: .uniqueLabels,
            sequence: 1,
            items: tokens.enumerated().map { index, token in
                FixtureItemReceipt(
                    token: token,
                    generation: 1,
                    autosaveName: token,
                    creationOrdinal: index,
                    frame: LabRect(x: Double(index), y: 0, width: 1, height: 1),
                    activations: 0
                )
            }
        )
    }
}
