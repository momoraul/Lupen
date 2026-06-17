import Foundation

/// Extracts the parent ↔ sub-agent linkage that Claude Code records
/// across two JSONL artifacts:
///
/// - **Parent** session JSONL: contains `Agent` tool_use blocks
///   (`{type:"tool_use", name:"Agent", id:"toolu_...", input:{description, subagent_type}}`)
///   followed by their `tool_result` whose text content begins with
///   `Async agent launched successfully.\nagentId: <agentId> ...`.
/// - **Sub-agent** JSONL at `<parent-session-id>/subagents/agent-<agentId>.jsonl`
///   carrying the actual usage records that Anthropic billed.
///
/// The strict linkage chain is therefore:
/// 1. Parent assistant line owns `Agent` tool_use with `tool_use_id = toolu_xxx`.
/// 2. Next user line carries the matching `tool_result` whose text contains
///    the sub-agent's runtime `agentId` (e.g. `a5ab166735f956e5c`).
/// 3. The sub-agent JSONL filename embeds that same `agentId`.
///
/// Empirical truth (verified against `~/.claude/projects/...` Apr 2026):
/// - The `tool_use_id` itself never appears inside the sub-agent file —
///   it is a one-way reference from parent → child.
/// - All concurrently spawned `Agent` tool_use blocks share the parent's
///   `message.id` (Claude API returns one assistant message with N
///   tool_use blocks; Claude Code splits each into its own JSONL line).
/// - Every concurrent sub-agent shares the parent's `promptId`, so
///   `promptId` is a parent-turn key, not a sub-agent key.
///
/// This helper is pure / Sendable / has no AppKit dependency so it can
/// be reused by `AppStateStore`, `CostAnalyzer`, and any future UI that
/// surfaces sub-agent attribution.
enum SubAgentLinker {
    enum LinkKind: String, Sendable, Equatable, Codable {
        case agent
        case workflow
    }

    /// One sub-agent invocation extracted from a parent JSONL.
    ///
    /// Serialized into `ParseSnapshot` keyed by parent sessionId. Bump
    /// `SnapshotSchema.currentVersion` whenever a field is added or
    /// removed.
    struct Link: Sendable, Equatable, Codable {
        let linkKind: LinkKind
        /// `agentId` recovered from the parent tool_result body and
        /// embedded in the sub-agent filename (`agent-<agentId>.jsonl`).
        let agentId: String
        /// `tool_use_id` (`toolu_…`) of the parent's `Agent` tool_use.
        /// Stable join key when correlating cost rollups by Step.
        let parentToolUseId: String
        /// `uuid` of the parent assistant line that issued the
        /// `Agent` tool_use. This is the parent **Step** identity —
        /// pin a sub-agent here when grafting into a `Turn`.
        let parentAssistantUuid: String
        /// Parent message id (`msg_…`). Multiple parallel `Agent`
        /// calls share this id since Claude Code splits a single
        /// assistant message into one JSONL line per tool_use block.
        let parentMessageId: String?
        /// Human-readable description from `tool_use.input.description`
        /// — also mirrored in the sub-agent's `.meta.json`.
        let description: String?
        /// Sub-agent type from `tool_use.input.subagent_type` —
        /// also mirrored in the sub-agent's `.meta.json` `agentType`.
        let subagentType: String?
        /// Timestamp of the parent assistant line that issued the call.
        let timestamp: String?
        /// Dynamic workflow launch task id (e.g. `wn6kr89ga`).
        let workflowTaskId: String?
        /// Dynamic workflow run id (e.g. `wf_018fb292-3bf`).
        let workflowRunId: String?
        /// Workflow script metadata name, if available.
        let workflowName: String?
        /// Workflow phase that owns this child agent.
        let workflowPhaseTitle: String?
        /// Workflow UI label for this child agent.
        let workflowLabel: String?
        /// Workflow run state from the metadata JSON.
        let workflowStatus: String?
        /// Model recorded for the workflow child agent.
        let workflowModel: String?
        /// Child agent state (`queued`, `running`, `done`, etc.).
        let workflowAgentState: String?
        /// Workflow metadata token telemetry for this child agent. Not
        /// used for billing; real cost still comes from child JSONL usage.
        let workflowTelemetryTokens: Int?
        /// Workflow metadata tool-call count for this child agent.
        let workflowToolCalls: Int?
        /// Workflow metadata duration for this child agent.
        let workflowDurationMs: Int?

