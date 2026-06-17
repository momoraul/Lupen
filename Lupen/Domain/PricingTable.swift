import Foundation

struct ModelRates: Sendable {
    let inputPerMTok: Double
    let outputPerMTok: Double
    let cacheWrite5mPerMTok: Double
    let cacheWrite1hPerMTok: Double
    let cacheReadPerMTok: Double
    let fastInputPerMTok: Double?
    let fastOutputPerMTok: Double?
    let longContextInputThreshold: Int?
    let longContextInputMultiplier: Double
    let longContextOutputMultiplier: Double

    init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheWrite5mPerMTok: Double,
        cacheWrite1hPerMTok: Double,
        cacheReadPerMTok: Double,
        fastInputPerMTok: Double?,
        fastOutputPerMTok: Double?,
        longContextInputThreshold: Int? = nil,
        longContextInputMultiplier: Double = 1,
        longContextOutputMultiplier: Double = 1
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.fastInputPerMTok = fastInputPerMTok
        self.fastOutputPerMTok = fastOutputPerMTok
        self.longContextInputThreshold = longContextInputThreshold
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
    }

    func shouldUseLongContext(forPromptInputTokens promptInputTokens: Int) -> Bool {
        guard let threshold = longContextInputThreshold else { return false }
        return promptInputTokens > threshold
    }

    func adjustedForPromptInputTokens(
        _ promptInputTokens: Int,
        forceLongContext: Bool = false
    ) -> ModelRates {
        guard longContextInputThreshold != nil,
              forceLongContext || shouldUseLongContext(forPromptInputTokens: promptInputTokens) else {
            return self
        }
        return ModelRates(
            inputPerMTok: inputPerMTok * longContextInputMultiplier,
            outputPerMTok: outputPerMTok * longContextOutputMultiplier,
            cacheWrite5mPerMTok: cacheWrite5mPerMTok * longContextInputMultiplier,
            cacheWrite1hPerMTok: cacheWrite1hPerMTok * longContextInputMultiplier,
            cacheReadPerMTok: cacheReadPerMTok * longContextInputMultiplier,
            fastInputPerMTok: fastInputPerMTok.map { $0 * longContextInputMultiplier },
            fastOutputPerMTok: fastOutputPerMTok.map { $0 * longContextOutputMultiplier },
            longContextInputThreshold: longContextInputThreshold,
            longContextInputMultiplier: longContextInputMultiplier,
            longContextOutputMultiplier: longContextOutputMultiplier
        )
    }
}

