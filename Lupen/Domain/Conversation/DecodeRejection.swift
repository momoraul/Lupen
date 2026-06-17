import Foundation

/// Reason a JSONL line was not turned into a `RichEntry`.
///
/// The existing `RichEntryDecoder.decode(_:)` returns `nil` for many
/// distinct reasons — some are *expected* (noisy filter drops, image-source
/// metadata, sub-skill triggers) and some indicate *problems* (malformed
/// JSON, missing required fields, a brand-new JSONL `type` that Lupen
/// doesn't understand).
///
/// Treating all of these identically hid real issues. Users would see
/// incorrect Turn counts or token totals with no clue why. Claude Code
/// releases periodically introduce new entry shapes, and silent failure
/// meant those regressions shipped unnoticed.
///
/// This enum distinguishes the categories so callers can route silent
/// drops to `/dev/null` while surfacing warnings and errors to
/// `ParseDiagnostics` (and eventually the user-facing diagnostics panel).
enum DecodeRejection: Equatable, Sendable, Codable {

    // MARK: - Silent drops (info)

    /// `EntryFilter.shouldReject(data)` matched a known noisy type prefix
    /// (progress / file-history-snapshot / queue-operation / last-prompt).
    case filteredPreCheck

    /// user entry with `blocks.isEmpty`. This is how Claude Code signals
    /// a sub-skill trigger — expected, not an error. `extractParentLink`
    /// still preserves the chain link for assembler parent-chain walks.
    case emptyUserContent

    /// user entry that Claude Code auto-injects for slash-command
    /// orchestration, compaction summaries, or local-command stdout.
    /// The contained String is a best-effort identifier (e.g.
    /// "command-name", "local-command-stdout").
    case claudeCodeSystemMeta(String)

    /// `[Image source: /path]` meta entry. The assembler handles this
    /// by merging into a parent prompt Step; not emitted as a Step.
    case imageSourceMeta

    /// Counter-only: user entry carried an inline base64 image block
    /// (`{"type":"image","source":{...}}`). Bumped once per image block
    /// so the Diagnostics window can show "N inline images attached"
    /// without every one surfacing as a warning. Exists so a healthy
    /// rate of inline attachments is observable; unexpectedly low or
    /// zero counts (when the user knows they attached images) become a
    /// debugging lead that something regressed in the decoder.
    case inlineImageAttachment

    // MARK: - Warnings

    /// `type` field is neither "user" nor "assistant" and wasn't caught
    /// by `EntryFilter.shouldReject`. Likely indicates Claude Code has
    /// added a new entry kind that Lupen should consider handling.
    case unknownType(String)

    /// A content block inside `message.content` used a `type` string
    /// the decoder doesn't recognise. Associated text is the unknown
    /// type string. Warning rather than error because the surrounding
    /// entry still decodes successfully (the unknown block is dropped),
    /// but the user should know that *some* prompt/assistant content
    /// isn't being surfaced — typically a signal that Claude Code has
    /// introduced a new block type (e.g. "video", "audio", "file")
    /// that UI should be taught to handle.
    case unknownContentBlockType(String)

    /// `AttachmentResolver` processed a tool_use block whose `name`
    /// isn't in the known dispatch table (Read/Write/Edit/Glob/Grep/
    /// WebFetch/Bash/…) AND whose `inputJSON` didn't yield any path
    /// or URL via the heuristic fallback. A 0-attachment result here
    /// is not necessarily a bug — plenty of tools legitimately carry
    /// no file references (`WebSearch`, `TodoWrite`, custom MCP
    /// tools). But the first sighting of each tool name is a signal
    /// worth surfacing: if that tool *does* carry a path under a
    /// novel key, the Attachments tab will silently miss it until
    /// someone teaches the resolver the new key. Associated text is
    /// the tool name (e.g. `mcp__vendor__action`).
    case unknownToolForAttachmentExtraction(String)

    /// An assistant entry's `stop_reason` field carried a non-empty
    /// string that isn't one of the 6 values Lupen's `StopReason` enum
    /// recognises. Strong signal that Anthropic has added a new
    /// stop_reason (past precedent: `pause_turn` was introduced in
    /// 2025). The surrounding Turn still parses — the raw string stays
    /// on `Step.stopReason` for Raw-tab display — but Turn boundary
    /// classification falls back to `.stop` which may be wrong for the
    /// new value. First-sighting-per-value surfaces in Diagnostics so
    /// a new `StopReason` case can be added before regressions compound.
    /// Associated text is the raw stop_reason string.
    case unknownStopReason(String)

