import ArgumentParser
import Foundation

/// `lupen skills` — per-skill usage over the period: how many times each
/// skill ran, what it cost, the average per run, and the model it leans on.
/// Lupen's signature view; ccusage/tokscale don't break cost down by skill.
struct SkillsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skills",
        abstract: "Per-skill usage: invocations, cost, $/run, and top model.",
        discussion: "Sort with --sort cost (default), count, or name."
    )

    @OptionGroup var options: CLIGlobalOptions
    @OptionGroup var rowOptions: CLIRowOptions

    func run() throws {
        let range = try options.resolveRange()
        let sort = try SkillSort.parse(rowOptions.sort, default: .cost)

        let engine = try CLIEngine.open(provider: options.provider, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }

        let aggregates = try engine.store.skillAggregates(from: range.from, to: range.to)
        let modelCosts = try engine.store.skillModelCosts(from: range.from, to: range.to)
        let rows = CLISkillsReport.build(
            aggregates: aggregates, modelCosts: modelCosts, sort: sort, limit: rowOptions.limit
        )
        let report = CLISkillsReport(
            provider: options.provider,
            periodLabel: options.periodLabel,
            rows: rows,
            totalSkills: aggregates.count,
            totalRuns: aggregates.reduce(0) { $0 + $1.invocationCount },
            totalCostUSD: aggregates.reduce(0) { $0 + $1.costUSD }
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

enum SkillSort: String {
    case cost, count, name

    static func parse(_ raw: String?, default fallback: SkillSort) throws -> SkillSort {
        guard let raw else { return fallback }
        guard let sort = SkillSort(rawValue: raw.lowercased()) else {
            throw ValidationError("Invalid --sort '\(raw)'. Use cost, count, or name.")
        }
        return sort
    }
}

/// Data + rendering for `lupen skills`.
struct CLISkillsReport {
    struct Row: Equatable {
        let skill: String
        let runs: Int
        let costUSD: Double
        let topModel: String?

        var avgCostUSD: Double { runs > 0 ? costUSD / Double(runs) : 0 }
    }

    let provider: ProviderKind
    let periodLabel: String
    /// Rows actually shown (after --limit).
    let rows: [Row]
    /// Totals over ALL skills in the period (pre-limit), so the TOTAL line
    /// reflects the period rather than a truncated top-N.
    let totalSkills: Int
    let totalRuns: Int
    let totalCostUSD: Double

    /// Pure assembly: join aggregates with each skill's top model, sort
    /// deterministically, and apply the row limit. Kept testable (no store).
    static func build(
        aggregates: [StoreSkillAggregate],
        modelCosts: [StoreGroupedModelCost],
        sort: SkillSort,
        limit: Int?
    ) -> [Row] {
        let topModel = topModelBySkill(modelCosts)
        var rows = aggregates.map { aggregate in
            Row(
                skill: aggregate.skillName,
                runs: aggregate.invocationCount,
                costUSD: aggregate.costUSD,
                topModel: topModel[aggregate.skillName]
            )
        }
        // Skill name is the unique secondary key, so equal cost/count rows
        // (and the underlying SQL order, which has no tie-break) stay
        // reproducible across runs.
        switch sort {
        case .cost:
            rows.sort { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.skill < $1.skill }
        case .count:
            rows.sort { $0.runs != $1.runs ? $0.runs > $1.runs : $0.skill < $1.skill }
        case .name:
            rows.sort { $0.skill < $1.skill }
        }
        if let limit, limit >= 0, rows.count > limit {
            rows = Array(rows.prefix(limit))
        }
        return rows
    }

    /// The highest-cost model for each skill. Ties break on the
    /// lexicographically smaller model name so the pick is deterministic
    /// regardless of the (unordered) SQL row order.
    static func topModelBySkill(_ modelCosts: [StoreGroupedModelCost]) -> [String: String] {
        var best: [String: (model: String, cost: Double)] = [:]
        for entry in modelCosts {
            if let current = best[entry.groupKey] {
                if current.cost > entry.costUSD { continue }
                if current.cost == entry.costUSD, current.model <= entry.model { continue }
            }
            best[entry.groupKey] = (entry.model, entry.costUSD)
        }
        return best.mapValues(\.model)
    }

    // MARK: - Rendering

    func printTable(color: Bool) {
        guard !rows.isEmpty else {
            CLIOutput.line("No skill usage for \(periodLabel).")
            return
        }
        CLIOutput.line("\(provider.cliLabel) · \(periodLabel)")
        CLIOutput.line()

        let table = CLITable(
            columns: [
                .init("SKILL"),
                .init("RUNS", align: .right),
                .init("COST", align: .right),
                .init("$/RUN", align: .right),
                .init("TOP MODEL"),
            ],
            rows: rows.map { row in
                [
                    row.skill,
                    CLIFormat.int(row.runs),
                    CLIFormat.money(row.costUSD),
                    CLIFormat.money(row.avgCostUSD),
                    row.topModel ?? "—",
                ]
            }
        )
        CLIOutput.line(table.render(color: color))
        CLIOutput.line()
        CLIOutput.line(totalLine)
    }

    /// TOTAL reflects ALL skills in the period; flags when the table shows
    /// only a top-N subset so the total doesn't read as the shown rows' sum.
    var totalLine: String {
        let runs = CLIFormat.int(totalRuns)
        let cost = CLIFormat.money(totalCostUSD)
        if rows.count < totalSkills {
            return "TOTAL  top \(rows.count) of \(totalSkills) skills · \(runs) run(s) · \(cost)"
        }
        return "TOTAL  \(totalSkills) skill(s) · \(runs) run(s) · \(cost)"
    }

    var jsonArray: [[String: Any]] {
        rows.map { row in
            [
                "skill": row.skill,
                "runs": row.runs,
                "costUsd": row.costUSD,
                "avgCostUsd": row.avgCostUSD,
                "topModel": row.topModel as Any? ?? NSNull(),
            ]
        }
    }

    var csv: String {
        CLICSV.render(
            header: ["skill", "runs", "costUsd", "avgCostUsd", "topModel"],
            rows: rows.map { row in
                [
                    row.skill,
                    String(row.runs),
                    String(format: "%.6f", row.costUSD),
                    String(format: "%.6f", row.avgCostUSD),
                    row.topModel ?? "",
                ]
            }
        )
    }
}
