//
//  TurnAnalysisBundleBuilder.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import Foundation

/// Assembles a `TurnAnalysisBundle` from everything Lupen already knows about a
/// turn, plus the raw-line facts its decoders skip.
///
/// Pure: no filesystem, no `Date()`, no AppKit. The caller gathers the inputs
/// (which is where the I/O lives) and this decides what the document says.
///
/// ## Two invariants worth stating
///
/// 1. **The headline numbers come from the caller, not from recomputation.**
///    `displayCost` / `displayTokens` are the same values the outline header
///    shows, threaded through exactly as `DetailViewController.showTurn`
///    requires them. Recomputing here would let the export quietly disagree with
///    the row the user right-clicked — the specific desync those required
///    parameters exist to prevent.
/// 2. **Sub-agent rollups are not re-added.** The caller has already decided
///    whether its numbers include sub-agents; summing them again here would
///    double-count, the hazard `Turn.aggregateCost`'s documentation warns about.
enum TurnAnalysisBundleBuilder {

    /// One turn's headline numbers, used to build the session baseline the
    /// export compares against.
    struct MetricSample: Sendable, Equatable {
        let costUSD: Double
        let tokens: Int
        let durationSeconds: TimeInterval?

        init(costUSD: Double, tokens: Int, durationSeconds: TimeInterval?) {
            self.costUSD = costUSD
            self.tokens = tokens
            self.durationSeconds = durationSeconds
        }
    }

    struct Inputs: Sendable {
        let turn: Turn
        let provider: ProviderKind
        let displayCost: CostBreakdown
        let displayTokens: TokenBreakdown
        let projectLabel: String?
        let sessionTitle: String?
        /// Wall clock for this turn, measured the same way the baseline samples
        /// are. `nil` falls back to the step-timestamp span.
        let turnDurationSeconds: TimeInterval?
        /// Every turn in the session, including this one — the comparison basis.
        let sessionSamples: [MetricSample]
        let skillGroups: [SkillGroupBuilder.SkillGroup]
        let subAgentLinks: [SubAgentLinker.Link]
        let subAgentCostByAgentId: [String: CostBreakdown]
        let composition: ContextComposition.Result?
        let rawFacts: TurnRawFacts
        let budget: TurnExportBudget

        init(
            turn: Turn,
            provider: ProviderKind,
            displayCost: CostBreakdown,
            displayTokens: TokenBreakdown,
            projectLabel: String? = nil,
            sessionTitle: String? = nil,
            turnDurationSeconds: TimeInterval? = nil,
            sessionSamples: [MetricSample] = [],
            skillGroups: [SkillGroupBuilder.SkillGroup] = [],
            subAgentLinks: [SubAgentLinker.Link] = [],
            subAgentCostByAgentId: [String: CostBreakdown] = [:],
            composition: ContextComposition.Result? = nil,
            rawFacts: TurnRawFacts = TurnRawFacts(),
            budget: TurnExportBudget = .default
        ) {
            self.turn = turn
            self.provider = provider
            self.displayCost = displayCost
            self.displayTokens = displayTokens
            self.projectLabel = projectLabel
            self.sessionTitle = sessionTitle
            self.turnDurationSeconds = turnDurationSeconds
            self.sessionSamples = sessionSamples
            self.skillGroups = skillGroups
            self.subAgentLinks = subAgentLinks
            self.subAgentCostByAgentId = subAgentCostByAgentId
            self.composition = composition
            self.rawFacts = rawFacts
            self.budget = budget
        }
    }

    // MARK: - Entry point

