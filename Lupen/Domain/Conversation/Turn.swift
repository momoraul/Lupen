import Foundation

/// A bundle of Steps. One conversation unit starting with a Prompt and
/// ending with a Reply/Stop. See `docs/CONVERSATION-MODEL.md`.
///
/// `Codable` — included in `AssemblerSnapshot`. Bump
/// `SnapshotSchema.currentVersion` when adding/removing fields.
struct Turn: Sendable, Identifiable, Equatable, Codable {

    /// Turn id = UUID of the root `.prompt` Step (or the first Step's UUID if orphan).
    let id: String
    let sessionId: String

    /// All Steps in the Turn, sorted by timestamp ascending.
    let steps: [Step]

    /// Whether the user abandoned the Turn mid-flight. `true` iff
    /// `isComplete == false` and a subsequent Turn exists in the same
    /// session. Set by the Assembler at assembly time.
    let isInterrupted: Bool

    init(id: String, sessionId: String, steps: [Step], isInterrupted: Bool = false) {
        self.id = id
        self.sessionId = sessionId
        self.steps = steps
        self.isInterrupted = isInterrupted
    }
}

extension Turn {
    var firstStep: Step? { steps.first }

    var lastStep: Step? { steps.last }

    /// The Prompt Step that started the Turn (`kind == .prompt`). Nil
    /// for orphan Turns.
    var promptStep: Step? {
        if let first = steps.first, first.kind == .prompt { return first }
        return nil
    }

    /// `true` if the last Step is `.reply` or `.stop`.
    var isComplete: Bool {
        guard let last = lastStep else { return false }
        return last.kind == .reply || last.kind == .stop
    }

    /// `true` if the last Step is a synthetic placeholder injected by
    /// Claude Code on API failure. Lets the Turn header show a small
    /// warning icon + tooltip ("ended with API error") at a glance.
    /// Sibling-style derived flag to `isInterrupted` — computed from
    /// existing Step signals rather than adding a stored property to
    /// the assembler.
    var endedWithApiError: Bool {
        lastStep?.isSyntheticApiError ?? false
    }

    /// `true` if the Turn is orphan (does not start with a prompt —
    /// incomplete-data case).
    var isOrphan: Bool { promptStep == nil }

    /// `true` if this Turn looks like it lost its assistant follow-up
    /// to a Claude Code auto-/manual `/compact`: the turn has exactly
    /// one step (the user prompt) and the immediately-following turn
    /// in the same session is a compact-resume marker
    /// (`promptStep.isCompactSummary == true`). Auto-compact destroys
    /// the prior assistant entries from the JSONL — they cannot be
    /// recovered — so the UI surfaces a `✂ compacted` badge to convey
    /// "the reply was summarized into the next turn" rather than
    /// looking broken (zero replies, zero tokens).
    ///
    /// **Identity invariant**: when this returns `true`, `self.id ==
    /// promptStep.uuid` (`steps.count == 1` and the step is the
    /// prompt — assembler always assigns `Turn.id == prompt.uuid` for
    /// non-orphan turns). The TurnOutline cell renderer relies on
    /// this so it can recognize the prompt step row by `step.uuid`
    /// membership in the same `compactedAwayTurnIds` set.
    ///
    /// `nextTurnInSession` must be the next Turn in chronological
    /// order within the same session (the caller has the array; this
    /// type alone has no neighbour context).
    func wasCompactedAway(nextTurnInSession: Turn?) -> Bool {
        guard steps.count == 1,
              let prompt = promptStep,
              !prompt.isCompactSummary else { return false }
        return nextTurnInSession?.promptStep?.isCompactSummary == true
    }

    var startTime: Date? { steps.first?.timestamp }

    var endTime: Date? { steps.last?.timestamp }

    // MARK: - Aggregates

