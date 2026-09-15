@testable import BarlineCore
import Testing

@Suite("Temporary reveal ownership")
struct TemporaryRevealLedgerTests {
    private let item = MenuBarItemID(bundleIdentifier: "com.example.item", title: "Item")

    @Test("Overlapping reveals stay visible until every owner ends")
    func referenceCounting() {
        let one = TemporaryRevealLedger().beginning(item)
        let two = one.beginning(item)
        let remaining = two.ending(item)
        let finished = remaining?.ending(item)

        #expect(one.visibleItemIDs == [item])
        #expect(two.visibleItemIDs == [item])
        #expect(remaining?.visibleItemIDs == [item])
        #expect(finished?.visibleItemIDs.isEmpty == true)
    }

    @Test("Ending an unowned reveal is a no-op signal")
    func unknownEnd() {
        #expect(TemporaryRevealLedger().ending(item) == nil)
    }

    @Test("An uncommitted candidate cannot mutate accepted ownership")
    func candidateIsolation() {
        let accepted = TemporaryRevealLedger().beginning(item)
        _ = accepted.ending(item)
        #expect(accepted.visibleItemIDs == [item])
    }
}
