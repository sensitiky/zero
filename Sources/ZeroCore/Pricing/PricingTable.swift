import Foundation

/// Prices for providers that do not report their own cost.
///
/// A fallback, not the source of truth. Claude Code reports `total_cost_usd` and that figure always
/// wins — an estimate that disagrees with the provider's own number is worse than no estimate,
/// because it looks authoritative.
///
/// Baked into the bundle and updated with releases rather than fetched: the app needs no network for
/// anything else, and adding an outbound request for a price list is not a trade worth making.
public struct PricingTable: Sendable {
    /// Prices per million tokens.
    public struct Entry: Sendable, Codable, Equatable {
        /// Matched as a prefix of the model name, so `claude-sonnet-5` covers its dated variants.
        public let match: String
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheWrite: Double
        /// Total context window in tokens. Without it a usage ring has no denominator, and inventing
        /// one would draw a confident fraction of a number nobody knows.
        public let contextWindow: Int?

        public init(
            match: String,
            input: Double,
            output: Double,
            cacheRead: Double,
            cacheWrite: Double,
            contextWindow: Int? = nil
        ) {
            self.match = match
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.contextWindow = contextWindow
        }
    }

    private struct Document: Codable {
        let version: String
        let models: [Entry]
    }

    public let version: String
    private let entries: [Entry]

    public init(version: String, entries: [Entry]) {
        self.version = version
        self.entries = entries
    }

    /// The table shipped with the app. Empty if the resource is missing, which yields unknown costs
    /// rather than wrong ones.
    /// Cached once per process. A caller that stores `PricingTable.bundled()` as a struct property
    /// with a default-value expression — as `UsageIndicator` did — re-evaluates that expression on
    /// every construction, and every construction is every re-render. Without this cache that reads
    /// the bundle off disk and runs it through `JSONDecoder`, synchronously, on the main thread, on
    /// every keystroke a sibling text field produced — the real input-lag culprit, worse than the
    /// markdown parsing this was mistaken for. `static let` is lazy and thread-safe by construction,
    /// so this loads once regardless of how many views call `bundled()`.
    private static let cached: PricingTable = {
        guard let url = Bundle.module.url(forResource: "pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            return PricingTable(version: "unavailable", entries: [])
        }
        return PricingTable(version: document.version, entries: document.models)
    }()

    public static func bundled() -> PricingTable { cached }

    public func entry(forModel model: String) -> Entry? {
        // Longest match first, so a specific entry beats a broader one.
        entries
            .filter { model.hasPrefix($0.match) }
            .max { $0.match.count < $1.match.count }
    }

    /// The cost of a usage record, or nil when it cannot be known.
    ///
    /// Returns nil for an unpriced model instead of zero (FR-30): a zero reads as "this was free",
    /// which is a different and wrong claim from "we do not know".
    public func cost(of usage: Usage) -> Double? {
        if let reported = usage.costUSD { return reported }
        guard let model = usage.model, let entry = entry(forModel: model) else { return nil }
        func perMillion(_ tokens: Int?, _ rate: Double) -> Double {
            Double(tokens ?? 0) / 1_000_000 * rate
        }
        return perMillion(usage.inputTokens, entry.input)
            + perMillion(usage.outputTokens, entry.output)
            + perMillion(usage.cacheReadTokens, entry.cacheRead)
            + perMillion(usage.cacheWriteTokens, entry.cacheWrite)
    }

    /// How much of the model's context the last turn used, as a fraction, or nil when unknowable.
    public func contextFraction(of usage: Usage) -> Double? {
        guard let tokens = usage.contextTokens,
              let model = usage.model,
              let window = entry(forModel: model)?.contextWindow,
              window > 0
        else { return nil }
        return min(1, Double(tokens) / Double(window))
    }
}
