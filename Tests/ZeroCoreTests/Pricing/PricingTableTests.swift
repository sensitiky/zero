import Foundation
import Testing

@testable import ZeroCore

@Suite("PricingTable")
struct PricingTableTests {
    @Test("the bundled table loads")
    func bundledTableLoads() {
        let table = PricingTable.bundled()
        #expect(table.version != "unavailable")
        #expect(table.entry(forModel: "claude-sonnet-5") != nil)
    }

    @Test("a dated model variant matches its family")
    func datedVariantMatches() {
        let table = PricingTable.bundled()
        #expect(table.entry(forModel: "claude-haiku-4-5-20251001")?.match == "claude-haiku-4-5")
    }

    @Test("a provider's own cost always wins over the table")
    func reportedCostWins() {
        let table = PricingTable.bundled()
        let usage = Usage(model: "claude-sonnet-5", inputTokens: 1_000_000, costUSD: 0.42)
        // An estimate that contradicts the provider's own figure is worse than no estimate: it looks
        // authoritative and it is wrong.
        #expect(table.cost(of: usage) == 0.42)
    }

    @Test("an unpriced model yields unknown, not zero")
    func unpricedModelIsUnknown() {
        let table = PricingTable.bundled()
        let usage = Usage(model: "some-model-we-have-never-heard-of", inputTokens: 1_000_000)
        // Zero would read as "this was free", which is a different claim from "we do not know".
        #expect(table.cost(of: usage) == nil)
    }

    @Test("a usage record with no model at all yields unknown")
    func missingModelIsUnknown() {
        #expect(PricingTable.bundled().cost(of: Usage(inputTokens: 5000)) == nil)
    }

    @Test("token categories are priced separately")
    func categoriesPricedSeparately() {
        let table = PricingTable(
            version: "test",
            entries: [.init(match: "m", input: 10, output: 100, cacheRead: 1, cacheWrite: 20)]
        )
        let usage = Usage(
            model: "m",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            cacheWriteTokens: 1_000_000
        )
        #expect(table.cost(of: usage) == 131)
    }
}
