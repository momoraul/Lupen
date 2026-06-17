import Foundation

enum ImageSourceFormatter {

    private static let imageSourcePattern = try! NSRegularExpression(
        pattern: #"\[Image source: ([^\]]+)\]"#
    )
    private static let imageRefPattern = try! NSRegularExpression(
        pattern: #"\[Image #\d+\]"#
    )

    /// Clean image references for plain text display (dropdown, etc.)
    /// - `[Image #N]` → 🖼️ (inline reference, replace with emoji)
    /// - `[Image source: path]` → removed (metadata, not visible content)
    static func cleanForDisplay(_ text: String) -> String {
        var result = text
        // Remove [Image source: path] metadata entirely
        let r1 = NSRange(result.startIndex..., in: result)
        result = imageSourcePattern.stringByReplacingMatches(
            in: result, range: r1, withTemplate: ""
        )
        // Replace [Image #N] inline references with emoji
        let r2 = NSRange(result.startIndex..., in: result)
        result = imageRefPattern.stringByReplacingMatches(
            in: result, range: r2, withTemplate: "🖼️"
        )
        return result
    }

    /// Info about an image source found in text.
    struct ImageSource {
        let range: NSRange
        let path: String
    }

    /// Extract all `[Image source: path]` entries from text.
    static func extractSources(from text: String) -> [ImageSource] {
        let range = NSRange(text.startIndex..., in: text)
        return imageSourcePattern.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let pathRange = Range(match.range(at: 1), in: text) else { return nil }
            return ImageSource(range: match.range, path: String(text[pathRange]))
        }
    }

    /// Ranges of `[Image #N]` references.
    static func extractRefs(from text: String) -> [NSRange] {
        let range = NSRange(text.startIndex..., in: text)
        return imageRefPattern.matches(in: text, range: range).map(\.range)
    }
}
