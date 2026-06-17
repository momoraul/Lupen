import Foundation

struct TokenBreakdown: Sendable, Codable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationEphemeral1h: Int
    let cacheCreationEphemeral5m: Int
    let contextWindow: Int?

    init(
        inputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int = 0,
        cacheCreationInputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationEphemeral1h: Int,
        cacheCreationEphemeral5m: Int,
        contextWindow: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationEphemeral1h = cacheCreationEphemeral1h
        self.cacheCreationEphemeral5m = cacheCreationEphemeral5m
        self.contextWindow = contextWindow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        self.outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        self.reasoningOutputTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
        self.cacheCreationInputTokens = try c.decode(Int.self, forKey: .cacheCreationInputTokens)
        self.cacheReadInputTokens = try c.decode(Int.self, forKey: .cacheReadInputTokens)
        self.cacheCreationEphemeral1h = try c.decode(Int.self, forKey: .cacheCreationEphemeral1h)
        self.cacheCreationEphemeral5m = try c.decode(Int.self, forKey: .cacheCreationEphemeral5m)
        self.contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
    }

    var totalContextTokens: Int {
        inputTokens + outputTokens + reasoningOutputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    var effectiveTokens: Int {
        inputTokens + outputTokens + reasoningOutputTokens
    }

    var cacheEfficiencyRatio: Double? {
        let total = cacheCreationInputTokens + cacheReadInputTokens + inputTokens
        guard total > 0 else { return nil }
        return Double(cacheReadInputTokens) / Double(total)
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, reasoningOutputTokens, cacheCreationInputTokens,
             cacheReadInputTokens, cacheCreationEphemeral1h, cacheCreationEphemeral5m,
             contextWindow
    }
}
