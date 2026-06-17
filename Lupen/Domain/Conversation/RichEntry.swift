import Foundation

/// Decoded JSONL entry intermediate representation. Input to `ConversationAssembler`.
///
/// Unlike `RawEntry`, this preserves the structured content-block array
/// (tool_use / tool_result / thinking / image) needed for Step classification.
///
/// `Codable`: serialized as part of `ParseSnapshot.allRawEntries` so Parse state
/// can be reconstructed from a snapshot. `rawJSON: Data` encodes as base64.
struct RichEntry: Sendable, Equatable, Codable {

    let uuid: String
    let parentUuid: String?
    let sessionId: String
    let timestamp: Date
    /// JSONL `type` field — "user" or "assistant".
    let entryType: EntryType

    // assistant-only
    let requestId: String?
    let messageId: String?
    let model: String?
    let stopReason: String?
    let usage: RawEntry.UsageData?

    let blocks: [RichContentBlock]

    /// Original JSONL line, kept for the Raw tab.
    let rawJSON: Data

    /// `true` if this is a Claude Code auto-injected **image source meta** entry
    /// (a user entry whose only content is `[Image source: /path]` text).
    /// Assembler does not emit these as Steps; instead it walks the parent chain
    /// and merges `imageSourcePaths` into the nearest prompt Step's
    /// `imageSourcePaths`. We keep rather than drop them so the Attachments tab
    /// can expose the paths for Finder reveal / copy actions.
    let isImageSourceMeta: Bool

    /// Paths parsed from `[Image source: /path]` entries. Non-empty only when
    /// `isImageSourceMeta == true`; empty for regular user/assistant entries.
    let imageSourcePaths: [String]

    /// JSONL `isMeta: true` — system-injected by Claude Code
    /// (e.g. skill body injection "Base directory for this skill: ...").
    let isSystemInjected: Bool

    /// JSONL `isSidechain: true` — entry written by a sub-agent (spawned via the
    /// Task tool) to a separate JSONL file at
    /// `<parent>/subagents/agent-<id>.jsonl`. `sessionId` matches the parent
    /// session so `SessionGrouper` rolls them into the same Session (cost stays
    /// accurate). Used at the UI layer to decide outline grafting vs isolation.
    let isSidechain: Bool

    /// Sub-agent runtime agentId (e.g. `a5ab166735f956e5c`). Present only on
    /// sub-agent JSONL lines; matched against `SubAgentLinker.Link.agentId` to
    /// graft under the parent's Agent Step. `nil` on parent-session lines.
    let agentId: String?

    /// JSONL `isCompactSummary: true` — ground-truth flag Claude Code sets on
    /// the synthetic user message ("This session is being continued from a
    /// previous conversation...") emitted right after auto-/manual `/compact`.
    /// When `true` the entry survives as a regular `.prompt` (preserving its
    /// role as a chain hub) but the UI renders it as a short label like
    /// `"↻ Compact resume"`.
    let isCompactSummary: Bool

    /// JSONL `gitBranch` — the checked-out branch Claude Code records per
    /// entry. The importer folds the most recent request-carried value into
    /// `sessions.last_git_branch` (sidebar branch row).
    let gitBranch: String?

    enum EntryType: String, Sendable, Equatable, Codable {
        case user
        case assistant
    }

    init(
        uuid: String,
        parentUuid: String?,
        sessionId: String,
        timestamp: Date,
        entryType: EntryType,
        requestId: String? = nil,
        messageId: String? = nil,
        model: String? = nil,
        stopReason: String? = nil,
        usage: RawEntry.UsageData? = nil,
        blocks: [RichContentBlock],
        rawJSON: Data,
        isImageSourceMeta: Bool = false,
        imageSourcePaths: [String] = [],
        isSystemInjected: Bool = false,
        isSidechain: Bool = false,
        agentId: String? = nil,
        isCompactSummary: Bool = false,
        gitBranch: String? = nil
    ) {
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.entryType = entryType
        self.requestId = requestId
        self.messageId = messageId
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
        self.blocks = blocks
        self.rawJSON = rawJSON
        self.isImageSourceMeta = isImageSourceMeta
        self.imageSourcePaths = imageSourcePaths
        self.isSystemInjected = isSystemInjected
        self.isSidechain = isSidechain
        self.agentId = agentId
        self.isCompactSummary = isCompactSummary
        self.gitBranch = gitBranch
    }

