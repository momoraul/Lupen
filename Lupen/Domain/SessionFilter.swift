import Foundation

/// Declarative filter passed to `AppStateStore.filteredSessions(_:)` to
/// narrow the sidebar's session list.
///
/// This type is intentionally a pure value (no reference to store, no
/// side effects) so it can be:
///   1. Diffed for `Equatable` in the UI debounce logic ("has the filter
///      actually changed since last reload?").
///   2. Unit-tested against mock sessions without standing up a real
///      AppStateStore.
///   3. Stored/serialized later if we ever want saved searches.
///
/// Every field is "narrowing" — populating it reduces the result set.
/// An empty filter (`isEmpty == true`) returns every session unchanged.
struct SessionFilter: Sendable, Equatable {

    /// Case-insensitive substring match, searched across:
    ///   * the session's decoded project label (last segment of
    ///     `projectPath`, so "Lupen" matches sessions under
    ///     `-Users-.../Lupen`)
    ///   * the first user prompt's text (so "cache refactor" finds the
    ///     session where that was asked)
    ///   * the session's slug (`harmonic-nibbling-meerkat`) for users
    ///     who remember that handle
    var query: String = ""

    /// Scope for `query`. `.everything` (default) also matches conversation
    /// content — prompt / reply / thinking text via the FTS index — so a
    /// keyword finds a session by anything said inside it. `.sessions`
    /// restricts the match to session-level identity (project label, slug,
    /// and title), filtering the list by name without diving into content.
    /// Only meaningful when `query` is non-empty.
    var searchScope: SearchScope = .everything

    /// Narrow to a single project group. Matches exactly against the
    /// *raw* encoded project key (`session.projectPath`) — same key used
    /// by `SessionGrouping.groupByProject`, so the UI can pass a group
    /// key straight through without decode round-trips.
    ///
    /// `nil` means "any project".
    var projectFilter: String? = nil

    /// Narrow to sessions whose `startTime` falls inside a date range.
    /// `nil` means "any time".
    var dateRange: DateRange? = nil

    /// Narrow to sessions that include at least one request for one of
    /// the listed models. Empty set means "any model".
    ///
    /// Stored as a `Set<String>` of model ids (e.g.
    /// `"claude-opus-4-6"`). A session passes if the intersection with
    /// its requests' models is non-empty.
    var models: Set<String> = []

    /// True when no fields are set — the store can short-circuit the
    /// scan and just return `sessions` sorted.
    var isEmpty: Bool {
        query.isEmpty
            && projectFilter == nil
            && dateRange == nil
            && models.isEmpty
    }

    /// True when any filter beyond the free-text `query` is active.
    ///
    /// The sidebar's filter button uses this to pick between its
    /// outline and filled SF Symbol variants — the search field
    /// already visualizes `query` on its own, so we deliberately
    /// exclude it so the filter button only "lights up" for the
    /// structured filters the user set through the popover. Without
    /// this distinction, typing in the search field would also tint
    /// the filter icon, which reads as "there's a popover filter
    /// applied" — misleading. A non-default `searchScope` IS counted:
    /// it's set through the popover, so the lit icon correctly signals
    /// "the keyword is scoped to session names only".
    var hasStructuredFilters: Bool {
        projectFilter != nil || dateRange != nil || !models.isEmpty
            || searchScope != .everything
    }

    /// Overwrite this filter's popover-managed fields
    /// (`projectFilter`, `dateRange`, `models`) with the corresponding
    /// fields from `other`, while leaving `query` untouched.
    ///
    /// Exists because the filter popover and the search field own
    /// disjoint slices of `SessionFilter`: the popover controls the
    /// three structured fields, and the search field owns `query`.
    /// The popover emits a **full** `SessionFilter` value via its
    /// `onFilterChanged` callback — but that value's `query` is
    /// frozen at the moment the popover was opened, so blindly doing
    /// `currentFilter = emitted` would *clobber* any query the user
    /// has typed into the search field since the popover opened.
    ///
    /// Calling this helper instead keeps the two sources-of-truth
    /// honest: the sidebar's live `query` (owned by the search
    /// field) stays, and only the fields the popover actually
    /// manages get overwritten. If the popover ever grows a
    /// query-related control, this helper is the one place to relax
    /// that rule.
    mutating func applyStructuredFields(from other: SessionFilter) {
        projectFilter = other.projectFilter
        dateRange = other.dateRange
        models = other.models
        searchScope = other.searchScope
    }