    /// A Codex rollout line decoded as JSON but did not match any line
    /// shape currently consumed by the usage or conversation pipelines.
    /// Associated text is `entry.type/payload.type`, with `<missing>`
    /// placeholders where the local JSON omitted a field.
    case codexUnknownLineType(String)

    /// Codex emitted usage for a model that is not in Lupen's pricing table.
    /// Usage/token totals remain valid, but dollar-cost estimates for the
    /// affected requests are intentionally omitted until pricing is added.
    /// Associated text is the raw model name from the rollout file.
    case codexUnsupportedModelPricing(String)

    /// Codex emitted a repeated cumulative `token_count` total. Lupen skips
    /// the duplicate to avoid double-counting usage/cost. Associated value
    /// is the number of skipped duplicate events for the file.
    case codexSkippedDuplicateCumulativeTotals(Int)

    /// Codex emitted fork replay usage inside the replay window. Lupen skips
    /// it because the parent session already owns those token totals.
    /// Associated value is the number of skipped replay events for the file.
    case codexSkippedForkReplay(Int)

    // MARK: - Errors

    /// Raw bytes couldn't be decoded as JSON. Associated text is the
    /// underlying error description (`error.localizedDescription`).
    case malformedJSON(String)

    /// Required field is missing. Associated text is the field name
    /// ("type" / "uuid" / "sessionId" / "timestamp").
    case missingRequiredField(String)

    /// Timestamp string was present but couldn't be parsed by either
    /// fractional or non-fractional ISO-8601 formatter. Associated text
    /// is the raw value.
    case badTimestamp(String)

    // MARK: - Plan 9 — sub-agent linkage drift

    /// `Agent` tool_use was found in a parent file but the matching
    /// `tool_result` body did not contain the `agentId: <hex>` token
    /// that `SubAgentLinker.parseAgentId` looks for. Strong signal that
    /// Claude Code changed the wording of the launch confirmation
    /// message — sub-agent UI grafting and "links by tool_use id"
    /// will fall back to other heuristics, but the user should know
    /// that the linkage layer regressed. Associated text is the
    /// `tool_use_id` so the diagnostic surfaces which call drifted.
    case subagentLinkageMissingAgentId(String)

    /// A `SubAgentLinker.Link` was extracted from a parent file but no
    /// matching `<sessionId>/subagents/agent-<agentId>.jsonl` file
    /// exists on disk. Reasons: user manually deleted a sub-agent log,
    /// Claude Code crashed mid-write, or the sub-agent file lives at
    /// an unexpected path. Cost rollup at the Session level is
    /// unaffected (no file = nothing to ingest = no missing $$), but
    /// the parent UI has a "this Step spawned X" claim with no body
    /// to show. Associated text is the orphan `agentId`.
    case subagentLinkageOrphanLink(String)

    /// A sub-agent JSONL line itself contains an `Agent` tool_use —
    /// i.e. a sub-sub-agent (recursion depth ≥ 2). Phase B initial
    /// implementation only nests one level deep; deeper trees are
    /// rendered flat. Surfacing this lets us measure how often the
    /// case occurs in the wild before investing in N-level UI.
    /// Associated text is the spawning sub-agent's `agentId`.
    case subagentRecursiveDepth(String)

    /// A sub-agent JSONL line's own `sessionId` field disagrees with
    /// the `sessionId` derived from the parent directory layout
    /// (`<project>/<sessionId>/subagents/...`). Should never happen
    /// in healthy data; an early warning that Claude Code may have
    /// changed how it stamps sub-agent files (e.g. inheriting the
    /// agent's own runtime id instead of the parent session). Cost
    /// folding into the parent Session would silently break for any
    /// session affected. Associated text is "expected vs got".
    case subagentSessionIdMismatch(String)

    /// `CostVerifier` detected drift between the model output (what
    /// the menu bar / Reports show) and the deduplicated JSONL truth
    /// (what Anthropic actually billed). Catches silent-drop bugs:
    /// a usage-bearing line gets parsed but doesn't make it into
    /// `session.requests`, or a request gets duplicated by mistake.
    /// Associated text describes the drift ("session=… missing N
    /// requests, $X drift").
    case costVerificationDrift(String)

    // MARK: - Snapshot-path invalidation

