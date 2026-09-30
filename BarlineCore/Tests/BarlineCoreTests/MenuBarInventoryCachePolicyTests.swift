//
//  MenuBarInventoryCachePolicyTests.swift
//  Barline
//

@testable import BarlineCore
import Testing

struct MenuBarInventoryCachePolicyTests {
    @Test func slowInventoryStillHasItsFullReuseWindowAfterCompletion() {
        let lifetime: UInt64 = 100_000_000
        let startedAt: UInt64 = 1_000_000_000
        let completedAt = startedAt + 250_000_000

        // The old start-time stamp expired before this inventory returned.
        #expect(!MenuBarInventoryCachePolicy.isReusable(
            completedAt: startedAt, now: completedAt, lifetimeNanoseconds: lifetime
        ))
        #expect(MenuBarInventoryCachePolicy.isReusable(
            completedAt: completedAt, now: completedAt, lifetimeNanoseconds: lifetime
        ))
        #expect(MenuBarInventoryCachePolicy.isReusable(
            completedAt: completedAt, now: completedAt + lifetime - 1, lifetimeNanoseconds: lifetime
        ))
        #expect(!MenuBarInventoryCachePolicy.isReusable(
            completedAt: completedAt, now: completedAt + lifetime, lifetimeNanoseconds: lifetime
        ))
    }

    @Test func regressedUptimeAndZeroLifetimeCannotReuseAnInventory() {
        #expect(!MenuBarInventoryCachePolicy.isReusable(
            completedAt: 10, now: 9, lifetimeNanoseconds: 100
        ))
        #expect(!MenuBarInventoryCachePolicy.isReusable(
            completedAt: 10, now: 10, lifetimeNanoseconds: 0
        ))
    }

    @Test func upperUptimeBoundaryUsesSubtractionWithoutOverflow() {
        #expect(MenuBarInventoryCachePolicy.isReusable(
            completedAt: UInt64.max - 1, now: UInt64.max, lifetimeNanoseconds: 2
        ))
        #expect(!MenuBarInventoryCachePolicy.isReusable(
            completedAt: UInt64.max - 1, now: UInt64.max, lifetimeNanoseconds: 1
        ))
    }
}