    // MARK: - SearchScope

    /// What a free-text `query` is matched against.
    enum SearchScope: String, Sendable, Equatable, CaseIterable, Identifiable {
        /// Session identity only: project label, slug, and title.
        case sessions
        /// Also conversation content (prompt / reply / thinking) via FTS.
        case everything

        var id: Self { self }
    }

    // MARK: - DateRange

    /// Time window used to narrow sessions by `startTime`. `custom`
    /// lets callers supply arbitrary bounds; the other cases resolve
    /// to wall-clock windows via `resolveBounds(now:)`.
    enum DateRange: Sendable, Equatable {
        case today
        case yesterday
        case last24h
        case thisWeek
        case last30days
        case custom(from: Date, to: Date)

        /// Resolve this range to a concrete `[start, end]` closed
        /// interval against the given reference time. Pass `Date()` in
        /// production; tests inject a fixed instant so the presets
        /// behave deterministically across time zones and clock drift.
        ///
        /// Calendar semantics:
        ///   * `today` — start of today (user's local midnight) → `now`
        ///   * `yesterday` — yesterday's local midnight → the last
        ///                   instant before today's midnight
        ///                   (≈ 23:59:59.999). Both bounds sit inside
        ///                   yesterday so the closed-interval `contains`
        ///                   call never leaks into today.
        ///   * `last24h` — `now - 24h` → `now`
        ///   * `thisWeek` — start of this week (locale's first weekday
        ///                  midnight) → `now`
        ///   * `last30days` — `now - 30d` → `now`
        ///   * `custom` — the caller's bounds verbatim
        func resolveBounds(now: Date = Date()) -> (start: Date, end: Date) {
            let calendar = Calendar.current
            switch self {
            case .today:
                let start = calendar.startOfDay(for: now)
                return (start, now)
            case .yesterday:
                let todayStart = calendar.startOfDay(for: now)
                let yesterdayStart = calendar.date(
                    byAdding: .day, value: -1, to: todayStart
                ) ?? todayStart.addingTimeInterval(-86_400)
                // End at the last millisecond before today's midnight so
                // an inclusive `contains` check never bleeds into today.
                let yesterdayEnd = todayStart.addingTimeInterval(-0.001)
                return (yesterdayStart, yesterdayEnd)
            case .last24h:
                return (now.addingTimeInterval(-86_400), now)
            case .thisWeek:
                // `dateInterval(of:.weekOfYear, for:)` respects the
                // user's locale first-weekday (Sunday in en_US, Monday
                // in ko_KR, etc). Fall back to `now - 7d` if the
                // calendar can't resolve (practically never).
                if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                    return (interval.start, now)
                }
                return (now.addingTimeInterval(-7 * 86_400), now)
            case .last30days:
                return (now.addingTimeInterval(-30 * 86_400), now)
            case .custom(let from, let to):
                return (from, to)
            }
        }

        /// True when the given timestamp falls inside this range,
        /// evaluated against `now`. Convenience wrapper used by
        /// `AppStateStore.filteredSessions`.
        func contains(_ timestamp: Date, now: Date = Date()) -> Bool {
            let (start, end) = resolveBounds(now: now)
            return timestamp >= start && timestamp <= end
        }

        /// Build a `.custom` range from two user-picked calendar days,
        /// expanding to the full INCLUSIVE span: start of the earlier day
        /// through the last instant (23:59:59) of the later day. Tolerates a
        /// reversed pick (From after To) by swapping. Shared by both date-
        /// range UIs (the sidebar filter popover and the Reports window) so
        /// "custom" means exactly the same span in each.
        static func customSpanning(
            _ a: Date, _ b: Date, calendar: Calendar = .current
        ) -> DateRange {
            let dayA = calendar.startOfDay(for: a)
            let dayB = calendar.startOfDay(for: b)
            let (lo, hi) = dayA <= dayB ? (dayA, dayB) : (dayB, dayA)
            let end = calendar.date(
                byAdding: DateComponents(day: 1, second: -1), to: hi
            ) ?? hi
            return .custom(from: lo, to: end)
        }
    }
}
