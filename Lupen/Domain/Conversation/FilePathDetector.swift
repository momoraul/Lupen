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
    ///   2. Turn escaped whitespace into real whitespace, and `\ ` into a
    ///      sentinel so shell-escaped spaces don't split the path in step 3.
    ///      Any sentinel already present in the text becomes a separator, since
    ///      step 4's restore cannot tell it from one this step inserted.
    ///   3. Split on whitespace / newlines.
    ///   4. For each token: unescape the sentinel, trim trailing punctuation,
    ///      require `/` prefix and a `.ext` tail, dedupe.
    /// Turns escaped whitespace — the two characters `\` and `n`/`r`/`t` — into
    /// a real space.
    ///
    /// Callers scan text that has been through a serializer or is destined for
    /// one, so a line break inside it is often two ordinary characters rather
    /// than a newline. Tokenizers split on real whitespace, so left alone those
    /// escapes glue a path to whatever followed it: a shell command reading
    /// `cd /tmp\nUA='Mozilla/5.0 …` yielded a file called
    /// `/tmp\nUA='Mozilla/5.0`, accepted because `.0` passes for an extension.
    ///
    /// An escaped backslash (`\\`) is left intact rather than collapsed. That
    /// keeps a serialized path which genuinely contains one from having its `n`
    /// eaten by a match on the second backslash, and it makes this idempotent,
    /// so applying it twice is safe.
    ///
    /// **Known limit, accepted deliberately.** A *single* backslash directly
    /// before `n`/`r`/`t` is read as an escape either way, so a raw path really
    /// named `/tmp/log\nightly.txt` loses its `n` here. Both readings cannot be
    /// served at once, and the evidence is lopsided: 271 real commands in this
    /// machine's transcripts carry a literal escape that fabricated a
    /// nonexistent path, while 668 real human-typed prompts contained no path
    /// of this shape at all. Two of `extract`'s call sites do pass prose
    /// (`StepBuilder`, `CodexConversationAssembler`), so the exposure is real
    /// but unobserved — and a Windows path, the obvious candidate, never
    /// reaches a locator anyway for want of a leading `/`.
    static func normalizingEscapedWhitespace(_ text: String) -> String {
        rewritingEscapes(text, escapedSpaceReplacement: nil)
    }

    /// Single pass over the escapes this type cares about. Written as a scanner
    /// rather than a sequence of `replacingOccurrences` calls because those
    /// cannot tell `\n` from the tail of `\\n`.
    private static func rewritingEscapes(
        _ text: String,
        escapedSpaceReplacement: Character?
    ) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "\\" else {
                out.append(character)
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            guard next < text.endIndex else {
                out.append(character)
                break
            }
            switch text[next] {
            case "\\":
                // Consumed as a pair and re-emitted unchanged.
                out.append("\\")
                out.append("\\")
                index = text.index(after: next)
            case "n", "r", "t":
                out.append(" ")
                index = text.index(after: next)
            case " " where escapedSpaceReplacement != nil:
                out.append(escapedSpaceReplacement!)
                index = text.index(after: next)
            default:
                out.append(character)
                index = next
            }
        }
        return out
    }

    static func extract(from text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }

        let scrubbed = stripBacktickRuns(text)

        // Shell-escaped spaces become a sentinel so the split step doesn't tear
        // them, and escaped whitespace becomes real whitespace so the split step
        // *does* tear on it — see `rewritingEscapes`.
        //
        // A sentinel already in the text becomes a separator first. The restore
        // step below rewrites every occurrence, not only the ones this pass
        // inserted, so without this a U+0001 that arrived in the input came back
        // out as a space inside the locator.
        //
        // Replaced rather than deleted: deleting fuses what was on either side,
        // so `/a/b<U+0001>c.txt` became `/a/bc.txt` — a path that appears in no
        // input and would carry a Reveal affordance. Separating yields `/a/b`
        // and `c.txt`, both rejected, which is the trade this type states it
        // prefers: miss a path rather than emit a false positive.
        let placeholderString = String(escapedSpaceSentinel)
        let sanitized = scrubbed.contains(escapedSpaceSentinel)
            ? scrubbed.replacingOccurrences(of: placeholderString, with: " ")
            : scrubbed
        let escaped = rewritingEscapes(sanitized, escapedSpaceReplacement: escapedSpaceSentinel)

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
