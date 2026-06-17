//
//  TodayUsageProjection.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Menu-bar today usage from SQLite (plan 3.3). `isComplete` is the
/// coverage signal: false while any source touched today still awaits
/// import — the status bar shows its placeholder instead of a number
/// that is silently missing today's tail.
struct TodayUsageSnapshot: Equatable, Sendable {
    let costUSD: Double
    let contextTokens: Int
    let isComplete: Bool
}

enum TodayUsageProjection {
    static func snapshot(
        store: ProviderStore,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> TodayUsageSnapshot? {
        let startOfToday = calendar.startOfDay(for: now)
        guard let totals = try? store.usageTotals(from: startOfToday, to: nil),
              let pending = try? store.pendingSourceCount(modifiedSince: startOfToday) else {
            return nil
        }
        return TodayUsageSnapshot(
            costUSD: totals.costUSD,
            contextTokens: totals.contextTokens,
            isComplete: pending == 0
        )
    }
}

/// Steady-state hysteresis for the menu-bar today snapshot.
///
/// The raw projection's `isComplete` flips false the instant any of
/// today's sources re-enters the import queue. While Claude Code is
/// actively writing, every appended line triggers a rescan → that
/// source is briefly "pending" → the menu bar would flash its "…"
/// placeholder and snap back to the number, over and over.
///
/// Once today's total has converged once, that flicker is pure noise:
/// today's requests are append-only and de-duplicated, so the running
/// total only ever climbs toward the truth (a live append imports in
/// well under a second). This latch remembers the day a complete
/// snapshot was last seen and, from then on, presents later incomplete
/// projections as complete — the menu bar holds the (monotonic) number
/// instead of blinking. It resets on day rollover so a fresh day's
/// initial backfill can still show the placeholder until it converges.
///
/// Value type, mutated only from the driver's main-actor refresh path.
struct TodayUsageLatch {
    private(set) var convergedDay: Date?

    mutating func resolve(
        _ snapshot: TodayUsageSnapshot?,
        startOfToday: Date
    ) -> TodayUsageSnapshot? {
        guard let snapshot else { return nil }
        // Day rollover: last convergence belongs to a previous day.
        if convergedDay != startOfToday { convergedDay = nil }
        if snapshot.isComplete {
            convergedDay = startOfToday
            return snapshot
        }
        // Already converged today — a live append is folding in. Keep the
        // number up rather than reverting to the placeholder.
        if convergedDay == startOfToday {
            return TodayUsageSnapshot(
                costUSD: snapshot.costUSD,
                contextTokens: snapshot.contextTokens,
                isComplete: true
            )
        }
        // Initial backfill, not yet converged — placeholder is correct.
        return snapshot
    }
}
