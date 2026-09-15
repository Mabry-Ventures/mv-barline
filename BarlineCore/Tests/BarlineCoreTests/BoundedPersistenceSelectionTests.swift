@testable import BarlineCore
import Foundation
import Testing

@Suite("Bounded persistence selection")
struct BoundedPersistenceSelectionTests {
    @Test("Optional oversized values are skipped while later values remain eligible")
    func skipsOptionalOversizedValues() throws {
        let result = try BoundedPersistenceSelection.select(
            from: ["hidden", String(repeating: "x", count: 1000), "visible"],
            requiredIndices: [0],
            maximumCount: 3,
            maximumBytes: 32,
            encode: { try JSONEncoder().encode($0) }
        )

        #expect(result.elements == ["hidden", "visible"])
        #expect(result.data.count <= 32)
    }

    @Test("A required oversized value fails before state can be committed")
    func rejectsRequiredOversizedValue() {
        #expect(throws: BoundedPersistenceSelectionError.requiredValueDoesNotFit) {
            try BoundedPersistenceSelection.select(
                from: [String(repeating: "x", count: 1000)],
                requiredIndices: [0],
                maximumCount: 1,
                maximumBytes: 32,
                encode: { try JSONEncoder().encode($0) }
            )
        }
    }

    @Test("Required values beyond the count bound fail explicitly")
    func rejectsRequiredValueBeyondCountBound() {
        #expect(throws: BoundedPersistenceSelectionError.requiredValueDoesNotFit) {
            try BoundedPersistenceSelection.select(
                from: ["first", "required-a", "required-b"],
                requiredIndices: [1, 2],
                maximumCount: 1,
                maximumBytes: 128,
                encode: { try JSONEncoder().encode($0) }
            )
        }
    }

    @Test("A late required value evicts earlier optional values at the count bound")
    func requiredValueWinsCapacity() throws {
        let result = try BoundedPersistenceSelection.select(
            from: ["optional-a", "optional-b", "changed-visible"],
            requiredIndices: [2],
            maximumCount: 2,
            maximumBytes: 128,
            encode: { try JSONEncoder().encode($0) }
        )

        #expect(result.elements == ["optional-a", "changed-visible"])
    }

    @Test("A late required value reserves byte capacity before optional values")
    func requiredValueWinsByteCapacity() throws {
        let candidates = ["optional-a", "optional-b", "required"]
        let maximumBytes = try JSONEncoder().encode(["optional-a", "required"]).count
        let result = try BoundedPersistenceSelection.select(
            from: candidates,
            requiredIndices: [2],
            maximumCount: 3,
            maximumBytes: maximumBytes,
            encode: { try JSONEncoder().encode($0) }
        )

        #expect(result.elements == ["optional-a", "required"])
        #expect(result.data.count <= maximumBytes)
    }

    @Test("An invalid required index fails explicitly")
    func rejectsInvalidRequiredIndex() {
        #expect(throws: BoundedPersistenceSelectionError.invalidRequiredIndex) {
            try BoundedPersistenceSelection.select(
                from: ["only"],
                requiredIndices: [1],
                maximumCount: 1,
                maximumBytes: 128,
                encode: { try JSONEncoder().encode($0) }
            )
        }
    }
}
