import Foundation

/// Pure find logic for the in-conversation find bar. It operates on plain
/// strings (the rendered text of each conversation card, in document order) so
/// it is fully unit-testable without AppKit text views — the view layer maps a
/// `Match.textIndex` back to the actual `ConversationBodyTextView`.
///
/// Range finding is delegated to `QueryHighlighter.ranges(in:query:)` so the
/// in-conversation find and the sidebar/outline highlight match identically
/// (case-insensitive, non-overlapping, UTF-16 offsets).
enum ConversationFindEngine {

    /// A single occurrence: which text view (by document-order index) and the
    /// UTF-16 range within that view's string.
    struct Match: Equatable {
        let textIndex: Int
        let range: NSRange
    }

    /// All occurrences of `query` across `texts`, in document order (text 0
    /// first, then by position within each text). Empty/whitespace query — or
    /// no occurrence — yields `[]`.
    static func matches(in texts: [String], query: String) -> [Match] {
        var result: [Match] = []
        for (index, text) in texts.enumerated() {
            for range in QueryHighlighter.ranges(in: text, query: query) {
                result.append(Match(textIndex: index, range: range))
            }
        }
        return result
    }

    /// The current-match index after stepping forward/back with wraparound.
    /// - `count == 0` → `nil` (nothing to select).
    /// - `current == nil` (no selection yet) → first match when going forward,
    ///   last when going back.
    /// - otherwise advances cyclically.
    static func step(current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        if forward { return (current + 1) % count }
        return (current - 1 + count) % count
    }
}
