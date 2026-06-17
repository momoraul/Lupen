import Foundation

/// Time-dimension rollup for the Reports Overview chart.
///
/// Aggregation rules:
///   - `sessionCount`: keyed by session `startTime` — sessions that cross
///     midnight count toward their start day, matching the user's "session
///     I created today" mental model.
///   - `turnCount`: keyed by each Turn's `startTime`, so long-running
///     sessions distribute turns across days.
///   - `costUSD`: keyed by request `timestamp` so mid-session model
///     changes attribute correctly. `PricingTable.isSyntheticModel` is
///     excluded.
///   - `requestCount`: billable requests by timestamp.
///   - `avgCostPerSession`: nil when sessionCount is 0 — charts skip the
///     point to leave a gap, since wedging it to 0 reads as a "cheap day".
///
/// Zero-fill emits a contiguous bucket sequence so the chart renders
/// without breaks. Pure function — safe to call from `ReportsView.body`
/// on every recompute.
enum UsageTimelineAnalyzer {

    /// Bucket granularity. `.day` keeps the original "one bar per local
    /// calendar day" behaviour (multi-day ranges, Reports overview for
    /// weeks/months). `.hour` bucketizes every hour inside the range —
    /// used by "Today" in Reports so the user sees an intraday
    /// distribution (00:00–23:00 local) rather than a single bar.
    enum Granularity: Sendable, Equatable {
        case day
        case hour
    }

    struct DailyUsageBucket: Sendable, Equatable, Identifiable {
        /// Start-of-period in local time. For `.day` granularity this is
        /// local midnight (backward-compatible with the original
        /// interpretation). For `.hour` granularity this is the hour
        /// start (HH:00:00 local). Kept as `day:` for backward compat
        /// with existing call sites; callers that need to distinguish
        /// granularity track it alongside the bucket array.
        let day: Date
        let costUSD: Double
        let sessionCount: Int
        let turnCount: Int
        let requestCount: Int
        /// Sum of `totalContextTokens` across billable requests bucketed
        /// into this period. Matches the "Total Context" metric in the
        /// Detail pane so the two surfaces speak the same language: a
        /// single number that aggregates input + output + cache-create
        /// + cache-read. Charting this (rather than `effectiveTokens`
        /// alone) surfaces the *actual* data volume Claude moved,
        /// which is what tracks cost under cache-heavy workflows.
        let tokenCount: Int

        /// nil when sessionCount is 0 so the chart drops the point.
        var avgCostPerSession: Double? {
            sessionCount > 0 ? costUSD / Double(sessionCount) : nil
        }

        /// nil for zero-token buckets. Tracks how $/token shifts on
        /// cache-read heavy days — high cache hit rate drives it down.
        var avgCostPerToken: Double? {
            tokenCount > 0 ? costUSD / Double(tokenCount) : nil
        }

        var id: Date { day }
    }

    /// Inclusive on both ends. `.day` granularity normalises to local
    /// midnight, `.hour` normalises to hour-start — so callers may pass
    /// the current time as `to` and it will floor to the hour.
    struct DayRange: Sendable, Equatable {
        let from: Date
        let to: Date
    }

