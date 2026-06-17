import Foundation

/// Domain model for a single JSONL entry. One-to-one with a row in the
/// table view.
///
/// `kind` determines which fields are meaningful:
/// - `.prompt`    → `text`, `images`
/// - `.toolResult`→ `toolResult`
/// - `.toolCall`  → `toolCalls` (no text)
/// - `.thought`   → `text` + `toolCalls`
/// - `.reply`     → `text`
/// - `.stop`      → (stopReason metadata only)
///
/// Only assistant-role Steps carry `tokens` / `cost` / `model` /
/// `requestId` metrics.
///
/// `Codable` — included in `AssemblerSnapshot`. **Note**: `rawJSON` is
/// intentionally **excluded** from snapshot serialization, because
/// base64-encoding the original JSONL bytes ballooned snapshot size to
/// ~1.33x the raw JSONL total and pushed both load and save into the
/// 7-second range. Snapshots persist with `rawJSON = nil`; when the
/// Raw / Usage tabs actually need the original line,
/// `AppStateStore.rawJSON(for:)` lazy-scans the session's JSONL file.
///
/// `Equatable` likewise **omits** `rawJSON` so identity semantics hold
/// regardless of whether the cache is hydrated. `rawJSONLocator` is persisted
/// and compared because Codex step UUIDs are synthetic; their raw lines must be
/// recoverable from source offsets after the eager `rawJSON` bytes are stripped.
/// Two Steps with matching uuid / parsed fields are equal whether `rawJSON` is
/// in-memory (live parse) or nil (just restored from snapshot) — `rawJSON` is a
/// lazy-loadable cache field, not part of identity. This lets snapshot
/// round-trip equivalence tests pass regardless of `rawJSON` presence.
/// Bump `SnapshotSchema.currentVersion` whenever fields are added or
/// removed.
struct Step: Sendable, Identifiable, Codable {

    // MARK: - Identity

    /// UUID of the JSONL entry. Equal to Step.id.
    let uuid: String
    /// Parent entry UUID. Walk this chain to find the Turn root (`.prompt`).
    let parentUuid: String?
    let sessionId: String
    let timestamp: Date

    // MARK: - Classification

    let kind: StepKind
    /// System-injected entry from Claude Code (JSONL `isMeta: true`).
    let isSystemInjected: Bool
    /// JSONL `isSidechain: true` — a step recorded by a sub-agent (background
    /// agent spawned via the Task tool) into a separate file
    /// (`<parent>/subagents/agent-<id>.jsonl`). `sessionId` matches the
    /// parent session, so cost rollup via `SessionGrouper` is automatic.
    /// Used as a filter when the UI grafts or isolates these entries.
    let isSidechain: Bool
    /// Sub-agent runtime ID (e.g. `a5ab166735f956e5c`). Present only on
    /// sub-agent steps (one-to-one with `isSidechain == true`). Matched
    /// against `SubAgentLinker.Link.agentId` to graft under the parent's
    /// Agent Step.
    let agentId: String?

    /// JSONL `isCompactSummary: true` — ground-truth flag Claude Code sets
    /// on the synthetic user message immediately after `/compact` (auto or
    /// manual). The Step itself survives as a regular `.prompt` to act as
    /// a chain hub; the UI layer (`TurnPreview` / `oneLineSummary`) reads
    /// this flag to substitute a short label like `"↻ Compact resume"`.
    /// The full LLM-generated summary stays in `text` so the detail panel
    /// can show it.
    let isCompactSummary: Bool

    // MARK: - Content (validity depends on `kind`)

