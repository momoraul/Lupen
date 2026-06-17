import Foundation

/// Summary of a tool_result block.
///
/// A `.toolResult` user Step holds exactly one `ToolResultInfo`; if a single
/// user entry bundles multiple tool_result blocks the assembler only keeps
/// the first.
///
/// **Snapshot cap**: `encode(to:)` truncates `content` at
/// `encodedContentCapBytes` (~2 KB) so massive tool outputs (Bash dumps,
/// Read of large files, Grep results) don't dominate the persisted
/// snapshot. Full content stays available via the Raw tab, which
/// lazy-loads the original JSONL line through
/// `AppStateStore.rawJSON(for:)`. Measured on the 2026-04-20 corpus: cap
/// at 2 KB cuts ~130 MB from a 551 MB snapshot while affecting only
/// ~11 k of 59 k tool-result entries (p99=34 KB long-tail). Under-cap
/// entries encode verbatim so round-trip equality holds for all
/// reasonably-sized content.
struct ToolResultInfo: Sendable, Equatable, Codable {
    /// `id` of the matching tool_use; used to look up the parent toolCall Step.
    let toolUseId: String
    /// Tool output text; the assembler truncates extremely long results.
    let content: String
    let isError: Bool

    init(toolUseId: String, content: String, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }

    /// Abbreviated content for UI descriptions, capped at `limit` characters.
    func abbreviatedContent(limit: Int = 120) -> String {
        let firstLine = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        if firstLine.count <= limit { return firstLine }
        let endIndex = firstLine.index(firstLine.startIndex, offsetBy: limit)
        return String(firstLine[..<endIndex]) + "…"
    }

    // MARK: - Snapshot size cap

    /// Maximum encoded length for `content` in Character count
    /// (mis-estimates multi-byte input like CJK / emoji by up to 4x,
    /// still within safety budget). Conservative on purpose: most Bash
    /// outputs fit; large Read / Grep dumps get truncated with a marker.
    static let encodedContentCapBytes: Int = 2048

    /// Marker appended when `content` is truncated for snapshot
    /// persistence. Users see this in the Detail Conversation tab
    /// when the original payload exceeded the cap; full content is
    /// available via the Raw tab (lazy-loaded from the original
    /// JSONL line, not the snapshot).
    static let truncationMarker: String = "\n\n…[truncated — full content in Raw tab]"

    enum CodingKeys: String, CodingKey {
        case toolUseId, content, isError
    }

    // Auto-synthesized `init(from:)` decodes whatever was written —
    // if it was truncated on encode, the decoded String already
    // carries the marker. No round-trip asymmetry to document here
    // beyond what `encode(to:)` does.

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolUseId, forKey: .toolUseId)
        try c.encode(isError, forKey: .isError)
        if content.count > Self.encodedContentCapBytes {
            // `prefix` clamps by Character count, not bytes. The cap targets
            // disk-size control, not a hard safety limit, so the byte
            // mis-estimate on multi-byte input is acceptable.
            let head = String(content.prefix(Self.encodedContentCapBytes))
            try c.encode(head + Self.truncationMarker, forKey: .content)
        } else {
            try c.encode(content, forKey: .content)
        }
    }
}
