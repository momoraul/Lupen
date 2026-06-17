import Foundation

/// Pure utility that slices a session group to the current page window
/// and returns everything `SessionListViewController.reloadData` needs
/// to draw the visible rows and the "Show N more" sentinel — including
/// label maths. Framework-free so the rules are unit-testable
/// (same philosophy as `SessionGrouping`).
enum SessionPagination {

    struct Window {
        let visibleSessions: [Session]
        /// Sessions still hidden after applying the window. `0` means
        /// no Load-more row at all.
        let remaining: Int
        /// Convenience equivalent of `remaining > 0`.
        var hasLoadMoreRow: Bool { remaining > 0 }
        /// How many sessions the next Load-more click reveals; can be
        /// less than `pageSize` on the final partial page.
        let nextStep: Int
        /// Sessions still hidden **after** the next Load-more click —
        /// the parenthesised value in "Show 5 more  (42 left)". `0`
        /// when `hasLoadMoreRow == false`.
        let remainingAfterStep: Int
        /// True when the window has grown past one page — i.e. a
        /// "Show less" control would actually hide rows. Derived from
        /// *visible* rows, not the requested window size, so a stale
        /// over-large window over a small group doesn't offer a no-op
        /// collapse.
        let canCollapse: Bool
        /// The sidebar appends its action row when either direction is
        /// useful: more rows to reveal, or a grown window to collapse.
        var hasActionRow: Bool { hasLoadMoreRow || canCollapse }
    }

    /// - Parameters:
    ///   - sessions: Already sorted in the desired display order
    ///     (endTime DESC, etc.).
    ///   - visibleCount: Current window size, kept per-group by the
    ///     caller.
    ///   - pageSize: Default reveal count per "Show more" click.
    static func window(
        sessions: [Session],
        visibleCount: Int,
        pageSize: Int
    ) -> Window {
        let total = sessions.count
        // Defensive normalisation against negative / over-large input.
        let safeVisible = max(0, min(visibleCount, total))
        let visible = Array(sessions.prefix(safeVisible))
        let remaining = max(0, total - visible.count)
        let canCollapse = visible.count > pageSize

        guard remaining > 0 else {
            return Window(
                visibleSessions: visible,
                remaining: 0,
                nextStep: 0,
                remainingAfterStep: 0,
                canCollapse: canCollapse
            )
        }

        // Final partial page may reveal fewer than `pageSize`.
        let nextStep = min(pageSize, remaining)
        let remainingAfterStep = remaining - nextStep
        return Window(
            visibleSessions: visible,
            remaining: remaining,
            nextStep: nextStep,
            remainingAfterStep: remainingAfterStep,
            canCollapse: canCollapse
        )
    }
}
