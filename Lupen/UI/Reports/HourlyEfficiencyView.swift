import SwiftUI
import Charts

/// Phase 8.8 — "Hours" tab content for the Reports window. Renders a
/// 24-cell horizontal heat-strip showing how much of the user's 5-hour
/// usage limit gets consumed per dollar spent at each hour of the day,
/// plus anomaly callouts for hours that drift more than 1.5× off the
/// user's own median baseline.
///
/// The strip uses Swift Charts' `RectangleMark` so the visual matches
/// macOS 26 native chart styling. Color encodes the shrunk ratio
/// (perceptually-uniform purple → orange ramp) and opacity encodes
/// `log(sampleCount)` so under-sampled hours visibly fade — Grafana's
/// null-cell idiom adapted to a 1-row strip.
@MainActor
struct HourlyEfficiencyView: View {

    /// Time-series buckets — one per chronological hour in the
    /// rolling window. Last bucket is the hour containing `now`.
    let buckets: [HourlyEfficiencyAggregator.TimeSeriesBucket]
    /// Anomaly callouts derived from the *hour-of-day rollup* (not
    /// the time series). They surface "this hour-of-day is tight on
    /// average" patterns regardless of when in the week.
    let anomalies: [HourlyAnomalyDetector.Callout]
    let dataSourceLine: String
    /// Timezone the buckets were computed in. Surfaced in the chart
    /// title so the user can confirm the hours match what they expect
    /// (e.g., "KST" for the user's local time).
    let timeZone: TimeZone
    /// Rolling window the data is summarised over. Used in the
    /// anomaly callout header so the line reflects the *actual*
    /// window, not a hard-coded number.
    let windowDays: Int

    /// Currently-hovered chronological hour (its `hourStart`), or nil
    /// when the cursor is outside the chart. Identifies a single
    /// `TimeSeriesBucket` for the stats card.
    @State private var selectedHourStart: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heatStrip

            if let selected = selectedHourStart,
               let bucket = buckets.first(where: { $0.hourStart == selected }) {
                statsCard(bucket: bucket)
            } else {
                hoverHint
            }

            if !anomalies.isEmpty {
                anomalyList
            }

            Spacer()

