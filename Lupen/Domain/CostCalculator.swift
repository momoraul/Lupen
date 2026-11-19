import Foundation

enum CostCalculator {
    private static let perMillion = 1_000_000.0
    nonisolated(unsafe) private static var loggedUnknownModels: Set<String> = []
    private static let loggedUnknownModelsLock = NSLock()

    static func calculateCost(
        tokens: TokenBreakdown,
        model: String?,
        speed: String?,
        forceLongContext: Bool = false
    ) -> CostBreakdown? {
        guard let model else { return nil }
        if PricingTable.isSyntheticModel(model) { return nil }
        guard let baseRates = PricingTable.rates(for: model) else {
            // Background-safe routing — `calculateCost` is invoked from
            // the per-file concurrent parse worker before results land
            // back on the main actor.
            logUnknownModelIfNew(model)
            return nil
        }
        let rates = baseRates.adjustedForPromptInputTokens(
            promptInputTokenCount(tokens),
            forceLongContext: forceLongContext
        )

        let isFast = speed == "fast"
        let inputRate: Double
        let outputRate: Double

        if isFast {
            guard let fi = rates.fastInputPerMTok, let fo = rates.fastOutputPerMTok else {
                LoggerService.shared.logFromAnyThread(
                    .warning,
                    "Fast pricing unavailable for: \(model)",
                    context: "CostCalculator"
                )
                return nil
            }
            inputRate = fi
            outputRate = fo
        } else {
            inputRate = rates.inputPerMTok
            outputRate = rates.outputPerMTok
        }

        return CostBreakdown(
            inputCostUSD: Double(tokens.inputTokens) / perMillion * inputRate,
            outputCostUSD: Double(tokens.outputTokens + tokens.reasoningOutputTokens) / perMillion * outputRate,
            cacheCreate1hCostUSD: Double(tokens.cacheCreationEphemeral1h) / perMillion * rates.cacheWrite1hPerMTok,
            cacheCreate5mCostUSD: Double(tokens.cacheCreationEphemeral5m) / perMillion * rates.cacheWrite5mPerMTok,
            cacheReadCostUSD: Double(tokens.cacheReadInputTokens) / perMillion * rates.cacheReadPerMTok
        )
    }

    static func calculateCosts(for requests: [ParsedRequest]) -> [String: CostBreakdown?] {
        var longContextModels: Set<String> = []
        for request in requests {
            guard let model = request.model,
                  let rates = PricingTable.rates(for: model),
                  rates.longContextAppliesSessionWide,
                  rates.shouldUseLongContext(forPromptInputTokens: promptInputTokenCount(request.tokens)) else {
                continue
            }
            longContextModels.insert(model)
        }

        var costs: [String: CostBreakdown?] = [:]
        for request in requests {
            let forceLongContext = request.model.map { longContextModels.contains($0) } ?? false
            costs[request.id] = calculateCost(
                tokens: request.tokens,
                model: request.model,
                speed: request.speed,
                forceLongContext: forceLongContext
            )
        }
        return costs
    }

    /// Mirrors `GroundTruthCalculator.computeCost`: the split ephemeral
    /// counts win when present, the legacy lump field is the fallback.
    /// 42 rows in local logs report a 0 lump beside non-zero split counts
    /// (one pair off by 937,480 tokens), so reading the lump alone
    /// understates the prompt. Harmless until Haiku 5.5 — the first Claude
    /// model priced by prompt length — made this value decide a rate.
    private static func promptInputTokenCount(_ tokens: TokenBreakdown) -> Int {
        let cacheCreation = (tokens.cacheCreationEphemeral1h > 0 || tokens.cacheCreationEphemeral5m > 0)
            ? tokens.cacheCreationEphemeral1h + tokens.cacheCreationEphemeral5m
            : tokens.cacheCreationInputTokens
        return tokens.inputTokens + cacheCreation + tokens.cacheReadInputTokens
    }

    private static func logUnknownModelIfNew(_ model: String) {
        loggedUnknownModelsLock.lock()
        let shouldLog = loggedUnknownModels.insert(model).inserted
        loggedUnknownModelsLock.unlock()
        guard shouldLog else { return }
        LoggerService.shared.logFromAnyThread(
            .warning,
            "Unknown model: \(model)",
            context: "CostCalculator"
        )
    }

    static func resetUnknownModelLogCacheForTesting() {
        loggedUnknownModelsLock.lock()
        loggedUnknownModels.removeAll()
        loggedUnknownModelsLock.unlock()
    }

    static func hasLoggedUnknownModelForTesting(_ model: String) -> Bool {
        loggedUnknownModelsLock.lock()
        defer { loggedUnknownModelsLock.unlock() }
        return loggedUnknownModels.contains(model)
    }
}
