import ArgumentParser
import Foundation

// Single-dimension cost breakdowns that reuse one report type: per-model
// and per-project. Both are "labeled rows of (count, cost)".

struct ModelsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Cost and usage per model.",
        discussion: "Sort with --sort cost (default), count, or name."
    )
    @OptionGroup var options: CLIGlobalOptions
    @OptionGroup var rowOptions: CLIRowOptions

    func run() throws {
        let range = try options.resolveRange()
        let sort = try BreakdownSort.parse(rowOptions.sort, default: .cost)
        let engine = try CLIEngine.open(source: options.resolvedSource, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }

        let rows = try engine.store.modelUsageAggregates(from: range.from, to: range.to)
            .map { CLIBreakdownReport.Row(key: $0.model, count: $0.usageCount, costUSD: $0.costUSD) }
        try CLIBreakdownReport(
            provider: options.provider, periodLabel: options.periodLabel,
            keyName: "model", labelHeader: "MODEL", countHeader: "USES", countNoun: "model",
            rows: rows, sort: sort, limit: rowOptions.limit
        ).emit(options: options)
    }
}

struct ProjectsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projects",
        abstract: "Cost and session count per project.",
        discussion: "Sort with --sort cost (default), count, or name."
    )
    @OptionGroup var options: CLIGlobalOptions
    @OptionGroup var rowOptions: CLIRowOptions

    func run() throws {
        let range = try options.resolveRange()
        let sort = try BreakdownSort.parse(rowOptions.sort, default: .cost)
        let engine = try CLIEngine.open(source: options.resolvedSource, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }

        let rows = try engine.store.projectAggregates(from: range.from, to: range.to)
            .map { CLIBreakdownReport.Row(key: $0.projectPath ?? "(unknown)", count: $0.sessionCount, costUSD: $0.costUSD) }
        try CLIBreakdownReport(
            provider: options.provider, periodLabel: options.periodLabel,
            keyName: "project", labelHeader: "PROJECT", countHeader: "SESSIONS", countNoun: "project",
            rows: rows, sort: sort, limit: rowOptions.limit,
            displayTransform: ProjectLabelFormatter.decode
        ).emit(options: options)
    }
}

enum BreakdownSort: String {
    case cost, count, name

    static func parse(_ raw: String?, default fallback: BreakdownSort) throws -> BreakdownSort {
        guard let raw else { return fallback }
        guard let sort = BreakdownSort(rawValue: raw.lowercased()) else {
            throw ValidationError("Invalid --sort '\(raw)'. Use cost, count, or name.")
        }
        return sort
    }
}

/// Shared "label · count · cost" breakdown (models, projects).
struct CLIBreakdownReport {
    struct Row: Equatable {
        let key: String
        let count: Int
        let costUSD: Double
        var avgCostUSD: Double { count > 0 ? costUSD / Double(count) : 0 }
    }

    let provider: ProviderKind
    let periodLabel: String
    let keyName: String          // JSON/CSV key for the label column
    let labelHeader: String
    let countHeader: String
    let countNoun: String
    /// Table-only label prettifier (e.g. decode a munged project path). The
    /// raw key is preserved in --json/--csv for scripting.
    let displayTransform: (String) -> String

    /// Rows shown after sort + limit.
    let shownRows: [Row]
    /// All rows in the period (pre-limit) for the footer.
    let totalGroups: Int
    let totalCostUSD: Double

    init(
        provider: ProviderKind, periodLabel: String,
        keyName: String, labelHeader: String, countHeader: String, countNoun: String,
        rows: [Row], sort: BreakdownSort, limit: Int?,
        displayTransform: @escaping (String) -> String = { $0 }
    ) {
        self.provider = provider
        self.periodLabel = periodLabel
        self.keyName = keyName
        self.labelHeader = labelHeader
        self.countHeader = countHeader
        self.countNoun = countNoun
        self.displayTransform = displayTransform
        self.totalGroups = rows.count
        self.totalCostUSD = rows.reduce(0) { $0 + $1.costUSD }
        self.shownRows = CLIBreakdownReport.sortedLimited(rows, sort: sort, limit: limit)
    }

    static func sortedLimited(_ rows: [Row], sort: BreakdownSort, limit: Int?) -> [Row] {
        var rows = rows
        switch sort {
        case .cost:  rows.sort { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.key < $1.key }
        case .count: rows.sort { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
        case .name:  rows.sort { $0.key < $1.key }
        }
        if let limit, limit >= 0, rows.count > limit {
            rows = Array(rows.prefix(limit))
        }
        return rows
    }

    func emit(options: CLIGlobalOptions) throws {
        if options.json {
            try CLIOutput.printJSON(jsonArray)
        } else if options.csv {
            CLIOutput.line(csv)
        } else {
            printTable(color: CLIStyle.useColor(disabled: options.noColor))
        }
    }

    func printTable(color: Bool) {
        guard !shownRows.isEmpty else {
            CLIOutput.line("No usage for \(periodLabel).")
            return
        }
        CLIOutput.line("\(provider.cliLabel) · \(periodLabel)")
        CLIOutput.line()

        let table = CLITable(
            columns: [
                .init(labelHeader),
                .init(countHeader, align: .right),
                .init("COST", align: .right),
                .init("$/\(countNoun.uppercased())", align: .right),
            ],
            rows: shownRows.map { [displayTransform($0.key), CLIFormat.int($0.count), CLIFormat.money($0.costUSD), CLIFormat.money($0.avgCostUSD)] }
        )
        CLIOutput.line(table.render(color: color))
        CLIOutput.line()
        let prefix = shownRows.count < totalGroups
            ? "TOTAL  top \(shownRows.count) of \(totalGroups) \(countNoun)s"
            : "TOTAL  \(totalGroups) \(countNoun)(s)"
        CLIOutput.line("\(prefix) · \(CLIFormat.money(totalCostUSD))")
    }

    var jsonArray: [[String: Any]] {
        shownRows.map { [keyName: $0.key, "count": $0.count, "costUsd": $0.costUSD, "avgCostUsd": $0.avgCostUSD] }
    }

    var csv: String {
        CLICSV.render(
            header: [keyName, "count", "costUsd", "avgCostUsd"],
            rows: shownRows.map { [$0.key, String($0.count), String(format: "%.6f", $0.costUSD), String(format: "%.6f", $0.avgCostUSD)] }
        )
    }
}
