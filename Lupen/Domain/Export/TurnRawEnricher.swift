//
//  TurnRawEnricher.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import Foundation

/// Decodes the undecoded: pulls `TurnRawFacts` out of a turn's original JSONL
/// lines.
///
/// Pure by construction — the caller supplies the bytes (see `TurnRawSource` for
/// the disk-backed one), so every branch here is unit-testable against fixture
/// lines with no filesystem involved.
///
/// Parsing is deliberately defensive: these are fields no schema guarantees, on
/// logs written by tools that keep evolving. A shape we do not recognise is
/// skipped, never fatal — a partial enrichment still improves the document,
/// while a throw would lose the whole export over one odd line.
enum TurnRawEnricher {

    /// - Parameters:
    ///   - rawLines: `(step uuid, original JSONL line)` in **chronological
    ///     (step) order**. Order matters for the single-value "last wins"
    ///     fields (`gitBranch`, `cwd`, `serviceTier`): a `[String: Data]`
    ///     dictionary iterates in hash order, so a turn that switched branch
    ///     mid-way would report an arbitrary — and run-to-run unstable — value.
    ///     An ordered list makes "the value it ended on" both correct and
    ///     deterministic.
    ///   - turnContextLine: Codex `turn_context` envelope for this turn, if one
    ///     was found. Claude has no equivalent, so it is always `nil` there.
    ///   - missingLineCount: steps whose raw line could not be read.
    static func enrich(
        provider: ProviderKind,
        rawLines: [(uuid: String, line: Data)],
        turnContextLine: Data? = nil,
        missingLineCount: Int = 0
    ) -> TurnRawFacts {
        var facts = TurnRawFacts()
        facts.missingLineCount = missingLineCount

        for (uuid, line) in rawLines {
            guard let object = jsonObject(line) else { continue }
            switch provider {
            case .claudeCode: absorbClaude(object, uuid: uuid, into: &facts)
            case .codex: absorbCodex(object, into: &facts)
            }
        }

        if let turnContextLine, let object = jsonObject(turnContextLine) {
            absorbCodexTurnContext(object, into: &facts)
        }
        return facts
    }

    // MARK: - Claude

    private static func absorbClaude(
        _ object: [String: Any],
        uuid: String,
        into facts: inout TurnRawFacts
    ) {
        if let skill = nonEmptyString(object["attributionSkill"]) {
            facts.skillByStepUuid[uuid] = skill
        }
        // Stamped on every entry; last one wins, which is correct — a turn that
        // spans a branch switch should report the branch it ended on.
        facts.gitBranch = nonEmptyString(object["gitBranch"]) ?? facts.gitBranch
        facts.workingDirectory = nonEmptyString(object["cwd"]) ?? facts.workingDirectory
        if let server = nonEmptyString(object["attributionMcpServer"]) {
            facts.mcpByStepUuid[uuid] = TurnRawFacts.MCPAttribution(
                server: server,
                tool: nonEmptyString(object["attributionMcpTool"])
            )
        }

        // Hooks: `[{"command": "...", "durationMs": 131}, {"command": "callback"}]`.
        // Entries without a duration are callbacks with nothing measured — skip
        // them rather than recording a zero that would read as "instant".
        if let hooks = object["hookInfos"] as? [[String: Any]] {
            for hook in hooks {
                guard let command = nonEmptyString(hook["command"]),
                      let ms = double(hook["durationMs"]) else { continue }
                facts.hooks.append(TurnRawFacts.HookRun(command: command, seconds: ms / 1000))
            }
        }

        if let message = object["message"] as? [String: Any] {
            if let diagnostics = message["diagnostics"] as? [String: Any],
               let miss = diagnostics["cache_miss_reason"] as? [String: Any],
               let type = nonEmptyString(miss["type"]) {
                facts.cacheMissReasons[type, default: 0] += 1
            }
            if let usage = message["usage"] as? [String: Any],
               let tier = nonEmptyString(usage["service_tier"]) {
                facts.serviceTier = tier
            }
        }

        if let result = object["toolUseResult"] as? [String: Any] {
            absorbClaudeToolUseResult(result, entry: object, into: &facts)
        }
    }

