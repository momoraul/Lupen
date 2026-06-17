import Foundation

/// Pure helper that folds a Turn's flat Step list into a two-level outline
/// where each `Skill` tool invocation (or Codex `$skill` prompt command)
/// is a collapsible section owning its full execution span.
///
/// ## Grouping rule
///
/// 1. Iterate Steps in order. A Step whose `toolCalls` contains
///    `name == "Skill"` or whose prompt text starts with `$skill-name`
///    starts a new group.
/// 2. The group extends through every subsequent Step until one of:
///    - The next Skill `toolCalls` Step begins (→ that Step starts a new
///      group),
///    - A Turn-terminator Step (`.reply` or `.stop`) is reached, or
///    - The Turn ends.
/// 3. The boundary Step itself is **not** absorbed:
///    - A `.reply` / `.stop` stays as a sibling `.step` in the main-thread
///      outline.
///    - A subsequent Skill Step starts the next group, so it's the head
///      of the new group rather than a tail of the previous one.
///
/// ## Why `.reply` stays outside
///
/// `.reply` (stop_reason=end_turn) is the assistant's explicit return to
/// the user. Absorbing it inside a skill's group would hide the Turn's
/// natural conclusion. Every other sibling step between two Skill calls —
/// including tool calls that are technically main-thread work the user
/// interleaved — stays inside the preceding skill's group. This is the
/// tradeoff the user accepted: interleaved work is rare, and having the
/// collapse/expand unit match the aggregate numeric exactly is worth more
/// than perfect attribution for mid-Turn pivots.
///
/// ## Header title
///
/// `steps.first` is the group's trigger Step (the Step whose toolCalls
/// started the group). The UI renders the group's header row using the
/// trigger Step's own display so the text says whatever the first step
/// said — typically "Skill skill-name args" for a pure toolCall or
/// "thought text → Skill …" for a thought+Skill merge.
enum SkillGroupBuilder {

    // MARK: - Output

    enum OutlineRow: Equatable, Sendable {
        case step(Step)
        case skillGroup(SkillGroup)
    }

    /// A skill invocation's full span.
    ///
    /// `steps.first` is the trigger (always non-nil because the group
    /// only exists when the trigger Step was found). `steps.dropFirst()`
    /// is everything the collapse/expand widget reveals.
    struct SkillGroup: Equatable, Identifiable, Sendable {
        /// The initiating Skill `tool_use.id`. Stable across reloads.
        let id: String
        /// `/skill-name` parsed from the Skill tool_use input JSON.
        /// Used for tooltip / CostAnalyzer parity — the header's
        /// primary visual title comes from `steps.first`'s rendering.
        let label: String
        /// All Steps in the span: trigger first, then every Step until
        /// the boundary. Never empty — contains at least the trigger.
        let steps: [Step]
        /// Sum of `Step.cost` across `steps`. **Excludes** sub-agent
        /// (sidechain) Turn cost — same anti-double-count reason as
        /// `Turn.aggregateCost`. Use `aggregateCostIncludingSubAgents(...)`
        /// when the UI header needs the rollup that includes sub-agents.
        let aggregateCost: CostBreakdown
        /// Sum of `Step.tokens` across `steps`. **Excludes** sub-agent
        /// (sidechain) tokens — same anti-double-count reason as
        /// `Turn.aggregateTokens` (request-level reporting sums each
        /// sub-agent separately). Use `aggregateTokensIncludingSubAgents(...)`
        /// for the UI rollup.
        let aggregateTokens: TokenBreakdown
        /// Whether the matching `tool_result` was found anywhere in
        /// `steps`. False when the Turn ended before the skill could
        /// emit its result.
        let hasToolResult: Bool
        /// Whether an `isSystemInjected` prompt was found right after
        /// the matching `tool_result`. False for malformed runs.
        let hasIsMetaAnchor: Bool

        /// `aggregateCost` plus the `aggregateCost` of every sub-agent Turn
        /// spawned by any step inside this skill group. Used by the outline
        /// SkillGroup header cost cell to surface the cost of skills that
        /// spawn sub-agents (e.g. `/wiki-ingest` dispatching 6 parallel agents).
        ///
        /// Same caveat as `Turn.aggregateCostIncludingSubAgents(...)`:
        /// never use on the reporting path (would double-count).
        func aggregateCostIncludingSubAgents(
            linksByStepUuid: [String: [SubAgentLinker.Link]],
            subAgentTurnsByAgentId: [String: Turn]
        ) -> CostBreakdown {
            let subs = SubAgentCostAggregator.subAgentCost(
                forSteps: steps,
                linksByStepUuid: linksByStepUuid,
                subAgentTurnsByAgentId: subAgentTurnsByAgentId
            )
            return TokenCalculator.aggregateCosts([aggregateCost, subs])
        }

