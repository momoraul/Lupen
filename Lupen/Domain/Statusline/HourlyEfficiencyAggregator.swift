import Foundation

/// Aggregates `RateLimitSample` history + JSONL request costs into 24
/// hour-of-day buckets, each carrying the **average rate of 5-hour-limit
/// percent points consumed per dollar spent** during that hour.
///
/// The math is: for each consecutive sample pair `(t₁, t₂)`,
///
///     Δlimit = used_percentage(t₂) − used_percentage(t₁)
///     Δcost  = Σ cost of request entries with t₁ ≤ ts < t₂
///     R      = Δlimit / Δcost   // %limit per $
///
/// Each `R` is bucketed by `hour(t₂)` in the configured time zone — the
/// hour of day the user **finished** the request, which matches the
/// user's experience of "afternoon work feels expensive".
///
/// Edge cases (every one returns `nil`/skip rather than poisoning a
/// bucket):
///   * 5-hour reset between t₁ and t₂ — `used_percentage` jumps from
///     ~95 → ~0; `Δlimit` is negative.
///   * Non-monotonic decrease without a reset — small Anthropic-side
///     correction; treat as untrustworthy.
///   * `Δcost` below `minCostThreshold` — division blows up.
///   * Time gap > `maxGapHours` — usually means user closed Claude Code
///     for a long stretch; pair is no longer "this much cost moved the
///     limit by this much in this hour".
///
/// **Bayesian shrinkage.** Buckets with low sample counts pull toward
/// the global mean using `(Σ + k·μ) / (n + k)` with `k = 10`. The raw
/// stats stay available in the `HourlyBucket` for tooltips that want to
/// surface "you only have 2 samples for this hour".
///
/// Pure function — no I/O, deterministic given inputs, safe to call
/// from the main actor or off-thread.
enum HourlyEfficiencyAggregator {

    struct HourlyBucket: Sendable, Equatable {
        /// 0…23 in the configured time zone.
        let hour: Int
        /// Number of (Δlimit, Δcost) pairs that landed in this bucket.
        let sampleCount: Int
        /// Σ Δcost across the bucket's pairs. Useful as the "how much
        /// money moved through this hour" figure.
        let totalCostUSD: Double
        /// Σ Δlimit across the bucket's pairs (percentage points). Sums
        /// of resets are *excluded* — only monotonic increments.
        let totalLimitConsumed: Double

        // MARK: - Internal R-space stats (used by anomaly detector + tests)

        /// Arithmetic mean of `R = Δlimit% / Δcost$` across the
        /// bucket's pairs. Internal — UI uses display-space fields.
        let meanRatio: Double
        /// 50th percentile of `R` (linear-interpolated).
        let p50Ratio: Double
        /// 90th percentile of `R`. Used by the anomaly detector via
        /// the shrunkRatio path. **NOT** the same number as
        /// `dollarsPerPercentP10` — linear-interpolated percentiles
        /// don't commute with `1/x`, so we compute the display-space
        /// p10 directly from the inverted-ratio array.
        let p90Ratio: Double
        /// Bayesian-shrunk version of `meanRatio` toward the global
        /// **median** of R. Used by `HourlyAnomalyDetector` for
        /// tight/lenient classification.
        let shrunkRatio: Double

        // MARK: - User-facing display ($/1% limit)

        /// Dollars of work per 1% of 5h limit consumed during this
        /// hour, **as the Bayesian-shrunk mean of (1/R)** — i.e.
        /// computed directly in $-per-percent space, not derived as
        /// `1/shrunkRatio` which would carry Jensen-inequality bias.
        /// 0 when the bucket has no samples (no UX leak from the
        /// shrinkage prior).
        let dollarsPerPercentShrunk: Double
        /// Arithmetic mean of (1/R) over the bucket's pairs. The
        /// "what 1% bought on average this hour" headline number.
        let dollarsPerPercentMean: Double
        /// Median (linear-interpolated) of (1/R). Robust against
        /// single-pair outliers.
        let dollarsPerPercentP50: Double
        /// 10th percentile (linear-interpolated) of (1/R) — the
        /// "worst typical" reading: at the bottom 10% of pairs in
        /// this hour, 1% of limit bought this much work or less.
        let dollarsPerPercentP10: Double
    }