/// Per-model pricing with a forward-compatibility fallback.
///
/// **Exact match**: when the model name is listed in `table`, those
/// rates are returned verbatim.
///
/// **Tier fallback**: when the model name isn't listed but matches a
/// `claude-{opus|sonnet|haiku}-` prefix, rates are borrowed from the
/// newest known model of that tier (per `newestByTier`). This keeps
/// cost tracking functional the moment Anthropic ships a new model SKU
/// — Lupen no longer silently drops the cost to $0 just because
/// the pricing table hasn't been updated yet.
///
/// Every tier fallback emits **one warning log per unique model name**
/// (deduplicated via `loggedFallbacks`) so the developer can see which
/// new SKUs are in the wild and needs explicit pricing + a bump to
/// `newestByTier`. The log only fires when pricing actually diverges
/// from a hand-written entry, not for every request.
///
/// Unknown non-Claude models still return nil — CostCalculator treats
/// that as "no cost recorded" which propagates through the pipeline
/// the same way it did before this change.
///
/// # Server tool fees — intentionally NOT tracked
///
/// Anthropic charges extra for some server-side tools beyond raw tokens:
///
///   - `web_search` server tool: **$10 / 1,000 requests**.
///   - `code_execution` tool (standalone): **$0.05 / container-hour**
///     (free when used alongside `web_search` / `web_fetch`; 1,550 free
///     hours/month per org).
///   - `web_fetch` / `bash` / `text_editor` / `computer_use`: no extra
///     fee — only the usual token cost.
///
/// We do **not** apply these per-call surcharges here because of an
/// empirical observation specific to Claude Code CLI (verified
/// 2026-04-21 against a live Lupen session JSONL):
///
///   - Claude Code's `WebSearch` / `WebFetch` tools are **client-side**
///     — the CLI process itself fetches the URL / runs the search and
///     injects results back as ordinary user-role content. Anthropic's
///     Messages API sees nothing tool-specific, so
///     `usage.server_tool_use.web_search_requests` stays 0 even across
///     hundreds of `WebSearch` tool_use blocks. The $10/1k fee simply
///     does not apply.
///
///   - The only way those counters become non-zero is if a caller uses
///     the Messages API directly (not Claude Code) and passes the beta
///     `web_search_20250305` / `web_fetch_20250910` server tools in the
///     `tools` array. Lupen's data source is Claude Code JSONL, so
///     we've never observed a non-zero server_tool_use count.
///
/// If Lupen ever ingests non-Claude-Code logs, or Claude Code
/// switches to the server-side web_search tool, we'll need to extend
/// `ModelRates` with `webSearchPerThousand` / `codeExecutionPerHour`
/// and fold them into `CostCalculator`. The JSONL already carries the
/// counters (`usage.server_tool_use.{web_search,web_fetch,code_execution}_requests`),
/// so the plumbing would be purely additive on the cost side — no new
/// parse work needed.
///
/// Sources:
///   - platform.claude.com/docs/en/about-claude/pricing#tool-use-pricing
///   - Live verification: see the "server_tool_use" Usage-tab field in
///     any Lupen session Detail pane — all zeros as of writing.
enum PricingTable {

    /// Monotonic pricing-table revision, stamped onto finalized request
    /// rows (`requests.pricing_version`) so a rates change triggers a
    /// background cost recompute instead of silent staleness (plan G7).
    /// Bump on ANY change to `table` or the fallback behavior.
    /// v2: claude-fable-5 + claude-opus-4-8 entries; fable tier fallback
    ///     (fable requests had been $0/unavailable — no tier prefix matched).
    static let version = 2

    // Logging routed through `LoggerService.shared.logFromAnyThread`
    // so the in-app Diagnostics window picks it up alongside the
    // Console.app subsystem/category match.

