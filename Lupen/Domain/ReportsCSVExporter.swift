import Foundation

/// Turns `CostAnalyzer` summaries into CSV strings suitable for
/// spreadsheet import. Pure string work so it can be unit-tested
/// without any AppKit or filesystem setup — the UI layer owns the
/// actual save panel and disk write.
///
/// CSV format:
///   - RFC 4180-ish: `,` separator, `\n` line terminator (not `\r\n`
///     — macOS-native apps like Numbers read either; keeping it one
///     byte per terminator simplifies test assertions).
///   - Fields containing `,`, `"`, or `\n` are wrapped in double
///     quotes with embedded quotes doubled.
///   - Numeric fields are formatted with fixed precision
///     (`%.6f` for cost, `%d` for counts) so the spreadsheet gets
///     raw values instead of the UI's magnitude-adaptive dollar
///     formatting.
///   - Missing optionals render as empty — not "nil" or "—" — so
///     downstream formulas treat them as blank.
///
/// Column order mirrors the Reports window tables so a user
/// glancing between the app and the exported CSV sees the same
/// layout.
enum ReportsCSVExporter {

    // MARK: - Public API

    static func projectsCSV(_ rows: [CostAnalyzer.ProjectSummary]) -> String {
        let header = ["Project", "Sessions", "Primary Model", "Total Cost USD"]
        let body = rows.map { row in
            [
                row.projectLabel,
                String(row.sessionCount),
                row.primaryModel ?? "",
                formatCost(row.totalCost.totalCostUSD)
            ]
        }
        return render(header: header, rows: body)
    }

    static func skillsCSV(
        _ rows: [CostAnalyzer.SkillSummary],
        provider: ProviderKind = .claudeCode
    ) -> String {
        let header = ["Skill", "Invocations", "Avg Cost USD",
                      "Primary Model", "Total Cost USD"]
        let prefix = CostAnalyzer.skillCommandPrefix(for: provider)
        let body = rows.map { row in
            [
                prefix + row.skillName,
                String(row.invocationCount),
                formatCost(row.avgCostPerInvocation),
                row.primaryModel ?? "",
                formatCost(row.totalCost.totalCostUSD)
            ]
        }
        return render(header: header, rows: body)
    }

    static func modelsCSV(_ rows: [CostAnalyzer.ModelSummary]) -> String {
        let header = ["Model", "Requests", "Fast", "Avg Cost USD",
                      "Total Cost USD"]
        let body = rows.map { row in
            [
                row.modelName,
                String(row.usageCount),
                String(row.fastCount),
                formatCost(row.avgCostPerRequest),
                formatCost(row.totalCost.totalCostUSD)
            ]
        }
        return render(header: header, rows: body)
    }

    /// Daily-bucket CSV for the Overview tab. Date is fixed
    /// `yyyy-MM-dd` in POSIX so Finder sorts chronologically and other
    /// tools parse it cleanly. A nil `avgCostPerSession` renders as an
    /// empty cell so downstream formulas treat it as "no value".
    static func timelineCSV(_ buckets: [UsageTimelineAnalyzer.DailyUsageBucket]) -> String {
        let header = ["Date", "Cost USD", "Sessions", "Turns", "Requests",
                      "Tokens", "Avg Cost per Session USD"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .autoupdatingCurrent
        let body = buckets.map { b in
            [
                formatter.string(from: b.day),
                formatCost(b.costUSD),
                String(b.sessionCount),
                String(b.turnCount),
                String(b.requestCount),
                String(b.tokenCount),
                b.avgCostPerSession.map(formatCost) ?? ""
            ]
        }
        return render(header: header, rows: body)
    }

    /// Suggest a filename like `lupen-projects-2026-04-17.csv` or
    /// `lupen-codex-projects-2026-04-17.csv` when a provider scope is
    /// supplied.
    /// Date format is fixed `yyyy-MM-dd` in the POSIX locale so the
    /// filename sorts chronologically in Finder regardless of the
    /// user's Region settings.
    static func suggestedFilename(
        tab: String,
        provider: ProviderKind? = nil,
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: now)
        let prefix = provider.map { "lupen-\(providerSlug($0))" } ?? "lupen"
        return "\(prefix)-\(tab.lowercased())-\(stamp).csv"
    }

    // MARK: - Rendering

    private static func render(header: [String], rows: [[String]]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        lines.append(header.map(escape(_:)).joined(separator: ","))
        for row in rows {
            lines.append(row.map(escape(_:)).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// RFC 4180 field escape: wrap in quotes if the field contains
    /// `,`, `"`, or a newline, and double any embedded `"`.
    static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
        guard needsQuoting else { return field }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Fixed 6-decimal cost rendering — enough to preserve sub-cent
    /// precision for per-call skill averages without scientific
    /// notation in the output.
    private static func formatCost(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func providerSlug(_ provider: ProviderKind) -> String {
        switch provider {
        case .claudeCode:
            return "claude-code"
        case .codex:
            return "codex"
        }
    }
}
