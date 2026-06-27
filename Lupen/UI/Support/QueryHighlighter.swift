import AppKit

/// Overlays `NSColor.findHighlightColor` background on every
/// occurrence of `query` within an attributed string.
///
/// Used by `TurnOutlineViewController` to tint matched keywords in
/// the Conversation column when the sidebar search field has a
/// non-empty query. The highlight is applied on top of whatever
/// font / color / attachment attributes the string already has, so
/// it composes with slash-command cyan, interrupted dim styling, and
/// photo-symbol attachments without interfering.
///
/// Pure function — no side effects, no state, unit-testable.
enum QueryHighlighter {

    /// Every case-insensitive occurrence of `query` within `string`, as
    /// `NSRange`s (UTF-16 offsets, ready for `NSAttributedString` /
    /// `NSLayoutManager`). Empty or whitespace-only queries — and any string
    /// with no occurrence — return `[]`. Non-overlapping, left to right.
    ///
    /// Shared by the sidebar/outline highlight (`applied(to:query:)`) and the
    /// in-conversation find (which needs the raw ranges to drive temporary
    /// layout-manager highlighting + scroll-to-match).
    static func ranges(in string: String, query: String) -> [NSRange] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var ranges: [NSRange] = []
        var searchStart = string.startIndex
        while searchStart < string.endIndex,
              let match = string.range(
                  of: trimmed,
                  options: .caseInsensitive,
                  range: searchStart..<string.endIndex
              ) {
            ranges.append(NSRange(match, in: string))
            searchStart = match.upperBound
        }
        return ranges
    }

    /// Return a copy of `base` with `NSColor.findHighlightColor`
    /// background on every case-insensitive occurrence of `query`.
    ///
    /// Empty or whitespace-only queries return `base` unchanged.
    /// If no occurrence is found, returns `base` unchanged (no
    /// copy overhead — returns the same reference).
    static func applied(
        to base: NSAttributedString,
        query: String
    ) -> NSAttributedString {
        let ranges = ranges(in: base.string, query: query)
        guard !ranges.isEmpty else { return base }

        let result = NSMutableAttributedString(attributedString: base)
        for range in ranges {
            result.addAttributes([
                .backgroundColor: NSColor.findHighlightColor,
                .foregroundColor: NSColor.black,
            ], range: range)
        }
        return result
    }
}