    /// Prompt text (user input) or reply/thought response text.
    /// **Excludes thinking blocks** — those live in `thinkingText`.
    let text: String?
    /// Extended-thinking block text (assistant only). Stored separately
    /// from the reply/thought `text`.
    let thinkingText: String?
    /// Image references attached to a prompt.
    let images: [ImageRef]
    /// Filesystem paths extracted from `[Image source: /path]` meta
    /// entries that Claude Code records. Meaningful only on prompt
    /// Steps (the meta entries are merged into the parent prompt step
    /// by the Assembler rather than emitted as separate Steps). Backs
    /// the Finder-reveal / copy-path actions in the Attachments tab.
    let imageSourcePaths: [String]
    /// Absolute paths heuristically detected inside prompt text — i.e.
    /// the user pasted `/Users/.../foo.diff` as text instead of using
    /// drag-and-drop. Paths inside backticks are excluded.
    let mentionedFilePaths: [String]
    /// Unified attachment manifest (files / URLs / inline images) for
    /// this Step — the input to `AttachmentsDetailView`.
    ///
    /// Supersedes the per-channel `images` / `imageSourcePaths` /
    /// `mentionedFilePaths` trio for UI purposes: those three remain
    /// as raw extraction results (and to keep legacy snapshot decoding
    /// stable), but the Attachments tab reads **only** `attachments`
    /// so that tool-call / tool-result / reply-text paths surface
    /// alongside prompt-level attachments.
    ///
    /// Populated in a resolve pass (`AttachmentResolver`) after the
    /// raw assembler build, because computing `toolOutput` attachments
    /// needs session-wide state (parent `tool_use` name lookup) that
    /// `StepBuilder` doesn't have.
    let attachments: [AttachmentRef]
    /// `tool_use` blocks contained in a thought / toolCall step.
    let toolCalls: [ToolUseInfo]
    /// Payload of a toolResult step.
    let toolResult: ToolResultInfo?

    // MARK: - Assistant metrics (assistant role only)

    let requestId: String?
    let requestIds: [String]
    let messageId: String?
    let model: String?
    let speed: String?
    /// Raw `stop_reason` string (e.g. `"end_turn"`, `"tool_use"`,
    /// `"pause_turn"`). Stored verbatim so that new values introduced
    /// by the Claude API are preserved without loss.
    let stopReason: String?
    /// Typed-enum view of `stopReason`. nil for unknown strings — in
    /// that case `ConversationAssembler.ingest` logs a one-shot
    /// `DecodeRejection.unknownStopReason` diagnostic. Turn-boundary
    /// decisions go through `kind.terminatesTurn` instead.
    let stopReasonKind: StopReason?
    let tokens: TokenBreakdown?
    let cost: CostBreakdown?

    // MARK: - Raw

    /// Original JSONL line, for the Raw tab.
    let rawJSON: Data?
    /// Provider-scoped source locator for recovering the raw JSONL line without
    /// retaining `rawJSON` bytes in long-lived app/runtime state.
    let rawJSONLocator: RawPayloadLocator?

    // MARK: - Identifiable

    var id: String { uuid }

    // MARK: - Init

    init(
        uuid: String,
        parentUuid: String?,
        sessionId: String,
        timestamp: Date,
        kind: StepKind,
        isSystemInjected: Bool = false,
        isSidechain: Bool = false,
        agentId: String? = nil,
        isCompactSummary: Bool = false,
        text: String? = nil,
        thinkingText: String? = nil,
        images: [ImageRef] = [],
        imageSourcePaths: [String] = [],
        mentionedFilePaths: [String] = [],
        attachments: [AttachmentRef] = [],
        toolCalls: [ToolUseInfo] = [],
        toolResult: ToolResultInfo? = nil,
        requestId: String? = nil,
        requestIds: [String] = [],
        messageId: String? = nil,
        model: String? = nil,
        speed: String? = nil,
        stopReason: String? = nil,
        stopReasonKind: StopReason? = nil,
        tokens: TokenBreakdown? = nil,
        cost: CostBreakdown? = nil,
        rawJSON: Data? = nil,
        rawJSONLocator: RawPayloadLocator? = nil
    ) {
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.kind = kind
        self.isSystemInjected = isSystemInjected
        self.isSidechain = isSidechain
        self.agentId = agentId
        self.isCompactSummary = isCompactSummary
        self.text = text
        self.thinkingText = thinkingText
        self.images = images
        self.imageSourcePaths = imageSourcePaths
        self.mentionedFilePaths = mentionedFilePaths
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolResult = toolResult
        self.requestId = requestId
        self.requestIds = requestIds.isEmpty
            ? requestId.map { [$0] } ?? []
            : requestIds
        self.messageId = messageId
        self.model = model
        self.speed = speed
        self.stopReason = stopReason
        self.stopReasonKind = stopReasonKind
        self.tokens = tokens
        self.cost = cost
        self.rawJSON = rawJSON
        self.rawJSONLocator = rawJSONLocator
    }

