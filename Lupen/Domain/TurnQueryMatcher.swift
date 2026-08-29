import Foundation

/// Per-Turn query match predicate for the conversation pane's
/// highlight feature.
///
/// When the sidebar's search field has a non-empty query, the
/// conversation pane marks each Turn that matches with a subtle
/// background tint. This helper is the single source of truth for
/// "does this Turn match?" — pure, stateless, and unit-testable
/// without any AppKit stand-up.
///
/// **Scope follows the sidebar.** The search field can be pointed at the
/// user's prompts, at the model's replies, or at both, and the outline has
/// to agree with the list beside it: a session that surfaced because a
/// *reply* mentioned the term must show which turns those replies are in.
/// Matching prompts only — as this did before scoped search existed —
/// would leave those sessions with no highlighted turn at all.
///
/// Within prompts the rule is unchanged and deliberate:
///   * Only the Turn's **root prompt** (`turn.promptStep`) is scanned —
///     the first `.prompt` Step, which is the text the user actually
///     typed. Subsequent `.prompt` Steps in the same Turn are
///     system-injected context (e.g. Claude Code's "Base directory for
///     this skill: ..." preamble) and must not contribute to the match.
///     Matching those causes false positives when the injection text
///     happens to contain the query as a substring (e.g. "look" contains
///     "ok").
///   * Case-insensitive via `localizedCaseInsensitiveContains` — the same
///     algorithm `AppStateStore.sessionMatchesQuery` uses.
///   * Empty or whitespace-only queries always return false so the caller
///     doesn't need to guard on its own.
///
/// Note this is a **substring** match, unlike the FTS index the sidebar
/// consults, which matches whole terms with prefixes. The outline is
/// highlighting text already on screen, so substring is what the user
/// expects here; the two need not agree on which *rows* they'd return,
/// only on which side of the conversation they read.
enum TurnQueryMatcher {

    static func turnMatches(
        _ turn: Turn,
        query: String,
        scope: SearchTextScope = .everything
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if scope != .replies, let prompt = turn.promptStep?.text,
           prompt.localizedCaseInsensitiveContains(trimmed) {
            return true
        }
        if scope != .prompts, replyMatches(turn, trimmed) {
            return true
        }
        return false
    }

    /// Reply text in the turn. Tool calls, tool results and thinking are
    /// left out: those are machinery, and someone searching for "read"
    /// means the word in a reply, not every `Read` tool invocation. This
    /// matches what the `reply` rows in the FTS index cover, so the
    /// outline and the sidebar read the same side of the conversation.
    private static func replyMatches(_ turn: Turn, _ query: String) -> Bool {
        turn.steps.contains { step in
            guard step.kind == .reply, let text = step.text else { return false }
            return text.localizedCaseInsensitiveContains(query)
        }
    }
}
