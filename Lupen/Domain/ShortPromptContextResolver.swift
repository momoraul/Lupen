import Foundation

/// Pure helper that derives an inline "replying-to" hint for short-prompt
/// Turns so the outline row stays readable even when the user typed a bare
/// acknowledgment.
///
/// Turn rows are titled by the user's prompt text. When that prompt is
/// `"y"` / `"ok"`, the row reads out of context against the rest of the
/// session — the user has to open the Turn to recall what they were
/// confirming. This resolver extracts a compact snippet of the preceding
/// Turn's closing text so the UI can render:
///
///     y  ·  ↪ "Step 3 done. Move on to Phase A?"
///
/// The resolver is stateless. Callers pass the full `turns` array
/// (session-scoped, any ordering — the resolver finds the chronological
/// predecessor by `startTime`) plus the current Turn's `id`.
enum ShortPromptContextResolver {

    /// Explicit short-prompt whitelist. Case-insensitive match against the
    /// whitespace-trimmed prompt. Covers English + Korean affirmatives /
    /// negatives commonly used as confirmations.
    static let shortPromptWhitelist: Set<String> = [
        "y", "yes", "n", "no", "ok", "okay",
        "진행", "다음", "네", "응", "예", "아니", "아니오",
        "계속", "go", "yep", "nope", "확인"
    ]

    /// Non-whitelist prompts also count as "short" if the trimmed length
    /// is this or less. Kept conservative (4) because Korean is
    /// character-dense: a 7-character Korean string can already be a
    /// real instruction rather than a bare acknowledgment. Genuine
    /// short confirmations (`go`, `sure`, `ok!`) still clear the
    /// threshold, and the whitelist catches anything missed.
    static let shortPromptLengthLimit = 4

    /// Maximum characters of the previous Turn's closing text the hint
    /// keeps. Picked to stay readable in a single row width without
    /// dominating the primary prompt text.
    static let hintCharLimit = 60

    // MARK: - Public API

    /// Returns a hint string drawn from the chronologically-previous
    /// Turn's closing text when the current Turn's prompt is "short";
    /// `nil` otherwise.
    ///
    /// The resolver searches `turns` by `id` for the current Turn, then
    /// finds the Turn whose `startTime` is the largest value strictly
    /// less than the current Turn's start. This works regardless of
    /// whether the caller hands in an ascending- or descending-sorted
    /// array — previously an ASC-only API that silently returned the
    /// wrong neighbor under DESC.
    ///
    /// Callers render their own decoration (arrow, quotes, separator) —
    /// the resolver only owns **whether** a hint exists and **what text**
    /// it should show.
    static func hint(for turns: [Turn], currentTurnId: String) -> String? {
        guard let current = turns.first(where: { $0.id == currentTurnId }),
              let currentStart = current.startTime else { return nil }
        let prompt = current.promptStep?.text ?? ""
        guard isShort(prompt) else { return nil }

        // Chronologically previous = largest startTime strictly less than
        // currentStart. Linear scan; `turns` is small in practice.
        var previous: Turn?
        for t in turns {
            guard let ts = t.startTime, ts < currentStart else { continue }
            if let bestStart = previous?.startTime {
                if ts > bestStart { previous = t }
            } else {
                previous = t
            }
        }
        guard let prev = previous,
              let raw = closingText(of: prev) else { return nil }
        return trim(raw, to: hintCharLimit)
    }

    // MARK: - Helpers (internal-visibility for direct unit testing)

    /// True when `text` is a bare acknowledgment worth enriching.
    static func isShort(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if shortPromptWhitelist.contains(trimmed.lowercased()) { return true }
        return trimmed.count <= shortPromptLengthLimit
    }

    /// Extract the last usable assistant closing text from a Turn —
    /// walking backwards to the most recent `.reply` / `.stop` / `.thought`
    /// Step that carries non-empty text. Returns the first non-empty line
    /// only, trimmed. `nil` when no Step qualifies (interrupted Turn with
    /// no assistant text, toolCall-only Turn, etc).
    static func closingText(of turn: Turn) -> String? {
        for step in turn.steps.reversed() {
            switch step.kind {
            case .reply, .stop, .thought:
                if let line = firstNonEmptyLine(of: step.text) {
                    return line
                }
            case .prompt, .toolCall, .toolResult, .interruption:
                continue
            }
        }
        return nil
    }

    /// Truncate `text` to `limit` chars; append `…` when cut.
    static func trim(_ text: String, to limit: Int) -> String {
        if text.count <= limit { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Private

    private static func firstNonEmptyLine(of text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
