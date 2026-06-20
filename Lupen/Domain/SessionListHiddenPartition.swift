import Foundation

/// Splits a project group's sessions into "shown" and "hidden" buckets for
/// the sidebar. A session is hidden when it is *low-signal* — its cost
/// aggregate is present and non-positive (Codex `codex-auto-review`
/// assessment threads, empty `/clear` sessions, etc.): nothing billable
/// happened, so it is noise in the list. Framework-free so the rules stay
/// unit-testable (same philosophy as `SessionPagination` / `SessionGrouping`).
///
/// The cost lookup itself is injected as `isLowSignal` so the aggregate
/// availability gate — never hide on a *missing* aggregate, which would blank
/// the sidebar during a cold load before costs are imported — lives with the
/// view controller, and tests can stub the predicate directly.
enum SessionListHiddenPartition {

    struct Result: Equatable {
        let shown: [Session]
        let hidden: [Session]
    }

    /// - Parameters:
    ///   - sessions: group sessions already in display order (endTime DESC).
    ///   - hidingEnabled: when false (e.g. an active search/filter), nothing
    ///     is hidden — the user is looking for something and must see all.
    ///   - keepShown: session ids that must never be hidden even when
    ///     low-signal (typically the current selection, so a reload never
    ///     drops the row the user is viewing).
    ///   - isLowSignal: returns true when a session is a hide candidate.
    static func partition(
        sessions: [Session],
        hidingEnabled: Bool,
        keepShown: Set<String>,
        isLowSignal: (Session) -> Bool
    ) -> Result {
        guard hidingEnabled else {
            return Result(shown: sessions, hidden: [])
        }
        var shown: [Session] = []
        var hidden: [Session] = []
        for session in sessions {
            if isLowSignal(session) && !keepShown.contains(session.id) {
                hidden.append(session)
            } else {
                shown.append(session)
            }
        }
        return Result(shown: shown, hidden: hidden)
    }
}
