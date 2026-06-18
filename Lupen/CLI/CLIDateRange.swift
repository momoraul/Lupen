import Foundation

/// Resolves the CLI's period options (`--since/--until`, `--last`,
/// `--month`) into an inclusive `[from, to]` window passed to the store's
/// range queries (`timestamp >= from AND timestamp <= to`, with `nil`
/// meaning unbounded on that side).
///
/// Pure and calendar-injectable so the window math is unit-testable
/// without wall-clock flakiness. The three styles are mutually exclusive
/// — mixing them is a usage error rather than a silently-merged window.
enum CLIDateRange {
    struct Resolved: Equatable {
        let from: Date?
        let to: Date?
    }

    enum ResolveError: Error, CustomStringConvertible, Equatable {
        case conflictingOptions
        case badDate(String)
        case badRelative(String)
        case badMonth(String)

        var description: String {
            switch self {
            case .conflictingOptions:
                return "Use only one of --last, --month, or --since/--until."
            case .badDate(let value):
                return "Invalid date '\(value)'. Expected YYYY-MM-DD."
            case .badRelative(let value):
                return "Invalid --last '\(value)'. Expected forms like 30d, 4w, 1m."
            case .badMonth(let value):
                return "Invalid --month '\(value)'. Expected YYYY-MM."
            }
        }
    }

    static func resolve(
        since: String?,
        until: String?,
        last: String?,
        month: String?,
        now: Date,
        calendar: Calendar
    ) throws -> Resolved {
        let hasSinceUntil = (since != nil) || (until != nil)
        let groupsUsed = [hasSinceUntil, last != nil, month != nil].filter { $0 }.count
        if groupsUsed > 1 { throw ResolveError.conflictingOptions }

        if let last {
            return Resolved(from: try relativeStart(last, now: now, calendar: calendar), to: now)
        }
        if let month {
            return try monthRange(month, calendar: calendar)
        }
        return Resolved(
            from: try since.map { try startOfDay($0, calendar: calendar) },
            to: try until.map { try endOfDay($0, calendar: calendar) }
        )
    }

    // MARK: - Helpers

    private static func relativeStart(_ raw: String, now: Date, calendar: Calendar) throws -> Date {
        guard let unit = raw.last, let value = Int(raw.dropLast()), value > 0 else {
            throw ResolveError.badRelative(raw)
        }
        let component: Calendar.Component
        switch unit {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        default: throw ResolveError.badRelative(raw)
        }
        guard let start = calendar.date(byAdding: component, value: -value, to: now) else {
            throw ResolveError.badRelative(raw)
        }
        return start
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    /// Strict parse: requires the input to round-trip back to the same
    /// string. `DateFormatter` accepts wrong separators / out-of-range
    /// fields more leniently than `isLenient = false` implies (e.g.
    /// `2026/06/01` under `yyyy-MM-dd`, or `2026-13` rolling into the next
    /// year), so the round-trip is what actually rejects malformed input.
    private static func strictDate(_ raw: String, format: String, calendar: Calendar) -> Date? {
        let formatter = formatter(format, calendar: calendar)
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
            return nil
        }
        return date
    }

    private static func startOfDay(_ raw: String, calendar: Calendar) throws -> Date {
        guard let date = strictDate(raw, format: "yyyy-MM-dd", calendar: calendar) else {
            throw ResolveError.badDate(raw)
        }
        return calendar.startOfDay(for: date)
    }

    private static func endOfDay(_ raw: String, calendar: Calendar) throws -> Date {
        let start = try startOfDay(raw, calendar: calendar)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw ResolveError.badDate(raw)
        }
        return inclusiveEnd(beforeStartOf: nextDay)
    }

    private static func monthRange(_ raw: String, calendar: Calendar) throws -> Resolved {
        guard let monthStart = strictDate(raw, format: "yyyy-MM", calendar: calendar) else {
            throw ResolveError.badMonth(raw)
        }
        let start = calendar.startOfDay(for: monthStart)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) else {
            throw ResolveError.badMonth(raw)
        }
        return Resolved(from: start, to: inclusiveEnd(beforeStartOf: nextMonth))
    }

    /// Inclusive upper bound for a `timestamp <= to` query, given the
    /// exclusive next-period start. Backs off one millisecond rather than
    /// one second: stored timestamps carry millisecond precision, so a
    /// `-1s` end would silently drop activity in the final second of an
    /// `--until` day / `--month`.
    private static func inclusiveEnd(beforeStartOf nextPeriodStart: Date) -> Date {
        nextPeriodStart.addingTimeInterval(-0.001)
    }

    /// Human label for the selected period, derived from the raw flags so
    /// it reads the way the user typed it (`last 30d`, `2026-06`, …).
    /// Pure so it can be unit-tested without constructing the option set.
    static func label(since: String?, until: String?, last: String?, month: String?) -> String {
        if let last { return "last \(last)" }
        if let month { return month }
        switch (since, until) {
        case let (start?, end?): return "\(start) → \(end)"
        case let (start?, nil): return "since \(start)"
        case let (nil, end?): return "through \(end)"
        default: return "all time"
        }
    }
}