        /// Token-level twin of `aggregateCostIncludingSubAgents`.
        /// `aggregateTokens` plus the `aggregateTokens` of every sub-agent
        /// Turn spawned by any step inside this skill group. Used by all
        /// four token columns in the outline SkillGroup header.
        ///
        /// Same caveat as `Turn.aggregateTokensIncludingSubAgents(...)`:
        /// never use on the reporting path (would double-count).
        func aggregateTokensIncludingSubAgents(
            linksByStepUuid: [String: [SubAgentLinker.Link]],
            subAgentTurnsByAgentId: [String: Turn]
        ) -> TokenBreakdown {
            let subs = SubAgentTokenAggregator.subAgentTokens(
                forSteps: steps,
                linksByStepUuid: linksByStepUuid,
                subAgentTurnsByAgentId: subAgentTurnsByAgentId
            )
            return TokenCalculator.aggregateTokens([aggregateTokens, subs])
        }

        /// SQLite-first variant of `aggregateCostIncludingSubAgents`.
        /// Sub-agent cost comes from a caller-supplied map keyed by
        /// `agentId` (the SQL header aggregate) instead of the in-memory
        /// sub-agent `Turn`. This is required under SQLite-first because
        /// those Turns are unmaterialized **stubs** whose `aggregateCost`
        /// is zero — the `subAgentTurnsByAgentId` overload would silently
        /// undercount and the skill header would drop every sub-agent's
        /// cost (regression fixed 2026-06-15). De-duplicates by `agentId`
        /// so a sub-agent linked from more than one step is counted once.
        func aggregateCostIncludingSubAgents(
            linksByStepUuid: [String: [SubAgentLinker.Link]],
            subAgentCostByAgentId: [String: CostBreakdown]
        ) -> CostBreakdown {
            var seen: Set<String> = []
            var costs: [CostBreakdown?] = [aggregateCost]
            for step in steps {
                for link in linksByStepUuid[step.uuid] ?? [] where seen.insert(link.agentId).inserted {
                    costs.append(subAgentCostByAgentId[link.agentId])
                }
            }
            return TokenCalculator.aggregateCosts(costs)
        }

        /// Token twin of the `subAgentCostByAgentId` overload — same
        /// SQLite-first stub-Turn reasoning, applied to the four token
        /// columns (tokens / cacheRead / cacheWrite / TTL all derive
        /// from this breakdown). De-duplicates by `agentId`.
        func aggregateTokensIncludingSubAgents(
            linksByStepUuid: [String: [SubAgentLinker.Link]],
            subAgentTokensByAgentId: [String: TokenBreakdown]
        ) -> TokenBreakdown {
            var seen: Set<String> = []
            var toks: [TokenBreakdown] = [aggregateTokens]
            for step in steps {
                for link in linksByStepUuid[step.uuid] ?? [] where seen.insert(link.agentId).inserted {
                    if let t = subAgentTokensByAgentId[link.agentId] { toks.append(t) }
                }
            }
            return TokenCalculator.aggregateTokens(toks)
        }
    }

    // MARK: - Entry point

    static func group(
        _ steps: [Step],
        knownCodexSkillNames: Set<String>? = nil
    ) -> [OutlineRow] {
        guard !steps.isEmpty else { return [] }
        var cachedKnownCodexSkillNames = knownCodexSkillNames
        func effectiveKnownCodexSkillNames() -> Set<String> {
            if let cachedKnownCodexSkillNames {
                return cachedKnownCodexSkillNames
            }
            let loaded = CodexSkillCatalog.currentSkillNames()
            cachedKnownCodexSkillNames = loaded
            return loaded
        }

        // Pre-compute every skill trigger start index. Simplifies the
        // "extend until next skill" loop below.
        var skillIndices: [Int] = []
        for (i, step) in steps.enumerated() {
            if firstSkillCall(in: step) != nil {
                skillIndices.append(i)
            } else if step.kind == .prompt,
                      promptMayContainCodexSkillCommand(step.text),
                      skillTrigger(
                        in: step,
                        knownCodexSkillNames: effectiveKnownCodexSkillNames()
                      ) != nil {
                skillIndices.append(i)
            }
        }

        var rows: [OutlineRow] = []
        rows.reserveCapacity(steps.count)

        var cursor = 0
        var slot = 0  // index into skillIndices
        while cursor < steps.count {
            if slot < skillIndices.count, cursor == skillIndices[slot] {
                let nextSkillStart = slot + 1 < skillIndices.count
                    ? skillIndices[slot + 1]
                    : steps.count
                // The span runs from `cursor` up to either the next Skill
                // start OR the first Turn-terminator step in between,
                // whichever comes first. Turn terminators are `.reply`
                // (end_turn) and `.stop` (max_tokens / stop_sequence /
                // refusal / unknown) — both mark "the Turn ends here", so
                // a skill group ending on either reads as one cohesive
                // phase. `.reply` / `.stop` themselves stay outside the
                // group as siblings in the main thread.
                var spanEnd = nextSkillStart
                for j in cursor..<nextSkillStart {
                    if steps[j].kind == .reply || steps[j].kind == .stop {
                        spanEnd = j
                        break
                    }
                }
                let slice = Array(steps[cursor..<spanEnd])
                rows.append(.skillGroup(makeGroup(
                    from: slice,
                    knownCodexSkillNames: cachedKnownCodexSkillNames ?? []
                )))
                cursor = spanEnd
                slot += 1
            } else {
                rows.append(.step(steps[cursor]))
                cursor += 1
            }
        }
        return rows
    }