    /// Skip a Δcost that's effectively zero — division otherwise hits
    /// infinity and the rest of the bucket is poisoned. $0.001 is
    /// roughly the price of a Sonnet 4.5 hello-world response.
    static let minCostThreshold: Double = 0.001

    /// Skip a Δlimit smaller than this — defends against IEEE 754
    /// float jitter in legacy JSONL data (e.g. samples with
    /// `usedPercentage = 7.000000000000001` would otherwise produce
    /// pairs with Δlimit ≈ 1e-15 that pass the `> 0` guard but
    /// generate `1/R = infinity` downstream). Set far below any
    /// realistic sub-percent precision Anthropic could ship; new
    /// data is also rounded at extraction so this acts as a
    /// belt-and-suspenders.
    static let minLimitDelta: Double = 1e-6

    /// Skip a sample pair whose timestamps are more than this far apart
    /// — usually it means the user walked away from Claude Code, and
    /// the bucket math no longer reflects "active work".
    static let maxGapHours: Double = 4.0

    /// Bayesian shrinkage strength. Higher k = more pull toward global
    /// mean for low-N buckets. 10 is the heuristic chosen in
    /// research-statusline-settings-ux.md.
    static let shrinkageK: Double = 10.0

    /// Primary entry point.
    ///
    /// - Parameters:
    ///   - samples: All captured rate-limit samples. Order doesn't
    ///     matter — the function sorts internally.
    ///   - requestsWithCost: Flat list of `(timestamp, cost)` pairs.
    ///     Caller is expected to have filtered out synthetic models and
    ///     null-cost requests already; we just sum what's handed in.
    ///   - now: "Right now" used to anchor the rolling window. Defaults
    ///     to `Date()`; tests override.
    ///   - windowDays: Days of history to include. 14-day rolling
    ///     window matches the Reports footer convention.
    ///   - timeZone: Time zone for the hour-of-day bucket. Defaults to
    ///     the user's current local zone.
    static func aggregate(
        samples: [RateLimitSample],
        requestsWithCost: [(timestamp: Date, costUSD: Double)],
        now: Date = Date(),
        windowDays: Int = 14,
        timeZone: TimeZone = .current
    ) -> [HourlyBucket] {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let rawWindow = samples
            .filter { $0.ts >= cutoff && $0.fiveHour != nil }
            .sorted { $0.ts < $1.ts }

        // **Canonical max-watermark preprocessing**. Real sample
        // streams aren't monotonic — Claude Code sessions each cache
        // their own `rate_limits` view from their last API response,
        // so concurrent sessions push interleaving stale-vs-fresh
        // values that bounce up and down. Without preprocessing, a
        // stale-then-fresh transition (e.g. 9% → 42% within a second)
        // produces a fake +33% Δlimit that doesn't reflect real
        // consumption — it's just one session's view catching up to
        // another's. Solution: take the running max of usedPercentage
        // within each window, resetting only when `resetsAt` changes
        // (i.e., a new 5h window begins). The result is a clean
        // monotonically-non-decreasing series we can pair on.
        let inWindow: [RateLimitSample] = Self.canonicalize(rawWindow)

        guard inWindow.count >= 2 else { return emptyBuckets() }

        // Pre-sort requests by timestamp once so each pair's window
        // search is a 2-pointer scan rather than O(N) per pair.
        let sortedRequests = requestsWithCost
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }

        var ratiosByHour: [Int: [Double]] = [:]
        var costSumByHour: [Int: Double] = [:]
        var limitSumByHour: [Int: Double] = [:]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var rIdx = 0  // running cursor into sortedRequests
        for pairIdx in 1..<inWindow.count {
            let prev = inWindow[pairIdx - 1]
            let curr = inWindow[pairIdx]
            guard let prevWin = prev.fiveHour, let currWin = curr.fiveHour else { continue }

            // Skip reset boundary — Δlimit becomes meaningless.
            if currWin.usedPercentage < prevWin.usedPercentage {
                // Either an Anthropic-side correction (rare) or a
                // genuine reset. We can tell them apart by checking
                // whether `prev.fiveHour.resetsAt` is in the past
                // relative to `curr.ts`.
                if prevWin.resetsAt <= curr.ts {
                    // Window reset between samples — expected, skip.
                    continue
                }
                // Unexplained decrease — skip to be safe.
                continue
            }
            let dLimit = currWin.usedPercentage - prevWin.usedPercentage
            // No movement → no information. Don't pollute the average.
            if dLimit <= 0 { continue }

            let gapSec = curr.ts.timeIntervalSince(prev.ts)
            if gapSec <= 0 { continue }
            if gapSec > Self.maxGapHours * 3600 { continue }

            // Sum costs in (prev.ts, curr.ts]. Advance the running
            // cursor past entries strictly older than prev.ts; then
            // walk forward summing entries up to and including curr.ts.
            while rIdx < sortedRequests.count,
                  sortedRequests[rIdx].timestamp <= prev.ts {
                rIdx += 1
            }
            var dCost = 0.0
            var scan = rIdx
            while scan < sortedRequests.count,
                  sortedRequests[scan].timestamp <= curr.ts {
                dCost += sortedRequests[scan].costUSD
                scan += 1
            }
            if dCost < Self.minCostThreshold { continue }

            let r = dLimit / dCost
            let hour = calendar.component(.hour, from: curr.ts)
            ratiosByHour[hour, default: []].append(r)
            costSumByHour[hour, default: 0] += dCost
            limitSumByHour[hour, default: 0] += dLimit
        }

        // Global shrinkage targets — **median**, not arithmetic mean.
        // R is right-skewed (cache-heavy pairs produce huge R), so the
        // arithmetic mean is biased high by a few outlier pairs and
        // would pull every other bucket's shrunk value upward. Median
        // is robust against that and represents "the typical R" honestly.
        // Both R-space and (1/R)-space targets are needed because
        // shrinkage doesn't commute with 1/x (Jensen).
        let allRatios = ratiosByHour.values.flatMap { $0 }
        let allRatiosSorted = allRatios.sorted()
        let globalMedianR: Double = allRatiosSorted.isEmpty
            ? 0
            : percentile(allRatiosSorted, q: 0.5)
        let allInverseRatiosSorted = allRatios.map { 1.0 / $0 }.sorted()
        let globalMedianInv: Double = allInverseRatiosSorted.isEmpty
            ? 0
            : percentile(allInverseRatiosSorted, q: 0.5)

