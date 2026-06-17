//
//  SQLiteReportsProjection.swift
//  Lupen
//
//  Created by jaden on 2026/06/11.
//

import Foundation

/// Reports surfaces for SQLite-first mode (plan 4.4): maps the
/// `ReportsRepository` SQL aggregates onto the EXISTING row types
/// (`CostAnalyzer.*Summary`, `UsageTimelineAnalyzer.DailyUsageBucket`)
/// so the Reports tables, sort comparators and `ReportsCSVExporter`
/// flow unchanged.
///
/// Cost shape: every Reports surface renders `totalCost.totalCostUSD`
/// only (pinned by ReportsView/ReportsCSVExporter) — per-request cost
/// splits are not stored, so rows carry a total-only breakdown.
enum SQLiteReportsProjection {

    /// SQL totals are a single number; the row types want a
    /// `CostBreakdown`. Reports surfaces never read the components.
    private static func totalOnlyCost(_ total: Double) -> CostBreakdown {
        CostBreakdown(
            inputCostUSD: total, outputCostUSD: 0,
            cacheCreate1hCostUSD: 0, cacheCreate5mCostUSD: 0,
            cacheReadCostUSD: 0
        )
    }

    private static func primaryModels(
        from rows: [StoreGroupedModelCost]
    ) -> [String: String] {
        var bestByGroup: [String: (model: String, costUSD: Double)] = [:]
        for row in rows {
            if let best = bestByGroup[row.groupKey], best.costUSD >= row.costUSD {
                continue
            }
            bestByGroup[row.groupKey] = (row.model, row.costUSD)
        }
        return bestByGroup.mapValues(\.model)
    }

    // MARK: - Projects

    static func projectSummaries(
        store: ProviderStore,
        from: Date?,
        to: Date?
    ) -> [CostAnalyzer.ProjectSummary] {
        guard let aggregates = try? store.projectAggregates(from: from, to: to) else { return [] }
        let primary = primaryModels(
            from: (try? store.projectModelCosts(from: from, to: to)) ?? []
        )
        return aggregates.map { aggregate in
            let key = aggregate.projectPath ?? ""
            let label = ProjectLabelFormatter.decode(key)
            return CostAnalyzer.ProjectSummary(
                projectKey: key,
                projectLabel: label.isEmpty ? "Unknown" : label,
                sessionCount: aggregate.sessionCount,
                totalCost: totalOnlyCost(aggregate.costUSD),
                primaryModel: primary[key]
            )
        }
        .sorted { $0.totalCost.totalCostUSD > $1.totalCost.totalCostUSD }
    }

    // MARK: - Models

    static func modelSummaries(
        store: ProviderStore,
        from: Date?,
        to: Date?
    ) -> [CostAnalyzer.ModelSummary] {
        guard let aggregates = try? store.modelUsageAggregates(from: from, to: to) else { return [] }
        return aggregates.map { aggregate in
            CostAnalyzer.ModelSummary(
                modelName: aggregate.model,
                usageCount: aggregate.usageCount,
                totalCost: totalOnlyCost(aggregate.costUSD),
                avgCostPerRequest: aggregate.usageCount > 0
                    ? aggregate.costUSD / Double(aggregate.usageCount)
                    : 0,
                fastCount: aggregate.fastCount
            )
        }
    }

    // MARK: - Skills

    static func skillSummaries(
        store: ProviderStore,
        from: Date?,
        to: Date?
    ) -> [CostAnalyzer.SkillSummary] {
        guard let aggregates = try? store.skillAggregates(from: from, to: to) else { return [] }
        let primary = primaryModels(
            from: (try? store.skillModelCosts(from: from, to: to)) ?? []
        )
        return aggregates.map { aggregate in
            CostAnalyzer.SkillSummary(
                skillName: aggregate.skillName,
                invocationCount: aggregate.invocationCount,
                totalCost: totalOnlyCost(aggregate.costUSD),
                avgCostPerInvocation: aggregate.invocationCount > 0
                    ? aggregate.costUSD / Double(aggregate.invocationCount)
                    : 0,
                primaryModel: primary[aggregate.skillName]
            )
        }
    }

    // MARK: - Timeline / hourly

    /// Local-time buckets with the legacy zero-fill contract: a supplied
    /// range fills every bucket inside it; nil infers from observed data
    /// (empty result when there is none).
    static func timelineBuckets(
        store: ProviderStore,
        granularity: UsageTimelineAnalyzer.Granularity,
        range: UsageTimelineAnalyzer.DayRange?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [UsageTimelineAnalyzer.DailyUsageBucket] {
        let hourly = granularity == .hour
        let from = range?.from
        let to = range?.to

        guard let usage = try? store.usageBuckets(hourly: hourly, from: from, to: to)
        else { return [] }
        let sessions = (try? store.sessionStartCounts(hourly: hourly, from: from, to: to)) ?? []
        let turns = (try? store.turnStartCounts(hourly: hourly, from: from, to: to)) ?? []

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = hourly ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"

        var usageByDate: [Date: StoreUsageBucket] = [:]
        for bucket in usage {
            if let date = formatter.date(from: bucket.bucketKey) {
                usageByDate[date] = bucket
            }
        }
        var sessionsByDate: [Date: Int] = [:]
        for count in sessions {
            if let date = formatter.date(from: count.bucketKey) {
                sessionsByDate[date] = count.count
            }
        }
        var turnsByDate: [Date: Int] = [:]
        for count in turns {
            if let date = formatter.date(from: count.bucketKey) {
                turnsByDate[date] = count.count
            }
        }

        let observed = Set(usageByDate.keys)
            .union(sessionsByDate.keys)
            .union(turnsByDate.keys)
        let lo: Date
        let hi: Date
        if let range {
            lo = bucketStart(range.from, hourly: hourly, calendar: calendar)
            hi = bucketStart(range.to, hourly: hourly, calendar: calendar)
        } else if let minDate = observed.min(), let maxDate = observed.max() {
            lo = minDate
            hi = maxDate
        } else {
            return []
        }

        var buckets: [UsageTimelineAnalyzer.DailyUsageBucket] = []
        var cursor = lo
        let stride: Calendar.Component = hourly ? .hour : .day
        while cursor <= hi {
            let usageBucket = usageByDate[cursor]
            buckets.append(UsageTimelineAnalyzer.DailyUsageBucket(
                day: cursor,
                costUSD: usageBucket?.costUSD ?? 0,
                sessionCount: sessionsByDate[cursor] ?? 0,
                turnCount: turnsByDate[cursor] ?? 0,
                requestCount: usageBucket?.requestCount ?? 0,
                tokenCount: usageBucket?.tokenCount ?? 0
            ))
            guard let next = calendar.date(byAdding: stride, value: 1, to: cursor) else { break }
            cursor = next
        }
        return buckets
    }

    private static func bucketStart(
        _ date: Date, hourly: Bool, calendar: Calendar
    ) -> Date {
        hourly
            ? (calendar.dateInterval(of: .hour, for: date)?.start ?? calendar.startOfDay(for: date))
            : calendar.startOfDay(for: date)
    }
}
