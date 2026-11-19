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
    /// Whether one over-threshold request pulls every other request for
    /// this model in the same session into long-context pricing.
    /// Anthropic prices Haiku 5.5 strictly per request — "earlier
    /// requests keep the prices they were billed at" — while the OpenAI
    /// entries have been applied session-wide since the gpt-5.5 rollout.
    let longContextAppliesSessionWide: Bool

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
        longContextOutputMultiplier: Double = 1,
        longContextAppliesSessionWide: Bool = true
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
        self.longContextAppliesSessionWide = longContextAppliesSessionWide
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
            longContextOutputMultiplier: longContextOutputMultiplier,
            longContextAppliesSessionWide: longContextAppliesSessionWide
        )
    }
}

/// Per-model pricing with a forward-compatibility fallback.
///
/// **Exact match**: when the model name is listed in `table`, those
/// rates are returned verbatim.
///
/// **Tier fallback**: when the model name isn't listed but matches a
/// `claude-{fable|mythos|opus|sonnet|haiku}-` prefix, rates are borrowed from the
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
    /// v3: gpt-5.6 family (sol/terra/luna), flat rate with no long-context
    ///     tier — Codex `gpt-5.6-sol` had been unpriced (cost shown as "—").
    /// v4: claude-opus-5 entry + fast-mode rates ($10/$50) on Opus 5 and
    ///     Opus 4.8, and the opus tier fallback now points at Opus 5.
    ///     Standard-mode Opus 5 cost was already correct via the 4.8
    ///     fallback (identical rates); fast-mode requests had been unpriced.
    /// v5: claude-fable-5-1, claude-sonnet-5 and gpt-6-astra entries.
    ///     Fable 5.1 had been falling back to Fable 5, which prices cache
    ///     reads at 0.1x base input — 5.1 charges 0.025x, so every cache
    ///     read was billed at 4x. Sonnet 5 had been falling back to
    ///     Sonnet 4.6 and is 50% cheaper than it, so every Sonnet 5
    ///     request was overstated. Astra was unpriced (cost shown as "—").
    /// v6: the 5.5 generation (opus/sonnet/haiku) + Fable 5.2 + Mythos,
    ///     the gpt-6.x line, and corrected gpt-5.6 rates. ~199,000
    ///     already-indexed rows were mispriced: Opus 5.5 fell back to
    ///     Opus 5 (25% high on every component, 2.5x on cache reads, and
    ///     Claude Code is cache-read dominated), Haiku 5.5 fell back to
    ///     Haiku 4.5 at 10x, and gpt-6.1-sol had no `gpt-` fallback at
    ///     all so its cost showed as "—". The gpt-5.6 entries were right
    ///     when written and went stale: OpenAI cut those prices on
    ///     2026-07-30 and 2026-08-21 and added a >272k tier the original
    ///     entries said did not exist.
    static let version = 6

    // Logging routed through `LoggerService.shared.logFromAnyThread`
    // so the in-app Diagnostics window picks it up alongside the
    // Console.app subsystem/category match.

    private static let table: [String: ModelRates] = [
        // Cache rates follow Anthropic's standard multipliers on input:
        // write 5m = 1.25x, write 1h = 2x, read = 0.1x. The read
        // multiplier now has three classes, not one rule plus an
        // exception (pricing page, verified 2026-11-19):
        //   0.1x   — everything else, Haiku 5.5 included
        //   0.05x  — Opus 5.5, Sonnet 5.5
        //   0.025x — Fable 5.1 / 5.2, Mythos 5.1 / 5.2
        // Every entry spells its own read rate out, so the classes need no
        // mechanism — but an entry that inherits a tier fallback from the
        // wrong class is off by 2x to 4x on the dominant cost component.
        "claude-fable-5-2": ModelRates(
            inputPerMTok: 8.00, outputPerMTok: 40.00,
            cacheWrite5mPerMTok: 10.00, cacheWrite1hPerMTok: 16.00, cacheReadPerMTok: 0.20,
            fastInputPerMTok: 16.00, fastOutputPerMTok: 80.00
        ),
        "claude-fable-5-1": ModelRates(
            inputPerMTok: 10.00, outputPerMTok: 50.00,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20.00, cacheReadPerMTok: 0.25,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-fable-5": ModelRates(
            inputPerMTok: 10.00, outputPerMTok: 50.00,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20.00, cacheReadPerMTok: 1.00,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        // Mythos (limited availability) has matched Fable's rates in every
        // generation. Listed anyway because `claude-mythos-` is not a tier
        // prefix the fallback knew, so an unlisted mythos id returned nil
        // and rendered as "—" rather than approximately-right.
        "claude-mythos-5-2": ModelRates(
            inputPerMTok: 8.00, outputPerMTok: 40.00,
            cacheWrite5mPerMTok: 10.00, cacheWrite1hPerMTok: 16.00, cacheReadPerMTok: 0.20,
            fastInputPerMTok: 16.00, fastOutputPerMTok: 80.00
        ),
        "claude-mythos-5-1": ModelRates(
            inputPerMTok: 10.00, outputPerMTok: 50.00,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20.00, cacheReadPerMTok: 0.25,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-mythos-5": ModelRates(
            inputPerMTok: 10.00, outputPerMTok: 50.00,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20.00, cacheReadPerMTok: 1.00,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        // Fast mode is a flat 2x multiplier on the standard rate — NOT the
        // 6x the retired Opus 4.6 preview charged — and cache multipliers
        // still apply on top of the standard input rate, so only
        // input/output change. Offered on Opus 5.5, Opus 5 (research
        // preview), Opus 4.8, Fable 5.2 and Mythos 5.2.
        // (platform.claude.com/docs/en/build-with-claude/fast-mode#pricing,
        //  verified 2026-11-19.)
        "claude-opus-5-5": ModelRates(
            inputPerMTok: 4.00, outputPerMTok: 20.00,
            cacheWrite5mPerMTok: 5.00, cacheWrite1hPerMTok: 8.00, cacheReadPerMTok: 0.20,
            fastInputPerMTok: 8.00, fastOutputPerMTok: 40.00
        ),
        "claude-opus-5": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            fastInputPerMTok: 10.00, fastOutputPerMTok: 50.00
        ),
        "claude-opus-4-8": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            fastInputPerMTok: 10.00, fastOutputPerMTok: 50.00
        ),
        "claude-opus-4-7": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            // 4.7 never supported fast mode — `speed: "fast"` is rejected
            // outright, so no request can be billed at a fast rate.
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        "claude-opus-4-6": ModelRates(
            inputPerMTok: 5.00, outputPerMTok: 25.00,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10.00, cacheReadPerMTok: 0.50,
            // Historical only. Anthropic has since retired 4.6 fast mode: a
            // `speed: "fast"` request now runs at standard speed, bills at
            // standard rates, and reports `usage.speed: "standard"`. Lupen
            // keys off that reported value, so these rates are unreachable
            // for new rows — they stay to keep already-indexed rows from the
            // preview window priced as they were actually billed.
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
        // Sonnet 5.5 keeps Sonnet 5's base and cache-write rates and halves
        // the cache read — the one component the tier fallback could not
        // get right by accident, and the one that dominates Claude Code.
        "claude-sonnet-5-5": ModelRates(
            inputPerMTok: 2.00, outputPerMTok: 10.00,
            cacheWrite5mPerMTok: 2.50, cacheWrite1hPerMTok: 4.00, cacheReadPerMTok: 0.10,
            fastInputPerMTok: nil, fastOutputPerMTok: nil
        ),
        // Sonnet 5 is CHEAPER than the 4.6 it succeeds — $2/$10 against
        // $3/$15 — so the tier fallback overstated every Sonnet 5 request
        // by 50%. The $2/$10 launch price was billed as introductory
        // through 2026-08-31; Anthropic then cancelled the scheduled rise
        // to $3/$15 and made it standard, so one rate covers all history
        // and no date split is needed (verified 2026-09-09).
        "claude-sonnet-5": ModelRates(
            inputPerMTok: 2.00, outputPerMTok: 10.00,
            cacheWrite5mPerMTok: 2.50, cacheWrite1hPerMTok: 4.00, cacheReadPerMTok: 0.20,
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
        // Haiku 5.5 is a tenth of the 4.5 it succeeds, so the tier fallback
        // billed every request at 10x. It is also the only Claude model
        // priced by prompt length: over 100,000 tokens every component goes
        // up exactly 5x, which the long-context multipliers express as-is.
        // Two Anthropic rules matter here and both are already satisfied:
        // prompt length "counts all of its input tokens, including cache
        // reads and cache writes" (what `promptInputTokenCount` sums), and
        // "each request is priced on its own ... earlier requests keep the
        // prices they were billed at" — hence per-request, not session-wide,
        // unlike the OpenAI long-context entries.
        "claude-haiku-5-5": ModelRates(
            inputPerMTok: 0.10, outputPerMTok: 0.50,
            cacheWrite5mPerMTok: 0.125, cacheWrite1hPerMTok: 0.20, cacheReadPerMTok: 0.01,
            fastInputPerMTok: nil, fastOutputPerMTok: nil,
            longContextInputThreshold: 100_000,
            longContextInputMultiplier: 5,
            longContextOutputMultiplier: 5,
            longContextAppliesSessionWide: false
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
        // GPT-6 line (rates verified 2026-11-19 against the pricing page,
        // which publishes the long-context tier as absolute prices rather
        // than multipliers). Every entry below checked out as the same
        // shape: >272k charges 2x input AND cache, 1.5x output, for the
        // full request — exactly what `longContextInputMultiplier` applies.
        //
        // Listed ahead of first use on purpose. There is no `gpt-` tier
        // fallback (and there should not be: `gpt-5.4-nano` and
        // `gpt-6.2-astra` are 40x apart, so any shared anchor would be
        // wildly wrong), which makes an unlisted OpenAI model cost "—"
        // instead of approximately-right. Pre-registering is the only
        // mitigation available, and it paid off for Astra in v5.
        // developers.openai.com/api/docs/pricing
        "gpt-6.2-astra": openAIRates(
            input: 8.00,
            cachedInput: 0.40,
            output: 40.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6.2-astra-law": openAIRates(
            input: 8.00,
            cachedInput: 0.40,
            output: 40.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6.2-sol": openAIRates(
            input: 2.00,
            cachedInput: 0.10,
            output: 10.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6.1-sol": openAIRates(
            input: 2.00,
            cachedInput: 0.10,
            output: 10.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6.1-terra": openAIRates(
            input: 1.00,
            cachedInput: 0.05,
            output: 5.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6-astra": openAIRates(
            input: 10.00,
            cachedInput: 1.00,
            output: 50.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6-astra-law": openAIRates(
            input: 10.00,
            cachedInput: 1.00,
            output: 50.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6-rosalind": openAIRates(
            input: 10.00,
            cachedInput: 1.00,
            output: 50.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6-cyber": openAIRates(
            input: 20.00,
            cachedInput: 2.00,
            output: 100.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6-sol": openAIRates(
            input: 2.00,
            cachedInput: 0.20,
            output: 10.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-6-luna": openAIRates(
            input: 0.10,
            cachedInput: 0.01,
            output: 0.50,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        // GPT-5.6 family (GA 2026-07-09). The rates first recorded here
        // were correct on 2026-07-12 and then went stale: OpenAI cut Luna
        // 80% and Terra 20% on 2026-07-30, then Sol to $4/$20 on
        // 2026-08-21 (-20% input, -33% output). Applying those published
        // cuts to the old entries lands exactly on today's prices, so this
        // was a price change, not a transcription error — which is why
        // listed entries need re-checking, not just new models.
        //
        // The >272k tier this comment used to say the 5.6 line "DROPS
        // entirely" is on the pricing page for sol/terra/luna. Only
        // 5.6-cyber is genuinely flat.
        //
        // One rate per model cannot express a date range, so the cut is
        // applied to all history, including the 19 of 639 local
        // gpt-5.6-sol rows that predate 2026-08-21 and really were billed
        // at $5/$30. Holding the launch rate instead would misprice the
        // other 620, so this is the better of two one-sided answers, not a
        // correct one. The >272k tier is not retroactive invention: the
        // 2026-08-05 changelog already describes long-context 5.6
        // requests. Terra and luna appear in no local row at all.
        //
        // Sol's price is promotional "until November 30, 2026" on the
        // pricing page and "at least through November 21" in the
        // changelog, with no successor rate published — the same
        // limitation, pointed forward. Re-check in early December.
        // (Verified 2026-11-19.)
        "gpt-5.6-sol": openAIRates(
            input: 4.00,
            cachedInput: 0.40,
            output: 20.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-5.6-terra": openAIRates(
            input: 2.00,
            cachedInput: 0.20,
            output: 12.00,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-5.6-luna": openAIRates(
            input: 0.20,
            cachedInput: 0.02,
            output: 1.20,
            longContextInputThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        ),
        "gpt-5.6-cyber": openAIRates(input: 12.50, cachedInput: 1.25, output: 75.00),
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
    ///
    /// The haiku anchor deliberately stays one generation behind. Haiku
    /// 5.5 is the only Claude entry priced by prompt length, and an anchor
    /// carries its long-context threshold to every unlisted SKU of the
    /// tier — so anchoring on 5.5 would charge a future threshold-free
    /// haiku 5x over 100k tokens. Anchoring on 4.5 errs the other way
    /// (10x high) and the warning log fires either way, so this buys no
    /// detection; what makes it safe is that the one predictable unlisted
    /// haiku id — a dated `claude-haiku-5-5-YYYYMMDD` SKU — resolves
    /// through `rollingTagName` and never reaches the anchor at all.
    private static let newestByTier: [String: String] = [
        "claude-fable-": "claude-fable-5-2",
        "claude-mythos-": "claude-mythos-5-2",
        "claude-opus-": "claude-opus-5-5",
        "claude-sonnet-": "claude-sonnet-5-5",
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

    /// Look up per-model rates: exact match, then the rolling tag behind
    /// a dated SKU, then the newest-tier rates when the name matches a
    /// Claude tier prefix. Logs a one-time warning per tier fallback so
    /// the developer knows to add explicit pricing.
    static func rates(for model: String) -> ModelRates? {
        if let exact = table[model] { return exact }
        // Anthropic ships an immutable dated SKU beside each rolling tag
        // (`claude-haiku-4-5-20251001` alone accounts for 2,332 billable
        // rows locally). Same model, same price, so resolve to the rolling
        // entry rather than letting the tier anchor price it — the anchor
        // can be a whole generation and a 10x price away.
        if let rollingTag = rollingTagName(for: model), let exact = table[rollingTag] {
            return exact
        }
        guard let fallback = fallbackRates(for: model) else { return nil }
        logFallbackIfNew(from: model, to: fallback.modelName)
        return fallback.rates
    }

    static func isSyntheticModel(_ model: String) -> Bool {
        syntheticModels.contains(model)
    }

    // MARK: - Fallback internals

    /// `claude-opus-5-20260101` → `claude-opus-5`; nil when the name does
    /// not end in a `-YYYYMMDD` release-date suffix.
    private static func rollingTagName(for model: String) -> String? {
        let suffixLength = 9
        guard model.count > suffixLength else { return nil }
        let suffix = model.suffix(suffixLength)
        guard suffix.first == "-",
              suffix.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(model.dropLast(suffixLength))
    }

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