    /// `toolUseResult` is the richest thing Lupen currently throws away. Its
    /// shape varies by tool; only the two variants that carry *measured* signal
    /// are read here — subagent telemetry and web tool durations.
    private static func absorbClaudeToolUseResult(
        _ result: [String: Any],
        entry: [String: Any],
        into facts: inout TurnRawFacts
    ) {
        if let agentId = nonEmptyString(result["agentId"]) {
            var telemetry = facts.subAgentTelemetry[agentId]
                ?? TurnRawFacts.SubAgentTelemetry(agentId: agentId)
            // Launch and completion records both carry `agentId`; merge rather
            // than overwrite so the launch's `description`/`prompt` survives the
            // completion record that has the numbers.
            telemetry.agentType = nonEmptyString(result["agentType"]) ?? telemetry.agentType
            telemetry.description = nonEmptyString(result["description"]) ?? telemetry.description
            telemetry.resolvedModel = nonEmptyString(result["resolvedModel"]) ?? telemetry.resolvedModel
            telemetry.status = nonEmptyString(result["status"]) ?? telemetry.status
            if let ms = double(result["totalDurationMs"]) { telemetry.seconds = ms / 1000 }
            if let tokens = int(result["totalTokens"]) { telemetry.totalTokens = tokens }
            if let calls = int(result["totalToolUseCount"]) { telemetry.toolCallCount = calls }
            if let stats = result["toolStats"] as? [String: Any] {
                for (key, value) in stats {
                    if let count = int(value) { telemetry.toolStats[key] = count }
                }
            }
            facts.subAgentTelemetry[agentId] = telemetry
        }

        // Web tools report their own duration. Key it by the tool_use id carried
        // on the same entry so it lines up with the tool ledger.
        let seconds = double(result["durationSeconds"])
            ?? double(result["durationMs"]).map { $0 / 1000 }
        if let seconds, let toolUseId = claudeToolUseId(in: entry) {
            facts.measuredToolSeconds[toolUseId] = seconds
        }
    }

    /// A `tool_result` user entry names the call it answers inside
    /// `message.content[].tool_use_id`.
    private static func claudeToolUseId(in entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks {
            if let id = nonEmptyString(block["tool_use_id"]) { return id }
        }
        return nil
    }

    // MARK: - Codex

    private static func absorbCodex(_ object: [String: Any], into facts: inout TurnRawFacts) {
        // Codex rollout lines are `{timestamp, type, payload}`. A step's line is
        // a `response_item` / `event_msg`; `turn_context` arrives separately and
        // is handled by `absorbCodexTurnContext`.
        if nonEmptyString(object["type"]) == "turn_context" {
            absorbCodexTurnContext(object, into: &facts)
            return
        }
        guard let payload = object["payload"] as? [String: Any] else { return }

        if let namespace = nonEmptyString(payload["namespace"]),
           let callId = nonEmptyString(payload["call_id"]) {
            facts.namespaceByCallId[callId] = namespace
        }

        if nonEmptyString(payload["type"]) == "mcp_tool_call_end",
           let callId = nonEmptyString(payload["call_id"]),
           let seconds = codexDuration(payload["duration"]) {
            facts.measuredToolSeconds[callId] = seconds
        }
    }

    private static func absorbCodexTurnContext(
        _ object: [String: Any],
        into facts: inout TurnRawFacts
    ) {
        // Accept either the full envelope or a bare payload, so a caller that
        // already unwrapped one does not silently get nothing.
        let payload = (object["payload"] as? [String: Any]) ?? object
        facts.reasoningEffort = nonEmptyString(payload["effort"]) ?? facts.reasoningEffort
        facts.personality = nonEmptyString(payload["personality"]) ?? facts.personality
        facts.approvalPolicy = nonEmptyString(payload["approval_policy"]) ?? facts.approvalPolicy
        // `sandbox_policy` is an object on disk — `{"type":"workspace-write",…}` —
        // not the bare string the siblings are; read its `.type`. (Accept a bare
        // string too, in case the shape ever changes.)
        facts.sandboxPolicy = policyName(payload["sandbox_policy"]) ?? facts.sandboxPolicy
        facts.workingDirectory = nonEmptyString(payload["cwd"]) ?? facts.workingDirectory
    }

    /// A policy value that may be a bare string or a `{"type": "..."}` object,
    /// mirroring how `codexDuration` handles the number-vs-object dual shape.
    private static func policyName(_ value: Any?) -> String? {
        nonEmptyString(value) ?? nonEmptyString((value as? [String: Any])?["type"])
    }

    /// Codex serialises durations either as a plain number of seconds or as
    /// Rust's `{"secs": 1, "nanos": 500000000}`. Handle both; anything else is
    /// treated as unknown rather than coerced.
    private static func codexDuration(_ value: Any?) -> TimeInterval? {
        if let seconds = double(value) { return seconds }
        guard let object = value as? [String: Any] else { return nil }
        let secs = double(object["secs"]) ?? 0
        let nanos = double(object["nanos"]) ?? 0
        let total = secs + nanos / 1_000_000_000
        return total > 0 ? total : nil
    }

    // MARK: - Primitives

    private static func jsonObject(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