    static func build(_ inputs: Inputs) -> TurnAnalysisBundle {
        var ledger = TurnExportLedger(budget: inputs.budget)
        let steps = inputs.turn.steps
        // Skill shares divide by the turn's OWN direct step cost, not the
        // display total: a skill's cost is summed from its steps (which never
        // include sub-agent turns), so dividing by a sub-agent-inclusive total
        // would understate every skill. Same scope on both sides.
        let directCost = steps.compactMap(\.cost).reduce(0) { $0 + $1.totalCostUSD }

        let toolCalls = makeToolCalls(steps: steps, facts: inputs.rawFacts)

        return TurnAnalysisBundle(
            header: makeHeader(inputs),
            metrics: makeMetrics(inputs),
            costDrivers: makeCostDrivers(inputs.displayCost),
            cacheDiagnostics: makeCacheDiagnostics(inputs.rawFacts),
            tokens: inputs.displayTokens,
            cost: inputs.displayCost,
            composition: makeComposition(inputs.composition),
            timeline: makeTimeline(steps: steps, facts: inputs.rawFacts),
            prompt: makePrompt(inputs, ledger: &ledger),
            skills: makeSkills(inputs, totalCost: directCost),
            subAgents: makeSubAgents(inputs),
            toolCalls: toolCalls,
            toolTotals: makeToolTotals(toolCalls),
            trace: makeTrace(steps: steps, budget: inputs.budget, ledger: &ledger),
            omissions: ledger.omissions,
            caveats: makeCaveats(inputs)
        )
    }

    // MARK: - Header

    private static func makeHeader(_ inputs: Inputs) -> TurnAnalysisBundle.Header {
        let steps = inputs.turn.steps
        let confidence = CostConfidence.evaluate(provider: inputs.provider, steps: steps)
        return TurnAnalysisBundle.Header(
            provider: inputs.provider,
            sessionId: inputs.turn.sessionId,
            turnId: inputs.turn.id,
            projectLabel: inputs.projectLabel,
            sessionTitle: inputs.sessionTitle,
            gitBranch: inputs.rawFacts.gitBranch,
            workingDirectory: inputs.rawFacts.workingDirectory,
            models: distinct(steps.compactMap(\.model).filter { $0 != "<synthetic>" }),
            startedAt: inputs.turn.startTime,
            endedAt: inputs.turn.endTime,
            stepCount: inputs.turn.stepCount,
            billableStepCount: inputs.turn.billableStepCount,
            isComplete: inputs.turn.isComplete,
            isInterrupted: inputs.turn.isInterrupted,
            endedWithApiError: inputs.turn.endedWithApiError,
            stopReasons: distinct(steps.compactMap(\.stopReason)),
            costConfidence: confidence == .exact ? nil : confidence,
            reasoningEffort: inputs.rawFacts.reasoningEffort,
            personality: inputs.rawFacts.personality,
            approvalPolicy: inputs.rawFacts.approvalPolicy,
            sandboxPolicy: inputs.rawFacts.sandboxPolicy
        )
    }

    // MARK: - Metrics

    private static func makeMetrics(_ inputs: Inputs) -> TurnAnalysisBundle.Metrics {
        let samples = inputs.sessionSamples
        let cost = inputs.displayCost.totalCostUSD
        let tokens = inputs.displayTokens.totalContextTokens
        // Prefer the caller's duration (same aggregate-preferred clock as the
        // baseline samples); fall back to the step-timestamp span only when the
        // caller supplied none, so numerator and denominator stay comparable.
        let duration = inputs.turnDurationSeconds ?? inputs.turn.startTime.flatMap { start in
            inputs.turn.endTime.map { $0.timeIntervalSince(start) }
        }.flatMap { $0 > 0 ? $0 : nil }

        // A ratio needs at least one OTHER turn to compare against. `samples`
        // always includes this turn, so a lone-turn session would otherwise
        // report "1.0×" — the turn measured against itself. Gate on the count
        // AFTER the positive filter median() applies, not the raw sample count:
        // a 2-turn session whose other turn contributes a zero or nil value
        // (a SQLite-first stub reports duration 0) collapses back to this turn
        // alone, which would still read 1.0× if we trusted samples.count.
        func baseline(_ values: [Double]) -> Double? {
            values.filter { $0 > 0 }.count >= 2 ? median(values) : nil
        }

        return TurnAnalysisBundle.Metrics(
            costUSD: metric(cost, median: baseline(samples.map(\.costUSD))),
            totalTokens: metric(Double(tokens), median: baseline(samples.map { Double($0.tokens) })),
            durationSeconds: duration.map {
                metric($0, median: baseline(samples.compactMap(\.durationSeconds)))
            },
            sessionTurnCount: samples.count,
            // The population that actually backs the cost ratio (the headline
            // metric); the note keys on this so it never overstates the baseline.
            baselineTurnCount: samples.filter { $0.costUSD > 0 }.count
        )
    }

