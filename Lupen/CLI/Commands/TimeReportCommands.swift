import ArgumentParser
import Foundation

// Time-series reports: cost/usage per day, week, or month. All three roll
// up the store's per-day buckets (local-time, as in the GUI Reports view)
// in pure code, so they share one report type and renderer. Weekly grouping
// uses ISO weeks (Monday start) regardless of locale — the GUI's "this week"
// follows the user's locale instead; the CLI deliberately fixes Monday.

private let timeSortDiscussion = "Sort with --sort date (default) or cost. --limit keeps the most recent N (or the costliest N under --sort cost)."

struct DailyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daily", abstract: "Cost and usage per day.", discussion: timeSortDiscussion
    )
    @OptionGroup var options: CLIGlobalOptions
    @OptionGroup var rowOptions: CLIRowOptions
    func run() throws { try TimeReportRunner.run(granularity: .day, options: options, rowOptions: rowOptions) }
}

struct WeeklyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "weekly", abstract: "Cost and usage per ISO week (Monday start).", discussion: timeSortDiscussion
    )
    @OptionGroup var options: CLIGlobalOptions
    @OptionGroup var rowOptions: CLIRowOptions
    func run() throws { try TimeReportRunner.run(granularity: .week, options: options, rowOptions: rowOptions) }
}

struct MonthlyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monthly", abstract: "Cost and usage per calendar month.", discussion: timeSortDiscussion
    )
    @OptionGroup var options: CLIGlobalOptions
    @OptionGroup var rowOptions: CLIRowOptions
    func run() throws { try TimeReportRunner.run(granularity: .month, options: options, rowOptions: rowOptions) }
}

enum TimeReportRunner {
    static func run(granularity: TimeGranularity, options: CLIGlobalOptions, rowOptions: CLIRowOptions) throws {
        let range = try options.resolveRange()
        let sort = try TimeSort.parse(rowOptions.sort, default: .date)

        let engine = try CLIEngine.open(source: options.resolvedSource, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }

        let daily = try engine.store.usageBuckets(hourly: false, from: range.from, to: range.to)
        let rows = CLITimeReport.build(dailyBuckets: daily, granularity: granularity, sort: sort, limit: rowOptions.limit)
        let report = CLITimeReport(
            provider: options.provider,
            periodLabel: options.periodLabel,
            granularity: granularity,
            rows: rows,
            totalPeriods: CLITimeReport.distinctBucketCount(dailyBuckets: daily, granularity: granularity),
            totalCostUSD: daily.reduce(0) { $0 + $1.costUSD },
            totalRequests: daily.reduce(0) { $0 + $1.requestCount },
            totalTokens: daily.reduce(0) { $0 + $1.tokenCount }
        )

        if options.json {
            try CLIOutput.printJSON(report.jsonArray)
        } else if options.csv {
            CLIOutput.line(report.csv)
        } else {
            report.printTable(color: CLIStyle.useColor(disabled: options.noColor))
        }
    }
}

enum TimeGranularity {
    case day, week, month

    var columnHeader: String {
        switch self {
        case .day: return "DATE"
        case .week: return "WEEK OF"
        case .month: return "MONTH"
        }
    }

    var noun: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        }
    }
}

enum TimeSort: String {
    case date, cost

    static func parse(_ raw: String?, default fallback: TimeSort) throws -> TimeSort {
        guard let raw else { return fallback }
        guard let sort = TimeSort(rawValue: raw.lowercased()) else {
            throw ValidationError("Invalid --sort '\(raw)'. Use date or cost.")
        }
        return sort
    }
}

/// Data + rendering for the time-series reports.
struct CLITimeReport {
    struct Row: Equatable {
        let label: String
        let costUSD: Double
        let requests: Int
        let tokens: Int
    }

    let provider: ProviderKind
    let periodLabel: String
    let granularity: TimeGranularity
    let rows: [Row]
    /// Distinct buckets in the period (pre-limit) so TOTAL reflects the
    /// whole period and can flag a truncated subset.
    let totalPeriods: Int
    let totalCostUSD: Double
    let totalRequests: Int
    let totalTokens: Int

