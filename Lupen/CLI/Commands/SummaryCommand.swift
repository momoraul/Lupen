import ArgumentParser
import Foundation

/// `lupen summary` (the default subcommand) — whole-period totals for the
/// selected provider: cost, sessions, turns, requests, and a token
/// breakdown.
struct SummaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary",
        abstract: "Show cost and usage totals for the selected period."
    )

    @OptionGroup var options: CLIGlobalOptions

    func run() throws {
        let range = try options.resolveRange()
        let engine = try CLIEngine.open(provider: options.provider, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }

        let totals = try engine.store.usageTotals(from: range.from, to: range.to)
        let counts = try engine.store.requestActivityCounts(from: range.from, to: range.to)

        let report = CLISummaryReport(
            provider: options.provider,
            periodLabel: options.periodLabel,
            range: range,
            totals: totals,
            sessionCount: counts.sessionCount,
            turnCount: counts.turnCount
        )

        if options.json {
            try CLIOutput.printJSON(report.jsonObject)
        } else if options.csv {
            CLIOutput.line(report.csv)
        } else {
            report.printTable()
        }
    }
}

/// Data + rendering for `lupen summary`.
struct CLISummaryReport {
    let provider: ProviderKind
    let periodLabel: String
    let range: CLIDateRange.Resolved
    let totals: StoreUsageTotals
    let sessionCount: Int
    let turnCount: Int

    func printTable() {
        CLIOutput.line("\(provider.cliLabel) · \(periodLabel)")
        CLIOutput.line()
        CLIOutput.line("  Cost      \(CLIFormat.money(totals.costUSD))")
        CLIOutput.line("  Sessions  \(CLIFormat.int(sessionCount))")
        CLIOutput.line("  Turns     \(CLIFormat.int(turnCount))")
        CLIOutput.line("  Requests  \(CLIFormat.int(totals.requestCount))")
        CLIOutput.line("  Tokens    \(CLIFormat.int(totals.contextTokens))")
    }

    var jsonObject: [String: Any] {
        [
            "provider": provider.rawValue,
            "period": [
                "label": periodLabel,
                "from": Self.iso(range.from),
                "to": Self.iso(range.to),
            ],
            "costUsd": totals.costUSD,
            "sessions": sessionCount,
            "turns": turnCount,
            "requests": totals.requestCount,
            "tokens": [
                "input": totals.inputTokens,
                "output": totals.outputTokens,
                "reasoning": totals.reasoningOutputTokens,
                "cacheCreation": totals.cacheCreationInputTokens,
                "cacheRead": totals.cacheReadInputTokens,
                "context": totals.contextTokens,
            ],
        ]
    }

    /// ISO-8601 (UTC) string for a bound, or JSON `null` when unbounded.
    private static func iso(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return ISO8601DateFormatter().string(from: date)
    }

    /// Key/value CSV (a single report, so one metric per row).
    var csv: String {
        CLICSV.render(
            header: ["metric", "value"],
            rows: [
                ["provider", provider.rawValue],
                ["period", periodLabel],
                ["costUsd", String(format: "%.6f", totals.costUSD)],
                ["sessions", String(sessionCount)],
                ["turns", String(turnCount)],
                ["requests", String(totals.requestCount)],
                ["inputTokens", String(totals.inputTokens)],
                ["outputTokens", String(totals.outputTokens)],
                ["reasoningTokens", String(totals.reasoningOutputTokens)],
                ["cacheCreationTokens", String(totals.cacheCreationInputTokens)],
                ["cacheReadTokens", String(totals.cacheReadInputTokens)],
                ["contextTokens", String(totals.contextTokens)],
            ]
        )
    }
}