    private static func metric(_ value: Double, median: Double?) -> TurnAnalysisBundle.Metric {
        guard let median, median > 0 else {
            return TurnAnalysisBundle.Metric(value: value, ratioToSessionMedian: nil)
        }
        return TurnAnalysisBundle.Metric(value: value, ratioToSessionMedian: value / median)
    }

    /// Median rather than mean, for the same reason the outline's cost-outlier
    /// threshold is session-relative: one runaway turn drags a mean upward and
    /// ends up hiding itself behind its own contribution.
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    // MARK: - Cost drivers

    /// Ranks the billing categories. This is the "where did the money go" answer
    /// and it comes straight from the real billed components — no estimation.
    static func makeCostDrivers(_ cost: CostBreakdown) -> [TurnAnalysisBundle.CostDriver] {
        let total = cost.totalCostUSD
        guard total > 0 else { return [] }
        let raw: [(String, Double)] = [
            ("Output & reasoning", cost.outputCostUSD),
            ("Cache writes", cost.cacheCreate1hCostUSD + cost.cacheCreate5mCostUSD),
            ("Input (uncached)", cost.inputCostUSD),
            ("Cache reads", cost.cacheReadCostUSD)
        ]
        return raw
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { TurnAnalysisBundle.CostDriver(label: $0.0, costUSD: $0.1, share: $0.1 / total) }
    }

    private static func makeCacheDiagnostics(_ facts: TurnRawFacts) -> TurnAnalysisBundle.CacheDiagnostics {
        guard !facts.cacheMissReasons.isEmpty else { return .none }
        return TurnAnalysisBundle.CacheDiagnostics(
            missCount: facts.cacheMissReasons.values.reduce(0, +),
            reasonCounts: facts.cacheMissReasons
        )
    }

    // MARK: - Composition

    private static func makeComposition(
        _ result: ContextComposition.Result?
    ) -> [TurnAnalysisBundle.TokenSlice] {
        guard let result else { return [] }
        // A category can appear on BOTH the context and generation sides — Reply
        // is the common case (its text both fills the window and is generated
        // output). `result.cost` has already merged those into one entry per
        // category whose sum equals the real billed total, so driving the table
        // off it makes each category — and its cost — appear exactly once and
        // the cost column reconcile. Concatenating context+generation instead
        // would print Reply twice, each with the full merged cost.
        var tokensByCategory: [ContextComposition.Category: Int] = [:]
        // `isEstimate` must describe the TOKEN count, not the cost. Every
        // `CostSlice` is flagged estimate, but some token slices are exact
        // (the system baseline, Codex reasoning), so read the flag from the
        // token side or those exact rows would be mislabelled "(est.)".
        var estimateByCategory: [ContextComposition.Category: Bool] = [:]
        for slice in result.context + result.generation {
            tokensByCategory[slice.category, default: 0] += slice.estTokens
            estimateByCategory[slice.category] =
                (estimateByCategory[slice.category] ?? false) || slice.isEstimate
        }
        return result.cost
            .sorted { $0.costUSD > $1.costUSD }
            .map { slice in
                TurnAnalysisBundle.TokenSlice(
                    label: slice.category.label,
                    tokens: tokensByCategory[slice.category] ?? 0,
                    costUSD: slice.costUSD,
                    isEstimate: estimateByCategory[slice.category] ?? slice.isEstimate
                )
            }
    }

    // MARK: - Timeline

