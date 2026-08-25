import Foundation

/// Consumption, every field nullable.
///
/// A `null` `contextWindowTotal` means unknown, and a client must not draw a fraction against a
/// denominator it does not have — which is why the nulls are written rather than omitted.
public struct UsageDTO: Codable, Sendable, Equatable {
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var thinkingTokens: Int?
    public var contextWindowUsed: Int?
    public var contextWindowTotal: Int?
    public var costUSD: Double?

    public init(
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        thinkingTokens: Int? = nil,
        contextWindowUsed: Int? = nil,
        contextWindowTotal: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.thinkingTokens = thinkingTokens
        self.contextWindowUsed = contextWindowUsed
        self.contextWindowTotal = contextWindowTotal
        self.costUSD = costUSD
    }

    enum CodingKeys: String, CodingKey {
        case model, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens
        case thinkingTokens, contextWindowUsed, contextWindowTotal, costUSD
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeExplicit(model, forKey: .model)
        try container.encodeExplicit(inputTokens, forKey: .inputTokens)
        try container.encodeExplicit(outputTokens, forKey: .outputTokens)
        try container.encodeExplicit(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encodeExplicit(cacheWriteTokens, forKey: .cacheWriteTokens)
        try container.encodeExplicit(thinkingTokens, forKey: .thinkingTokens)
        try container.encodeExplicit(contextWindowUsed, forKey: .contextWindowUsed)
        try container.encodeExplicit(contextWindowTotal, forKey: .contextWindowTotal)
        try container.encodeExplicit(costUSD, forKey: .costUSD)
    }
}
