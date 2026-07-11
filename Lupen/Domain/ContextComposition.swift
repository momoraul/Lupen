//
//  ContextComposition.swift
//  Lupen
//
//  Created by jaden on 2026/07/05.
//

import Foundation

/// Turns the raw per-range sums (`StoreContextCompositionAggregate`) into the
/// two composition bars the Reports "Composition" tab renders (C-25):
///
/// - **Generation** — where the model's *output* tokens went. Anchored to the
///   ACTUAL `Σ output_tokens` (+ Codex `reasoning_output_tokens`); only the
///   split across Thinking / Reply / Tool calls is estimated, from content
///   character shares. The total is always the real billed number.
/// - **Context** — what fills the context the model carries. A real per-session
///   baseline (system prompt + tool schemas + initial context — the one block
///   that can't be measured line-by-line) plus the measured content categories
///   (Prompts / Tool input / Tool output / Reply), estimated from character
///   lengths at ~`charsPerToken` chars per token.
///
/// Honesty contract: a `Slice` is flagged `isEstimate == false` only when its
/// token count is a real billed number (generation total anchor, the reasoning
/// slice on Codex, the system baseline). Everything else is a labelled estimate.
///
/// Pure and `Sendable` — no I/O, no Date, no main-actor state — so it is fully
/// unit-testable off the aggregate struct.
enum ContextComposition {

    /// Rough characters-per-token for prose + code + JSON. Only affects the
    /// *proportions* of estimated slices, never a real total, so tokenizer
    /// drift (e.g. Opus 4.8's denser tokens) does not distort the anchors.
    static let defaultCharsPerToken: Double = 3.8

    enum Category: String, CaseIterable, Sendable {
        // Generation
        case thinking
        case reply
        case toolCall
        // Context
        case prompt
        case toolInput
        case toolOutput
        case systemBaseline

        /// UI label — English to match the rest of the Reports window.
        var label: String {
            switch self {
            case .thinking: return "Thinking"
            case .reply: return "Reply"
            case .toolCall: return "Tool calls"
            case .prompt: return "Prompts"
            case .toolInput: return "Tool input"
            case .toolOutput: return "Tool output"
            case .systemBaseline: return "System & tools"
            }
        }
    }

    struct Slice: Sendable, Equatable, Identifiable {
        let category: Category
        let estTokens: Int
        /// `false` when `estTokens` is an actual billed number (not derived
        /// from a character→token approximation).
        let isEstimate: Bool
        var id: String { category.rawValue }
    }

    /// One category's dollar share of the unified Cost bar. Always estimated
    /// at the category level — only the bar's *total* is a real billed number.
    struct CostSlice: Sendable, Equatable, Identifiable {
        let category: Category
        let costUSD: Double
        let isEstimate: Bool
        var id: String { category.rawValue }
    }

    struct Result: Sendable, Equatable {
        /// Thinking / Reply / Tool calls — sums exactly to `generationTokens`.
        let generation: [Slice]
        /// System baseline / Prompts / Tool input / Tool output / Reply.
        let context: [Slice]
        /// Actual Σ output_tokens (+ reasoning). The Generation bar's total.
        let generationTokens: Int
        /// Real baseline + estimated content tokens. The Context bar's total.
        let contextTokens: Int
        /// Unified $-by-category breakdown (generation + context merged). Each
        /// category's cost is `real component total × its estimated token
        /// share`; the sum is the real billed total.
        let cost: [CostSlice]
        /// Real Σ output cost + context (input + cache) cost. The Cost bar's
        /// total and the hero figure.
        let totalCostUSD: Double

        var hasData: Bool { generationTokens > 0 || contextTokens > 0 }
        var hasCostData: Bool { totalCostUSD > 0 && !cost.isEmpty }

        /// Share of generation spent on thinking, 0…1 — a headline stat
        /// ("N% of output was thinking"). nil when there was no generation.
        var thinkingShare: Double? {
            guard generationTokens > 0 else { return nil }
            let think = generation.first { $0.category == .thinking }?.estTokens ?? 0
            return Double(think) / Double(generationTokens)
        }

        /// Largest cost category + its share of the total — powers the Cost
        /// view's one-line insight ("Thinking was your biggest cost — 47%").
        var topCost: (category: Category, costUSD: Double, share: Double)? {
            guard totalCostUSD > 0,
                  let top = cost.max(by: { $0.costUSD < $1.costUSD }) else { return nil }
            return (top.category, top.costUSD, top.costUSD / totalCostUSD)
        }
    }