    private static func makeTimeline(
        steps: [Step],
        facts: TurnRawFacts
    ) -> TurnAnalysisBundle.Timeline {
        let model = TurnTimeline.build(steps: steps)
        let lanes = (model?.lanes ?? []).map {
            TurnAnalysisBundle.TimedSpan(
                label: $0.name,
                seconds: $0.totalDuration,
                isMeasured: false,
                detail: nil
            )
        }

        // The only durations the logs actually record. Kept separate from the
        // lanes so the document can never imply a derived number was measured.
        var measured: [TurnAnalysisBundle.TimedSpan] = []
        for hook in facts.hooks {
            measured.append(TurnAnalysisBundle.TimedSpan(
                label: "Hook",
                seconds: hook.seconds,
                isMeasured: true,
                detail: hook.command
            ))
        }
        // Iterate the telemetry dict in a fixed order (by agent id) — the final
        // sort below is by seconds, and Swift's sort is unstable, so a
        // dict-ordered source would reorder equal-seconds spans across launches.
        for telemetry in facts.subAgentTelemetry.sorted(by: { $0.key < $1.key }).map(\.value) {
            guard let seconds = telemetry.seconds else { continue }
            measured.append(TurnAnalysisBundle.TimedSpan(
                label: "Subagent",
                seconds: seconds,
                isMeasured: true,
                detail: telemetry.agentType ?? telemetry.agentId
            ))
        }
        return TurnAnalysisBundle.Timeline(
            totalSeconds: model?.totalDuration,
            lanes: lanes,
            // Total-order tiebreak so ties don't depend on append/sort stability.
            measured: measured.sorted {
                $0.seconds != $1.seconds
                    ? $0.seconds > $1.seconds
                    : ($0.label, $0.detail ?? "") < ($1.label, $1.detail ?? "")
            },
            summary: model?.summaryText
        )
    }

    // MARK: - Prompt

    private static func makePrompt(_ inputs: Inputs, ledger: inout TurnExportLedger) -> String? {
        guard let text = inputs.turn.promptStep?.text, !text.isEmpty else { return nil }
        let clipped = TurnExportBudget.clip(text, head: inputs.budget.promptHead)
        // Test truncation by the source length, not `clipped.count < text.count`:
        // for a prompt only slightly over the cap the omission marker is longer
        // than the few characters it replaced, so the clipped string can be
        // *longer* than the original and the drop would go unrecorded.
        if text.count > inputs.budget.promptHead { ledger.note("prompt tail") }
        ledger.spend(clipped.count)
        return clipped
    }

    // MARK: - Skills

    /// Prefers Claude's `attributionSkill` — stamped on every entry a skill
    /// produced, so spans are exact — and falls back to `SkillGroupBuilder`'s
    /// ordering-based inference when attribution is absent (Codex, or older
    /// logs). The `isAttributed` flag travels with the entry so the document can
    /// say which one the reader is looking at.
    private static func makeSkills(
        _ inputs: Inputs,
        totalCost: Double
    ) -> [TurnAnalysisBundle.SkillEntry] {
        let attribution = inputs.rawFacts.skillByStepUuid
        if !attribution.isEmpty {
            var stepsByName: [String: [Step]] = [:]
            for step in inputs.turn.steps {
                guard let name = attribution[step.uuid] else { continue }
                stepsByName[name, default: []].append(step)
            }
            return stepsByName
                .map { name, steps in
                    let cost = steps.compactMap(\.cost).reduce(0) { $0 + $1.totalCostUSD }
                    return TurnAnalysisBundle.SkillEntry(
                        name: name,
                        stepCount: steps.count,
                        tokens: steps.compactMap(\.tokens).reduce(0) { $0 + $1.totalContextTokens },
                        costUSD: cost,
                        shareOfTurn: totalCost > 0 ? cost / totalCost : 0,
                        isAttributed: true
                    )
                }
                // Name tiebreak: `stepsByName` is a dict, so equal-cost skills
                // would otherwise order by hash — nondeterministic per launch.
                .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.name < $1.name }
        }