    // MARK: - Codable (rawJSON intentionally excluded)

    /// `rawJSON` is **intentionally excluded** from the snapshot.
    /// Re-encoding 90k Steps' original JSONL bytes as base64 inflated
    /// snapshot size to ~1.33x the raw JSONL total (~760 MB → ~1 GB)
    /// and pushed both load and save into the 7-second range. The field
    /// is only consumed by the Raw / Usage tabs, so snapshots restore
    /// it as nil and `AppStateStore.rawJSON(for:)` lazy-scans the
    /// original file on demand.
    ///
    /// When adding a new field: it must be added explicitly to
    /// `CodingKeys`, `init(from:)`, and `encode(to:)` — synthesis is
    /// disabled here, so it won't be picked up automatically. Also
    /// bump `SnapshotSchema.currentVersion`.
    private enum CodingKeys: String, CodingKey {
        case uuid, parentUuid, sessionId, timestamp,
             kind, isSystemInjected, isSidechain, agentId,
             isCompactSummary,
             text, thinkingText, images, imageSourcePaths,
             mentionedFilePaths, attachments, toolCalls, toolResult,
             requestId, requestIds, messageId, model, speed, stopReason,
             stopReasonKind,
             tokens, cost,
             rawJSONLocator
        // rawJSON intentionally omitted — see the doc comment above.
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.uuid = try c.decode(String.self, forKey: .uuid)
        self.parentUuid = try c.decodeIfPresent(String.self, forKey: .parentUuid)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.kind = try c.decode(StepKind.self, forKey: .kind)
        self.isSystemInjected = try c.decode(Bool.self, forKey: .isSystemInjected)
        self.isSidechain = try c.decode(Bool.self, forKey: .isSidechain)
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        // `decodeIfPresent` so v8 snapshots (no isCompactSummary)
        // hydrate cleanly with `false`. The schema version bump (v9)
        // forces full reparse on first load, after which the field
        // is populated from the JSONL flag, so this fallback only
        // covers the brief transition window.
        self.isCompactSummary = try c.decodeIfPresent(Bool.self, forKey: .isCompactSummary) ?? false
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.thinkingText = try c.decodeIfPresent(String.self, forKey: .thinkingText)
        self.images = try c.decode([ImageRef].self, forKey: .images)
        self.imageSourcePaths = try c.decode([String].self, forKey: .imageSourcePaths)
        self.mentionedFilePaths = try c.decode([String].self, forKey: .mentionedFilePaths)
        // `decodeIfPresent` so snapshots written before v5 (which
        // lacked this field) decode cleanly with an empty manifest.
        // A v4 → v5 schema bump forces full reparse anyway, so the
        // fallback window is narrow — but belt-and-suspenders.
        self.attachments = try c.decodeIfPresent([AttachmentRef].self, forKey: .attachments) ?? []
        self.toolCalls = try c.decode([ToolUseInfo].self, forKey: .toolCalls)
        self.toolResult = try c.decodeIfPresent(ToolResultInfo.self, forKey: .toolResult)
        self.requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        self.requestIds = try c.decodeIfPresent([String].self, forKey: .requestIds)
            ?? self.requestId.map { [$0] }
            ?? []
        self.messageId = try c.decodeIfPresent(String.self, forKey: .messageId)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.speed = try c.decodeIfPresent(String.self, forKey: .speed)
        self.stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        // `decodeIfPresent` so v6 snapshots (which lacked this field)
        // decode cleanly. The v6 → v7 schema bump discards v6 files via
        // version mismatch and a full reparse overwrites with the
        // correct value, so this fallback is belt-and-suspenders.
        self.stopReasonKind = try c.decodeIfPresent(StopReason.self, forKey: .stopReasonKind)
        self.tokens = try c.decodeIfPresent(TokenBreakdown.self, forKey: .tokens)
        self.cost = try c.decodeIfPresent(CostBreakdown.self, forKey: .cost)
        self.rawJSON = nil
        self.rawJSONLocator = try c.decodeIfPresent(RawPayloadLocator.self, forKey: .rawJSONLocator)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid, forKey: .uuid)
        try c.encodeIfPresent(parentUuid, forKey: .parentUuid)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(kind, forKey: .kind)
        try c.encode(isSystemInjected, forKey: .isSystemInjected)
        try c.encode(isSidechain, forKey: .isSidechain)
        try c.encodeIfPresent(agentId, forKey: .agentId)
        try c.encode(isCompactSummary, forKey: .isCompactSummary)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(thinkingText, forKey: .thinkingText)
        try c.encode(images, forKey: .images)
        try c.encode(imageSourcePaths, forKey: .imageSourcePaths)
        try c.encode(mentionedFilePaths, forKey: .mentionedFilePaths)
        try c.encode(attachments, forKey: .attachments)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolResult, forKey: .toolResult)
        try c.encodeIfPresent(requestId, forKey: .requestId)
        if !requestIds.isEmpty {
            try c.encode(requestIds, forKey: .requestIds)
        }
        try c.encodeIfPresent(messageId, forKey: .messageId)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(speed, forKey: .speed)
        try c.encodeIfPresent(stopReason, forKey: .stopReason)
        try c.encodeIfPresent(stopReasonKind, forKey: .stopReasonKind)
        try c.encodeIfPresent(tokens, forKey: .tokens)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encodeIfPresent(rawJSONLocator, forKey: .rawJSONLocator)
        // rawJSON intentionally not encoded — loaded lazily from JSONL
        // on demand via AppStateStore.rawJSON(for:).
    }
}

