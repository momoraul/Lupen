import ArgumentParser
import Foundation

/// `lupen top` — the most expensive sessions or days in the period.
/// Answers the question a daily total can't: "what actually ran up the
/// bill?" Always ranked by cost, descending.
struct TopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top",
        abstract: "The most expensive sessions or days in the period.",
        discussion: "Rank with --by sessions (default) or days; --limit sets how many (default 10)."
    )

    @OptionGroup var options: CLIGlobalOptions
    @Option(name: .long, help: "What to rank: sessions or days.")
    var by: TopDimension = .sessions
    @Option(name: .long, help: "How many to show.")
    var limit = 10

    func validate() throws {
        if limit < 0 { throw ValidationError("--limit must be 0 or greater.") }
    }

    func run() throws {
        let range = try options.resolveRange()

        let engine = try CLIEngine.open(provider: options.provider, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }

        let periodCost = try engine.store.totalCostUSD(from: range.from, to: range.to)
        let rows: [CLITopReport.Row]
        let totalCount: Int
        switch by {
        case .sessions:
            rows = try engine.store.topSessionCosts(from: range.from, to: range.to, limit: limit)
                .map { CLITopReport.Row(key: $0.sessionId, project: $0.projectPath, title: $0.title, costUSD: $0.costUSD, requests: $0.requestCount) }
            // Count the same population the rows come from (visible, non-superseded),
            // not requestActivityCounts (which counts every session with activity,
            // incl. re-homed replay shells) — otherwise "top N of M" inflates M.
            totalCount = try engine.store.visibleSessionCount(from: range.from, to: range.to)
        case .days:
            let buckets = try engine.store.usageBuckets(hourly: false, from: range.from, to: range.to)
            rows = CLITopReport.topDays(buckets, limit: limit)
            totalCount = buckets.count
        }

        let report = CLITopReport(
            provider: options.provider, periodLabel: options.periodLabel,
            dimension: by, rows: rows, totalCount: totalCount, periodCostUSD: periodCost
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

enum TopDimension: String, CaseIterable, ExpressibleByArgument {
    case sessions, days
    static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

/// Data + rendering for `lupen top`.
struct CLITopReport {
    struct Row: Equatable {
        let key: String          // session id, or YYYY-MM-DD for days
        let project: String?     // sessions only
        let title: String?       // sessions only
        let costUSD: Double
        let requests: Int
    }

    let provider: ProviderKind
    let periodLabel: String
    let dimension: TopDimension
    let rows: [Row]
    /// All sessions/days in the period (pre-limit), so the footer can anchor
    /// the shown top-N against the whole period.
    let totalCount: Int
    let periodCostUSD: Double

    /// Top-cost days from per-day buckets (pure: sort by cost desc, take N).
    static func topDays(_ buckets: [StoreUsageBucket], limit: Int) -> [Row] {
        let ranked = buckets.sorted {
            $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.bucketKey < $1.bucketKey
        }
        return Array(ranked.prefix(max(0, limit)))
            .map { Row(key: $0.bucketKey, project: nil, title: nil, costUSD: $0.costUSD, requests: $0.requestCount) }
    }

    /// Short session id for display. The full id stays in `--json`/`--csv`
    /// for scripting.
    static func shortID(_ id: String) -> String {
        id.count > 8 ? String(id.prefix(8)) : id
    }

    static func truncate(_ value: String, _ max: Int) -> String {
        value.count > max ? String(value.prefix(max - 1)) + "…" : value
    }

    // MARK: - Rendering

    func printTable(color: Bool) {
        guard !rows.isEmpty else {
            CLIOutput.line("No usage for \(periodLabel).")
            return
        }
        CLIOutput.line("\(provider.cliLabel) · \(periodLabel)")
        CLIOutput.line()

        let table: CLITable
        switch dimension {
        case .sessions:
            table = CLITable(
                columns: [
                    .init("#", align: .right),
                    .init("COST", align: .right),
                    .init("REQ", align: .right),
                    .init("SESSION"),
                    .init("TITLE"),
                ],
                rows: rows.enumerated().map { index, row in
                    [
                        String(index + 1),
                        CLIFormat.money(row.costUSD),
                        CLIFormat.int(row.requests),
                        Self.shortID(row.key),
                        row.title.map { Self.truncate($0, 60) } ?? "—",
                    ]
                }
            )
        case .days:
            table = CLITable(
                columns: [
                    .init("#", align: .right),
                    .init("DAY"),
                    .init("COST", align: .right),
                    .init("REQ", align: .right),
                ],
                rows: rows.enumerated().map { index, row in
                    [String(index + 1), row.key, CLIFormat.money(row.costUSD), CLIFormat.int(row.requests)]
                }
            )
        }
        CLIOutput.line(table.render(color: color))
        CLIOutput.line()
        CLIOutput.line(totalLine)
    }

    var totalLine: String {
        let noun = dimension == .sessions ? "session" : "day"
        let cost = CLIFormat.money(periodCostUSD)
        if rows.count < totalCount {
            return "TOTAL  top \(rows.count) of \(totalCount) \(noun)s · \(cost) period total"
        }
        return "TOTAL  \(totalCount) \(noun)(s) · \(cost) period total"
    }

    var jsonArray: [[String: Any]] {
        rows.map { row in
            switch dimension {
            case .sessions:
                return [
                    "sessionId": row.key,
                    "project": row.project as Any? ?? NSNull(),
                    "title": row.title as Any? ?? NSNull(),
                    "costUsd": row.costUSD,
                    "requests": row.requests,
                ]
            case .days:
                return ["day": row.key, "costUsd": row.costUSD, "requests": row.requests]
            }
        }
    }

    var csv: String {
        switch dimension {
        case .sessions:
            return CLICSV.render(
                header: ["sessionId", "project", "title", "costUsd", "requests"],
                rows: rows.map { [$0.key, $0.project ?? "", $0.title ?? "", String(format: "%.6f", $0.costUSD), String($0.requests)] }
            )
        case .days:
            return CLICSV.render(
                header: ["day", "costUsd", "requests"],
                rows: rows.map { [$0.key, String(format: "%.6f", $0.costUSD), String($0.requests)] }
            )
        }
    }
}