    /// Primary entry point.
    ///
    /// - Parameters:
    ///   - sessions: callers pass the full `store.sessions`; no session-
    ///     level date filter is applied because request-level bucketing
    ///     produces the exact figures regardless.
    ///   - turnsBySession: turns for those sessions.
    ///   - costsByRequestId: cost map from the store.
    ///   - range: zero-fill range. nil infers from observed min/max
    ///     (returns empty when there is no data). When supplied, request /
    ///     turn / session aggregation is clamped to this range so the
    ///     Reports per-request aggregator and the Overview chart agree on
    ///     the same numbers.
    ///   - calendar: calendar used for day classification.
    static func aggregate(
        sessions: [Session],
        turnsBySession: [String: [Turn]],
        costsByRequestId: [String: CostBreakdown?],
        range: DayRange? = nil,
        granularity: Granularity = .day,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [DailyUsageBucket] {

        // --- 1. Accumulate per bucket (day or hour) ---
        var costByBucket: [Date: Double] = [:]
        var sessionsByBucket: [Date: Int] = [:]
        var turnsByBucket: [Date: Int] = [:]
        var requestsByBucket: [Date: Int] = [:]
        var tokensByBucket: [Date: Int] = [:]

        var observedMin: Date? = nil
        var observedMax: Date? = nil

        // Normalise a timestamp to its bucket start — the hash key for
        // every accumulator above. For hour granularity we cannot use
        // `Date(timeIntervalSinceReferenceDate: floor(t / 3600) * 3600)`
        // because calendar.date(byAdding: .hour, …) respects DST
        // transitions; a naive floor would land mid-hour on the fall-back
        // day. Let the calendar decide.
        let bucketStart: (Date) -> Date = { ts in
            switch granularity {
            case .day:
                return calendar.startOfDay(for: ts)
            case .hour:
                return calendar.dateInterval(of: .hour, for: ts)?.start
                    ?? calendar.startOfDay(for: ts)
            }
        }

        // Pre-compute range bounds so every per-entry check is a cheap
        // Date comparison instead of a fresh startOf* call.
        let rangeLo: Date? = range.map { bucketStart($0.from) }
        let rangeHi: Date? = range.map { bucketStart($0.to) }
        let inRange: (Date) -> Bool = { bucket in
            if let lo = rangeLo, bucket < lo { return false }
            if let hi = rangeHi, bucket > hi { return false }
            return true
        }

        for session in sessions {
            if let start = session.startTime {
                let sessionBucket = bucketStart(start)
                if inRange(sessionBucket) {
                    sessionsByBucket[sessionBucket, default: 0] += 1
                    observedMin = observedMin.map { min($0, sessionBucket) } ?? sessionBucket
                    observedMax = observedMax.map { max($0, sessionBucket) } ?? sessionBucket
                }
            }

            for request in session.requests {
                guard let model = request.model,
                      !PricingTable.isSyntheticModel(model)
                else { continue }
                let rbucket = bucketStart(request.timestamp)
                guard inRange(rbucket) else { continue }
                requestsByBucket[rbucket, default: 0] += 1
                tokensByBucket[rbucket, default: 0] += request.tokens.totalContextTokens
                observedMin = observedMin.map { min($0, rbucket) } ?? rbucket
                observedMax = observedMax.map { max($0, rbucket) } ?? rbucket
                if case .some(.some(let c)) = costsByRequestId[request.id] {
                    costByBucket[rbucket, default: 0] += c.totalCostUSD
                }
            }
        }

        // Turns by each turn's own startTime.
        for (_, turns) in turnsBySession {
            for turn in turns {
                guard let start = turn.startTime else { continue }
                let b = bucketStart(start)
                guard inRange(b) else { continue }
                turnsByBucket[b, default: 0] += 1
                observedMin = observedMin.map { min($0, b) } ?? b
                observedMax = observedMax.map { max($0, b) } ?? b
            }
        }

        // --- 2. Determine zero-fill range ---
        let effectiveFrom: Date
        let effectiveTo: Date
        if let r = range {
            effectiveFrom = bucketStart(r.from)
            effectiveTo = bucketStart(r.to)
        } else {
            guard let lo = observedMin, let hi = observedMax else {
                return []
            }
            effectiveFrom = lo
            effectiveTo = hi
        }

        guard effectiveFrom <= effectiveTo else { return [] }

        // --- 3. Emit continuous bucket sequence ---
        var buckets: [DailyUsageBucket] = []
        var cursor = effectiveFrom
        // Safety cap — defend against pathological calendar math.
        // Day mode: ~10 years. Hour mode: ~93 days (31 days × 24h is the
        // typical "Last 30 days" upper bound; padded to absorb DST).
        let maxIterations = (granularity == .day) ? 3_650 : 24 * 93
        let stepComponent: Calendar.Component = (granularity == .day) ? .day : .hour
        var iterations = 0
        while cursor <= effectiveTo, iterations < maxIterations {
            buckets.append(DailyUsageBucket(
                day: cursor,
                costUSD: costByBucket[cursor] ?? 0,
                sessionCount: sessionsByBucket[cursor] ?? 0,
                turnCount: turnsByBucket[cursor] ?? 0,
                requestCount: requestsByBucket[cursor] ?? 0,
                tokenCount: tokensByBucket[cursor] ?? 0
            ))
            guard let next = calendar.date(byAdding: stepComponent, value: 1, to: cursor) else {
                break
            }
            cursor = next
            iterations += 1
        }
        return buckets
    }
}