    // MARK: - Private

    private struct SkillTrigger {
        let id: String
        let label: String
        let toolCall: ToolUseInfo?
    }

    private static func makeGroup(
        from slice: [Step],
        knownCodexSkillNames: Set<String>
    ) -> SkillGroup {
        precondition(!slice.isEmpty, "group slice must contain the trigger Step")
        guard let trigger = skillTrigger(
            in: slice[0],
            knownCodexSkillNames: knownCodexSkillNames
        ) else {
            preconditionFailure(
                "makeGroup invariant violated: slice[0] has no skill trigger. " +
                "Call site must only invoke makeGroup with a slice whose first " +
                "step carries a name==\"Skill\" toolCalls entry or Codex $skill prompt."
            )
        }

        // Diagnostic flags: did the skill emit its tool_result / isMeta?
        let hasToolResult: Bool
        let hasIsMetaAnchor: Bool
        if trigger.toolCall != nil {
            let toolResultIndex = slice.firstIndex {
                $0.toolResult?.toolUseId == trigger.id
            }
            hasToolResult = toolResultIndex != nil
            hasIsMetaAnchor = {
                guard let trIdx = toolResultIndex, trIdx + 1 < slice.count else { return false }
                let next = slice[trIdx + 1]
                return next.isSystemInjected && next.kind == .prompt
            }()
        } else {
            hasToolResult = true
            hasIsMetaAnchor = true
        }

        return SkillGroup(
            id: trigger.id,
            label: trigger.label,
            steps: slice,
            aggregateCost: sumCost(slice),
            aggregateTokens: sumTokens(slice),
            hasToolResult: hasToolResult,
            hasIsMetaAnchor: hasIsMetaAnchor
        )
    }

    private static func firstSkillCall(in step: Step) -> ToolUseInfo? {
        step.toolCalls.first { $0.name == "Skill" }
    }

    private static func promptMayContainCodexSkillCommand(_ text: String?) -> Bool {
        guard let text else { return false }
        let lines = text.components(separatedBy: .newlines)
        let candidate: String?
        if let requestHeaderIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveContains("my request for codex:")
        }) {
            candidate = lines[(requestHeaderIndex + 1)...]
                .lazy
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        } else {
            candidate = lines
                .lazy
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        guard let candidate else { return false }
        return candidate.hasPrefix("$") || candidate.hasPrefix("[$")
    }

    private static func skillTrigger(
        in step: Step,
        knownCodexSkillNames: Set<String>
    ) -> SkillTrigger? {
        if let toolCall = firstSkillCall(in: step) {
            return SkillTrigger(
                id: toolCall.id,
                label: label(from: toolCall),
                toolCall: toolCall
            )
        }
        guard step.kind == .prompt,
              let skillName = CostAnalyzer.extractSkillName(
                from: step.text,
                provider: .codex,
                knownCodexSkillNames: knownCodexSkillNames
              ) else {
            return nil
        }
        return SkillTrigger(
            id: step.uuid,
            label: "$" + skillName,
            toolCall: nil
        )
    }

    // MARK: - Label parsing

    /// Produce a display label from the Skill tool metadata.
    /// `ToolUseInfo.skillName` is preferred because it survives snapshot
    /// truncation of long Skill args. Malformed / missing / whitespace inputs
    /// collapse to `"/Skill"`.
    static func label(from trigger: ToolUseInfo) -> String {
        if let skillName = trigger.resolvedSkillName {
            return "/" + skillName
        }
        guard
            let data = trigger.inputJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = obj["skill"] as? String
        else {
            return "/Skill"
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/Skill" : "/" + trimmed
    }

    // MARK: - Aggregation

    private static func sumCost(_ steps: [Step]) -> CostBreakdown {
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

    private static func sumTokens(_ steps: [Step]) -> TokenBreakdown {
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
            contextWindow = maxContextWindow(contextWindow, t.contextWindow)
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

    private static func maxContextWindow(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): return max(lhs, rhs)
        case (.some(let lhs), .none): return lhs
        case (.none, .some(let rhs)): return rhs
        case (.none, .none): return nil
        }
    }
}