    /// Sum of tokens across every billable Step in this Turn. Does
    /// **not** include sub-agent (sidechain) Turn tokens — session-wide
    /// aggregators like `AppStateStore.totalTokens(in:)` already sum
    /// sub-agents as their own Turns (or own requests), so excluding
    /// them here prevents double-counting. For the Outline UI's
    /// "include sub-agent tokens spawned by this turn" display use
    /// `aggregateTokensIncludingSubAgents(...)`.
    var aggregateTokens: TokenBreakdown {
        var input = 0, output = 0, reasoning = 0, creation = 0, read = 0, eph1h = 0, eph5m = 0
        var contextWindow: Int?
        for step in steps {
            guard let t = step.tokens else { continue }
            input += t.inputTokens
            output += t.outputTokens
            reasoning += t.reasoningOutputTokens
            creation += t.cacheCreationInputTokens
            read += t.cacheReadInputTokens
            eph1h += t.cacheCreationEphemeral1h
            eph5m += t.cacheCreationEphemeral5m
            contextWindow = Self.maxContextWindow(contextWindow, t.contextWindow)
        }
        return TokenBreakdown(
            inputTokens: input,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            cacheCreationInputTokens: creation,
            cacheReadInputTokens: read,
            cacheCreationEphemeral1h: eph1h,
            cacheCreationEphemeral5m: eph5m,
            contextWindow: contextWindow
        )
    }

    /// Sum of cost (USD) across every Step in this Turn. Does **not**
    /// include sub-agent (sidechain) Turn cost — session-wide
    /// aggregators like `CostAnalyzer` / Reports already sum sub-agents
    /// as their own Turns, so excluding them here prevents
    /// double-counting. For the Outline UI's "include sub-agent cost
    /// spawned by this turn" display use
    /// `aggregateCostIncludingSubAgents(...)`.
    var aggregateCost: CostBreakdown {
        var i = 0.0, o = 0.0, c1h = 0.0, c5m = 0.0, cr = 0.0
        for step in steps {
            guard let c = step.cost else { continue }
            i += c.inputCostUSD
            o += c.outputCostUSD
            c1h += c.cacheCreate1hCostUSD
            c5m += c.cacheCreate5mCostUSD
            cr += c.cacheReadCostUSD
        }
        return CostBreakdown(
            inputCostUSD: i,
            outputCostUSD: o,
            cacheCreate1hCostUSD: c1h,
            cacheCreate5mCostUSD: c5m,
            cacheReadCostUSD: cr
        )
    }

    /// `aggregateCost` plus the `aggregateCost` of every sub-agent
    /// Turn spawned by some Step in this Turn. Used by the Outline
    /// Turn-header cost cell to show, in one line, the total cost the
    /// user perceives this turn as consuming (own steps + own
    /// sub-agents).
    ///
    /// **Do not use on the reporting path** — `CostAnalyzer` already
    /// sums sub-agent Turns as their own Turns, so calling this there
    /// would double-count sub-agents. Outline-header display only.
    ///
    /// Lookup map comes from the parent session's `SubAgentGraftIndex`.
    /// An empty map gives the same result as `aggregateCost`.
    /// 1-level **cross-Turn** only — nested cases inside a sub-agent
    /// Turn (additional Agent toolCalls within its Steps) are already
    /// covered because `subTurn.aggregateCost` sums every Step cost in
    /// that sub-agent Turn. True cross-file recursion (parent →
    /// sub-agent file → sub-sub-agent file) is not covered because CC
    /// does not produce it yet. See `SubAgentCostAggregator` doc for
    /// details.
    func aggregateCostIncludingSubAgents(
        linksByStepUuid: [String: [SubAgentLinker.Link]],
        subAgentTurnsByAgentId: [String: Turn]
    ) -> CostBreakdown {
        let base = aggregateCost
        let subs = SubAgentCostAggregator.subAgentCost(
            forSteps: steps,
            linksByStepUuid: linksByStepUuid,
            subAgentTurnsByAgentId: subAgentTurnsByAgentId
        )
        return TokenCalculator.aggregateCosts([base, subs])
    }

