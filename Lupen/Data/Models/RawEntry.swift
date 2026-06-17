import Foundation

struct RawEntry: Codable, Sendable, Equatable {
    let type: String
    let uuid: String
    let parentUuid: String?
    let sessionId: String
    let timestamp: String
    let requestId: String?
    let isSidechain: Bool
    let version: String?
    let message: MessagePayload
    /// Git branch at the time this entry was recorded. A mid-session
    /// checkout can vary this per entry, so "the session's branch" must
    /// be read from the most recent entry.
    let gitBranch: String?
    /// Human-friendly unique slug auto-assigned by Claude Code (e.g.
    /// "harmonic-nibbling-meerkat"). Stable across a session.
    let slug: String?

    // Default values for the two recently added optional fields so test
    // fixtures (and any other call site that predates them) keep working
    // without explicit `gitBranch: nil, slug: nil`.
    init(
        type: String,
        uuid: String,
        parentUuid: String?,
        sessionId: String,
        timestamp: String,
        requestId: String?,
        isSidechain: Bool,
        version: String?,
        message: MessagePayload,
        gitBranch: String? = nil,
        slug: String? = nil
    ) {
        self.type = type
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.requestId = requestId
        self.isSidechain = isSidechain
        self.version = version
        self.message = message
        self.gitBranch = gitBranch
        self.slug = slug
    }

    // Explicit decoding so legacy JSON (without gitBranch/slug) still parses.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(String.self, forKey: .type)
        self.uuid = try c.decode(String.self, forKey: .uuid)
        self.parentUuid = try c.decodeIfPresent(String.self, forKey: .parentUuid)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.timestamp = try c.decode(String.self, forKey: .timestamp)
        self.requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        self.isSidechain = try c.decode(Bool.self, forKey: .isSidechain)
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.message = try c.decode(MessagePayload.self, forKey: .message)
        self.gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
    }

    // NOTE: only `init(from:)` is custom; `encode(to:)` is still synthesized
    // from these `CodingKeys`. Adding a new stored property without listing
    // it here would silently drop it from any persisted representation.
    // Keep this list in sync with the stored properties above.
    private enum CodingKeys: String, CodingKey {
        case type, uuid, parentUuid, sessionId, timestamp, requestId,
             isSidechain, version, message, gitBranch, slug
    }

    /// Parsed `message` envelope from a JSONL entry.
    ///
    /// **Codable asymmetry (Plan 13 Phase 8+)**:
    ///
    /// `init(from:)` (auto-synthesized) reads every field including
    /// `content` — this is the path used by `JSONLParser` when decoding
    /// raw JSONL lines at initial-parse / live-append time. The parsed
    /// content is consumed exactly once (by `AuxiliaryLinker.link` →
    /// `AuxiliaryRequestData.assistantContent`, currently only wired
    /// to the dead `DetailViewController.showRequest` path) and then
    /// sits in memory inside `allRawEntries`.
    ///
    /// `encode(to:)` is overridden below to **omit `content`**. This is
    /// specifically for `ParseSnapshot` serialization — the parsed
    /// content blocks represented ~450 MB of the ~574 MB v2 snapshot
    /// (76% of the file) and were redundant with `Step.text` /
    /// `Step.toolCalls` / `Step.toolResult` already persisted via
    /// `AssemblerSnapshot`. After load, `decodeIfPresent` returns nil
    /// for content — downstream consumers that care (none in active
    /// code paths) see `entry.message.content == nil` on restored
    /// entries and need to fall back to `Step` data or re-read the
    /// JSONL line via `AppStateStore.rawJSON(for:)`.
    ///
    /// Live-parsed entries (those appended after snapshot restore via
    /// `ingestFileFanOut`) keep their content populated until the next
    /// save. `allRawEntries` can therefore be a mixed state where some
    /// entries have content and some don't — this is correct and safe
    /// because no active consumer treats `content == nil` differently
    /// from "assistant had no parsed content".
    struct MessagePayload: Codable, Sendable, Equatable {
        let id: String?
        let role: String?
        let model: String?
        let stopReason: String?
        let usage: UsageData?
        let content: ContentField?

        enum CodingKeys: String, CodingKey {
            case id, role, model, usage, content
            case stopReason = "stop_reason"
        }

        // Auto-synthesized `init(from:)` is used — `decodeIfPresent`
        // on `content` correctly yields nil for snapshot-restored
        // entries and the full blocks for JSONL-parsed entries.

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encodeIfPresent(role, forKey: .role)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(stopReason, forKey: .stopReason)
            try c.encodeIfPresent(usage, forKey: .usage)
            // `content` is intentionally NOT encoded. See the type doc
            // comment for the full rationale (Plan 13 Phase 8 snapshot
            // size reduction, dead-code-path safety argument).
        }
    }

    struct UsageData: Codable, Sendable, Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreation: CacheCreationBreakdown?
        let speed: String?

        enum CodingKeys: String, CodingKey {
            case speed
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreation = "cache_creation"
        }
    }

    struct CacheCreationBreakdown: Codable, Sendable, Equatable {
        /// Optional because Claude's API has historically emitted
        /// `cache_creation` objects with only one leg populated — non-
        /// optional `Int` would throw on decode and silently drop the
        /// whole surrounding `RawEntry` line (→ missing billable request
        /// in Verify Costs). The independent `GroundTruthCalculator`
        /// already tolerates this shape, so matching its tolerance keeps
        /// view aligned with truth. A missing leg is treated as zero
        /// downstream via `?? 0`.
        let ephemeral1hInputTokens: Int?
        let ephemeral5mInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
            case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        }
    }
}

/// Polymorphic content field: can be a String or array of content blocks.
enum ContentField: Codable, Sendable, Equatable {
    case string(String)
    case blocks([Block])

    struct Block: Codable, Sendable, Equatable {
        let type: String?
        let text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let b = try? container.decode([Block].self) {
            self = .blocks(b)
        } else {
            self = .blocks([])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .blocks(let b): try container.encode(b)
        }
    }

    var flatText: String {
        switch self {
        case .string(let s): return s
        case .blocks(let blocks):
            return blocks.compactMap { $0.text }.joined(separator: "\n")
        }
    }
}