        return inputs.skillGroups
            .map { group in
                let cost = group.aggregateCost.totalCostUSD
                return TurnAnalysisBundle.SkillEntry(
                    name: group.label,
                    stepCount: group.steps.count,
                    tokens: group.aggregateTokens.totalContextTokens,
                    costUSD: cost,
                    shareOfTurn: totalCost > 0 ? cost / totalCost : 0,
                    isAttributed: false
                )
            }
            .sorted { $0.costUSD > $1.costUSD }
    }

    // MARK: - Sub-agents

    private static func makeSubAgents(_ inputs: Inputs) -> [TurnAnalysisBundle.SubAgentEntry] {
        var byId: [String: TurnAnalysisBundle.SubAgentEntry] = [:]
        var order: [String] = []

        for link in inputs.subAgentLinks {
            if byId[link.agentId] == nil { order.append(link.agentId) }
            let telemetry = inputs.rawFacts.subAgentTelemetry[link.agentId]
            byId[link.agentId] = TurnAnalysisBundle.SubAgentEntry(
                identifier: link.agentId,
                agentType: telemetry?.agentType ?? link.subagentType,
                nickname: link.workflowLabel,
                description: telemetry?.description ?? link.description,
                model: telemetry?.resolvedModel ?? link.workflowModel,
                // Prefer the measured `totalDurationMs` over the workflow
                // telemetry field; both are measured, but the former is present
                // on plain Agent runs too.
                durationSeconds: telemetry?.seconds
                    ?? link.workflowDurationMs.map { Double($0) / 1000 },
                tokens: telemetry?.totalTokens ?? link.workflowTelemetryTokens,
                toolCallCount: telemetry?.toolCallCount ?? link.workflowToolCalls,
                costUSD: inputs.subAgentCostByAgentId[link.agentId]?.totalCostUSD,
                toolStats: telemetry?.toolStats ?? [:]
            )
        }

        // Telemetry can name an agent no link resolved (the parent's tool_result
        // survived but the link did not) — keep it rather than losing a measured
        // run. Iterate by agent id, not dict hash order, so these fallback
        // agents appear in the same order across two exports of one turn.
        for (agentId, telemetry) in inputs.rawFacts.subAgentTelemetry
            .sorted(by: { $0.key < $1.key }) where byId[agentId] == nil {
            order.append(agentId)
            byId[agentId] = TurnAnalysisBundle.SubAgentEntry(
                identifier: agentId,
                agentType: telemetry.agentType,
                nickname: nil,
                description: telemetry.description,
                model: telemetry.resolvedModel,
                durationSeconds: telemetry.seconds,
                tokens: telemetry.totalTokens,
                toolCallCount: telemetry.toolCallCount,
                costUSD: inputs.subAgentCostByAgentId[agentId]?.totalCostUSD,
                toolStats: telemetry.toolStats
            )
        }

        return order.compactMap { byId[$0] }
    }

    // MARK: - Tools

    /// Walks the turn once, pairing each `tool_use` with the `tool_result` that
    /// answers it.
    ///
    /// The latency is **derived**: Claude records no per-call duration, so the
    /// only available signal is the delta between the call's arrival timestamp
    /// and its result's. Millisecond precision makes that meaningful, but it
    /// still includes any queueing, so the bundle marks it derived and the
    /// renderer labels it.
    static func makeToolCalls(
        steps: [Step],
        facts: TurnRawFacts
    ) -> [TurnAnalysisBundle.ToolCallEntry] {
        struct Pending {
            let ordinal: Int
            let name: String
            let inputSummary: String
            let timestamp: Date
            let mcpServer: String?
        }
        // Queue per id, not a single slot: Codex can synthesize a `call_id`
        // that repeats within a turn, and overwriting would strand the first
        // call with no result and pin its result onto the second. FIFO pairs
        // each result with the oldest unmatched call of that id.
        var pending: [String: [Pending]] = [:]
        var entries: [Int: TurnAnalysisBundle.ToolCallEntry] = [:]
        var ordinal = 0

        for step in steps {
            for call in step.toolCalls {
                ordinal += 1
                let mcp = facts.mcpByStepUuid[step.uuid].map { attribution in
                    attribution.tool.map { "\(attribution.server)/\($0)" } ?? attribution.server
                } ?? facts.namespaceByCallId[call.id]
                pending[call.id, default: []].append(Pending(
                    ordinal: ordinal,
                    name: call.name,
                    inputSummary: call.abbreviatedInput(limit: 160),
                    timestamp: step.timestamp,
                    mcpServer: mcp
                ))
                // Emit immediately so a call whose result never arrived (the
                // turn was interrupted) still appears in the ledger.
                entries[ordinal] = TurnAnalysisBundle.ToolCallEntry(
                    ordinal: ordinal,
                    name: call.name,
                    mcpServer: mcp,
                    inputSummary: call.abbreviatedInput(limit: 160),
                    resultCharacters: nil,
                    isError: false,
                    derivedSeconds: facts.measuredToolSeconds[call.id],
                    isMeasured: facts.measuredToolSeconds[call.id] != nil,
                    includesLikelyIdle: false
                )
            }

            guard let result = step.toolResult,
                  var queue = pending[result.toolUseId], !queue.isEmpty else { continue }
            let call = queue.removeFirst()
            pending[result.toolUseId] = queue
            // A measured value is real tool time; the timestamp-delta fallback
            // can absorb a permission prompt or the user stepping away, so flag
            // it as likely-idle past the same threshold the step trace uses —
            // otherwise a tool that ran in milliseconds ranks first for "time".
            let measured = facts.measuredToolSeconds[result.toolUseId]
            let gap = max(0, step.timestamp.timeIntervalSince(call.timestamp))
            let derived = measured ?? gap
            let idle = measured == nil && gap > TurnTimeline.idleBreakThreshold
            entries[call.ordinal] = TurnAnalysisBundle.ToolCallEntry(
                ordinal: call.ordinal,
                name: call.name,
                mcpServer: call.mcpServer,
                inputSummary: call.inputSummary,
                resultCharacters: result.content.count,
                isError: result.isError,
                derivedSeconds: derived,
                isMeasured: measured != nil,
                includesLikelyIdle: idle
            )
        }
        return entries.keys.sorted().compactMap { entries[$0] }
    }

    static func makeToolTotals(
        _ calls: [TurnAnalysisBundle.ToolCallEntry]
    ) -> [TurnAnalysisBundle.ToolTotal] {
        var order: [String] = []
        var grouped: [String: [TurnAnalysisBundle.ToolCallEntry]] = [:]
        for call in calls {
            if grouped[call.name] == nil { order.append(call.name) }
            grouped[call.name, default: []].append(call)
        }
        return order
            .compactMap { name -> TurnAnalysisBundle.ToolTotal? in
                guard let group = grouped[name] else { return nil }
                let timed = group.filter { $0.derivedSeconds != nil }
                let seconds = timed.compactMap(\.derivedSeconds)
                return TurnAnalysisBundle.ToolTotal(
                    name: name,
                    callCount: group.count,
                    errorCount: group.filter(\.isError).count,
                    totalResultCharacters: group.compactMap(\.resultCharacters).reduce(0, +),
                    derivedSeconds: seconds.isEmpty ? nil : seconds.reduce(0, +),
                    allMeasured: !timed.isEmpty && timed.allSatisfy(\.isMeasured),
                    includesLikelyIdle: group.contains(where: \.includesLikelyIdle)
                )
            }
            .sorted { ($0.derivedSeconds ?? 0, $0.callCount) > ($1.derivedSeconds ?? 0, $1.callCount) }
    }

    // MARK: - Trace

    private static func makeTrace(
        steps: [Step],
        budget: TurnExportBudget,
        ledger: inout TurnExportLedger
    ) -> [TurnAnalysisBundle.TraceEntry] {
        var entries: [TurnAnalysisBundle.TraceEntry] = []
        entries.reserveCapacity(steps.count)

        for (index, step) in steps.enumerated() {
            let body = traceBody(for: step, budget: budget)
            // Bodies degrade first when the budget runs out — the tool ledger
            // above already names every call, so the trace losing its prose
            // costs the least understanding per character reclaimed.
            let admitted = body.flatMap { ledger.admit($0, describedAs: "step body") }
            let gap = stepGap(at: index, in: steps)
            entries.append(TurnAnalysisBundle.TraceEntry(
                ordinal: index + 1,
                kind: step.kind,
                timestamp: step.timestamp,
                derivedSeconds: gap,
                includesLikelyIdle: (gap ?? 0) > TurnTimeline.idleBreakThreshold,
                model: step.model,
                body: admitted,
                tokens: step.tokens?.totalContextTokens,
                costUSD: step.cost?.totalCostUSD
            ))
        }
        return entries
    }

    /// Time attributed to the step at `index`, following `TurnTimeline`'s
    /// arrival-time rule.
    ///
    /// Returns `nil` for the first step and for prompts. A prompt's preceding
    /// gap is the user writing their message — real elapsed time, but not time
    /// the turn spent, and labelling it "step duration" would point an analyst
    /// at the one thing they cannot optimize.
    static func stepGap(at index: Int, in steps: [Step]) -> TimeInterval? {
        guard index > 0, index < steps.count else { return nil }
        let step = steps[index]
        guard step.kind != .prompt else { return nil }
        let gap = step.timestamp.timeIntervalSince(steps[index - 1].timestamp)
        return gap > 0 ? gap : nil
    }

    private static func traceBody(for step: Step, budget: TurnExportBudget) -> String? {
        switch step.kind {
        case .thought:
            if let thinking = step.thinkingText, !thinking.isEmpty {
                return TurnExportBudget.clip(thinking, head: budget.thinkingHead)
            }
            return step.text.map { TurnExportBudget.clip($0, head: budget.traceBodyHead) }
        case .toolResult:
            guard let result = step.toolResult else { return nil }
            return TurnExportBudget.clip(
                result.content,
                head: budget.toolResultHead,
                tail: budget.toolResultTail
            )
        case .toolCall:
            guard let call = step.toolCalls.first else { return nil }
            return TurnExportBudget.clip(call.inputJSON, head: budget.toolInputHead)
        case .prompt, .reply, .stop, .interruption:
            return step.text.map { TurnExportBudget.clip($0, head: budget.traceBodyHead) }
        }
    }

    // MARK: - Caveats

    private static func makeCaveats(_ inputs: Inputs) -> [String] {
        var caveats: [String] = []
        if inputs.turn.steps.isEmpty {
            caveats.append("This turn has no materialized steps — only header aggregates were available.")
        }
        if inputs.rawFacts.missingLineCount > 0 {
            caveats.append(
                "\(inputs.rawFacts.missingLineCount) source line(s) could not be read "
                + "(the log was rotated or rewritten), so tool payloads and raw diagnostics "
                + "are incomplete for those steps."
            )
        }
        if inputs.rawFacts.isEmpty {
            caveats.append(
                "Raw-log enrichment found nothing — cache-miss reasons, hook timings and "
                + "subagent telemetry are unavailable for this turn."
            )
        }
        if inputs.sessionSamples.count < 3 {
            caveats.append(
                "Too few turns in this session for a meaningful baseline, so the "
                + "\"vs. session median\" column is weak evidence."
            )
        }
        // Skill shares divide by direct step cost; when sub-agents contributed,
        // say so, or a reader takes the shares as a fraction of the (larger)
        // headline total and reads every skill as smaller than it was.
        let directCost = inputs.turn.steps.compactMap(\.cost).reduce(0) { $0 + $1.totalCostUSD }
        let subAgentCost = inputs.displayCost.totalCostUSD - directCost
        if subAgentCost > 0.005, !inputs.rawFacts.skillByStepUuid.isEmpty || !inputs.skillGroups.isEmpty {
            caveats.append(
                "Skill \"share of turn\" is a fraction of this turn's direct step cost "
                + "(\(TurnAnalysisMarkdownRenderer.money(directCost))); sub-agent cost "
                + "(\(TurnAnalysisMarkdownRenderer.money(subAgentCost))) is not attributed to a "
                + "skill and is excluded from these shares."
            )
        }
        return caveats
    }

    // MARK: - Helpers

    private static func distinct(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
