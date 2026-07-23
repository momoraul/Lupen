//
//  TurnAnalysisBundle.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import Foundation

/// Everything an AI needs to diagnose one expensive turn, in a form that has
/// already made every judgement call the renderer would otherwise have to make.
///
/// The bundle is **pure data**: no AppKit, no filesystem, no `Date()`. The
/// builder gathers it, the renderer formats it, and both halves are unit-testable
/// on their own — the same split `ReportsCSVExporter` uses.
///
/// ## The honesty contract
///
/// Lupen can measure some things and can only estimate others, and an analyst
/// that cannot tell them apart will confidently blame the wrong thing. Two
/// mechanisms enforce the distinction, and every consumer must preserve it:
///
/// - `Duration.isMeasured` — `false` means the number came from
///   `TurnTimeline`'s gap attribution (JSONL timestamps are *arrival* times, so
///   a step "costs" the gap that ends at it). Only hooks, subagent runs, web
///   search/fetch and Codex MCP calls carry a real measured duration.
/// - `TokenSlice.isEstimate` — mirrors `ContextComposition.Slice.isEstimate`,
///   where only billed anchors (output totals, Codex reasoning, the session
///   baseline) are real and the category split is derived from character shares.
///
/// A field that is unknown is `nil`, never a zero standing in for "unknown" —
/// the renderer prints "unknown" rather than letting a model read 0 as a fact.
struct TurnAnalysisBundle: Sendable, Equatable {

    /// Bumped when the document's shape changes in a way a downstream parser
    /// would notice. Emitted into the document as an HTML comment.
    static let schemaVersion = 1

    let header: Header
    let metrics: Metrics
    let costDrivers: [CostDriver]
    let cacheDiagnostics: CacheDiagnostics
    let tokens: TokenBreakdown
    let cost: CostBreakdown
    let composition: [TokenSlice]
    let timeline: Timeline
    /// The user's opening prompt, verbatim. The single artifact most likely to
    /// be the thing that needs editing, so it is never abbreviated.
    let prompt: String?
    let skills: [SkillEntry]
    let subAgents: [SubAgentEntry]
    let toolCalls: [ToolCallEntry]
    let toolTotals: [ToolTotal]
    let trace: [TraceEntry]
    /// What the budget dropped, in human terms. Empty when nothing was cut.
    let omissions: [String]
    /// Non-fatal problems worth stating out loud in the document — e.g. the
    /// source log was deleted so tool payloads are unavailable. Silence here
    /// would let the analyst read an incomplete picture as a complete one.
    let caveats: [String]

    // MARK: - Header

    struct Header: Sendable, Equatable {
        let provider: ProviderKind
        let sessionId: String
        let turnId: String
        let projectLabel: String?
        let sessionTitle: String?
        let gitBranch: String?
        let workingDirectory: String?
        /// Every distinct model that billed inside this turn, in first-seen order.
        let models: [String]
        let startedAt: Date?
        let endedAt: Date?
        let stepCount: Int
        let billableStepCount: Int
        let isComplete: Bool
        let isInterrupted: Bool
        let endedWithApiError: Bool
        /// Distinct `stop_reason` values seen, in first-seen order.
        let stopReasons: [String]
        /// `nil` when every step's cost was exact; otherwise the weakest
        /// confidence found, so the document can flag an approximate total.
        let costConfidence: CostConfidence?

        /// Codex `turn_context` fields. All `nil` on Claude, which has no
        /// equivalent per-turn configuration record.
        let reasoningEffort: String?
        let personality: String?
        let approvalPolicy: String?
        let sandboxPolicy: String?

        var duration: TimeInterval? {
            guard let startedAt, let endedAt else { return nil }
            let seconds = endedAt.timeIntervalSince(startedAt)
            return seconds > 0 ? seconds : nil
        }
    }

    // MARK: - Metrics

    /// One headline number plus how unusual it is *within its own session*.
    ///
    /// The comparison is the reason this section exists. Absolute cost cannot
    /// distinguish "wasteful" from "genuinely big task"; a multiple of the
    /// session's own median can. Median rather than mean for the same reason
    /// `recomputeCostOutlierThreshold` works session-relative: one runaway turn
    /// would drag a mean upward and hide itself.
    struct Metric: Sendable, Equatable {
        let value: Double
        /// `value / session median`. `nil` when the session has no other turn
        /// to compare against, or the median is zero.
        let ratioToSessionMedian: Double?
    }

    struct Metrics: Sendable, Equatable {
        let costUSD: Metric
        let totalTokens: Metric
        /// `nil` when the turn has no usable start/end pair.
        let durationSeconds: Metric?
        /// Total turns in the session (raw sample count) — drives the "too few
        /// turns" caveat.
        let sessionTurnCount: Int
        /// Turns that actually backed the cost ratio (positive-cost samples).
        /// The baseline note keys on this, not `sessionTurnCount`, so it never
        /// claims a baseline the "vs. median" cells don't show — a session
        /// whose other turns are zero-cost stubs has ratios of "—" and no note.
        let baselineTurnCount: Int
    }

    // MARK: - Cost attribution

    /// One line of "where the money went", already ranked.
    struct CostDriver: Sendable, Equatable {
        let label: String
        let costUSD: Double
        /// 0…1 of the turn's total cost.
        let share: Double
    }

    /// Why the context was re-billed at input rate instead of cache-read rate.
    ///
    /// This is the highest-value signal in the whole bundle: a cache miss
    /// silently multiplies the cost of a long context, and nothing else in
    /// Lupen's decoded data explains a sudden spike. Claude records it as
    /// `message.diagnostics.cache_miss_reason`; there is no Codex equivalent.
    struct CacheDiagnostics: Sendable, Equatable {
        /// Assistant messages in this turn that reported a cache miss.
        let missCount: Int
        /// Reason type → occurrences, e.g. `previous_message_not_found: 3`.
        let reasonCounts: [String: Int]