    /// `ParseSnapshot` startup path hit a fallback trigger. The UI always
    /// uses the full-parse result so correctness is preserved, but we want
    /// to observe which condition invalidated the snapshot so the next
    /// launch can avoid repeating the mistake.
    ///
    /// Causes (recorded verbatim in associated text):
    ///   - "fileNotFound" — snapshot file absent (first run / manual delete)
    ///   - "decodeError: …" — corrupt JSON
    ///   - "schemaVersionMismatch" — format mismatch after app upgrade
    ///   - "ttlExceeded: … days" — snapshot too old
    ///   - "fileTruncated: <path>" — file offset > current size
    ///   - "fileVanished: <path>" — file referenced by snapshot disappeared
    ///     (deleted / moved / renamed)
    ///   - "fileRewrittenBeforeSnapshot: <path>" — file mtime is earlier
    ///     than snapshot saved time (inode change / external rewrite)
    ///
    /// Always warning severity — visible to user but not catastrophic
    /// (the full-parse path guarantees correctness).
    case snapshotFallback(String)

    /// Independent ground truth (`GroundTruthCalculator`) disagrees with
    /// the view's observable state. Detects silent drops, double counts,
    /// bad dedup, and cost-calculation bugs by comparing the live pipeline
    /// against a simple calculator that re-reads JSONL bytes directly.
    ///
    /// Associated text packs session / item / view value / truth value
    /// for immediate drill-down (e.g. "session=abc cost view=$1.05
    /// truth=$1.09 delta=-$0.04").
    ///
    /// Error severity — cost accuracy must never silently drift.
    case groundTruthDrift(String)
}

extension DecodeRejection {
    private enum CodingKeys: String, CodingKey {
        case kind
        case stringValue
        case intValue
    }

