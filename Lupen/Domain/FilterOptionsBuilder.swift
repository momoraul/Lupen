import Foundation

/// Pure helpers that turn a session array into the option lists the
/// sidebar's filter popover renders (project dropdown, model
/// checkboxes).
///
/// Kept separate from `FilterPopoverViewController` so:
///   1. The "which projects exist right now?" and "which models exist
///      right now?" questions can be unit-tested without standing up
///      any AppKit views.
///   2. Any future consumer (saved searches, reports window, a
///      command-palette search scope) can reuse the same deduplication
///      and ordering rules without re-deriving them from `sessions`.
///
/// These helpers deliberately operate on the *unfiltered* session set:
/// the popover shows the same options regardless of which filter is
/// currently applied, so the user can always switch to a different
/// project (or clear all filters) without its dropdown collapsing to
/// one item.
enum FilterOptionsBuilder {

    /// Project option as the popover renders it.
    ///
    /// `key` is the raw encoded project path (`Session.projectPath`) so
    /// the popover can drop it straight into `SessionFilter.projectFilter`
    /// with no round-trip through the label.
    struct ProjectOption: Equatable {
        let key: String
        let label: String
        let count: Int
    }

    /// Model option as the popover renders it.
    struct ModelOption: Equatable {
        /// Raw model id (e.g. `"claude-opus-4-6"`) — matches
        /// `ParsedRequest.model` so the popover can drop it straight
        /// into `SessionFilter.models`.
        let id: String
        /// How many sessions used this model at least once. Used for
        /// a "(N)" affix in the checkbox label and as the primary
        /// sort key (most-used first).
        let count: Int
    }

    /// Distinct projects present in `sessions`, sorted so the project
    /// with the most-recent activity appears first.
    ///
    /// The ordering is delegated to `SessionGrouping.groupByProject` so
    /// the popover's dropdown reads in the same order as the sidebar
    /// headers — users should never have to context-switch between
    /// "order I see on the left" and "order in the filter menu".
    ///
    /// Sessions with `projectPath == nil` are intentionally excluded:
    /// they collapse into `SessionGrouping`'s `""`-keyed Unknown group,
    /// which `SessionFilter.projectFilter` equality can't target (the
    /// filter compares `session.projectPath != projectFilter` where
    /// `nil != ""` is true). Exposing an "Unknown" entry that silently
    /// filters nothing would be worse than hiding it.
    static func distinctProjects(from sessions: [Session]) -> [ProjectOption] {
        let groups = SessionGrouping.groupByProject(sessions)
        return groups
            .filter { !$0.key.isEmpty }
            .map { group in
                ProjectOption(
                    key: group.key,
                    label: group.label,
                    count: group.sessions.count
                )
            }
    }

    /// Sentinel model id used by the JSONL parser for requests that
    /// arrived without a real model field (old cache lines, partial
    /// writes). Excluded from the popover's model list because
    /// selecting "filter by `<synthetic>`" would narrow to a pseudo
    /// model that users can't reason about — it's a parser artifact,
    /// not something they ran a conversation with.
    private static let syntheticModelId = "<synthetic>"

    /// Distinct models present across every session's requests, sorted
    /// by number-of-sessions DESC, with a stable id-ascending tie-break.
    ///
    /// A session counts once per model regardless of how many requests
    /// it made to that model. The filter semantics are "session
    /// contains ≥1 request to any of these models", so counting per
    /// request would double-weight long sessions and bias the sort
    /// toward whatever model happened to run the most turns, not the
    /// model users actually ran in the most sessions.
    ///
    /// SQLite-first shells carry no request rows (6.2) — pass the SQL
    /// sidebar aggregates' model sets as `modelsBySession` (keyed by
    /// `Session.id`); a session falls back to that map when its
    /// `requests` is empty, so options and Stage-3 matching read the
    /// same source.
    ///
    /// Sessions with no model information contribute nothing. The
    /// parser's `<synthetic>` sentinel is also excluded — see
    /// `syntheticModelId`.
    static func distinctModels(
        from sessions: [Session],
        modelsBySession: [String: Set<String>] = [:]
    ) -> [ModelOption] {
        var counts: [String: Int] = [:]
        for session in sessions {
            let rawModels = session.requests.isEmpty
                ? (modelsBySession[session.id] ?? [])
                : Set(session.requests.compactMap { $0.model })
            for model in rawModels where model != Self.syntheticModelId {
                counts[model, default: 0] += 1
            }
        }
        return counts
            .map { ModelOption(id: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.id < rhs.id
            }
    }
}
