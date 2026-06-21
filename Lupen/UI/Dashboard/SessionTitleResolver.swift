import Foundation

/// Pure resolver for the sidebar's "what was this session about?" label.
///
/// Extracted from `SessionListViewController.sessionTitle(for:)` so the
/// priority ladder is unit-testable. The VC method is a thin wrapper that
/// supplies `firstTurnPreview` from `store.firstTurn(in:)`.
///
/// Priority (first non-empty wins):
///   1. `session.customTitle` — user-assigned via Claude Code `/rename`.
///      Highest priority: if the user bothered to name the session, the
///      label must never drift back to derived content.
///   2. `firstTurnPreview` — live first-Turn preview. Authoritative when
///      the background parse has assembled `turnsBySession`.
///   3. `session.cachedTitle` — persisted fallback from the previous
///      parse, so cache-hit cold launches render without flashing the
///      slug while the parse runs.
///   4. `session.slug` — Claude Code's human-readable slug.
///   5. `session.firstPrompt` — the cleaned first user prompt
///      (importer-derived, `sessions.first_prompt`). Codex sessions have
///      no `slug` and may lack a `cachedTitle` when `session_index.jsonl`
///      carries no thread name; this is what keeps them from falling all
///      the way to the id prefix. Deliberately placed *below* `slug` so
///      Claude sessions keep their existing slug label — only sessions
///      with neither a cached title nor a slug reach it.
///   6. Session id prefix — last-resort stub so the row is never empty.
///
/// Kept pure (no `store` / no UI framework) so regressions in the
/// priority order surface as unit test failures rather than manual
/// visual checks. Ties directly back to the Plan 7 incident where
/// `customTitle` wiring relied on manual verification alone.
enum SessionTitleResolver {

    /// Identifies which branch of the priority ladder produced the label.
    /// Consumed by the sidebar cell to render a small `tag.fill` SF Symbol
    /// in front of user-named sessions, à la Finder tags.
    ///
    /// The non-`custom` cases are all "derived" — we could collapse them
    /// into a single `.derived` variant, but keeping them distinct leaves
    /// room for future UX that cares (e.g. italic for pure slug fallback,
    /// or a "stale" indicator when only `cachedTitle` is available).
    enum Origin: Equatable, Sendable {
        case custom       // `session.customTitle` — user /rename
        case firstTurn    // live `firstTurnPreview`
        case cached       // `session.cachedTitle`
        case slug         // `session.slug`
        case firstPrompt  // `session.firstPrompt` — importer-derived
        case idPrefix     // fallback
    }

    struct Resolved: Equatable, Sendable {
        let text: String
        let origin: Origin
    }

    /// Whitespace policy: each source is checked "trimmed-non-empty" but
    /// returned **verbatim**. Upstream (`RichEntryDecoder.extractCustomTitle`)
    /// already trims leading/trailing whitespace before storing, so
    /// `session.customTitle` with only outer whitespace cannot reach here;
    /// but internal spacing ("plan  7") is preserved exactly as typed by
    /// the user. Same for `firstTurnPreview` / `cachedTitle`. `firstPrompt`
    /// is the exception: it is importer-extracted (not user-authored), so its
    /// outer whitespace is trimmed before display (inner spacing preserved).
    static func resolve(
        session: Session,
        firstTurnPreview: String?
    ) -> Resolved {
        if let custom = session.customTitle,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Resolved(text: custom, origin: .custom)
        }
        if let preview = firstTurnPreview,
           !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Resolved(text: preview, origin: .firstTurn)
        }
        if let cached = session.cachedTitle, !cached.isEmpty {
            return Resolved(text: cached, origin: .cached)
        }
        if let slug = session.slug, !slug.isEmpty {
            return Resolved(text: slug, origin: .slug)
        }
        if let firstPrompt = session.firstPrompt {
            // Unlike customTitle / firstTurnPreview (user-authored, kept
            // verbatim), firstPrompt is importer-extracted message text — trim
            // outer whitespace so a prompt that starts with blank lines or
            // pasted indentation doesn't render as an empty/indented row.
            let trimmed = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return Resolved(text: trimmed, origin: .firstPrompt)
            }
        }
        return Resolved(text: String(session.rawSessionId.prefix(8)), origin: .idPrefix)
    }

    /// Convenience shim for call sites that only need the text.
    static func resolveText(
        session: Session,
        firstTurnPreview: String?
    ) -> String {
        resolve(session: session, firstTurnPreview: firstTurnPreview).text
    }
}
