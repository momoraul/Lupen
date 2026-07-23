//
//  TurnRawFacts.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import Foundation

/// Facts recovered from a turn's original JSONL lines that Lupen's decoders do
/// not keep.
///
/// ## Why these live outside the decoders
///
/// Every field here is present on disk and absent from our models. Teaching
/// `RichEntryDecoder` / `CodexEntry` about them would mean bumping
/// `SnapshotSchema.currentVersion` or `ProviderDatabase.schemaVersion`, and a
/// version bump **wipes and re-indexes the user's entire corpus**. That is a
/// heavy, visible cost to pay for a rarely-used, user-initiated export.
///
/// Reading the turn's own raw lines at export time costs one bounded file read
/// and leaves the import path — the hot path — completely untouched.
///
/// Everything is optional or empty-by-default: a log that predates a field, or a
/// source file that has been rotated away, degrades to "we don't know" rather
/// than to a wrong zero.
struct TurnRawFacts: Sendable, Equatable {

    /// `message.diagnostics.cache_miss_reason.type` → occurrences.
    ///
    /// The most valuable entry in this struct. A cache miss re-bills the whole
    /// context at input rate instead of cache-read rate, which is the usual
    /// explanation for a turn that costs many times its neighbours — and
    /// nothing in our decoded data hints at it.
    var cacheMissReasons: [String: Int] = [:]

    /// step uuid → `attributionSkill`. Ground truth: Claude stamps it on every
    /// assistant entry produced while a skill is active, not just on the
    /// invocation, so it gives exact spans where `SkillGroupBuilder` can only
    /// infer them from step ordering.
    var skillByStepUuid: [String: String] = [:]

    /// step uuid → (server, tool) from `attributionMcpServer` /
    /// `attributionMcpTool`. Separates MCP cost from native tool cost.
    var mcpByStepUuid: [String: MCPAttribution] = [:]

    /// Hook executions with their **measured** wall time.
    var hooks: [HookRun] = []

    /// agent id → measured subagent telemetry from `toolUseResult`.
    var subAgentTelemetry: [String: SubAgentTelemetry] = [:]

    /// Measured tool durations keyed by `tool_use` id — WebSearch
    /// (`durationSeconds`), WebFetch (`durationMs`), Codex `mcp_tool_call_end`
    /// (`duration`). Distinct from the derived call latencies the builder
    /// computes from timestamp deltas.
    var measuredToolSeconds: [String: TimeInterval] = [:]

    /// `usage.service_tier`, when reported.
    var serviceTier: String?

    /// Where the work happened. Claude stamps `gitBranch` and `cwd` on every
    /// entry; Codex carries `cwd` on `turn_context`. Both matter to an analyst
    /// reading the turn cold — "which branch was this" is otherwise unanswerable
    /// from the document alone.
    var gitBranch: String?
    var workingDirectory: String?

    /// Codex `turn_context` — configuration that materially changes cost.
    /// `reasoningEffort` in particular drives reasoning-token volume, making it
    /// a first-order explanation for an expensive Codex turn.
    var reasoningEffort: String?
    var personality: String?
    var approvalPolicy: String?
    var sandboxPolicy: String?

    /// Codex `function_call.namespace` by call id — `mcp__serena`,
    /// `multi_agent_v1`, … A clean MCP-vs-native discriminator that is not even
    /// in the payload's `CodingKeys`.
    var namespaceByCallId: [String: String] = [:]

    /// Set when at least one step's raw line could not be read, so the caller
    /// can add a caveat instead of presenting a partial picture as complete.
    var missingLineCount: Int = 0

    var isEmpty: Bool {
        cacheMissReasons.isEmpty && skillByStepUuid.isEmpty && mcpByStepUuid.isEmpty
            && hooks.isEmpty && subAgentTelemetry.isEmpty && measuredToolSeconds.isEmpty
            && serviceTier == nil && reasoningEffort == nil && personality == nil
            && approvalPolicy == nil && sandboxPolicy == nil && namespaceByCallId.isEmpty
            && gitBranch == nil && workingDirectory == nil
    }

    // MARK: - Nested

    struct MCPAttribution: Sendable, Equatable {
        let server: String
        let tool: String?
    }

    struct HookRun: Sendable, Equatable {
        let command: String
        let seconds: TimeInterval
    }

    struct SubAgentTelemetry: Sendable, Equatable {
        let agentId: String
        var agentType: String?
        var description: String?
        var resolvedModel: String?
        var status: String?
        /// Measured — `toolUseResult.totalDurationMs`.
        var seconds: TimeInterval?
        var totalTokens: Int?
        var toolCallCount: Int?
        /// `toolStats`: readCount / bashCount / editFileCount / linesAdded / …
        var toolStats: [String: Int] = [:]
    }
}
