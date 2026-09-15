import Foundation

public enum BoundedPersistenceSelectionError: Error, Equatable, Sendable {
    case invalidRequiredIndex
    case requiredValueDoesNotFit
}

/// Builds a deterministic bounded document without silently dropping values
/// that the caller requires for the transaction being committed.
public enum BoundedPersistenceSelection {
    public static func select<Element>(
        from candidates: [Element],
        requiredIndices: Set<Int>,
        maximumCount: Int,
        maximumBytes: Int,
        encode: ([Element]) throws -> Data
    ) throws -> (elements: [Element], data: Data) {
        guard requiredIndices.allSatisfy(candidates.indices.contains) else {
            throw BoundedPersistenceSelectionError.invalidRequiredIndex
        }
        var selectedIndices = Set<Int>()
        var selectedData = try encode([])
        let orderedIndices = requiredIndices.sorted() + candidates.indices.filter {
            !requiredIndices.contains($0)
        }
        for index in orderedIndices where candidates.indices.contains(index) {
            guard selectedIndices.count < maximumCount else {
                if requiredIndices.contains(index) {
                    throw BoundedPersistenceSelectionError.requiredValueDoesNotFit
                }
                continue
            }
            let proposedIndices = selectedIndices.union([index])
            let proposed = candidates.indices.compactMap {
                proposedIndices.contains($0) ? candidates[$0] : nil
            }
            let data = try encode(proposed)
            if data.count <= maximumBytes {
                selectedIndices = proposedIndices
                selectedData = data
            } else if requiredIndices.contains(index) {
                throw BoundedPersistenceSelectionError.requiredValueDoesNotFit
            }
        }
        guard selectedData.count <= maximumBytes else {
            throw BoundedPersistenceSelectionError.requiredValueDoesNotFit
        }
        let selected = candidates.indices.compactMap {
            selectedIndices.contains($0) ? candidates[$0] : nil
        }
        return (selected, selectedData)
    }
}