    private enum Kind: String, Codable {
        case filteredPreCheck
        case emptyUserContent
        case claudeCodeSystemMeta
        case imageSourceMeta
        case inlineImageAttachment
        case unknownType
        case unknownContentBlockType
        case unknownToolForAttachmentExtraction
        case unknownStopReason
        case codexUnknownLineType
        case codexUnsupportedModelPricing
        case codexSkippedDuplicateCumulativeTotals
        case codexSkippedForkReplay
        case malformedJSON
        case missingRequiredField
        case badTimestamp
        case subagentLinkageMissingAgentId
        case subagentLinkageOrphanLink
        case subagentRecursiveDepth
        case subagentSessionIdMismatch
        case costVerificationDrift
        case snapshotFallback
        case groundTruthDrift
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let stringValue = try container.decodeIfPresent(String.self, forKey: .stringValue) ?? ""
        let intValue = try container.decodeIfPresent(Int.self, forKey: .intValue) ?? 0
        switch kind {
        case .filteredPreCheck: self = .filteredPreCheck
        case .emptyUserContent: self = .emptyUserContent
        case .claudeCodeSystemMeta: self = .claudeCodeSystemMeta(stringValue)
        case .imageSourceMeta: self = .imageSourceMeta
        case .inlineImageAttachment: self = .inlineImageAttachment
        case .unknownType: self = .unknownType(stringValue)
        case .unknownContentBlockType: self = .unknownContentBlockType(stringValue)
        case .unknownToolForAttachmentExtraction: self = .unknownToolForAttachmentExtraction(stringValue)
        case .unknownStopReason: self = .unknownStopReason(stringValue)
        case .codexUnknownLineType: self = .codexUnknownLineType(stringValue)
        case .codexUnsupportedModelPricing: self = .codexUnsupportedModelPricing(stringValue)
        case .codexSkippedDuplicateCumulativeTotals: self = .codexSkippedDuplicateCumulativeTotals(intValue)
        case .codexSkippedForkReplay: self = .codexSkippedForkReplay(intValue)
        case .malformedJSON: self = .malformedJSON(stringValue)
        case .missingRequiredField: self = .missingRequiredField(stringValue)
        case .badTimestamp: self = .badTimestamp(stringValue)
        case .subagentLinkageMissingAgentId: self = .subagentLinkageMissingAgentId(stringValue)
        case .subagentLinkageOrphanLink: self = .subagentLinkageOrphanLink(stringValue)
        case .subagentRecursiveDepth: self = .subagentRecursiveDepth(stringValue)
        case .subagentSessionIdMismatch: self = .subagentSessionIdMismatch(stringValue)
        case .costVerificationDrift: self = .costVerificationDrift(stringValue)
        case .snapshotFallback: self = .snapshotFallback(stringValue)
        case .groundTruthDrift: self = .groundTruthDrift(stringValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .filteredPreCheck:
            try container.encode(Kind.filteredPreCheck, forKey: .kind)
        case .emptyUserContent:
            try container.encode(Kind.emptyUserContent, forKey: .kind)
        case .claudeCodeSystemMeta(let value):
            try container.encode(Kind.claudeCodeSystemMeta, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .imageSourceMeta:
            try container.encode(Kind.imageSourceMeta, forKey: .kind)
        case .inlineImageAttachment:
            try container.encode(Kind.inlineImageAttachment, forKey: .kind)
        case .unknownType(let value):
            try container.encode(Kind.unknownType, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .unknownContentBlockType(let value):
            try container.encode(Kind.unknownContentBlockType, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .unknownToolForAttachmentExtraction(let value):
            try container.encode(Kind.unknownToolForAttachmentExtraction, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .unknownStopReason(let value):
            try container.encode(Kind.unknownStopReason, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .codexUnknownLineType(let value):
            try container.encode(Kind.codexUnknownLineType, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .codexUnsupportedModelPricing(let value):
            try container.encode(Kind.codexUnsupportedModelPricing, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .codexSkippedDuplicateCumulativeTotals(let value):
            try container.encode(Kind.codexSkippedDuplicateCumulativeTotals, forKey: .kind)
            try container.encode(value, forKey: .intValue)
        case .codexSkippedForkReplay(let value):
            try container.encode(Kind.codexSkippedForkReplay, forKey: .kind)
            try container.encode(value, forKey: .intValue)
        case .malformedJSON(let value):
            try container.encode(Kind.malformedJSON, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .missingRequiredField(let value):
            try container.encode(Kind.missingRequiredField, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .badTimestamp(let value):
            try container.encode(Kind.badTimestamp, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .subagentLinkageMissingAgentId(let value):
            try container.encode(Kind.subagentLinkageMissingAgentId, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .subagentLinkageOrphanLink(let value):
            try container.encode(Kind.subagentLinkageOrphanLink, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .subagentRecursiveDepth(let value):
            try container.encode(Kind.subagentRecursiveDepth, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .subagentSessionIdMismatch(let value):
            try container.encode(Kind.subagentSessionIdMismatch, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .costVerificationDrift(let value):
            try container.encode(Kind.costVerificationDrift, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .snapshotFallback(let value):
            try container.encode(Kind.snapshotFallback, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .groundTruthDrift(let value):
            try container.encode(Kind.groundTruthDrift, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        }
    }
}

extension DecodeRejection {

    /// How loud this rejection should be. Callers use this to decide
    /// between silent drop, log-only, and user-visible surfacing.
    enum Severity: Sendable {
        case info      // silent — expected operation
        case warning   // counted, logged, no toast
        case error     // counted, logged, surfaced to user
    }

    var severity: Severity {
        switch self {
        case .filteredPreCheck,
             .emptyUserContent,
             .claudeCodeSystemMeta,
             .imageSourceMeta,
             .inlineImageAttachment,
             .subagentRecursiveDepth:
            // Recursive depth is rare and benign for cost (sub-agents
            // still ingested via sessionId). Surface as info so we
            // can graph the rate without spamming the Diagnostics
            // window. Inline-image attachments are *expected*; they're
            // counted here purely as a health signal.
            return .info
        case .unknownType,
             .unknownContentBlockType,
             .unknownToolForAttachmentExtraction,
             .unknownStopReason,
             .codexUnknownLineType,
             .codexUnsupportedModelPricing,
             .codexSkippedDuplicateCumulativeTotals,
             .codexSkippedForkReplay,
             .subagentLinkageMissingAgentId,
             .subagentLinkageOrphanLink,
             .snapshotFallback:
            return .warning
        case .malformedJSON,
             .missingRequiredField,
             .badTimestamp,
             .subagentSessionIdMismatch,
             .costVerificationDrift,
             .groundTruthDrift:
            return .error
        }
    }

    /// Short stable identifier suitable for counter keys and UI row
    /// grouping. Stays the same across associated-value variations.
    var categoryKey: String {
        switch self {
        case .filteredPreCheck:               return "filteredPreCheck"
        case .emptyUserContent:               return "emptyUserContent"
        case .claudeCodeSystemMeta:           return "claudeCodeSystemMeta"
        case .imageSourceMeta:                return "imageSourceMeta"
        case .inlineImageAttachment:          return "inlineImageAttachment"
        case .unknownType:                    return "unknownType"
        case .unknownContentBlockType:        return "unknownContentBlockType"
        case .unknownToolForAttachmentExtraction: return "unknownToolForAttachmentExtraction"
        case .unknownStopReason:              return "unknownStopReason"
        case .codexUnknownLineType:           return "codexUnknownLineType"
        case .codexUnsupportedModelPricing:   return "codexUnsupportedModelPricing"
        case .codexSkippedDuplicateCumulativeTotals: return "codexSkippedDuplicateCumulativeTotals"
        case .codexSkippedForkReplay:         return "codexSkippedForkReplay"
        case .malformedJSON:                  return "malformedJSON"
        case .missingRequiredField:           return "missingRequiredField"
        case .badTimestamp:                   return "badTimestamp"
        case .subagentLinkageMissingAgentId:  return "subagentLinkageMissingAgentId"
        case .subagentLinkageOrphanLink:      return "subagentLinkageOrphanLink"
        case .subagentRecursiveDepth:         return "subagentRecursiveDepth"
        case .subagentSessionIdMismatch:      return "subagentSessionIdMismatch"
        case .costVerificationDrift:          return "costVerificationDrift"
        case .snapshotFallback:               return "snapshotFallback"
        case .groundTruthDrift:               return "groundTruthDrift"
        }
    }

    /// Human-readable description for logs and the diagnostics window.
    var humanDescription: String {
        switch self {
        case .filteredPreCheck:
            return "Filtered by EntryFilter pre-check (known noisy type)"
        case .emptyUserContent:
            return "Empty user content (sub-skill trigger)"
        case .claudeCodeSystemMeta(let kind):
            return "Claude Code system meta (\(kind))"
        case .imageSourceMeta:
            return "Image source meta (merged into parent prompt)"
        case .inlineImageAttachment:
            return "Inline base64 image block on user prompt"
        case .unknownType(let t):
            return "Unknown JSONL type: '\(t)'"
        case .unknownContentBlockType(let t):
            return "Unknown content block type: '\(t)' — Claude Code may have added a new block shape"
        case .unknownToolForAttachmentExtraction(let tool):
            return "Attachment extractor didn't find any paths / URLs for tool '\(tool)' — new input shape? (Attachments tab may be missing rows)"
        case .unknownStopReason(let raw):
            return "Unknown stop_reason '\(raw)' — Claude may have introduced a new value (Turn classification falls back to .stop)"
        case .codexUnknownLineType(let type):
            return "Unknown Codex rollout line type: '\(type)' — Codex may have added a new local JSONL shape"
        case .codexUnsupportedModelPricing(let model):
            return "Unsupported Codex model pricing: '\(model)' — usage is counted, but dollar cost is omitted until pricing is added"
        case .codexSkippedDuplicateCumulativeTotals(let count):
            return "Skipped \(count) duplicate Codex cumulative token total(s) to avoid double-counting usage"
        case .codexSkippedForkReplay(let count):
            return "Skipped \(count) Codex fork replay token event(s) because the parent session already owns the usage"
        case .malformedJSON(let err):
            return "Malformed JSON: \(err)"
        case .missingRequiredField(let field):
            return "Missing required field: '\(field)'"
        case .badTimestamp(let raw):
            return "Unparseable timestamp: '\(raw)'"
        case .subagentLinkageMissingAgentId(let toolUseId):
            return "Sub-agent launch wording changed (no agentId in tool_result for \(toolUseId))"
        case .subagentLinkageOrphanLink(let agentId):
            return "Sub-agent file missing for linked agentId '\(agentId)'"
        case .subagentRecursiveDepth(let agentId):
            return "Sub-sub-agent (depth ≥ 2) spawned by agent '\(agentId)' — flat fallback"
        case .subagentSessionIdMismatch(let detail):
            return "Sub-agent sessionId mismatch: \(detail)"
        case .costVerificationDrift(let detail):
            return "Cost verification drift: \(detail)"
        case .snapshotFallback(let reason):
            return "Snapshot invalidated — fell back to full parse (\(reason))"
        case .groundTruthDrift(let detail):
            return "Ground-truth divergence: \(detail)"
        }
    }
}

/// Result of a detailed decode pass — either a successfully decoded
/// `RichEntry`, or the reason the line was rejected.
enum DecodeOutcome: Sendable {
    case entry(RichEntry)
    case drop(DecodeRejection)
}
