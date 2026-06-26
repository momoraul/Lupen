import ArgumentParser
import Foundation

/// `lupen budget --over <usd>` — exit 4 when spend over the period exceeds
/// a threshold. A CI / cron / pre-commit guard ("fail if this week cost
/// more than $20").
struct BudgetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "budget",
        abstract: "Exit 4 when spend exceeds a threshold (a CI / cron guard).",
        discussion: "Scope with --last/--month/--since/--until; default is all time. Exit 0 = within, 4 = over."
    )

    @OptionGroup var options: CLIGlobalOptions
    @Option(name: .long, help: "Budget in USD. Spend above this exits 4.")
    var over: Double

    func validate() throws {
        // Reject nan/inf: `nan < 0` is false and `cost > nan` is always
        // false, so a non-finite threshold would make the gate never trip.
        guard over.isFinite else { throw ValidationError("--over must be a finite number.") }
        if over < 0 { throw ValidationError("--over must be 0 or greater.") }
    }

    func run() throws {
        let range = try options.resolveRange()
        let engine = try CLIEngine.open(source: options.resolvedSource, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }

        let report = CLIBudgetReport(
            provider: options.provider, periodLabel: options.periodLabel,
            costUSD: try engine.store.totalCostUSD(from: range.from, to: range.to),
            budgetUSD: over
        )
        if options.json {
            try CLIOutput.printJSON(report.jsonObject)
        } else if options.csv {
            CLIOutput.line(report.csv)
        } else {
            CLIOutput.line(report.line)
        }
        if report.isOver { throw ExitCode(4) }
    }
}

struct CLIBudgetReport {
    let provider: ProviderKind
    let periodLabel: String
    let costUSD: Double
    let budgetUSD: Double

    var isOver: Bool { costUSD > budgetUSD }

    var line: String {
        let status = isOver ? "OVER budget" : "within budget"
        return "\(provider.cliLabel) · \(periodLabel): \(CLIFormat.money(costUSD)) of \(CLIFormat.money(budgetUSD)) — \(status)"
    }

    var jsonObject: [String: Any] {
        [
            "provider": provider.rawValue,
            "period": periodLabel,
            "costUsd": costUSD,
            "budgetUsd": budgetUSD,
            "overBudget": isOver,
        ]
    }

    var csv: String {
        CLICSV.render(
            header: ["provider", "period", "costUsd", "budgetUsd", "overBudget"],
            rows: [[provider.rawValue, periodLabel, String(format: "%.6f", costUSD), String(format: "%.6f", budgetUSD), String(isOver)]]
        )
    }
}

/// `lupen statusline` — a single compact spend figure for a shell prompt,
/// tmux, or a Claude Code `statusLine.command`. Defaults to today's spend
/// and never refreshes (it must be instant on every prompt render). This is
/// NOT the internal `--statusline-tap` helper (which samples rate limits).
struct StatuslineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statusline",
        abstract: "A compact one-line spend figure for a shell prompt / statusline."
    )

    @OptionGroup var options: CLIGlobalOptions

    func run() throws {
        let range = try CLIStatusline.range(
            last: options.last, month: options.month, since: options.since, until: options.until,
            now: Date(), calendar: .current
        )
        // Never refresh: a statusline runs on every prompt render and must
        // not block importing logs. (Opening the index may create it on a
        // first run, or rebuild it after an app-version schema bump, but it
        // never imports.) Stay silent — no freshness note — so a bare
        // `$(lupen statusline)` capture is a single clean token.
        let engine = try CLIEngine.open(source: options.resolvedSource, refresh: false)
        let cost = try engine.store.totalCostUSD(from: range.from, to: range.to)

        if options.json {
            try CLIOutput.printJSON(["provider": options.provider.rawValue, "costUsd": cost])
        } else if options.csv {
            CLIOutput.line(CLICSV.render(header: ["costUsd"], rows: [[String(format: "%.6f", cost)]]))
        } else {
            CLIOutput.line(CLIFormat.money(cost))
        }
    }
}

enum CLIStatusline {
    /// Period for the statusline: today (start of day → now) when no period
    /// flag is given, otherwise the resolved window.
    static func range(
        last: String?, month: String?, since: String?, until: String?,
        now: Date, calendar: Calendar
    ) throws -> CLIDateRange.Resolved {
        if last == nil, month == nil, since == nil, until == nil {
            return CLIDateRange.Resolved(from: calendar.startOfDay(for: now), to: now)
        }
        return try CLIDateRange.resolve(since: since, until: until, last: last, month: month, now: now, calendar: calendar)
    }
}
