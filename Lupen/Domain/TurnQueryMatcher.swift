import Foundation

/// Per-Turn query match predicate for the conversation pane's
/// highlight feature.
///
/// When the sidebar's search field has a non-empty query, the
/// conversation pane marks each Turn whose user prompt contains the
/// query with a subtle background tint. This helper is the single
/// source of truth for "does this Turn match?" — pure, stateless,
/// and unit-testable without any AppKit stand-up.
///
/// Matching rules:
///   * Only the Turn's **root prompt** (`turn.promptStep`) is
///     scanned — the first `.prompt` Step, which is the text the
///     user actually typed. Subsequent `.prompt` Steps in the same
///     Turn are system-injected context (e.g. Claude Code's
///     "Base directory for this skill: ..." preamble) and must not
///     contribute to the match. Matching those would cause false
///     positives when the injection text happens to contain the
///     query as a substring (e.g. "look" contains "ok").
///   * Assistant replies, tool calls, and tool results are never
///     searched — users are answering "what did I ask about", not
///     "what did Claude say" (Plan 3 Open Question #2).
///   * Case-insensitive via `localizedCaseInsensitiveContains`
///     (same algorithm `AppStateStore.sessionMatchesQuery` uses for
///     session-level matching).
///   * Empty or whitespace-only queries always return false so the
///     caller doesn't need to guard on its own.
///
/// This mirrors `AppStateStore.sessionMatchesQuery`'s per-Turn
/// loop, which also reads `turn.promptStep?.text` (not every
/// `.prompt` Step). Keeping the two in sync avoids a confusing
/// situation where a session passes the sidebar filter via one
/// rule and the Turn highlight uses a different one.
enum TurnQueryMatcher {

    static func turnMatches(_ turn: Turn, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let text = turn.promptStep?.text else { return false }
        return text.localizedCaseInsensitiveContains(trimmed)
    }
}