            Text(dataSourceLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Heat strip

    private var heatStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Value of 1% 5h-limit by hour of day · \(tzLabel) · last \(windowDays) days")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // Median across hours that have enough samples — drawn as
            // a dashed horizontal reference line so the user can spot
            // "above/below typical" at a glance. nil when no hour has
            // data (e.g. first launch).
            let baseline = computeBaseline()

            Chart {
                // 168 chronological hour bars (or whatever windowHours
                // resolved to). Each bucket spans [hourStart, +1h).
                // Empty hours render as zero-height (invisible) so the
                // time axis stays unbroken visually.
                ForEach(buckets, id: \.hourStart) { bucket in
                    RectangleMark(
                        xStart: .value("from", bucket.hourStart),
                        xEnd:   .value("to",   bucket.hourStart.addingTimeInterval(3600)),
                        yStart: .value("base", 0.0),
                        yEnd:   .value("$/1% limit", bucket.dollarsPerPercentShrunk)
                    )
                    .foregroundStyle(barColor(for: bucket, baseline: baseline))
                    .opacity(
                        selectedHourStart == bucket.hourStart
                            ? 1.0
                            : opacity(for: bucket.sampleCount)
                    )
                }

                if let baseline {
                    RuleMark(y: .value("median", baseline))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(String(format: "median %@", formatDollars(baseline)))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: chartDomain)
            .chartXAxis {
                // One tick per day boundary at local midnight, plus
                // a label showing month-day. Hour-level ticks would
                // be far too dense for 168 bars.
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel(format: .dateTime.month().day(),
                                   centered: true)
                        .font(.system(size: 10))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    if let value = v.as(Double.self) {
                        AxisValueLabel {
                            Text(formatDollars(value))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                }
            }
            .chartLegend(.hidden)
            .frame(height: 200)
            // Hover-driven selection (macOS HIG): the bar under the
            // cursor highlights and the stats card below updates.
            // When the cursor leaves the chart bounds the selection
            // clears. No click-to-lock — keeping the model simple.
            // Drag/double-tap was the previous gesture set; replaced
            // because tap-to-select-then-double-tap-to-deselect is
            // unusual on macOS and felt clunky to the user.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                updateSelection(from: location, proxy: proxy, geo: geo)
                            case .ended:
                                selectedHourStart = nil
                            }
                        }
                }
            }
        }
    }

    /// Domain for the time axis — covers exactly the rolling window,
    /// rounded to whole hours. Right edge is the *end* of the
    /// containing hour so the rightmost bar (the current hour) doesn't
    /// get clipped at the chart's edge.
    private var chartDomain: ClosedRange<Date> {
        let first = buckets.first?.hourStart
            ?? Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let lastEnd = (buckets.last?.hourStart
            ?? Date()).addingTimeInterval(3600)
        return first...lastEnd
    }

    /// Map a hover x-coordinate to the hourStart of the bucket the
    /// cursor is over. Snap by integer hour offset from the first
    /// bucket so hovering between bar bounds still selects the
    /// nearest covered hour.
    private func updateSelection(
        from point: CGPoint,
        proxy: ChartProxy,
        geo: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geo[plotFrame]
        let xInPlot = point.x - frame.origin.x
        guard xInPlot >= 0, xInPlot <= frame.width else { return }
        guard let date: Date = proxy.value(atX: xInPlot, as: Date.self) else { return }
        // Find the bucket whose [hourStart, hourStart+1h) contains the
        // resolved date. With sorted buckets, lower_bound style:
        guard let match = buckets.last(where: { $0.hourStart <= date }) else {
            return
        }
        if date < match.hourStart.addingTimeInterval(3600) {
            selectedHourStart = match.hourStart
        }
    }

    /// Short timezone label for the chart title — abbreviation if the
    /// system gives one (e.g., "KST", "PDT"), otherwise the
    /// identifier ("Asia/Seoul"). Falls back to "local" if neither.
    private var tzLabel: String {
        if let abbr = timeZone.abbreviation(), !abbr.isEmpty {
            return abbr
        }
        return timeZone.identifier
    }

    /// Median $/1% across hours with at least one pair — drawn as the
    /// dashed reference line. We don't gate on ≥5 samples here (the
    /// time-series chart can have many sparse hours and the gating
    /// would discard a representative center). For the *anomaly*
    /// callouts the underlying detector still uses its own min-N
    /// threshold from the hour-of-day rollup.
    private func computeBaseline() -> Double? {
        let qualifying = buckets
            .filter { $0.sampleCount > 0 }
            .map { $0.dollarsPerPercentShrunk }
            .filter { $0 > 0 }
            .sorted()
        guard qualifying.count >= 3 else { return nil }
        return qualifying[qualifying.count / 2]
    }

    /// Bar color encodes the same tight-vs-lenient signal the previous
    /// heat-strip used, but secondarily — height is the primary
    /// reading. Above-baseline bars get the lenient color; below get
    /// the tight color; near-baseline get a neutral accent.
    private func barColor(
        for bucket: HourlyEfficiencyAggregator.TimeSeriesBucket,
        baseline: Double?
    ) -> Color {
        guard bucket.sampleCount > 0 else {
            return Color.secondary.opacity(0.3)
        }
        guard let baseline, baseline > 0 else {
            return Color.accentColor
        }
        let ratio = bucket.dollarsPerPercentShrunk / baseline
        if ratio >= 1.5 {
            return Color(.sRGB, red: 0.36, green: 0.55, blue: 0.85)  // cool: lenient
        } else if ratio <= 0.6 {
            return Color(.sRGB, red: 0.95, green: 0.60, blue: 0.20)  // warm: tight
        } else {
            return Color.accentColor.opacity(0.85)
        }
    }

    // MARK: - Stats card

    private func statsCard(bucket: HourlyEfficiencyAggregator.TimeSeriesBucket) -> some View {
        let formatter: DateFormatter = {
            let f = DateFormatter()
            f.timeZone = timeZone
            f.dateFormat = "MMM d (E) HH:00"
            return f
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(formatter.string(from: bucket.hourStart))
                .font(.system(size: 13, weight: .semibold))

            if bucket.sampleCount == 0 {
                Text("No samples yet for this hour.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                // User asked for the "value of 1%" framing — present
                // the data as `$ per 1% limit` (higher = more lenient
                // hour). Median is shown beside the mean because a
                // few outlier sessions can pull the mean around;
                // p10 surfaces the worst typical observation in this
                // hour ("at the bottom 10%, 1% only bought $X").
                let mean = formatDollars(bucket.dollarsPerPercentMean)
                let p50 = formatDollars(bucket.dollarsPerPercentP50)
                let p10 = formatDollars(bucket.dollarsPerPercentP10)
                Text("n = \(bucket.sampleCount) pairs · 1% limit ≈ \(mean) of work · median \(p50) · worst-typical \(p10)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(
                    format: "spent $%.2f → consumed %.1f%% of 5h limit",
                    bucket.totalCostUSD, bucket.totalLimitConsumed
                ))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Adaptive USD precision. Sub-$1 values get cents (`$0.42`); a
    /// tight hour where 1% buys only fractions of a cent gets 4-digit
    /// precision so the user can still see the ratio.
    private func formatDollars(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1.0 { return String(format: "$%.2f", value) }
        return String(format: "$%.2f", value)
    }

    private var hoverHint: some View {
        Text("Hover over a bar to inspect that hour. Bar height = $ value of 1% of your 5-hour limit.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    // MARK: - Anomalies

    private var anomalyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Patterns in the last \(windowDays) days")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(anomalies.enumerated()), id: \.offset) { _, callout in
                HStack(spacing: 6) {
                    Image(systemName: callout.direction == .high
                          ? "exclamationmark.triangle.fill"
                          : "leaf.fill")
                        .foregroundStyle(callout.direction == .high
                                         ? Color.orange
                                         : Color.secondary)
                        .font(.system(size: 10))
                    Text(callout.localizedSummary)
                        .font(.system(size: 11))
                }
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private func opacity(for sampleCount: Int) -> Double {
        // log scale: n=0 → 0.15 (still visible as "no data"),
        //           n=1 → ~0.4, n=10 → ~0.85, n>=20 → 1.0
        if sampleCount == 0 { return 0.15 }
        let denom = log(20.0 + 1)
        return min(1.0, log(Double(sampleCount) + 1) / denom)
    }

}
