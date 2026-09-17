@testable import BarlineCore
import Foundation
import Testing

struct VerifiedUserDefaultsDataCommitTests {
    @Test
    func falseSynchronizeResultDoesNotRejectVerifiedValues() throws {
        let suiteName = "BarlineTests.VerifiedDefaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = Data("committed".utf8)
        let result = VerifiedUserDefaultsDataCommit.commit(
            ["layout": expected],
            to: defaults,
            synchronize: { false }
        )

        #expect(result)
        #expect(defaults.data(forKey: "layout") == expected)
    }

    @Test
    func commitsAllValuesAsOneVerifiedBoundary() throws {
        let suiteName = "BarlineTests.VerifiedDefaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let values = [
            "layout": Data("layout-v2".utf8),
            "inventory": Data("inventory-v2".utf8),
        ]

        #expect(VerifiedUserDefaultsDataCommit.commit(values, to: defaults))
        #expect(defaults.data(forKey: "layout") == values["layout"])
        #expect(defaults.data(forKey: "inventory") == values["inventory"])
    }
}