        var buckets: [HourlyBucket] = []
        buckets.reserveCapacity(24)
        for hour in 0..<24 {
            let ratios = ratiosByHour[hour] ?? []
            if ratios.isEmpty {
                // **Empty bucket honesty**: zero out every display
                // field. Earlier versions seeded `shrunkRatio` with
                // the global mean so the heat-strip drew faded bars
                // for hours that had no observations. The bar then
                // looked like data-at-the-baseline, which is a UX
                // lie — fixed.
                buckets.append(HourlyBucket(
                    hour: hour,
                    sampleCount: 0,
                    totalCostUSD: 0,
                    totalLimitConsumed: 0,
                    meanRatio: 0,
                    p50Ratio: 0,
                    p90Ratio: 0,
                    shrunkRatio: 0,
                    dollarsPerPercentShrunk: 0,
                    dollarsPerPercentMean: 0,
                    dollarsPerPercentP50: 0,
                    dollarsPerPercentP10: 0
                ))
                continue
            }

            // R-space stats (used by the anomaly detector + tests).
            let sortedR = ratios.sorted()
            let n = sortedR.count
            let meanR = sortedR.reduce(0, +) / Double(n)
            let p50R = percentile(sortedR, q: 0.5)
            let p90R = percentile(sortedR, q: 0.9)
            let shrunkR = (sortedR.reduce(0, +) + Self.shrinkageK * globalMedianR)
                / (Double(n) + Self.shrinkageK)

            // Display-space stats: percentiles + mean computed on the
            // already-inverted observations so they're numerically
            // honest. `1/p90(R) ≠ p10(1/R)` for empirical
            // linear-interpolated percentiles because `1/x` is convex
            // and doesn't commute with interpolation. Computing here
            // costs O(n log n) per bucket, dwarfed by everything else.
            let inverses = ratios.map { 1.0 / $0 }
            let sortedInv = inverses.sorted()
            let meanInv = inverses.reduce(0, +) / Double(n)
            let p50Inv = percentile(sortedInv, q: 0.5)
            let p10Inv = percentile(sortedInv, q: 0.1)
            let shrunkInv = (inverses.reduce(0, +) + Self.shrinkageK * globalMedianInv)
                / (Double(n) + Self.shrinkageK)

            buckets.append(HourlyBucket(
                hour: hour,
                sampleCount: n,
                totalCostUSD: costSumByHour[hour] ?? 0,
                totalLimitConsumed: limitSumByHour[hour] ?? 0,
                meanRatio: meanR,
                p50Ratio: p50R,
                p90Ratio: p90R,
                shrunkRatio: shrunkR,
                dollarsPerPercentShrunk: shrunkInv,
                dollarsPerPercentMean: meanInv,
                dollarsPerPercentP50: p50Inv,
                dollarsPerPercentP10: p10Inv
            ))
        }
        return buckets
    }

    // MARK: - Helpers

    private static func emptyBuckets() -> [HourlyBucket] {
        (0..<24).map {
            HourlyBucket(
                hour: $0,
                sampleCount: 0,
                totalCostUSD: 0,
                totalLimitConsumed: 0,
                meanRatio: 0,
                p50Ratio: 0,
                p90Ratio: 0,
                shrunkRatio: 0,
                dollarsPerPercentShrunk: 0,
                dollarsPerPercentMean: 0,
                dollarsPerPercentP50: 0,
                dollarsPerPercentP10: 0
            )
        }
    }

    /// Apply max-watermark canonicalisation **and consecutive-flat
    /// collapse** to a time-sorted sample stream. Two layers:
    ///
    /// 1. **Max-watermark within window**: replace each sample's
    ///    `usedPercentage` with the running max so multi-session
    ///    stale-view races (one session's 9% push between another's
    ///    42% pushes) don't create fake +33% Δlimit pairs. Reset on
    ///    `resetsAt` change.
    ///
    /// 2. **Collapse consecutive-equal**: after watermark masking,
    ///    long stretches of the same canonical value are collapsed to
    ///    the first occurrence. Without this, the aggregator's pair
    ///    construction would burn the entire flat run as Δ=0 skips,
    ///    then form the next-real-increase pair on a tiny tail
    ///    window — losing the cost that actually accumulated during
    ///    the flat run. Collapsing keeps the first sample at each
    ///    plateau so the next-increase pair spans the full window
    ///    of real activity, attributing all cost correctly.
    ///
    /// `nonisolated` for testability — pure transformation.
    nonisolated static func canonicalize(
        _ samples: [RateLimitSample]
    ) -> [RateLimitSample] {
        var watermarked: [RateLimitSample] = []
        watermarked.reserveCapacity(samples.count)
        var maxPercent: Double = 0
        var currentResetsAt: Date? = nil

        // Pass 1: max-watermark within window.
        for sample in samples {
            guard let win = sample.fiveHour else {
                watermarked.append(sample)
                continue
            }
            if let cw = currentResetsAt, cw != win.resetsAt {
                // Window rolled over.
                maxPercent = win.usedPercentage
            } else {
                maxPercent = max(maxPercent, win.usedPercentage)
            }
            currentResetsAt = win.resetsAt
            let canonicalWin = RateLimitSample.WindowState(
                usedPercentage: maxPercent,
                resetsAt: win.resetsAt
            )
            watermarked.append(RateLimitSample(
                ts: sample.ts,
                sessionId: sample.sessionId,
                fiveHour: canonicalWin,
                sevenDay: sample.sevenDay
            ))
        }

        // Pass 2: collapse consecutive samples whose canonical
        // five_hour state is identical (same usedPercentage AND same
        // resetsAt). Keep the first one — its timestamp marks when
        // the value first reached this level, so the next-increase
        // pair correctly attributes cost over the full plateau.
        // Tolerance comparison protects against legacy JSONL data
        // that pre-dated the extractor's snap-to-4-decimal rounding
        // (e.g. 7.0 vs 7.000000000000001 from upstream IEEE-754
        // jitter). New data is already cleaned at the source.
        var collapsed: [RateLimitSample] = []
        collapsed.reserveCapacity(watermarked.count)
        for sample in watermarked {
            if let prev = collapsed.last,
               let prevWin = prev.fiveHour,
               let curWin = sample.fiveHour,
               abs(prevWin.usedPercentage - curWin.usedPercentage) < Self.minLimitDelta,
               prevWin.resetsAt == curWin.resetsAt {
                continue
            }
            collapsed.append(sample)
        }
        return collapsed
    }

    // MARK: - Time-series aggregation

    /// One chronological hour in the time series. Unlike `HourlyBucket`
    /// which aggregates "every Tuesday at 14:00 across the window",
    /// this represents a single specific hour like
    /// "2026-04-29T15:00:00 KST".
    struct TimeSeriesBucket: Sendable, Equatable {
        /// Local-time start of this hour. The bar in the chart spans
        /// `[hourStart, hourStart + 1h)`.
        let hourStart: Date
        let sampleCount: Int
        let totalCostUSD: Double
        let totalLimitConsumed: Double
        let dollarsPerPercentShrunk: Double
        let dollarsPerPercentMean: Double
        let dollarsPerPercentP50: Double
        let dollarsPerPercentP10: Double
    }

    /// Time-series companion to `aggregate(...)`. Same pair-construction
    /// logic (canonicalize → reset detection → max-gap → percentile/
    /// shrinkage), but bucket key is each pair's chronological hour
    /// rather than its hour-of-day. Result is exactly `windowHours`
    /// buckets, sorted oldest-first, with the **last** bucket
    /// representing the hour containing `now`.
    ///
    /// Empty hours (no pairs landed in that bucket) appear as
    /// zero-everything entries — chart consumers render them as bar
    /// height 0 (invisible) so the time axis stays unbroken.
    static func aggregateTimeSeries(
        samples: [RateLimitSample],
        requestsWithCost: [(timestamp: Date, costUSD: Double)],
        now: Date = Date(),
        windowHours: Int = 168,
        timeZone: TimeZone = .current
    ) -> [TimeSeriesBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let nowHourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let cutoff = nowHourStart.addingTimeInterval(-Double(windowHours) * 3600)

        let rawWindow = samples
            .filter { $0.ts >= cutoff && $0.fiveHour != nil }
            .sorted { $0.ts < $1.ts }
        let inWindow = Self.canonicalize(rawWindow)

        // Pre-build the empty bucket sequence (so empty windows still
        // get a well-formed return, not [] which would break the
        // chart's domain inference).
        func emptyBucket(at start: Date) -> TimeSeriesBucket {
            .init(
                hourStart: start, sampleCount: 0,
                totalCostUSD: 0, totalLimitConsumed: 0,
                dollarsPerPercentShrunk: 0, dollarsPerPercentMean: 0,
                dollarsPerPercentP50: 0, dollarsPerPercentP10: 0
            )
        }
        let allHourStarts: [Date] = (0..<windowHours).map { offset in
            calendar.date(
                byAdding: .hour,
                value: -(windowHours - 1 - offset),
                to: nowHourStart
            ) ?? nowHourStart
        }

        guard inWindow.count >= 2 else {
            return allHourStarts.map { emptyBucket(at: $0) }
        }

        let sortedRequests = requestsWithCost
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }

        var ratiosByHour: [Date: [Double]] = [:]
        var costSumByHour: [Date: Double] = [:]
        var limitSumByHour: [Date: Double] = [:]

        var rIdx = 0
        for pairIdx in 1..<inWindow.count {
            let prev = inWindow[pairIdx - 1]
            let curr = inWindow[pairIdx]
            guard let prevWin = prev.fiveHour, let currWin = curr.fiveHour
            else { continue }
            // Reset / non-monotonic guards (same as hour-of-day path).
            if currWin.usedPercentage < prevWin.usedPercentage {
                if prevWin.resetsAt <= curr.ts { continue }
                continue
            }
            let dLimit = currWin.usedPercentage - prevWin.usedPercentage
            // `< minLimitDelta` rather than `<= 0` to tolerate float
            // jitter in legacy JSONL data that pre-dated the
            // SampleExtractor's snap-to-4-decimal rounding. Without
            // this, a pair like (7.0, 7.000000000000001) would have
            // dLimit ≈ 1e-15 (positive but meaningless), R ≈ 0,
            // displayed 1/R ≈ infinity → percentiles + Bayesian
            // shrinkage anchor poisoned. The threshold is well below
            // any realistic precision Anthropic could surface (0.01%
            // would still pass at 0.0001 ≫ 1e-6).
            if dLimit < Self.minLimitDelta { continue }
            let gapSec = curr.ts.timeIntervalSince(prev.ts)
            if gapSec <= 0 || gapSec > Self.maxGapHours * 3600 { continue }

            while rIdx < sortedRequests.count,
                  sortedRequests[rIdx].timestamp <= prev.ts {
                rIdx += 1
            }
            var dCost = 0.0
            var scan = rIdx
            while scan < sortedRequests.count,
                  sortedRequests[scan].timestamp <= curr.ts {
                dCost += sortedRequests[scan].costUSD
                scan += 1
            }
            if dCost < Self.minCostThreshold { continue }

            let r = dLimit / dCost
            // Bucket key: the chronological hour-start of curr.ts.
            let hourStart = calendar
                .dateInterval(of: .hour, for: curr.ts)?.start ?? curr.ts
            ratiosByHour[hourStart, default: []].append(r)
            costSumByHour[hourStart, default: 0] += dCost
            limitSumByHour[hourStart, default: 0] += dLimit
        }

        // Same shrinkage targets as hour-of-day path.
        let allRatios = ratiosByHour.values.flatMap { $0 }
        let allRatiosSorted = allRatios.sorted()
        let globalMedianR = allRatiosSorted.isEmpty
            ? 0 : percentile(allRatiosSorted, q: 0.5)
        let allInvSorted = allRatios.map { 1.0 / $0 }.sorted()
        let globalMedianInv = allInvSorted.isEmpty
            ? 0 : percentile(allInvSorted, q: 0.5)

        return allHourStarts.map { hourStart -> TimeSeriesBucket in
            let ratios = ratiosByHour[hourStart] ?? []
            if ratios.isEmpty {
                return emptyBucket(at: hourStart)
            }
            let sortedR = ratios.sorted()
            let n = sortedR.count
            let meanR = sortedR.reduce(0, +) / Double(n)
            let _p50R = percentile(sortedR, q: 0.5)
            let _p90R = percentile(sortedR, q: 0.9)
            let _shrunkR = (sortedR.reduce(0, +) + Self.shrinkageK * globalMedianR)
                / (Double(n) + Self.shrinkageK)
            // Suppress unused-variable warnings from the R-space
            // intermediates — they exist for parity with the
            // hour-of-day path; the time-series view only needs
            // display-space numbers.
            _ = (meanR, _p50R, _p90R, _shrunkR)

            let inverses = ratios.map { 1.0 / $0 }
            let sortedInv = inverses.sorted()
            let meanInv = inverses.reduce(0, +) / Double(n)
            let p50Inv = percentile(sortedInv, q: 0.5)
            let p10Inv = percentile(sortedInv, q: 0.1)
            let shrunkInv = (inverses.reduce(0, +) + Self.shrinkageK * globalMedianInv)
                / (Double(n) + Self.shrinkageK)
            return TimeSeriesBucket(
                hourStart: hourStart,
                sampleCount: n,
                totalCostUSD: costSumByHour[hourStart] ?? 0,
                totalLimitConsumed: limitSumByHour[hourStart] ?? 0,
                dollarsPerPercentShrunk: shrunkInv,
                dollarsPerPercentMean: meanInv,
                dollarsPerPercentP50: p50Inv,
                dollarsPerPercentP10: p10Inv
            )
        }
    }

    /// Linear-interpolated percentile. `sorted` must be ascending.
    static func percentile(_ sorted: [Double], q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let position = q * Double(sorted.count - 1)
        let lo = Int(position.rounded(.down))
        let hi = Int(position.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = position - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}