    static func make(
        from agg: StoreContextCompositionAggregate,
        charsPerToken: Double = defaultCharsPerToken
    ) -> Result {
        let cpt = charsPerToken > 0 ? charsPerToken : defaultCharsPerToken
        func toTokens(_ chars: Int) -> Int {
            chars <= 0 ? 0 : Int((Double(chars) / cpt).rounded())
        }

        // MARK: Generation — anchored to real output (+ reasoning) tokens.
        let generationTotal = agg.outputTokens + agg.reasoningTokens
        var generation: [Slice] = []
        if generationTotal > 0 {
            if agg.reasoningTokens > 0 {
                // Codex: thinking is a real, separately-billed number; split
                // the remaining output tokens across reply vs tool calls by
                // their character shares.
                let split = distribute(
                    agg.outputTokens,
                    weights: [agg.replyChars, agg.toolInputChars]
                )
                generation = [
                    Slice(category: .thinking, estTokens: agg.reasoningTokens, isEstimate: false),
                    Slice(category: .reply, estTokens: split[0], isEstimate: true),
                    Slice(category: .toolCall, estTokens: split[1], isEstimate: true)
                ]
            } else if agg.thinkingChars + agg.replyChars + agg.toolInputChars == 0 {
                // Output billed but no assistant content captured (rare) — fall
                // back to a single neutral Reply slice rather than misattributing
                // the whole to Thinking.
                generation = [Slice(category: .reply, estTokens: generationTotal, isEstimate: true)]
            } else {
                // Claude: thinking is folded into output_tokens; split the whole
                // by thinking / reply / tool-call character shares.
                let split = distribute(
                    generationTotal,
                    weights: [agg.thinkingChars, agg.replyChars, agg.toolInputChars]
                )
                generation = [
                    Slice(category: .thinking, estTokens: split[0], isEstimate: true),
                    Slice(category: .reply, estTokens: split[1], isEstimate: true),
                    Slice(category: .toolCall, estTokens: split[2], isEstimate: true)
                ]
            }
            generation = generation.filter { $0.estTokens > 0 }
        }

        // MARK: Context — real baseline + estimated content categories.
        let baseline = max(0, agg.sessionBaselineTokens)
        let contextSlices: [Slice] = [
            Slice(category: .systemBaseline, estTokens: baseline, isEstimate: false),
            Slice(category: .prompt, estTokens: toTokens(agg.promptChars), isEstimate: true),
            Slice(category: .toolInput, estTokens: toTokens(agg.toolInputChars), isEstimate: true),
            Slice(category: .toolOutput, estTokens: toTokens(agg.toolOutputChars), isEstimate: true),
            Slice(category: .reply, estTokens: toTokens(agg.replyChars), isEstimate: true)
        ].filter { $0.estTokens > 0 }
        let contextTotal = contextSlices.reduce(0) { $0 + $1.estTokens }

        // MARK: Cost — one unified $-by-category bar. Each category's cost is
        // its estimated token share of the real component total (output cost
        // for generation categories, context cost for context categories),
        // merged so a category present on both sides (Reply) sums once.
        var costByCategory: [Category: Double] = [:]
        if agg.outputCostUSD > 0 {
            if generationTotal > 0 {
                for slice in generation {
                    costByCategory[slice.category, default: 0] +=
                        agg.outputCostUSD * Double(slice.estTokens) / Double(generationTotal)
                }
            } else {
                // Output billed but no generation tokens to split by — keep the
                // money in the bar (as neutral Reply) so slices still reconcile
                // to the real total rather than silently dropping it.
                costByCategory[.reply, default: 0] += agg.outputCostUSD
            }
        }
        if agg.contextCostUSD > 0 {
            if contextTotal > 0 {
                for slice in contextSlices {
                    costByCategory[slice.category, default: 0] +=
                        agg.contextCostUSD * Double(slice.estTokens) / Double(contextTotal)
                }
            } else {
                // Context billed but no measured content — attribute to the
                // un-itemizable System & tools baseline.
                costByCategory[.systemBaseline, default: 0] += agg.contextCostUSD
            }
        }
        let costSlices = costByCategory
            .map { CostSlice(category: $0.key, costUSD: $0.value, isEstimate: true) }
            .filter { $0.costUSD > 0 }
            .sorted { $0.costUSD > $1.costUSD }
        // With the fallbacks above, the slices always reconcile to this total,
        // so the hero, bar, and legend share one consistent denominator.
        let totalCost = agg.outputCostUSD + agg.contextCostUSD

        return Result(
            generation: generation,
            context: contextSlices,
            generationTokens: generationTotal,
            contextTokens: contextTotal,
            cost: costSlices,
            totalCostUSD: totalCost
        )
    }

    /// Splits an integer `total` across `weights` so the parts sum EXACTLY to
    /// `total` (largest-remainder apportionment). Zero total or all-zero
    /// weights yields all zeros. Guarantees the Generation slices reconcile
    /// to the real billed number with no rounding leak.
    static func distribute(_ total: Int, weights: [Int]) -> [Int] {
        guard total > 0, !weights.isEmpty else { return Array(repeating: 0, count: weights.count) }
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else {
            // No basis to split — dump everything into the first bucket.
            var out = Array(repeating: 0, count: weights.count)
            out[0] = total
            return out
        }
        // Floor each share, then hand the leftover units to the largest
        // fractional remainders.
        var floors: [Int] = []
        var remainders: [(index: Int, frac: Double)] = []
        var allocated = 0
        for (i, w) in weights.enumerated() {
            let exact = Double(total) * Double(w) / Double(weightSum)
            let f = Int(exact)  // floor for non-negative
            floors.append(f)
            allocated += f
            remainders.append((i, exact - Double(f)))
        }
        var leftover = total - allocated
        for (index, _) in remainders.sorted(by: { $0.frac > $1.frac }) where leftover > 0 {
            floors[index] += 1
            leftover -= 1
        }
        return floors
    }
}