// MARK: - Equatable (rawJSON excluded, see type doc comment)

extension Step: Equatable {
    static func == (lhs: Step, rhs: Step) -> Bool {
        lhs.uuid == rhs.uuid
            && lhs.parentUuid == rhs.parentUuid
            && lhs.sessionId == rhs.sessionId
            && lhs.timestamp == rhs.timestamp
            && lhs.kind == rhs.kind
            && lhs.isSystemInjected == rhs.isSystemInjected
            && lhs.isSidechain == rhs.isSidechain
            && lhs.agentId == rhs.agentId
            && lhs.isCompactSummary == rhs.isCompactSummary
            && lhs.text == rhs.text
            && lhs.thinkingText == rhs.thinkingText
            && lhs.images == rhs.images
            && lhs.imageSourcePaths == rhs.imageSourcePaths
            && lhs.mentionedFilePaths == rhs.mentionedFilePaths
            && lhs.attachments == rhs.attachments
            && lhs.toolCalls == rhs.toolCalls
            && lhs.toolResult == rhs.toolResult
            && lhs.requestId == rhs.requestId
            && lhs.requestIds == rhs.requestIds
            && lhs.messageId == rhs.messageId
            && lhs.model == rhs.model
            && lhs.speed == rhs.speed
            && lhs.stopReason == rhs.stopReason
            && lhs.stopReasonKind == rhs.stopReasonKind
            && lhs.tokens == rhs.tokens
            && lhs.cost == rhs.cost
            && lhs.rawJSONLocator == rhs.rawJSONLocator
        // rawJSON intentionally not compared — lazy cache, not identity.
    }
}

