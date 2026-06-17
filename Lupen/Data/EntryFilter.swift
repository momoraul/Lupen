import Foundation

enum EntryFilter {
    /// Fast pre-decode rejection for JSONL lines that are guaranteed to be
    /// non-conversational noise. Uses the first N bytes only — we want this
    /// path cheaper than a full JSON parse.
    ///
    /// **UTF-8 safety**: `String(decoding:as:)` is used instead of
    /// `String(data:encoding:)` because the latter returns `nil` when the
    /// byte window is cut mid-character. Entries containing Korean or other
    /// multi-byte text immediately after the `type` field (e.g.
    /// `"lastPrompt":"진행하기전에..."`) would otherwise bypass the filter
    /// and surface as `.missingRequiredField('uuid')` errors in
    /// ParseDiagnostics. Lossy decoding preserves ASCII bytes so the
    /// `"type":"X"` substring still matches.
    static func shouldReject(_ lineData: Data) -> Bool {
        let prefix = lineData.prefix(200)
        let prefixStr = String(decoding: prefix, as: UTF8.self)
        if prefixStr.contains("\"type\":\"progress\"") { return true }
        if prefixStr.contains("\"type\":\"file-history-snapshot\"") { return true }
        if prefixStr.contains("\"type\":\"queue-operation\"") { return true }
        if prefixStr.contains("\"type\":\"last-prompt\"") { return true }
        // `attachment` is the single highest-volume non-conversational
        // type observed across user JSONLs (~27k lines per project on
        // 2026-04 audit). Prefix-rejecting here saves the full RawLine
        // decode that would otherwise run before knownSilentTypes
        // catches it. Routing is identical: both paths resolve to
        // `.filteredPreCheck`, and `decodeDetailedWithHeaderAndRejections`
        // still calls `scanHeader` on prefix-rejected lines so
        // parentLinks / customTitleState collection in AppStateStore is
        // unaffected.
        if prefixStr.contains("\"type\":\"attachment\"") { return true }
        return false
    }
}