        init(
            linkKind: LinkKind = .agent,
            agentId: String,
            parentToolUseId: String,
            parentAssistantUuid: String,
            parentMessageId: String?,
            description: String?,
            subagentType: String?,
            timestamp: String?,
            workflowTaskId: String? = nil,
            workflowRunId: String? = nil,
            workflowName: String? = nil,
            workflowPhaseTitle: String? = nil,
            workflowLabel: String? = nil,
            workflowStatus: String? = nil,
            workflowModel: String? = nil,
            workflowAgentState: String? = nil,
            workflowTelemetryTokens: Int? = nil,
            workflowToolCalls: Int? = nil,
            workflowDurationMs: Int? = nil
        ) {
            self.linkKind = linkKind
            self.agentId = agentId
            self.parentToolUseId = parentToolUseId
            self.parentAssistantUuid = parentAssistantUuid
            self.parentMessageId = parentMessageId
            self.description = description
            self.subagentType = subagentType
            self.timestamp = timestamp
            self.workflowTaskId = workflowTaskId
            self.workflowRunId = workflowRunId
            self.workflowName = workflowName
            self.workflowPhaseTitle = workflowPhaseTitle
            self.workflowLabel = workflowLabel
            self.workflowStatus = workflowStatus
            self.workflowModel = workflowModel
            self.workflowAgentState = workflowAgentState
            self.workflowTelemetryTokens = workflowTelemetryTokens
            self.workflowToolCalls = workflowToolCalls
            self.workflowDurationMs = workflowDurationMs
        }