        static let none = CacheDiagnostics(missCount: 0, reasonCounts: [:])

        var isEmpty: Bool { missCount == 0 }
    }

    // MARK: - Composition

    /// A `ContextComposition` slice flattened for rendering, keeping the
    /// estimate flag intact.
    struct TokenSlice: Sendable, Equatable {
        let label: String
        let tokens: Int
        let costUSD: Double?
        let isEstimate: Bool
    }

    // MARK: - Timing

    /// A span of time with its provenance attached. `isMeasured == false` means
    /// gap-attributed — real enough to rank by, not to quote as a fact.
    struct TimedSpan: Sendable, Equatable {
        let label: String
        let seconds: TimeInterval
        let isMeasured: Bool
        /// Optional extra context, e.g. the hook's command or the agent type.
        let detail: String?
    }

    struct Timeline: Sendable, Equatable {
        /// Wall clock, first step to last.
        let totalSeconds: TimeInterval?
        /// `TurnTimeline` lanes — always derived.
        let lanes: [TimedSpan]
        /// Hooks, subagent runs, web search/fetch, Codex MCP calls — the only
        /// durations the logs actually record.
        let measured: [TimedSpan]
        /// `TurnTimeline.summaryText`, e.g. "3m 42s · Bash 62% · Thinking 18%".
        let summary: String?

        static let empty = Timeline(totalSeconds: nil, lanes: [], measured: [], summary: nil)
    }

    // MARK: - Skills / subagents

    struct SkillEntry: Sendable, Equatable {
        let name: String
        let stepCount: Int
        let tokens: Int
        let costUSD: Double
        /// 0…1 of the turn's direct step cost (excludes sub-agent turns, the
        /// same scope as `costUSD`, so the fraction is apples-to-apples).
        let shareOfTurn: Double
        /// `true` when the name came from Claude's `attributionSkill` (ground
        /// truth, stamped on every entry a skill produced) rather than from
        /// `SkillGroupBuilder`'s step-ordering inference.
        let isAttributed: Bool
    }

    struct SubAgentEntry: Sendable, Equatable {
        let identifier: String
        /// Claude `agentType` / Codex `agent_type`, e.g. `general-purpose`.
        let agentType: String?
        /// Codex nickname, when the spawn output supplied one.
        let nickname: String?
        let description: String?
        let model: String?
        /// Measured, from `toolUseResult.totalDurationMs` — not gap-attributed.
        let durationSeconds: TimeInterval?
        let tokens: Int?
        let toolCallCount: Int?
        let costUSD: Double?
        /// `toolStats` rollup: reads / bash / edits / lines added / removed.
        let toolStats: [String: Int]
    }

    // MARK: - Tools

    struct ToolCallEntry: Sendable, Equatable {
        let ordinal: Int
        let name: String
        /// MCP server, when the call went through one.
        let mcpServer: String?
        let inputSummary: String
        let resultCharacters: Int?
        let isError: Bool
        /// Time attributed to the call. A measured value (web tools, MCP) when
        /// available, else `tool_result.timestamp − tool_use.timestamp` — Claude
        /// has no native per-call duration, so the fallback is derived.
        let derivedSeconds: TimeInterval?
        /// `true` when `derivedSeconds` came from a tool-reported measurement
        /// (WebSearch/WebFetch, Codex MCP) rather than the timestamp gap. The
        /// column is labelled derived by default, so a measured call must say so
        /// or the analyst discounts the turn's most reliable timing.
        let isMeasured: Bool
        /// `true` when `derivedSeconds` is a derived gap past
        /// `TurnTimeline.idleBreakThreshold`: the wait very likely contains a
        /// permission prompt or the user stepping away, not tool compute. Same
        /// flag the step trace carries, so the two views agree.
        let includesLikelyIdle: Bool
    }

    /// Per-tool rollup — the "you called Read 41 times" view that a
    /// call-by-call ledger buries.
    struct ToolTotal: Sendable, Equatable {
        let name: String
        let callCount: Int
        let errorCount: Int
        let totalResultCharacters: Int
        let derivedSeconds: TimeInterval?
        /// `true` only when every timed call folded into this total was
        /// tool-measured; a mix stays derived (the conservative label).
        let allMeasured: Bool
        /// `true` when any call folded into this total was idle-inflated, so the
        /// summed time cannot be read as pure tool compute.
        let includesLikelyIdle: Bool
    }

    // MARK: - Trace

    struct TraceEntry: Sendable, Equatable {
        let ordinal: Int
        let kind: StepKind
        let timestamp: Date?
        /// Time attributed to this step: the gap from the previous step, per
        /// `TurnTimeline`'s rule that a gap belongs to the step arriving at its
        /// end (JSONL timestamps are arrival times).
        ///
        /// `nil` for the first step (no predecessor) and for `.prompt` steps,
        /// where the preceding gap is the user composing their message, not
        /// work the turn performed. Reporting that as a step duration would
        /// invite an analyst to "optimize" the user's thinking time.
        let derivedSeconds: TimeInterval?
        /// `true` when the gap exceeds `TurnTimeline.idleBreakThreshold`, so it
        /// very likely contains waiting rather than compute — the same stretch
        /// the timeline card compresses out of its axis.
        let includesLikelyIdle: Bool
        let model: String?
        /// Already budget-truncated by the builder, with omission markers in
        /// place. The renderer never truncates.
        let body: String?
        let tokens: Int?
        let costUSD: Double?
    }
}