    /// `aggregateTokens` plus the `aggregateTokens` of every sub-agent
    /// Turn spawned by some Step in this Turn. Used by the Outline
    /// Turn-header tokens / cacheRead / cacheWrite / cacheTTL cells —
    /// the symmetric counterpart to `aggregateCostIncludingSubAgents`,
    /// exposing "total tokens consumed by this turn" in one line.
    /// Rolling up only Cost while showing bare Tokens would create
    /// cognitive dissonance from implausible ratios like
    /// "Cost $4.67 / Tokens 2,341" the user sees.
    ///
    /// **Do not use on the reporting path** —
    /// `AppStateStore.totalTokens(in:)` already sums every sub-agent
    /// token at the request level, so calling this there would
    /// double-count. Outline-header display only.
    ///
    /// 1-level **cross-Turn** only (nested cases inside a sub-agent
    /// Turn are already covered by `subTurn.aggregateTokens`). See
    /// `SubAgentTokenAggregator` doc for details.
    func aggregateTokensIncludingSubAgents(
        linksByStepUuid: [String: [SubAgentLinker.Link]],
        subAgentTurnsByAgentId: [String: Turn]
    ) -> TokenBreakdown {
        let base = aggregateTokens
        let subs = SubAgentTokenAggregator.subAgentTokens(
            forSteps: steps,
            linksByStepUuid: linksByStepUuid,
            subAgentTurnsByAgentId: subAgentTurnsByAgentId
        )
        return TokenCalculator.aggregateTokens([base, subs])
    }

    /// Number of billable (assistant) Steps.
    var billableStepCount: Int { steps.filter { $0.isBillable }.count }

    var stepCount: Int { steps.count }

    private static func maxContextWindow(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): return max(lhs, rhs)
        case (.some(let lhs), .none): return lhs
        case (.none, .some(let rhs)): return rhs
        case (.none, .none): return nil
        }
    }

    /// `true` if every Step in this Turn originates from a sub-agent
    /// (sidechain). When `true` the Turn is a candidate for isolated
    /// display in the conversation outline (Phase A+) or grafting
    /// under its parent Step (Phase B). Parent-session main-line Turns
    /// are always false. Mixed Turns (only some Steps are sidechain)
    /// do not occur with the current data structure (sub-agent
    /// parentUuid chains never jump into the parent file), but for
    /// safety this is true only when *all* Steps are sidechain.
    var isSidechainOnly: Bool {
        !steps.isEmpty && steps.allSatisfy(\.isSidechain)
    }

    /// De-duplicated attachment manifest for the whole Turn — what the
    /// Attachments tab renders when the user selects the Turn header
    /// row rather than a single Step.
    ///
    /// Behaviour:
    ///   - Walks every Step in `steps` order (chronological).
    ///   - Dedup key is `locator` alone. When the same path appears
    ///     with multiple origins (common: a file Claude *wrote* will
    ///     also appear as a `replyMention` when the assistant confirms
    ///     the write), keeps the ref with the highest-priority origin
    ///     per `AttachmentRef.Origin.dedupPriority`.
    ///   - `.inlineImage` refs use a synthetic `#inline:…` locator so
    ///     they never collide with real paths. Multiple inline images
    ///     in the same prompt each get a distinct key.
    ///   - Interrupted / orphan / sidechain-only Turns are treated no
    ///     differently — their Step-level attachments are valid data
    ///     even if the Turn itself is incomplete.
    var allAttachments: [AttachmentRef] {
        // First-seen order matters for the "first appearance wins
        // position" heuristic: an image attached up top should render
        // before a file Claude wrote in reply. Dedup upgrade happens
        // in-place when a later origin beats the stored one's
        // priority, but the row's position stays with the first
        // occurrence so the section ordering in the UI is stable.
        var order: [String] = []
        var byLocator: [String: AttachmentRef] = [:]

        for step in steps {
            for ref in step.attachments {
                if let existing = byLocator[ref.locator] {
                    if ref.origin.dedupPriority > existing.origin.dedupPriority {
                        byLocator[ref.locator] = ref
                    }
                } else {
                    byLocator[ref.locator] = ref
                    order.append(ref.locator)
                }
            }
        }

        return order.compactMap { byLocator[$0] }
    }
}