extension Step {
    /// True if this assistant Step is billable (has token metrics).
    var isBillable: Bool { tokens != nil }

    /// Whether this `.stop` Step is a synthetic entry Claude Code
    /// injected as a placeholder for an API failure.
    ///
    /// On API call failure (network / 5xx / rate limit) Claude Code
    /// writes a fake assistant entry with `model: "<synthetic>"`,
    /// `usage: { all zeros }`, `stop_reason: "stop_sequence"` to close
    /// the Turn. The raw line carries explicit metadata like
    /// `isApiErrorMessage: true` / `apiErrorStatus: <code>` /
    /// `error: "<type>"`, but `RawEntry` does not decode those yet,
    /// so the only deterministic marker available at the Step level
    /// is `model == "<synthetic>"`. Other cost paths
    /// (`AppStateStore.loadFromCache`, `PricingTable`) already
    /// identify and exclude synthetic entries via the same marker —
    /// a consistent signal.
    ///
    /// Why distinguish from a genuine `stop_sequence` (model finished
    /// because it matched a caller-set custom stop sequence): genuine
    /// stop_sequence only occurs when the API caller explicitly
    /// configured a stop sequence, which is essentially never under
    /// Claude Code, but it remains a valid sub-case of `.stop` by
    /// definition (`.stop` also covers max_tokens / refusal / etc.).
    var isSyntheticApiError: Bool {
        kind == .stop && model == "<synthetic>"
    }

    /// One-line summary of the Step, used in Turn-row / Step-row
    /// descriptions.
    ///
    /// - `.prompt` / `.reply` / `.thought`: the **first non-empty line**
    ///   of the source text only. Returning a real single line keeps
    ///   long bodies from wrapping or overlapping in the cell and
    ///   matches the *oneLine*Summary name.
    /// - `.toolCall`: `"tool_name(input)"`.
    /// - `.toolResult`: `"↪ tool_use_id: <content>"`.
    /// - `.stop`: `"(stopped: reason)"`.
    ///
    /// For `.toolResult`, the parent toolCall name is resolved by the
    /// assembler and passed in via `resolveToolName`.
    func oneLineSummary(resolveToolName: (String) -> String? = { _ in nil }) -> String {
        switch kind {
        case .prompt:
            // Post-compact synthetic prompt: short label instead of
            // the multi-KB LLM-generated summary body. The full
            // summary is still in `text` for the Detail panel.
            if isCompactSummary {
                return "↻ Compact resume"
            }
            let line = Self.firstNonEmptyLine(text)
            // Prompt Step rows in the Turn outline read `oneLineSummary`
            // directly. Current Claude Code emits attached images as
            // inline base64 blocks with no `[Image #N]` text marker, so
            // without this prefix the row would just show the prompt
            // text with no hint that an image was attached.
            let hasImages = !images.isEmpty || !imageSourcePaths.isEmpty
            if hasImages {
                return line.isEmpty ? "🖼 (image only)" : "🖼 \(line)"
            }
            return line
        case .toolResult:
            guard let tr = toolResult else { return "(empty tool result)" }
            let name = resolveToolName(tr.toolUseId) ?? "tool"
            let prefix = tr.isError ? "✗" : "↪"
            return "\(prefix) \(name): \(tr.abbreviatedContent())"
        case .toolCall:
            if let first = toolCalls.first {
                let rest = toolCalls.count > 1 ? " +\(toolCalls.count - 1)" : ""
                return "\(first.name)(\(first.abbreviatedInput()))\(rest)"
            }
            return "(empty tool call)"
        case .thought:
            let t = Self.firstNonEmptyLine(text)
            if let first = toolCalls.first {
                let rest = toolCalls.count > 1 ? " +\(toolCalls.count - 1)" : ""
                if t.isEmpty {
                    // thinking-only thought: show only the tool call.
                    return "\(first.name)(\(first.abbreviatedInput()))\(rest)"
                }
                return "\(t) → \(first.name)\(rest)"
            }
            return t.isEmpty ? "(thinking)" : t
        case .reply:
            let line = Self.firstNonEmptyLine(text)
            if !line.isEmpty { return line }
            if requestId != nil || tokens != nil || cost != nil {
                return "Usage update"
            }
            return "(empty reply)"
        case .stop:
            // Synthetic API-error placeholder: surface the actual error
            // text Claude Code put in the message body ("API Error: 529
            // Overloaded…", "You've hit your limit · resets 6pm…", …)
            // instead of the meaningless `(stopped: stop_sequence)`
            // wrapper. The wrapper is correct for genuine non-end_turn
            // stops (max_tokens / refusal / a real custom-stop-sequence
            // match), so keep that path for non-synthetic `.stop`.
            if isSyntheticApiError, let line = Self.firstNonEmptyLine(text) as String?, !line.isEmpty {
                return "⚠ \(line)"
            }
            return "(stopped: \(stopReason ?? "unknown"))"
        case .interruption:
            return "Interrupted by user"
        }
    }