    func withSessionId(_ newSessionId: String) -> RichEntry {
        guard sessionId != newSessionId else { return self }
        return RichEntry(
            uuid: uuid,
            parentUuid: parentUuid,
            sessionId: newSessionId,
            timestamp: timestamp,
            entryType: entryType,
            requestId: requestId,
            messageId: messageId,
            model: model,
            stopReason: stopReason,
            usage: usage,
            blocks: blocks,
            rawJSON: rawJSON,
            isImageSourceMeta: isImageSourceMeta,
            imageSourcePaths: imageSourcePaths,
            isSystemInjected: isSystemInjected,
            isSidechain: isSidechain,
            agentId: agentId,
            isCompactSummary: isCompactSummary,
            gitBranch: gitBranch
        )
    }
}

/// Rich content block — one entry per block in JSONL `message.content`, typed by kind.
///
/// `Codable`: included in `ParseSnapshot`. Each case serializes as a `kind`
/// discriminator plus payload fields. Adding / removing / renaming a case
/// MUST bump `SnapshotSchema.currentVersion`.
enum RichContentBlock: Sendable, Equatable {
    /// Plain text block.
    case text(String)
    /// Extended thinking block (assistant).
    case thinking(String)
    /// Assistant `tool_use` block.
    case toolUse(id: String, name: String, inputJSON: String)
    /// User `tool_result` block.
    case toolResult(toolUseId: String, content: String, isError: Bool)
    /// Image block.
    case image(mediaType: String?, path: String?)
}

extension RichContentBlock: Codable {

    /// Discriminator. String raw value enables synthesized Codable.
    private enum Kind: String, Codable {
        case text, thinking, toolUse, toolResult, image
    }

    /// Payload keys. Only a subset is populated per case.
    private enum CodingKeys: String, CodingKey {
        case kind
        // text / thinking
        case text
        // toolUse
        case toolUseId
        case toolUseName
        case toolUseInput
        // toolResult
        case toolResultUseId
        case toolResultContent
        case toolResultIsError
        // image
        case imageMediaType
        case imagePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            let s = try c.decode(String.self, forKey: .text)
            self = .text(s)
        case .thinking:
            let s = try c.decode(String.self, forKey: .text)
            self = .thinking(s)
        case .toolUse:
            let id = try c.decode(String.self, forKey: .toolUseId)
            let name = try c.decode(String.self, forKey: .toolUseName)
            let input = try c.decode(String.self, forKey: .toolUseInput)
            self = .toolUse(id: id, name: name, inputJSON: input)
        case .toolResult:
            let tuid = try c.decode(String.self, forKey: .toolResultUseId)
            let content = try c.decode(String.self, forKey: .toolResultContent)
            let isError = try c.decode(Bool.self, forKey: .toolResultIsError)
            self = .toolResult(toolUseId: tuid, content: content, isError: isError)
        case .image:
            let mt = try c.decodeIfPresent(String.self, forKey: .imageMediaType)
            let path = try c.decodeIfPresent(String.self, forKey: .imagePath)
            self = .image(mediaType: mt, path: path)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .thinking(let s):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .toolUseId)
            try c.encode(name, forKey: .toolUseName)
            try c.encode(input, forKey: .toolUseInput)
        case .toolResult(let tuid, let content, let isError):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(tuid, forKey: .toolResultUseId)
            try c.encode(content, forKey: .toolResultContent)
            try c.encode(isError, forKey: .toolResultIsError)
        case .image(let mt, let path):
            try c.encode(Kind.image, forKey: .kind)
            try c.encodeIfPresent(mt, forKey: .imageMediaType)
            try c.encodeIfPresent(path, forKey: .imagePath)
        }
    }
}

extension RichContentBlock {
    var isText: Bool { if case .text = self { return true } else { return false } }
    var isToolUse: Bool { if case .toolUse = self { return true } else { return false } }
    var isToolResult: Bool { if case .toolResult = self { return true } else { return false } }
    var isImage: Bool { if case .image = self { return true } else { return false } }
    var isThinking: Bool { if case .thinking = self { return true } else { return false } }

    /// Text payload of this block, or nil for non-text cases.
    var text: String? {
        switch self {
        case .text(let s): return s
        case .thinking(let s): return s
        default: return nil
        }
    }
}
