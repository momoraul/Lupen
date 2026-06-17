import Foundation

/// Heuristic extractor for filesystem paths mentioned inside prompt text.
///
/// Claude Code CLI has no structured "file attachment" channel — when a user
/// drags a file onto the terminal or pastes an absolute path, it lands in the
/// user prompt as raw text. This detector recovers those paths so the UI can
/// surface them in the Attachments tab (Finder reveal, copy, etc).
///
/// Scope & rules:
///   - **Absolute paths only** (`/…`). Relative paths are intentionally ignored
///     because they produce far too many false positives ("Sources/foo.swift",
///     "Tests/bar", etc, are ordinary English in programmer conversation).
///   - **Must have a recognizable extension** (`.ext`, 1–8 alphanumeric). Bare
///     directory paths ("/Users/example/work") are skipped — there's nothing to
///     "open in Finder" that a user would sensibly want.
///   - **Backtick-wrapped paths are excluded.** Inline code (`` `/foo/bar` ``)
///     is usually a reference to a path inside a code example, not an
///     attachment. The detector strips backtick runs (both single and triple)
///     before scanning.
///   - **Shell-escaped spaces are honored.** `/Users/example/Desktop/json\
///     sample/home.json` is recognized as one path; the escape is unescaped in
///     the returned string so the value is a real filesystem path.
///   - **Paths must appear as full whitespace-delimited tokens.** A substring
///     like `/Step.swift` inside `Lupen/Domain/Conversation/Step.swift` is
///     ignored — only tokens whose first character is `/` count.
///   - **De-duplicated preserving first-seen order.** A user who pastes the
///     same path twice still gets it listed once.
///
/// The detector is deliberately conservative: it prefers to miss a path over
/// emitting a false positive, because UI affordances on bogus paths ("Reveal
/// in Finder" fails) feel worse than an occasional missed attachment.
enum FilePathDetector {

    /// Internal placeholder replacing shell-escaped spaces (`\ `) during the
    /// whitespace-split pass. Chosen as U+0001 (Start of Heading) — it can't
    /// appear in any real filesystem path we care about, and it's a single
    /// unicode scalar so the replace-back step is trivial.
    private static let escapedSpaceSentinel: Character = "\u{0001}"

    /// Extracts absolute file paths from the given text.
    ///
    /// Strategy:
    ///   1. Strip backtick runs (both `` ` `` and ` ``` `) so we don't pick up
    ///      paths inside code spans or fenced blocks.
    ///   2. Replace `\ ` with a sentinel so shell-escaped spaces don't split
    ///      the path in step 3.
    ///   3. Split on whitespace / newlines.
    ///   4. For each token: unescape the sentinel, trim trailing punctuation,
    ///      require `/` prefix and a `.ext` tail, dedupe.
    static func extract(from text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }

        let scrubbed = stripBacktickRuns(text)

        // Replace shell-escaped spaces so the split step doesn't tear them.
        let placeholderString = String(escapedSpaceSentinel)
        let escaped = scrubbed.replacingOccurrences(of: "\\ ", with: placeholderString)

        var seen = Set<String>()
        var results: [String] = []

        // Separator characters: whitespace + common bracket/paren closers so
        // that markup like `[Image #N]/Users/...` splits into `[Image` + `#N`
        // + `/Users/...`. Without `]` in the separator set the path would stay
        // glued to the marker and fail the leading-`/` check below.
        let tokens = escaped.split(whereSeparator: { ch in
            ch.isWhitespace
                || ch.isNewline
                || ch == "]"
                || ch == "["
                || ch == "("
                || ch == ")"
        })
        for token in tokens {
            let raw = String(token)
            // Restore escaped spaces.
            let unescaped = raw.replacingOccurrences(of: placeholderString, with: " ")
            // Strip trailing punctuation that is almost never part of a path
            // but often follows one in a sentence ("open /foo/bar.txt.").
            let trimmed = unescaped.trimmingTrailingPunctuation()
            // Claude Code CLI mentions are rendered as `@/abs/path` in the
            // user prompt — strip the leading `@` so the path's `/` reaches
            // the `isAcceptablePath` gate. Bare `/abs/path` tokens pass
            // through unchanged.
            let stripped = trimmed.hasPrefix("@/")
                ? String(trimmed.dropFirst())
                : trimmed
            guard isAcceptablePath(stripped) else { continue }
            if seen.insert(stripped).inserted {
                results.append(stripped)
            }
        }
        return results
    }

    // MARK: - Acceptance rules

    /// A token is an acceptable path iff it:
    ///   - starts with `/`
    ///   - has a `.` inside the last segment followed by 1–8 alphanumerics
    ///   - the segment before the `.` is non-empty (i.e. not a hidden-file
    ///     only string like `/.bashrc` — we allow that below via a separate
    ///     check; the goal here is to block bare `.` tokens)
    private static func isAcceptablePath(_ s: String) -> Bool {
        guard s.hasPrefix("/"), s.count > 1 else { return false }
        // Extract the last path segment.
        guard let lastSlash = s.lastIndex(of: "/") else { return false }
        let segmentStart = s.index(after: lastSlash)
        guard segmentStart < s.endIndex else { return false }  // trailing slash
        let segment = s[segmentStart...]
        // Require an extension somewhere in the last segment.
        guard let dotIdx = segment.lastIndex(of: "."),
              dotIdx != segment.startIndex else {
            return false
        }
        let extStart = segment.index(after: dotIdx)
        guard extStart < segment.endIndex else { return false }  // trailing dot
        let ext = segment[extStart...]
        let count = ext.count
        guard (1...8).contains(count) else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: - Backtick scrubbing

    /// Removes all backtick-wrapped runs (`…` and ```…```) from the input,
    /// replacing them with a single space so adjacent tokens don't merge.
    private static func stripBacktickRuns(_ text: String) -> String {
        var s = text
        // Triple-backtick fence first (non-greedy, any chars including newline).
        s = removePattern(s, pattern: "```[\\s\\S]*?```")
        // Single-backtick span — limited to the same line.
        s = removePattern(s, pattern: "`[^`\\n]*`")
        return s
    }

    private static func removePattern(_ text: String, pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let ns = text as NSString
        return re.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: " "
        )
    }
}

private extension String {
    /// Drops trailing punctuation that is unlikely to be part of a filesystem
    /// path: `.`, `,`, `;`, `:`, `!`, `?`, `)`, `]`, `}`, `"`, `'`.
    func trimmingTrailingPunctuation() -> String {
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'"]
        var end = self.endIndex
        while end > self.startIndex {
            let prev = self.index(before: end)
            if trailing.contains(self[prev]) {
                end = prev
            } else {
                break
            }
        }
        return String(self[..<end])
    }
}
