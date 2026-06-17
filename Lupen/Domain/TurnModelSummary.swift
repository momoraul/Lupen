import Foundation

/// Pure helper — distill a `Turn`'s mixed model usage into "primary +
/// extras" so the outline's Model column can show a single accent text
/// with optional suffix instead of an unreadable list of every model
/// that touched the Turn.
///
/// Design (macos-ux-designer review 2026-04-22):
///   * **primary** = the reply / thought / tool-call Step model that
///     contributed the most output+input tokens. Last-Step-wins would
///     be misleading when Claude Code does `compact → haiku
///     summarization → opus resume`; the bulk-token heuristic keeps
///     the main workhorse tinted.
///   * **extras** = every other distinct model, secondary tint.
///   * Single-model Turn → `"opus-4-7"`.
///   * Two models       → `"opus · haiku"`.
///   * 3+               → `"opus +2"` (suffix in tertiary tint).
///
/// Steps lacking a model (prompt / toolResult with no assistant
/// metadata) are ignored — they're rendered as blank cells by the UI.
enum TurnModelSummary {

    struct Resolved: Equatable {
        /// `nil` when the Turn has no assistant Steps at all.
        let primary: String?
        /// Ordered list of other distinct models in decreasing token
        /// contribution order. Does NOT include `primary`.
        let extras: [String]

        var isMixed: Bool { !extras.isEmpty }
    }

    /// Resolve a Turn's model display. Pure; safe to call per-cell.
    static func resolve(for turn: Turn) -> Resolved {
        // Accumulate `(inputTokens + outputTokens)` per model. Input
        // alone would starve streaming cases where the reply is huge
        // and the prompt small; output alone would starve long-context
        // read-heavy workloads. The sum is the honest proxy for "this
        // model did the work for this Turn."
        var tokensByModel: [String: Int] = [:]
        var orderByModel: [String: Int] = [:] // first-seen index tiebreaker
        for (i, step) in turn.steps.enumerated() {
            guard let model = step.model, !model.isEmpty,
                  !PricingTable.isSyntheticModel(model)
            else { continue }
            let weight = (step.tokens?.inputTokens ?? 0)
                + (step.tokens?.outputTokens ?? 0)
            tokensByModel[model, default: 0] += weight
            if orderByModel[model] == nil {
                orderByModel[model] = i
            }
        }

        guard !tokensByModel.isEmpty else {
            return Resolved(primary: nil, extras: [])
        }

        // Sort: tokens DESC, then first-seen ASC for deterministic
        // "two models tied at 0 tokens" order.
        let ranked = tokensByModel.keys.sorted { a, b in
            let ta = tokensByModel[a] ?? 0
            let tb = tokensByModel[b] ?? 0
            if ta != tb { return ta > tb }
            return (orderByModel[a] ?? .max) < (orderByModel[b] ?? .max)
        }
        let primary = ranked.first
        let extras = Array(ranked.dropFirst())
        return Resolved(primary: primary, extras: extras)
    }
}
