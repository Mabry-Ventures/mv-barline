//
//  MenuBarInventoryCachePolicy.swift
//  Barline
//

/// Reuse is measured from a successful inventory's completion, independently
/// of the snapshot's observation timestamp and generation.
public enum MenuBarInventoryCachePolicy {
    public static func isReusable(
        completedAt: UInt64,
        now: UInt64,
        lifetimeNanoseconds: UInt64
    ) -> Bool {
        guard now >= completedAt else { return false }
        return now - completedAt < lifetimeNanoseconds
    }
}