    /// Splits `text` on `\n` / `\r\n` / `\r` and returns the first
    /// non-empty trimmed line. Returns "" if everything is whitespace.
    ///
    /// **Why not just first-line**: if the source starts with a
    /// markdown code fence (```` ``` ````) or a markup-only line like
    /// `━━━ divider ━━━`, returning the literal first line surfaces
    /// the fence or divider itself instead of any real content.
    ///
    /// Fix: (1) skip markup-only lines (code fences, dividers) and
    /// join the remaining content lines with " · ". (2) NSTextField is
    /// already configured with `usesSingleLineMode = true` +
    /// `lineBreakMode = .byTruncatingTail`, so long joined strings
    /// tail-truncate without wrapping.
    ///
    /// - `\r\n` / `\r` / `\n` all handled via the `.newlines` character set.
    /// - Markup detection: a line consisting of `\`\`\`` (with or without a lang tag).
    private static func firstNonEmptyLine(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let trimmedLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !trimmedLines.isEmpty else { return "" }

        // Markup-only line detection — lines that don't carry content
        // insight. Two categories:
        //
        // (1) Code fence: `\`\`\`` / `\`\`\`swift` / `\`\`\`json`, etc.
        //     Treated as content if it contains a space or is 20+ chars.
        //
        // (2) Divider-only: a line whose non-whitespace characters are
        //     all in the divider set below and total **3 or more**.
        //     `━━━`, `---`, `===`, `___`, etc. — pure separators.
        //     Lines like `━━━ Phase 2 ━━━` mix in content characters
        //     and are kept. em-dash (`—`) / en-dash (`–`) are excluded
        //     from the divider set because they appear in prose.
        let dividerChars: Set<Character> = ["-", "=", "_", "━", "═", "─"]
        let isCodeFence: (String) -> Bool = { line in
            guard line.hasPrefix("```") else { return false }
            return !line.contains(" ") && line.count < 20
        }
        let isDividerOnly: (String) -> Bool = { line in
            let nonWhitespace = line.filter { !$0.isWhitespace }
            guard nonWhitespace.count >= 3 else { return false }
            return nonWhitespace.allSatisfy { dividerChars.contains($0) }
        }
        let isMarkupOnly: (String) -> Bool = { line in
            isCodeFence(line) || isDividerOnly(line)
        }

        let content = trimmedLines.filter { !isMarkupOnly($0) }

        // If every line is markup, joining produces noise like
        // "``` · ``` · ━━━". Fall back to the first trimmed line for
        // the least-bad degrade.
        guard !content.isEmpty else {
            return trimmedLines.first ?? ""
        }

        // One line: return as-is. Multiple: join with " · ", the
        // middle-dot separator used as a metadata delimiter across
        // the macOS app.
        if content.count == 1 { return content[0] }
        return content.joined(separator: " · ")
    }
}