    private static let table: [String: ModelRates] = [
        // Cache rates follow Anthropic's standard multipliers on input:
        // write 5m = 1.25x, write 1h = 2x, read = 0.1x.
        "claude-fable-5": ModelRates(
            inputPerMTok: 10.00, outputPerMTok: 50.00,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20.00, cacheReadPerMTok: 1.00,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-opus-4-8": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-opus-4-7": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            // Fast mode is Opus 4.6 only per Anthropic docs
            // (platform.claude.com/docs/en/docs/about-claude/pricing — Fast mode
            // section). Claude Code's /fast toggle routes to 4.6, so 4.7
            // requests never carry `speed: "fast"`.
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-opus-4-6": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            fastInputPerMTok: 30.00, fastOutputPerMTok: 150.00
        ),
        "claude-opus-4-5": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        // Dated alias for claude-opus-4-5 — Anthropic ships immutable
        // SKUs alongside the rolling tag. Same rates; explicit entry
        // suppresses the tier-fallback warning observed Apr 2026.
        "claude-opus-4-5-20251101": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-opus-4-1": ModelRates(
            inputPerMTok: 15.00, outputPerMTok: 75.00,
            cacheWrite5mPerMTok: 18.75, cacheWrite1hPerMTok: 30.00, cacheReadPerMTok: 1.50,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-opus-4-20250514": ModelRates(
            inputPerMTok: 15.00, outputPerMTok: 75.00,
            cacheWrite5mPerMTok: 18.75, cacheWrite1hPerMTok: 30.00, cacheReadPerMTok: 1.50,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-sonnet-4-6": ModelRates(
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6.00, cacheReadPerMTok: 0.30,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-sonnet-4-5": ModelRates(
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6.00, cacheReadPerMTok: 0.30,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        // Dated alias for claude-sonnet-4-5 (immutable SKU).
        "claude-sonnet-4-5-20250929": ModelRates(
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6.00, cacheReadPerMTok: 0.30,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-sonnet-4-20250514": ModelRates(
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6.00, cacheReadPerMTok: 0.30,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-haiku-4-5": ModelRates(
            inputPerMTok: 1.00, outputPerMTok: 5.00,
            cacheWrite5mPerMTok: 1.25, cacheWrite1hPerMTok: 2.00, cacheReadPerMTok: 0.10,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        // Dated alias for claude-haiku-4-5 (immutable SKU).
        "claude-haiku-4-5-20251001": ModelRates(
            inputPerMTok: 1.00, outputPerMTok: 5.00,
            cacheWrite5mPerMTok: 1.25, cacheWrite1hPerMTok: 2.00, cacheReadPerMTok: 0.10,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-haiku-3-5": ModelRates(
            inputPerMTok: 0.80, outputPerMTok: 4.00,
            cacheWrite5mPerMTok: 1.00, cacheWrite1hPerMTok: 1.60, cacheReadPerMTok: 0.08,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-haiku-3": ModelRates(
            inputPerMTok: 0.25, outputPerMTok: 1.25,
            cacheWrite5mPerMTok: 0.30, cacheWrite1hPerMTok: 0.50, cacheReadPerMTok: 0.03,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-opus-3-20240229": ModelRates(
            inputPerMTok: 15.00, outputPerMTok: 75.00,
            cacheWrite5mPerMTok: 18.75, cacheWrite1hPerMTok: 30.00, cacheReadPerMTok: 1.50,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-sonnet-3-7": ModelRates(
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6.00, cacheReadPerMTok: 0.30,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-sonnet-3-5-20241022": ModelRates(
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6.00, cacheReadPerMTok: 0.30,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        // OpenAI API pricing, standard processing, checked 2026-05-28:
        // developers.openai.com/api/docs/pricing
        // developers.openai.com/api/docs/models/gpt-5.2-codex
        // developers.openai.com/api/docs/models/gpt-5.1-codex
        // developers.openai.com/api/docs/models/gpt-5.1-codex-max
        // developers.openai.com/api/docs/models/gpt-5-codex
        // developers.openai.com/api/docs/models/gpt-5.1-codex-mini
        // developers.openai.com/api/docs/models/codex-mini-latest
        // developers.openai.com/api/docs/models/gpt-5
        // developers.openai.com/api/docs/models/gpt-5.1
        // developers.openai.com/api/docs/models/gpt-5.2
        // developers.openai.com/api/docs/models/gpt-5.4
        // developers.openai.com/api/docs/models/gpt-5.5
        // Codex local JSONL reports cached input separately; map OpenAI's
        // "cached input" rate to Lupen's cache-read bucket.
        "gpt-5": openAIRates(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5.1": openAIRates(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5.2": openAIRates(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.3-codex": openAIRates(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.2-codex": openAIRates(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.1-codex-max": openAIRates(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5.1-codex": openAIRates(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5-codex": openAIRates(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5.1-codex-mini": openAIRates(input: 0.25, cachedInput: 0.025, output: 2.00),
        "codex-mini-latest": openAIRates(input: 1.50, cachedInput: 0.375, output: 6.00),
        "gpt-5.5": openAIRates(
            input: 5.00,
            cachedInput: 0.50,
            output: 30.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-5.5-pro": openAIRates(
            input: 30.00,
            cachedInput: 0.00,
            output: 180.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-5.4": openAIRates(
            input: 2.50,
            cachedInput: 0.25,
            output: 15.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-5.4-mini": openAIRates(input: 0.75, cachedInput: 0.075, output: 4.50),
        "gpt-5.4-nano": openAIRates(input: 0.20, cachedInput: 0.02, output: 1.25),
        "gpt-5.4-pro": openAIRates(
            input: 30.00,
            cachedInput: 0.00,
            output: 180.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
    ]

    /// Newest known model per tier — fallback target for unlisted
    /// SKUs that still carry a Claude tier prefix.
    ///
    /// **Keep in sync when adding a new entry to `table`.** A missed
    /// update means future unknowns fall back to last-cycle pricing
    /// (not disastrous — a warning still fires — but the cost shown
    /// to the user stays slightly stale). The test
    /// `fallback_usesNewestKnownTierModel` guards against the most
    /// visible drift: that the newest entry for each tier is *in* the
    /// table.
    private static let newestByTier: [String: String] = [
        "claude-fable-": "claude-fable-5",
        "claude-opus-": "claude-opus-4-8",
        "claude-sonnet-": "claude-sonnet-4-6",
        "claude-haiku-": "claude-haiku-4-5"
    ]

    private static let syntheticModels: Set<String> = ["<synthetic>"]

    private static func openAIRates(
        input: Double,
        cachedInput: Double,
        output: Double,
        longContextInputThreshold: Int? = nil,
        longContextInputMultiplier: Double = 1,
        longContextOutputMultiplier: Double = 1
    ) -> ModelRates {
        ModelRates(
            inputPerMTok: input,
            outputPerMTok: output,
            cacheWrite5mPerMTok: 0,
            cacheWrite1hPerMTok: 0,
            cacheReadPerMTok: cachedInput,
            fastInputPerMTok: nil,
            fastOutputPerMTok: nil,
            longContextInputThreshold: longContextInputThreshold,
            longContextInputMultiplier: longContextInputMultiplier,
            longContextOutputMultiplier: longContextOutputMultiplier
        )
    }

    // MARK: - Fallback de-dup

    nonisolated(unsafe) private static var loggedFallbacks: Set<String> = []
    private static let loggedFallbacksLock = NSLock()

    // MARK: - API

    /// Look up per-model rates. Falls back to the newest-tier rates
    /// when the exact model isn't listed but the name matches a
    /// Claude tier prefix. Logs a one-time warning per fallback so
    /// the developer knows to add explicit pricing.
    static func rates(for model: String) -> ModelRates? {
        if let exact = table[model] { return exact }
        guard let fallback = fallbackRates(for: model) else { return nil }
        logFallbackIfNew(from: model, to: fallback.modelName)
        return fallback.rates
    }

    static func isSyntheticModel(_ model: String) -> Bool {
        syntheticModels.contains(model)
    }

    // MARK: - Fallback internals

    private static func fallbackRates(for model: String) -> (modelName: String, rates: ModelRates)? {
        // Match the most specific tier prefix first. Each key already
        // ends in `-` so "claude-opus-something" never cross-matches
        // "claude-sonnet-".
        for (prefix, target) in newestByTier {
            if model.hasPrefix(prefix), let rates = table[target] {
                return (target, rates)
            }
        }
        return nil
    }

    private static func logFallbackIfNew(from model: String, to fallback: String) {
        loggedFallbacksLock.lock()
        let alreadyLogged = !loggedFallbacks.insert(model).inserted
        loggedFallbacksLock.unlock()
        guard !alreadyLogged else { return }
        // Background-safe: fallback look-up happens during the per-file
        // concurrent parse worker.
        LoggerService.shared.logFromAnyThread(
            .warning,
            "Unknown model '\(model)' — using '\(fallback)' rates as fallback. "
            + "Add explicit pricing to PricingTable.swift.",
            context: "PricingTable"
        )
    }

    /// Test-only: drop the fallback dedupe cache so tests can assert
    /// that the warning fires at least once for a given model without
    /// interfering with other tests that share the process.
    static func resetFallbackLogCacheForTesting() {
        loggedFallbacksLock.lock()
        loggedFallbacks.removeAll()
        loggedFallbacksLock.unlock()
    }
}
