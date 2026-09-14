@testable import BarlineCore
import Testing

struct GoldenGateAXActivationPolicyTests {
    @Test func successfulActionIsDelivered() {
        #expect(GoldenGateAXActivationPolicy.disposition(forAXError: 0) == .delivered)
    }

    @Test func cannotCompleteIsNeverRetried() {
        #expect(
            GoldenGateAXActivationPolicy.disposition(forAXError: -25204) ==
                .deliveredIndeterminately
        )
    }

    @Test func unsupportedAndInvalidActionsFail() {
        #expect(GoldenGateAXActivationPolicy.disposition(forAXError: -25206) == .failed)
        #expect(GoldenGateAXActivationPolicy.disposition(forAXError: -25202) == .failed)
    }
}