        enum CodingKeys: String, CodingKey {
            case linkKind
            case agentId
            case parentToolUseId
            case parentAssistantUuid
            case parentMessageId
            case description
            case subagentType
            case timestamp
            case workflowTaskId
            case workflowRunId
            case workflowName
            case workflowPhaseTitle
            case workflowLabel
            case workflowStatus
            case workflowModel
            case workflowAgentState
            case workflowTelemetryTokens
            case workflowToolCalls
            case workflowDurationMs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                linkKind: try c.decodeIfPresent(LinkKind.self, forKey: .linkKind) ?? .agent,
                agentId: try c.decode(String.self, forKey: .agentId),
                parentToolUseId: try c.decode(String.self, forKey: .parentToolUseId),
                parentAssistantUuid: try c.decode(String.self, forKey: .parentAssistantUuid),
                parentMessageId: try c.decodeIfPresent(String.self, forKey: .parentMessageId),
                description: try c.decodeIfPresent(String.self, forKey: .description),
                subagentType: try c.decodeIfPresent(String.self, forKey: .subagentType),
                timestamp: try c.decodeIfPresent(String.self, forKey: .timestamp),
                workflowTaskId: try c.decodeIfPresent(String.self, forKey: .workflowTaskId),
                workflowRunId: try c.decodeIfPresent(String.self, forKey: .workflowRunId),
                workflowName: try c.decodeIfPresent(String.self, forKey: .workflowName),
                workflowPhaseTitle: try c.decodeIfPresent(String.self, forKey: .workflowPhaseTitle),
                workflowLabel: try c.decodeIfPresent(String.self, forKey: .workflowLabel),
                workflowStatus: try c.decodeIfPresent(String.self, forKey: .workflowStatus),
                workflowModel: try c.decodeIfPresent(String.self, forKey: .workflowModel),
                workflowAgentState: try c.decodeIfPresent(String.self, forKey: .workflowAgentState),
                workflowTelemetryTokens: try c.decodeIfPresent(Int.self, forKey: .workflowTelemetryTokens),
                workflowToolCalls: try c.decodeIfPresent(Int.self, forKey: .workflowToolCalls),
                workflowDurationMs: try c.decodeIfPresent(Int.self, forKey: .workflowDurationMs)
            )
        }
    }

    /// Result of a richer extraction pass that also reports drift cases
    /// for `ParseDiagnostics`. `extractLinks` is the simple "links only"
    /// variant — keep using it from places that don't have a diagnostics
    /// sink wired in.
    struct ExtractionResult: Sendable {
        let links: [Link]
        /// `Agent` tool_use → tool_result pairs where the result body
        /// did not contain the `agentId:` token. Each `String` is the
        /// `tool_use_id` so the diagnostic UI can pinpoint the call.
        let droppedToolUseIdsMissingAgentId: [String]
    }

    /// Walk a parent JSONL byte stream (one JSONL line per `Data` slice)
    /// and return every `Agent` tool_use → tool_result pair as a `Link`.
    ///
    /// Lines that fail to decode, lines that are not assistant/user, or
    /// `Agent` tool_use blocks that have no following `tool_result`
    /// before EOF are skipped silently — this helper is **read-only
    /// observation** of an external format and must not raise on
    /// schema drift. Drift surfacing belongs to `ParseDiagnostics` —
    /// use `extractDetailed` to get both Links and drift markers.
    static func extractLinks(fromParentLines lines: [Data]) -> [Link] {
        extractDetailed(fromParentLines: lines).links
    }

    static func extractLinks(fromParentLines lines: [Data], parentFileURL: URL?) -> [Link] {
        extractDetailed(fromParentLines: lines, parentFileURL: parentFileURL).links
    }

    /// Like `extractLinks` but also records drift signatures
    /// (`Agent` tool_use + tool_result pair where the body lost the
    /// `agentId:` marker) into the result so callers can route them
    /// to `ParseDiagnostics`.
    static func extractDetailed(fromParentLines lines: [Data]) -> ExtractionResult {
        extractDetailed(fromParentLines: lines, parentFileURL: nil)
    }

    static func extractDetailed(fromParentLines lines: [Data], parentFileURL: URL?) -> ExtractionResult {
        var pending: [String: PendingCall] = [:]
        var links: [Link] = []
        var dropped: [String] = []
        let decoder = JSONDecoder()
        for line in lines {
            guard let env = try? decoder.decode(Envelope.self, from: line) else { continue }
            guard let blocks = env.message?.content?.blocks else { continue }
            switch env.type {
            case "assistant":
                for b in blocks where b.type == "tool_use" && (b.name == "Agent" || b.name == "Workflow") {
                    guard let id = b.id else { continue }
                    pending[id] = PendingCall(
                        toolName: b.name ?? "",
                        parentAssistantUuid: env.uuid,
                        parentMessageId: env.message?.id,
                        description: b.input?.description,
                        subagentType: b.input?.subagentType,
                        timestamp: env.timestamp
                    )
                }
            case "user":
                for b in blocks where b.type == "tool_result" {
                    guard let tuid = b.toolUseId, let call = pending.removeValue(forKey: tuid) else { continue }
                    if call.toolName == "Workflow" {
                        let launch = env.toolUseResult ?? WorkflowLaunchResult(fromText: b.contentText)
                        let workflowLinks = makeWorkflowLinks(
                            launch: launch,
                            parentFileURL: parentFileURL,
                            parentToolUseId: tuid,
                            call: call
                        )
                        links.append(contentsOf: workflowLinks)
                    } else if let agentId = parseAgentId(fromToolResultText: b.contentText) {
                        links.append(Link(
                            agentId: agentId,
                            parentToolUseId: tuid,
                            parentAssistantUuid: call.parentAssistantUuid,
                            parentMessageId: call.parentMessageId,
                            description: call.description,
                            subagentType: call.subagentType,
                            timestamp: call.timestamp
                        ))
                    } else if b.isError == true {
                        // Agent launch failed (e.g. "Failed to resolve
                        // base branch HEAD: git rev-parse failed").
                        // The body legitimately has no agentId because
                        // no agent was spawned — this is NOT wording
                        // drift, just a failed call. Skip silently;
                        // there's no sub-agent file to link to.
                        continue
                    } else if !isAsyncLaunchEnvelope(b.contentText) {
                        // Legacy synchronous `Agent` Task: the body
                        // carries the sub-agent's full markdown
                        // response in-line (e.g. "Perfect! Now I have
                        // a comprehensive understanding..."), no
                        // separate sub-agent JSONL is created, no
                        // launch confirmation prefix exists. Cost is
                        // already counted via the parent's own usage,
                        // and there's no body to graft. Silent skip
                        // — flagging these as wording drift drowned
                        // 26+ legitimate calls in our first live run.
                        continue
                    } else {
                        // Wording drift: the body LOOKS like an async
                        // launch envelope (starts with the expected
                        // prefix) but the agentId marker disappeared.
                        // Strong signal Claude Code changed the
                        // launch-confirmation wording. Caller emits
                        // `subagentLinkageMissingAgentId`.
                        dropped.append(tuid)
                    }
                }
            default:
                continue
            }
        }
        return ExtractionResult(
            links: links,
            droppedToolUseIdsMissingAgentId: dropped
        )
    }

    /// Convenience: load a parent file from disk and extract every link.
    static func extractLinks(fromParentFile url: URL) -> [Link] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let lines = data.split(separator: 0x0A).map { Data($0) }
        return extractLinks(fromParentLines: lines, parentFileURL: url)
    }

    /// True when a `tool_result` body looks like the async-launch
    /// confirmation envelope ("Async agent launched successfully.")
    /// regardless of whether the `agentId:` marker is present. Used
    /// to distinguish (a) legitimate async launches (where missing
    /// agentId means real wording drift) from (b) legacy synchronous
    /// `Agent` Task results (where the body is the sub-agent's full
    /// markdown response and there was never an agentId in the first
    /// place). Strict prefix match — anything that doesn't lead with
    /// the envelope text is treated as a non-async result.
    static func isAsyncLaunchEnvelope(_ text: String) -> Bool {
        text.hasPrefix("Async agent launched")
    }

    /// `agentId: <hex>` is rendered on the second line of the
    /// `Async agent launched successfully.` template that the
    /// Agent tool returns. The capture stops at whitespace so we
    /// don't accidentally swallow the following `(internal ID …`
    /// parenthetical.
    static func parseAgentId(fromToolResultText text: String) -> String? {
        guard let range = text.range(of: "agentId:") else { return nil }
        let tail = text[range.upperBound...]
        let trimmed = tail.drop(while: { $0 == " " || $0 == "\t" })
        let id = trimmed.prefix(while: { $0.isHexDigit || $0.isLetter })
        let result = String(id)
        return result.isEmpty ? nil : result
    }

    private static func makeWorkflowLinks(
        launch: WorkflowLaunchResult?,
        parentFileURL: URL?,
        parentToolUseId: String,
        call: PendingCall
    ) -> [Link] {
        let metadata = loadWorkflowMetadata(launch: launch, parentFileURL: parentFileURL)
        let agents = mergedWorkflowAgents(metadata: metadata, launch: launch)
        guard !agents.isEmpty else { return [] }
        let workflowTaskId = metadata?.taskId ?? launch?.taskId
        let workflowRunId = metadata?.runId ?? launch?.runId
        let workflowName = metadata?.workflowName
        let workflowStatus = metadata?.status ?? launch?.status
        return agents.map { agent in
            Link(
                linkKind: .workflow,
                agentId: agent.agentId,
                parentToolUseId: parentToolUseId,
                parentAssistantUuid: call.parentAssistantUuid,
                parentMessageId: call.parentMessageId,
                description: agent.label ?? call.description ?? metadata?.summary ?? launch?.summary,
                subagentType: "workflow-subagent",
                timestamp: call.timestamp,
                workflowTaskId: workflowTaskId,
                workflowRunId: workflowRunId,
                workflowName: workflowName,
                workflowPhaseTitle: agent.phaseTitle,
                workflowLabel: agent.label,
                workflowStatus: workflowStatus,
                workflowModel: agent.model,
                workflowAgentState: agent.state,
                workflowTelemetryTokens: agent.tokens,
                workflowToolCalls: agent.toolCalls,
                workflowDurationMs: agent.durationMs
            )
        }
    }

    private static func mergedWorkflowAgents(
        metadata: WorkflowMetadata?,
        launch: WorkflowLaunchResult?
    ) -> [WorkflowAgent] {
        var agents = metadata?.agents ?? []
        var seen = Set(agents.map(\.agentId))
        for fallback in fallbackWorkflowAgents(from: launch) where seen.insert(fallback.agentId).inserted {
            agents.append(fallback)
        }
        return agents
    }

    private static func loadWorkflowMetadata(
        launch: WorkflowLaunchResult?,
        parentFileURL: URL?
    ) -> WorkflowMetadata? {
        guard let runId = launch?.runId else { return nil }
        var candidates: [URL] = []
        if let parentFileURL {
            candidates.append(
                parentFileURL
                    .deletingPathExtension()
                    .appendingPathComponent("workflows")
                    .appendingPathComponent("\(runId).json")
            )
        }
        if let scriptPath = launch?.scriptPath {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            candidates.append(
                scriptURL
                    .deletingLastPathComponent()  // scripts
                    .deletingLastPathComponent()  // workflows
                    .appendingPathComponent("\(runId).json")
            )
        }
        if let transcriptDir = launch?.transcriptDir {
            let transcriptURL = URL(fileURLWithPath: transcriptDir)
            candidates.append(
                transcriptURL
                    .deletingLastPathComponent()  // runId
                    .deletingLastPathComponent()  // workflows
                    .deletingLastPathComponent()  // subagents
                    .appendingPathComponent("workflows")
                    .appendingPathComponent("\(runId).json")
            )
        }

        let decoder = JSONDecoder()
        var seen: Set<String> = []
        for url in candidates where seen.insert(url.path).inserted {
            guard let data = try? Data(contentsOf: url),
                  let metadata = try? decoder.decode(WorkflowMetadata.self, from: data) else {
                continue
            }
            return metadata
        }
        return nil
    }

    private static func fallbackWorkflowAgents(from launch: WorkflowLaunchResult?) -> [WorkflowAgent] {
        guard let transcriptDir = launch?.transcriptDir else { return [] }
        let url = URL(fileURLWithPath: transcriptDir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { file -> WorkflowAgent? in
                let stem = file.deletingPathExtension().lastPathComponent
                let prefix = "agent-"
                guard stem.hasPrefix(prefix) else { return nil }
                let agentId = String(stem.dropFirst(prefix.count))
                return agentId.isEmpty ? nil : WorkflowAgent(index: nil, agentId: agentId)
            }
            .sorted { $0.agentId < $1.agentId }
    }

    // MARK: - Decoding helpers (private)

    private struct PendingCall {
        let toolName: String
        let parentAssistantUuid: String
        let parentMessageId: String?
        let description: String?
        let subagentType: String?
        let timestamp: String?
    }

    private struct WorkflowLaunchResult: Decodable {
        let status: String?
        let taskId: String?
        let runId: String?
        let summary: String?
        let transcriptDir: String?
        let scriptPath: String?

        init(
            status: String? = nil,
            taskId: String? = nil,
            runId: String? = nil,
            summary: String? = nil,
            transcriptDir: String? = nil,
            scriptPath: String? = nil
        ) {
            self.status = status
            self.taskId = taskId
            self.runId = runId
            self.summary = summary
            self.transcriptDir = transcriptDir
            self.scriptPath = scriptPath
        }

        init?(fromText text: String) {
            let taskId = Self.value(after: "Task ID:", in: text)
            let runId = Self.value(after: "Run ID:", in: text)
            let summary = Self.value(after: "Summary:", in: text)
            let transcriptDir = Self.value(after: "Transcript dir:", in: text)
            let scriptPath = Self.quotedValue(after: "scriptPath:", in: text)
            guard taskId != nil || runId != nil || transcriptDir != nil else { return nil }
            self.init(
                status: nil,
                taskId: taskId,
                runId: runId,
                summary: summary,
                transcriptDir: transcriptDir,
                scriptPath: scriptPath
            )
        }

        private static func value(after marker: String, in text: String) -> String? {
            guard let range = text.range(of: marker) else { return nil }
            let tail = text[range.upperBound...]
            let line = tail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func quotedValue(after marker: String, in text: String) -> String? {
            guard let range = text.range(of: marker) else { return nil }
            let tail = text[range.upperBound...]
            guard let firstQuote = tail.firstIndex(of: "\"") else { return nil }
            let afterQuote = tail[tail.index(after: firstQuote)...]
            guard let secondQuote = afterQuote.firstIndex(of: "\"") else { return nil }
            let value = String(afterQuote[..<secondQuote])
            return value.isEmpty ? nil : value
        }
    }

    private struct WorkflowMetadata: Decodable {
        let runId: String?
        let taskId: String?
        let workflowName: String?
        let status: String?
        let summary: String?
        let workflowProgress: [WorkflowProgress]?

        enum CodingKeys: String, CodingKey {
            case runId
            case taskId
            case workflowName
            case status
            case summary
            case workflowProgress
            case script
            case scriptPath
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runId = try c.decodeIfPresent(String.self, forKey: .runId)
            taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            workflowProgress = try c.decodeIfPresent([WorkflowProgress].self, forKey: .workflowProgress)
            let topLevelName = try c.decodeIfPresent(String.self, forKey: .workflowName)
            let script = (try? c.decodeIfPresent(WorkflowScript.self, forKey: .script)) ?? nil
            let scriptPath = try c.decodeIfPresent(String.self, forKey: .scriptPath)
            workflowName = Self.firstNonEmpty(
                topLevelName,
                script?.meta?.name,
                script?.path.map(Self.fileStem(fromPath:)),
                scriptPath.map(Self.fileStem(fromPath:))
            )
        }

        var agents: [WorkflowAgent] {
            (workflowProgress ?? [])
                .compactMap(WorkflowAgent.init(progress:))
                .sorted { lhs, rhs in
                    switch (lhs.index, rhs.index) {
                    case (let l?, let r?): return l < r
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return lhs.agentId < rhs.agentId
                    }
                }
        }

        private static func firstNonEmpty(_ values: String?...) -> String? {
            for value in values {
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }

        private static func fileStem(fromPath path: String) -> String {
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    private struct WorkflowScript: Decodable {
        let path: String?
        let meta: WorkflowScriptMeta?
    }

    private struct WorkflowScriptMeta: Decodable {
        let name: String?
    }

    private struct WorkflowProgress: Decodable {
        let type: String?
        let index: Int?
        let label: String?
        let phaseTitle: String?
        let agentId: String?
        let model: String?
        let state: String?
        let tokens: Int?
        let toolCalls: Int?
        let durationMs: Int?
    }

    private struct WorkflowAgent: Sendable {
        let index: Int?
        let agentId: String
        let label: String?
        let phaseTitle: String?
        let model: String?
        let state: String?
        let tokens: Int?
        let toolCalls: Int?
        let durationMs: Int?

        init(
            index: Int?,
            agentId: String,
            label: String? = nil,
            phaseTitle: String? = nil,
            model: String? = nil,
            state: String? = nil,
            tokens: Int? = nil,
            toolCalls: Int? = nil,
            durationMs: Int? = nil
        ) {
            self.index = index
            self.agentId = agentId
            self.label = label
            self.phaseTitle = phaseTitle
            self.model = model
            self.state = state
            self.tokens = tokens
            self.toolCalls = toolCalls
            self.durationMs = durationMs
        }

        init?(progress: WorkflowProgress) {
            guard progress.type == "workflow_agent",
                  let agentId = progress.agentId,
                  !agentId.isEmpty else {
                return nil
            }
            self.init(
                index: progress.index,
                agentId: agentId,
                label: progress.label,
                phaseTitle: progress.phaseTitle,
                model: progress.model,
                state: progress.state,
                tokens: progress.tokens,
                toolCalls: progress.toolCalls,
                durationMs: progress.durationMs
            )
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let uuid: String
        let timestamp: String?
        let message: Message?
        let toolUseResult: WorkflowLaunchResult?

        enum CodingKeys: String, CodingKey {
            case type
            case uuid
            case timestamp
            case message
            case toolUseResult
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            uuid = try c.decode(String.self, forKey: .uuid)
            timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
            toolUseResult = try? c.decodeIfPresent(WorkflowLaunchResult.self, forKey: .toolUseResult)
        }

        struct Message: Decodable {
            let id: String?
            let content: Content?
        }

        struct Content: Decodable {
            let blocks: [Block]
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let arr = try? c.decode([Block].self) {
                    self.blocks = arr
                } else {
                    self.blocks = []
                }
            }
        }

        struct Block: Decodable {
            let type: String?
            // tool_use
            let id: String?
            let name: String?
            let input: ToolInput?
            // tool_result
            let toolUseId: String?
            let content: ToolResultContent?
            let isError: Bool?

            var contentText: String {
                content?.text ?? ""
            }

            enum CodingKeys: String, CodingKey {
                case type, id, name, input, content
                case toolUseId = "tool_use_id"
                case isError = "is_error"
            }
        }

        struct ToolInput: Decodable {
            let description: String?
            let subagentType: String?

            enum CodingKeys: String, CodingKey {
                case description
                case subagentType = "subagent_type"
            }
        }

        /// `tool_result.content` is polymorphic: a plain string OR an
        /// array of `{type, text}` blocks. We flatten to a single
        /// string for `agentId:` scanning.
        struct ToolResultContent: Decodable {
            let text: String

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) {
                    self.text = s
                } else if let arr = try? c.decode([Frag].self) {
                    self.text = arr.compactMap { $0.text }.joined(separator: "\n")
                } else {
                    self.text = ""
                }
            }

            struct Frag: Decodable {
                let text: String?
            }
        }
    }
}
