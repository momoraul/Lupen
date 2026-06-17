import Foundation

/// Generates the preview string shown in a Turn row.
///
/// Rules:
/// - Max `defaultMaxLength` chars (context-dependent)
/// - Image markers (`[Image #N]`, `[Image source: path]`) collapse to a glyph
/// - A slash-only prompt (`/skill`) is preserved as-is
/// - Image-only prompt becomes `🖼 (image only)`
/// - Empty prompt becomes `(empty)`
enum TurnPreview {

    /// Cap for the one-line Turn preview — BOTH the stored
    /// `turns.prompt_preview` / `sessions.cached_title` columns (the
    /// importers' `titleMaxLength` defaults to this) and the Turn-header
    /// render path apply it. 300 ≈ one full line on the widest realistic
    /// Conversation column; the cells already truncate to width
    /// (`byTruncatingTail`), so this is a storage/cost bound, not the
    /// visual one (6.12 — the old 50 forced "…" mid-line on wide
    /// windows). Raising it needs a schema bump so existing rows
    /// re-index with the longer preview. Keep it under the importers'
    /// `firstPromptMaxLength` (500): preview < first-prompt.
    static let defaultMaxLength = 300

    static func make(for turn: Turn, maxLength: Int = defaultMaxLength) -> String {
        guard let prompt = turn.promptStep else {
            return orphanPreview(for: turn, maxLength: maxLength)
        }
        return make(promptStep: prompt, maxLength: maxLength)
    }

    /// Substituted preview for post-compact synthetic prompts. Also the
    /// detection key when a stored `prompt_preview` must round-trip back
    /// to `isCompactSummary` (SQLite turn-header stubs, plan 4.1).
    static let compactResumeLabel = "↻ Compact resume"

    /// Preview for a prompt Step without a fully-assembled Turn. Shared
    /// by the Turn outline path above and the metadata scanner's bounded
    /// head read (plan 2.1) so the two derivations can never drift.
    static func make(promptStep prompt: Step, maxLength: Int = defaultMaxLength) -> String {
        // Post-compact synthetic prompt: short label, never truncate
        // / clean the multi-KB summary body. The actual summary
        // remains accessible in the Detail panel via `prompt.text`.
        if prompt.isCompactSummary {
            return Self.compactResumeLabel
        }
        let raw = prompt.text ?? ""
        // Inline base64 image blocks (current Claude Code format) live on
        // `Step.images` with path == nil. `[Image source: /path]` meta
        // entries live on `Step.imageSourcePaths` as actual file paths.
        // Either of these means "this prompt had an attached image",
        // even if the clean text alone would lose the signal.
        let hasImages = !prompt.images.isEmpty || !prompt.imageSourcePaths.isEmpty
        let cleaned = clean(raw)

        if cleaned.isEmpty {
            return hasImages ? "🖼 (image only)" : "(empty)"
        }

        if let slash = slashOnly(cleaned) {
            return hasImages ? "🖼 \(slash)" : slash
        }

        // Prepend the image glyph when the prompt carried an attachment.
        // The `🖼 ` prefix eats 2 characters of the length budget so the
        // final string still respects `maxLength`.
        if hasImages {
            let budget = max(0, maxLength - 2)
            return "🖼 \(truncate(cleaned, to: budget))"
        }
        return truncate(cleaned, to: maxLength)
    }

    // MARK: - Internal helpers (internal for testability)

    static func clean(_ text: String) -> String {
        var s = text

        s = s.replacingOccurrences(
            of: #"\[Image source:[^\]]*\]"#,
            with: "",
            options: .regularExpression
        )

        s = s.replacingOccurrences(
            of: #"\[Image #\d+\]"#,
            with: "🖼",
            options: .regularExpression
        )

        // `@/abs/path/file.ext` CLI mentions collapse to `@file.ext`. Full paths
        // flood the 50-char preview budget so only 1-2 words of real text make
        // it through. The basename is enough for recognition; the full path
        // lives in the Attachments tab.
        s = shortenFileMentions(s)

        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")

        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }

        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Compiled once per process — NSRegularExpression JIT-compiles
    /// its pattern on every `init`, and `clean` runs on every outline
    /// row render. Without this cache the Turn list stuttered in the
    /// original rollout.
    private static let atMentionPathRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"@(/[^\s\)\]\"]+)"#, options: [])
    }()

    /// Collapses `@/abs/path/to/file.ext` substrings down to
    /// `@file.ext` in the given string. Tokens that happen to *start*
    /// with `@/` but have no valid path extension are left alone so
    /// we don't accidentally mangle an email-adjacent sequence.
    private static func shortenFileMentions(_ text: String) -> String {
        guard let re = atMentionPathRegex else { return text }
        let ns = text as NSString
        let matches = re.matches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return text }
        // Replace in reverse so earlier-match ranges stay valid.
        let result = NSMutableString(string: text)
        for m in matches.reversed() where m.numberOfRanges >= 2 {
            let pathRange = m.range(at: 1)
            guard pathRange.location != NSNotFound else { continue }
            let path = ns.substring(with: pathRange)
            let basename = (path as NSString).lastPathComponent
            guard !basename.isEmpty else { continue }
            result.replaceCharacters(in: m.range, with: "@" + basename)
        }
        return result as String
    }

    /// Returns the input only when it's a bare slash command (no whitespace).
    /// "/skill" -> "/skill", "/skill foo" -> nil.
    static func slashOnly(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") else { return nil }
        if t.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return nil }
        return t
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        if text.count <= limit { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }

    private static func orphanPreview(for turn: Turn, maxLength: Int) -> String {
        for step in turn.steps {
            let summary = clean(step.oneLineSummary())
            if !summary.isEmpty {
                return truncate(summary, to: maxLength)
            }
        }
        if turn.aggregateTokens.totalContextTokens > 0 || turn.aggregateCost.totalCostUSD > 0 {
            return "Usage update"
        }
        return "(empty)"
    }
}
