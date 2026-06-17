import Foundation

/// Pure token / cost aggregation helpers — no business logic.
enum TokenCalculator {
    static func aggregateTokens(_ requests: [ParsedRequest]) -> TokenBreakdown {
        var input = 0, output = 0, reasoning = 0, creation = 0, read = 0, eph1h = 0, eph5m = 0
        var contextWindow: Int?
        for r in requests {
            input += r.tokens.inputTokens
            output += r.tokens.outputTokens
            reasoning += r.tokens.reasoningOutputTokens
            creation += r.tokens.cacheCreationInputTokens
            read += r.tokens.cacheReadInputTokens
            eph1h += r.tokens.cacheCreationEphemeral1h
            eph5m += r.tokens.cacheCreationEphemeral5m
            contextWindow = max(contextWindow, r.tokens.contextWindow)
        }
        return TokenBreakdown(
            inputTokens: input, outputTokens: output,
            reasoningOutputTokens: reasoning,
            cacheCreationInputTokens: creation, cacheReadInputTokens: read,
            cacheCreationEphemeral1h: eph1h, cacheCreationEphemeral5m: eph5m,
            contextWindow: contextWindow
        )
    }

    /// Element-wise sum across pre-computed `TokenBreakdown` values.
    /// Mirror of `aggregateCosts(_:)`. Used by the sub-agent token
    /// rollup path (`Turn.aggregateTokensIncludingSubAgents` etc.) —
    /// callers already have `TokenBreakdown` values rather than
    /// `ParsedRequest`s, so going through the request overload would
    /// require a synthetic ParsedRequest.
    static func aggregateTokens(_ tokens: [TokenBreakdown]) -> TokenBreakdown {
        var input = 0, output = 0, reasoning = 0, creation = 0, read = 0, eph1h = 0, eph5m = 0
        var contextWindow: Int?
        for t in tokens {
            input += t.inputTokens
            output += t.outputTokens
            reasoning += t.reasoningOutputTokens
            creation += t.cacheCreationInputTokens
            read += t.cacheReadInputTokens
            eph1h += t.cacheCreationEphemeral1h
            eph5m += t.cacheCreationEphemeral5m
            contextWindow = max(contextWindow, t.contextWindow)
        }
        return TokenBreakdown(
            inputTokens: input, outputTokens: output,
            reasoningOutputTokens: reasoning,
            cacheCreationInputTokens: creation, cacheReadInputTokens: read,
            cacheCreationEphemeral1h: eph1h, cacheCreationEphemeral5m: eph5m,
            contextWindow: contextWindow
        )
    }

    static func aggregateCosts(_ costs: [CostBreakdown?]) -> CostBreakdown {
        var i = 0.0, o = 0.0, c1h = 0.0, c5m = 0.0, cr = 0.0
        for cost in costs.compactMap({ $0 }) {
            i += cost.inputCostUSD; o += cost.outputCostUSD
            c1h += cost.cacheCreate1hCostUSD; c5m += cost.cacheCreate5mCostUSD
            cr += cost.cacheReadCostUSD
        }
        return CostBreakdown(inputCostUSD: i, outputCostUSD: o,
                             cacheCreate1hCostUSD: c1h, cacheCreate5mCostUSD: c5m, cacheReadCostUSD: cr)
    }

    private static func max(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): return Swift.max(lhs, rhs)
        case (.some(let lhs), .none): return lhs
        case (.none, .some(let rhs)): return rhs
        case (.none, .none): return nil
        }
    }
}
