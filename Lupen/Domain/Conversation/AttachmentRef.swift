import Foundation

/// A single file / URL / inline image surfaced by `AttachmentsDetailView`.
///
/// An `AttachmentRef` is the lingua franca between the conversation
/// parser and the Attachments tab: each Step produces zero or more
/// refs at build time, and a Turn's "all attachments" view is just the
/// union of its Steps' refs (de-duplicated by `locator`).
///
/// Originally the Attachments tab read three independent Step fields
/// (`images`, `imageSourcePaths`, `mentionedFilePaths`) and could only
/// see prompt-level data. Tool-call file I/O (Write / Read / WebFetch
/// / etc.) and reply-text paths were silently dropped. This ref type
/// unifies every channel so a Turn's detail view can be a real
/// manifest of everything Claude touched.
///
/// `Codable` — persisted inside `Step` in the assembler snapshot. Field
/// changes require `SnapshotSchema.currentVersion` bump.
struct AttachmentRef: Sendable, Equatable, Codable, Hashable {

    /// What the `locator` points at. Drives the Attachments row icon
    /// and whether a primary click reveals in Finder (file/image) or
    /// opens the URL in the default handler.
    enum Kind: String, Sendable, Codable, Hashable {
        /// File-backed image — `.promptImageMeta` legacy or extracted
        /// from a tool payload that produced an image.
        case image
        /// Inline base64 image block (no file path). `locator` is a
        /// synthetic `#inline:<idx>:<mediaType>` key so dedup keeps
        /// multiple inline images distinct.
        case inlineImage
        /// Regular file path.
        case file
        /// Directory path (Glob / Grep `path` argument, typically).
        case directory
        /// `http:` / `https:` URL. `file:` URLs are routed to `file` /
        /// `image` instead so the Finder-reveal affordance applies.
        case url
    }

    /// Where this ref came from. Used by the Attachments tab to group
    /// rows into sections, and by `Turn.allAttachments` to pick the
    /// highest-information origin when the same `locator` appears in
    /// multiple Steps.
    enum Origin: String, Sendable, Codable, Hashable {
        /// `message.content` image block in a prompt. Claude Code
        /// emits drag-&-drop attachments this way.
        case inlinePromptImage
        /// Legacy `[Image source: /abs/path]` meta entry merged into
        /// the prompt Step by the assembler.
        case promptImageMeta
        /// Absolute path heuristically detected inside prompt text.
        case promptTextMention
        /// Extracted from a tool-call's `inputJSON` — Write/Read/Edit
        /// `file_path`, WebFetch `url`, Glob `path`, etc.
        case toolInput
        /// Extracted from a `tool_result` content payload — "File
        /// created successfully at …", "Applied N edits to …", etc.
        case toolOutput
        /// Absolute path mentioned inside an assistant `reply` /
        /// `thought` text (including markdown links).
        case replyMention
    }

    let kind: Kind
    let origin: Origin

    /// File path, URL, or `#inline:…` synthetic key. Uniqueness across
    /// a Turn is checked on this field alone; the dedup winner is
    /// chosen by `origin` priority.
    let locator: String

    /// Tool name (e.g. "Write", "WebFetch") for `origin ∈
    /// {toolInput, toolOutput}`. UI uses it as a row subline prefix.
    /// `nil` for prompt-level and reply-level refs.
    let toolName: String?

    /// MIME type for `kind == .inlineImage` (e.g. "image/png").
    /// `nil` otherwise.
    let mediaType: String?

    init(
        kind: Kind,
        origin: Origin,
        locator: String,
        toolName: String? = nil,
        mediaType: String? = nil
    ) {
        self.kind = kind
        self.origin = origin
        self.locator = locator
        self.toolName = toolName
        self.mediaType = mediaType
    }
}

extension AttachmentRef.Origin {
    /// Dedup priority when the same `locator` appears with multiple
    /// origins inside a single Turn. The highest-numbered origin wins,
    /// so `toolOutput` beats `toolInput`, which beats `replyMention`,
    /// etc. Rationale: a file that Claude *wrote* is more informative
    /// than a file that was only mentioned in passing.
    var dedupPriority: Int {
        switch self {
        case .toolOutput:        return 60
        case .toolInput:         return 50
        case .replyMention:      return 40
        case .promptTextMention: return 30
        case .promptImageMeta:   return 20
        case .inlinePromptImage: return 10
        }
    }
}