    /// Roll the store's per-day buckets up to the requested granularity,
    /// sort, and limit. Pure — no store access.
    static func build(
        dailyBuckets: [StoreUsageBucket],
        granularity: TimeGranularity,
        sort: TimeSort,
        limit: Int?
    ) -> [Row] {
        var byKey: [String: (cost: Double, requests: Int, tokens: Int)] = [:]
        for bucket in dailyBuckets {
            let key = key(forDay: bucket.bucketKey, granularity: granularity)
            var aggregate = byKey[key] ?? (0, 0, 0)
            aggregate.cost += bucket.costUSD
            aggregate.requests += bucket.requestCount
            aggregate.tokens += bucket.tokenCount
            byKey[key] = aggregate
        }
        var rows = byKey.map { Row(label: $0.key, costUSD: $0.value.cost, requests: $0.value.requests, tokens: $0.value.tokens) }
        switch sort {
        case .date:
            rows.sort { $0.label < $1.label }  // keys are zero-padded → lexical == chronological
        case .cost:
            rows.sort { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.label < $1.label }
        }
        if let limit, limit >= 0, rows.count > limit {
            // Chronological series: keep the most RECENT N (the tail), still
            // in ascending display order. Cost-ranked: keep the top N (head).
            rows = sort == .date ? Array(rows.suffix(limit)) : Array(rows.prefix(limit))
        }
        return rows
    }

    static func distinctBucketCount(dailyBuckets: [StoreUsageBucket], granularity: TimeGranularity) -> Int {
        Set(dailyBuckets.map { key(forDay: $0.bucketKey, granularity: granularity) }).count
    }

    /// Map a `YYYY-MM-DD` day key to its bucket key for the granularity.
    static func key(forDay day: String, granularity: TimeGranularity) -> String {
        switch granularity {
        case .day: return day
        case .month: return String(day.prefix(7))  // YYYY-MM
        case .week: return weekStart(forDay: day) ?? day
        }
    }

    /// Monday of the ISO week containing `day` (local time), as YYYY-MM-DD.
    /// Falls back to the day itself if the key can't be parsed.
    static func weekStart(forDay day: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .iso8601)
        parser.timeZone = Calendar.current.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return nil }

        var calendar = Calendar(identifier: .iso8601)  // Monday-first, ISO weeks
        calendar.timeZone = Calendar.current.timeZone
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        return parser.string(from: start)
    }

    // MARK: - Rendering

    func printTable(color: Bool) {
        guard !rows.isEmpty else {
            CLIOutput.line("No usage for \(periodLabel).")
            return
        }
        CLIOutput.line("\(provider.cliLabel) · \(periodLabel)")
        CLIOutput.line()

        // TOKENS is the store's per-bucket token sum (input + output + cache);
        // it excludes Codex reasoning tokens, matching the GUI Reports buckets
        // — so it can read slightly lower than `summary`'s context-token figure.
        let table = CLITable(
            columns: [
                .init(granularity.columnHeader),
                .init("COST", align: .right),
                .init("REQUESTS", align: .right),
                .init("TOKENS", align: .right),
            ],
            rows: rows.map { row in
                [row.label, CLIFormat.money(row.costUSD), CLIFormat.int(row.requests), CLIFormat.int(row.tokens)]
            }
        )
        CLIOutput.line(table.render(color: color))
        CLIOutput.line()
        CLIOutput.line(totalLine)
    }

    var totalLine: String {
        let cost = CLIFormat.money(totalCostUSD)
        let requests = CLIFormat.int(totalRequests)
        let tokens = CLIFormat.int(totalTokens)
        // "showing N of M" (not "top"): the shown rows may be the most-recent
        // N (date sort) rather than a ranking. Totals always reflect the period.
        let prefix = rows.count < totalPeriods
            ? "TOTAL  showing \(rows.count) of \(totalPeriods) \(granularity.noun)s"
            : "TOTAL  \(totalPeriods) \(granularity.noun)(s)"
        return "\(prefix) · \(cost) · \(requests) req · \(tokens) tok"
    }

    var jsonArray: [[String: Any]] {
        rows.map { ["period": $0.label, "costUsd": $0.costUSD, "requests": $0.requests, "tokens": $0.tokens] }
    }

    var csv: String {
        CLICSV.render(
            header: ["period", "costUsd", "requests", "tokens"],
            rows: rows.map { [$0.label, String(format: "%.6f", $0.costUSD), String($0.requests), String($0.tokens)] }
        )
    }
}
