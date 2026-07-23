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
        let totalCost = inputs.displayCost.totalCostUSD

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
            skills: makeSkills(inputs, totalCost: totalCost),
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
        let duration = inputs.turn.startTime.flatMap { start in
            inputs.turn.endTime.map { $0.timeIntervalSince(start) }
        }.flatMap { $0 > 0 ? $0 : nil }

        return TurnAnalysisBundle.Metrics(
            costUSD: metric(cost, median: median(samples.map(\.costUSD))),
            totalTokens: metric(Double(tokens), median: median(samples.map { Double($0.tokens) })),
            durationSeconds: duration.map {
                metric($0, median: median(samples.compactMap(\.durationSeconds)))
            },
            sessionTurnCount: samples.count
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
        let costByCategory = Dictionary(
            result.cost.map { ($0.category, $0.costUSD) },
            uniquingKeysWith: { first, _ in first }
        )
        // Context slices describe what fills the window — the framing that makes
        // "why is this expensive" answerable. Generation slices are folded in by
        // label so a category appearing on both sides reads once.
        return (result.context + result.generation).map { slice in
            TurnAnalysisBundle.TokenSlice(
                label: slice.category.label,
                tokens: slice.estTokens,
                costUSD: costByCategory[slice.category],
                isEstimate: slice.isEstimate
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
        for telemetry in facts.subAgentTelemetry.values.sorted(by: { ($0.seconds ?? 0) > ($1.seconds ?? 0) }) {
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
            measured: measured.sorted { $0.seconds > $1.seconds },
            summary: model?.summaryText
        )
    }

    // MARK: - Prompt

    private static func makePrompt(_ inputs: Inputs, ledger: inout TurnExportLedger) -> String? {
        guard let text = inputs.turn.promptStep?.text, !text.isEmpty else { return nil }
        let clipped = TurnExportBudget.clip(text, head: inputs.budget.promptHead)
        if clipped.count < text.count { ledger.note("prompt tail") }
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
                .sorted { $0.costUSD > $1.costUSD }
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
        // run.
        for (agentId, telemetry) in inputs.rawFacts.subAgentTelemetry where byId[agentId] == nil {
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
        var pending: [String: Pending] = [:]
        var entries: [Int: TurnAnalysisBundle.ToolCallEntry] = [:]
        var ordinal = 0

        for step in steps {
            for call in step.toolCalls {
                ordinal += 1
                let mcp = facts.mcpByStepUuid[step.uuid].map { attribution in
                    attribution.tool.map { "\(attribution.server)/\($0)" } ?? attribution.server
                } ?? facts.namespaceByCallId[call.id]
                pending[call.id] = Pending(
                    ordinal: ordinal,
                    name: call.name,
                    inputSummary: call.abbreviatedInput(limit: 160),
                    timestamp: step.timestamp,
                    mcpServer: mcp
                )
                // Emit immediately so a call whose result never arrived (the
                // turn was interrupted) still appears in the ledger.
                entries[ordinal] = TurnAnalysisBundle.ToolCallEntry(
                    ordinal: ordinal,
                    name: call.name,
                    mcpServer: mcp,
                    inputSummary: call.abbreviatedInput(limit: 160),
                    resultCharacters: nil,
                    isError: false,
                    derivedSeconds: facts.measuredToolSeconds[call.id]
                )
            }

            guard let result = step.toolResult, let call = pending[result.toolUseId] else { continue }
            let derived = facts.measuredToolSeconds[result.toolUseId]
                ?? max(0, step.timestamp.timeIntervalSince(call.timestamp))
            entries[call.ordinal] = TurnAnalysisBundle.ToolCallEntry(
                ordinal: call.ordinal,
                name: call.name,
                mcpServer: call.mcpServer,
                inputSummary: call.inputSummary,
                resultCharacters: result.content.count,
                isError: result.isError,
                derivedSeconds: derived
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
                let seconds = group.compactMap(\.derivedSeconds)
                return TurnAnalysisBundle.ToolTotal(
                    name: name,
                    callCount: group.count,
                    errorCount: group.filter(\.isError).count,
                    totalResultCharacters: group.compactMap(\.resultCharacters).reduce(0, +),
                    derivedSeconds: seconds.isEmpty ? nil : seconds.reduce(0, +)
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
        return caveats
    }

    // MARK: - Helpers

    private static func distinct(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
