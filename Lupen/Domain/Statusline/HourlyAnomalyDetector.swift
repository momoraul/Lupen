import Foundation

/// Surfaces "this hour-of-day drains my limit faster (or slower) than my
/// own baseline" callouts so the user doesn't have to eyeball the
/// 24-cell heat-strip to spot the pattern. Operates on the already-
/// shrunk `meanRatio` from `HourlyEfficiencyAggregator` so single-pair
/// outliers don't trigger false positives.
///
/// **Baseline** = median of all under-sampled-bucket-eligible hourly
/// shrunk ratios.
///
/// **Trigger** = bucket's shrunkRatio is `≥ highMultiplier` × baseline
/// (high anomaly) or `≤ lowMultiplier` × baseline (low anomaly).
///
/// Adjacent hours that share the same direction are grouped into a
/// single callout — e.g. "14:00–17:00 drains 1.7× faster than your
/// baseline". An hour with `sampleCount < minSampleCount` is excluded
/// from both baseline AND trigger evaluation.
enum HourlyAnomalyDetector {

    struct Callout: Sendable, Equatable {
        let direction: Direction
        let startHour: Int
        let endHour: Int   // inclusive
        let multiplier: Double  // shrunkRatio / baseline averaged across the group

        enum Direction: Sendable, Equatable {
            case high  // hour drains *faster* — TIGHT (1% buys less)
            case low   // hour drains *slower* — LENIENT (1% buys more)
        }

        /// Human-readable line in the user's mental model: "1% of limit
        /// buys you `multiplier`× what it usually does this hour".
        /// `.high` direction = tight hour (multiplier < 1 in $/% terms);
        /// `.low` direction = lenient hour (multiplier > 1 in $/% terms).
        /// We invert the raw multiplier here so the displayed number is
        /// always "$ value relative to baseline" — easier to reason
        /// about than a consumption ratio.
        var localizedSummary: String {
            let range: String
            if startHour == endHour {
                range = String(format: "%02d:00–%02d:59", startHour, startHour)
            } else {
                range = String(format: "%02d:00–%02d:59", startHour, endHour)
            }
            // Inverted multiplier — "1% buys X× of your usual work this hour".
            let invMultiplier = multiplier > 0 ? 1.0 / multiplier : 0
            switch direction {
            case .high:
                // Tight: 1% buys less than usual.
                return String(format: "%@ — tight: 1%% buys only %.1f× usual work",
                              range, invMultiplier)
            case .low:
                // Lenient: 1% buys more than usual.
                return String(format: "%@ — lenient: 1%% buys %.1f× usual work",
                              range, invMultiplier)
            }
        }
    }

    static let highMultiplier: Double = 1.5
    static let lowMultiplier: Double = 0.6
    static let minSampleCount: Int = 5

    static func detect(
        buckets: [HourlyEfficiencyAggregator.HourlyBucket]
    ) -> [Callout] {
        // Baseline = median of buckets with sufficient samples.
        let qualifying = buckets.filter { $0.sampleCount >= minSampleCount }
        guard qualifying.count >= 3 else { return [] }
        let sortedRatios = qualifying.map { $0.shrunkRatio }.sorted()
        let baseline = sortedRatios[sortedRatios.count / 2]
        if baseline <= 0 { return [] }

        // Walk hour 0..23, tag each as high / low / neutral.
        enum Tag { case high, low, none }
        var tags: [Tag] = Array(repeating: .none, count: 24)
        for bucket in buckets where bucket.sampleCount >= minSampleCount {
            let ratio = bucket.shrunkRatio / baseline
            if ratio >= highMultiplier {
                tags[bucket.hour] = .high
            } else if ratio <= lowMultiplier {
                tags[bucket.hour] = .low
            }
        }

        // Coalesce consecutive runs of the same tag.
        var callouts: [Callout] = []
        var idx = 0
        while idx < 24 {
            let tag = tags[idx]
            if tag == .none {
                idx += 1
                continue
            }
            var end = idx
            while end + 1 < 24, tags[end + 1] == tag {
                end += 1
            }
            // Group multiplier = avg of (shrunkRatio/baseline) across the run.
            let runRatios: [Double] = (idx...end).compactMap { hour in
                buckets.first { $0.hour == hour }?.shrunkRatio
            }
            let avgRatio = runRatios.isEmpty
                ? 0
                : runRatios.reduce(0, +) / Double(runRatios.count)
            let mult = baseline > 0 ? avgRatio / baseline : 0
            callouts.append(Callout(
                direction: tag == .high ? .high : .low,
                startHour: idx,
                endHour: end,
                multiplier: mult
            ))
            idx = end + 1
        }
        return callouts
    }
}
