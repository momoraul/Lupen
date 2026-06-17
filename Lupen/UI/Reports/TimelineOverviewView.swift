import SwiftUI
import Charts

/// Overview tab of the Reports window — **Hero + Sparkline cards** pattern.
///
/// Layout:
///
///   ┌─ KPI cards row (6 cards: value + 36pt sparkline) ───┐
///   │  Cost*  Sessions  Turns  Tokens  Avg/Sess  Avg/Tok   │
///   │  ↑ click a card → hero chart promotes that metric    │
///   ├─ Hero chart (~280pt, large chart of selected metric) ┤
///   └──────────────────────────────────────────────────────┘
///
/// **Hover sync**: hovering a day in the hero chart also retargets the
/// cards' value readout to that date. Cards themselves do not own hover
/// selection — pixel-precise selection inside 36pt is fiddly, so the hero
/// is the single source.
///
/// **Granularity**:
///   - `.day` (default): 6 KPI cards, hero titled "Daily ..."
///   - `.hour` (Today range): hero / sparkline both render 24 hourly bars.
///     `Avg / Session` / `Avg / Token` collapse to a denominator of 1 in
///     hourly mode, so sparkline + hero are disabled — readout shows "—".
@MainActor
struct TimelineOverviewView: View {

    let buckets: [UsageTimelineAnalyzer.DailyUsageBucket]
    let rangeLabel: String
    /// Drives the X-axis label, BarMark unit, selection caption, and chart
    /// title. `.day` = one bar per day; `.hour` = hourly bars from 00:00 to
    /// the current hour (used by the "Today" range).
    let granularity: UsageTimelineAnalyzer.Granularity

    init(
        buckets: [UsageTimelineAnalyzer.DailyUsageBucket],
        rangeLabel: String,
        granularity: UsageTimelineAnalyzer.Granularity = .day
    ) {
        self.buckets = buckets
        self.rangeLabel = rangeLabel
        self.granularity = granularity
    }

    @State private var selectedMetric: Metric = .cost

    /// Day under hover in the hero chart. nil = cards/hero show totals/avg.
    @State private var hoveredDay: Date? = nil

    // MARK: - Metric definition

    /// The 6 metrics shared by cards and the hero chart. Mutating
    /// `selectedMetric` keeps the hero chart and card selection border in
    /// sync from a single source.
    enum Metric: String, CaseIterable, Identifiable, Hashable {
        case cost
        case sessions
        case turns
        case tokens
        case avgCostPerSession
        case avgCostPerToken

        var id: String { rawValue }

        var shortLabel: String {
            switch self {
            case .cost: return "Cost"
            case .sessions: return "Sessions"
            case .turns: return "Turns"
            case .tokens: return "Tokens"
            case .avgCostPerSession: return "Avg / session"
            case .avgCostPerToken: return "Avg / token"
            }
        }

        /// Avg ratio metrics render as a line (continuous ratio); absolute
        /// metrics render as bars (discrete day buckets).
        var rendersAsLine: Bool {
            self == .avgCostPerSession || self == .avgCostPerToken
        }

        /// Avg ratios collapse to a denominator of 1 in hourly mode and lose
        /// meaning, so they are disabled there.
        var meaningfulInHourly: Bool { !rendersAsLine }

        var color: Color {
            switch self {
            case .cost: return .accentColor
            case .sessions: return .green
            case .turns: return .orange
            case .tokens: return .cyan
            case .avgCostPerSession: return .purple
            case .avgCostPerToken: return .pink
            }
        }
    }

    var body: some View {
        if buckets.isEmpty || allZero {
            emptyState
        } else {
            // The combined intrinsic height of the card grid (which wraps
            // as 4+2, 3+3, 6+0, …) plus the hero can exceed the window.
            // Wrap in a ScrollView to guarantee top alignment — a centered
            // parent frame would clip the VStack on both ends (e.g. cropping
            // the top of "● Cost"), whereas a ScrollView fills from
            // top-leading.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    cardsRow
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                    Divider()
                    heroSection
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            // Disable bounce when content fits — matches desktop expectation
            // of an unscrollable region.
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Cards row

    private var cardsRow: some View {
        let columns = [GridItem(.adaptive(minimum: 132, maximum: .infinity), spacing: 10)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Metric.allCases) { metric in
                metricCard(metric)
            }
        }
    }

    private func metricCard(_ metric: Metric) -> some View {
        let isSelected = (metric == selectedMetric)
        let isMeaningful = (granularity == .day) || metric.meaningfulInHourly
        // Cards always show range totals/avg regardless of hover; hover is
        // surfaced only via the hero's RuleMark + readout. Flickering 6
        // values at once would be too noisy.
        let valueText = totalValueText(metric)
        let captionText = rangeLabel

        return Button {
            // Block promotion of ratio metrics in hourly mode — the hero
            // would render as an empty chart.
            guard isMeaningful else { return }
            selectedMetric = metric
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(metric.color)
                        .frame(width: 6, height: 6)
                    Text(metric.shortLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(valueText)
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
                cardSparkline(metric)
                    .frame(height: 28)
                    .opacity(isMeaningful ? 1 : 0.25)
                Text(captionText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? metric.color.opacity(0.10)
                          : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? metric.color.opacity(0.85)
                                              : Color.clear,
                                  lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .help(isMeaningful
              ? "Show \(metric.shortLabel) chart"
              : "\(metric.shortLabel) is not meaningful for hourly view")
        .accessibilityLabel(metric.shortLabel)
        .accessibilityValue(valueText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Card sparkline

    /// Mini chart inside a card. Axes / grid / labels are all hidden —
    /// meaningful labelling is impossible inside 36pt; we only convey the
    /// metric's *shape*.
    @ViewBuilder
    private func cardSparkline(_ metric: Metric) -> some View {
        if metric.rendersAsLine {
            sparklineLine(metric)
        } else {
            sparklineBars(metric)
        }
    }

    private func sparklineBars(_ metric: Metric) -> some View {
        Chart(buckets) { b in
            BarMark(
                x: .value("x", b.day, unit: chartUnit),
                y: .value("y", barValue(b, metric: metric))
            )
            .foregroundStyle(metric.color.opacity(0.9))
        }
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
    }

    private func sparklineLine(_ metric: Metric) -> some View {
        let points = ratioPoints(metric)
        return Chart(points, id: \.day) { p in
            LineMark(
                x: .value("x", p.day, unit: chartUnit),
                y: .value("y", p.value)
            )
            .foregroundStyle(metric.color.opacity(0.9))
            .interpolationMethod(.catmullRom)
        }
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
    }

    // MARK: - Hero section

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(heroTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(heroReadout)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            heroChart
                .frame(height: 280)
        }
    }

    @ViewBuilder
    private var heroChart: some View {
        // Defensive placeholder: card clicks already block this state, but
        // an external change to `selectedMetric` could land us here.
        if granularity == .hour && !selectedMetric.meaningfulInHourly {
            VStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("\(selectedMetric.shortLabel) is shown for daily ranges only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedMetric.rendersAsLine {
            heroLineChart
        } else {
            heroBarChart
        }
    }

    private var heroBarChart: some View {
        Chart {
            ForEach(buckets) { b in
                BarMark(
                    x: .value(xLabel, b.day, unit: chartUnit),
                    y: .value(selectedMetric.shortLabel, barValue(b, metric: selectedMetric))
                )
                .foregroundStyle(selectedMetric.color.gradient)
            }
            // Dashed RuleMark marks the hovered bucket — since cards stay
            // static this is the only "where am I looking" cue.
            if let hoveredDay {
                RuleMark(x: .value(xLabel, hoveredDay, unit: chartUnit))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    heroAxisLabel(for: value)
                }
            }
        }
        .chartXAxis { xAxisMarks }
        .chartXSelection(value: $hoveredDay)
    }

    private var heroLineChart: some View {
        let points = ratioPoints(selectedMetric)
        return Chart {
            ForEach(points, id: \.day) { p in
                LineMark(
                    x: .value(xLabel, p.day, unit: chartUnit),
                    y: .value(selectedMetric.shortLabel, p.value)
                )
                .foregroundStyle(selectedMetric.color)
                .interpolationMethod(.catmullRom)
                .symbol(Circle().strokeBorder(lineWidth: 1.5))
                .symbolSize(28)
            }
            if let hoveredDay {
                RuleMark(x: .value(xLabel, hoveredDay, unit: chartUnit))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    heroAxisLabel(for: value)
                }
            }
        }
        .chartXAxis { xAxisMarks }
        .chartXSelection(value: $hoveredDay)
    }

    @ViewBuilder
    private func heroAxisLabel(for value: AxisValue) -> some View {
        switch selectedMetric {
        case .cost, .avgCostPerSession, .avgCostPerToken:
            if let v = value.as(Double.self) {
                Text(axisLabelForCost(v, metric: selectedMetric))
                    .font(.system(size: 9).monospacedDigit())
            }
        case .sessions, .turns:
            if let v = value.as(Int.self) {
                Text("\(v)")
                    .font(.system(size: 9).monospacedDigit())
            }
        case .tokens:
            if let v = value.as(Int.self) {
                Text(Self.formatTokensAxis(v))
                    .font(.system(size: 9).monospacedDigit())
            }
        }
    }

    /// avg/token values are raw $/token (not $/M token), which the regular
    /// cost formatter rounds to 0 — branch to a dedicated formatter.
    private func axisLabelForCost(_ value: Double, metric: Metric) -> String {
        if metric == .avgCostPerToken {
            return formatCostPerTokenAxis(value)
        }
        return formatUSDAxis(value)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("No activity")
                .font(.system(size: 13, weight: .medium))
            Text("No sessions or requests in the selected date range.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding()
    }

    // MARK: - Derived helpers

    private var allZero: Bool {
        buckets.allSatisfy {
            $0.costUSD == 0 && $0.sessionCount == 0
                && $0.turnCount == 0 && $0.tokenCount == 0
        }
    }

    private var totalCost: Double { buckets.reduce(0) { $0 + $1.costUSD } }
    private var totalSessions: Int { buckets.reduce(0) { $0 + $1.sessionCount } }
    private var totalTurns: Int { buckets.reduce(0) { $0 + $1.turnCount } }
    private var totalTokens: Int { buckets.reduce(0) { $0 + $1.tokenCount } }

    private var hoveredBucket: UsageTimelineAnalyzer.DailyUsageBucket? {
        guard let hoveredDay else { return nil }
        let cal = Calendar.autoupdatingCurrent
        switch granularity {
        case .day:
            let target = cal.startOfDay(for: hoveredDay)
            return buckets.first { cal.isDate($0.day, inSameDayAs: target) }
        case .hour:
            let target = cal.dateInterval(of: .hour, for: hoveredDay)?.start
                ?? hoveredDay
            return buckets.first { abs($0.day.timeIntervalSince(target)) < 30 }
        }
    }

    private var hoveredCaption: String? {
        guard let b = hoveredBucket else { return nil }
        // Hover re-evaluates `body` many times per second; the previous
        // `let f = DateFormatter()` allocated per call. Two cached
        // formatters cover the granularity branches with zero alloc.
        switch granularity {
        case .day:  return Self.hoverDayFormatter.string(from: b.day)
        case .hour: return Self.hoverHourFormatter.string(from: b.day)
        }
    }

    nonisolated(unsafe) private static let hoverDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    nonisolated(unsafe) private static let hoverHourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:00"
        return f
    }()

    private func totalValueText(_ metric: Metric) -> String {
        switch metric {
        case .cost: return formatUSD(totalCost)
        case .sessions: return "\(totalSessions)"
        case .turns: return "\(totalTurns)"
        case .tokens: return Self.formatTokens(totalTokens)
        case .avgCostPerSession:
            return totalSessions > 0
                ? formatUSD(totalCost / Double(totalSessions))
                : "—"
        case .avgCostPerToken:
            return totalTokens > 0
                ? formatCostPerToken(totalCost / Double(totalTokens))
                : "—"
        }
    }

    private var heroTitle: String {
        let prefix = (granularity == .hour) ? "Hourly" : "Daily"
        let body: String
        switch selectedMetric {
        case .cost: body = "Cost"
        case .sessions: body = "Sessions"
        case .turns: body = "Turns"
        case .tokens: body = "Tokens"
        case .avgCostPerSession: body = "Avg Cost / Session"
        case .avgCostPerToken: body = "Avg Cost / Token"
        }
        return "\(prefix) \(body)"
    }

    private var heroReadout: String {
        if let b = hoveredBucket, let caption = hoveredCaption {
            // "Apr 24 · $52.34" — show date + value so the hover position is
            // unambiguous while the cards remain static.
            let value: String
            switch selectedMetric {
            case .cost: value = formatUSD(b.costUSD)
            case .sessions: value = "\(b.sessionCount)"
            case .turns: value = "\(b.turnCount)"
            case .tokens: value = Self.formatTokens(b.tokenCount)
            case .avgCostPerSession:
                value = b.avgCostPerSession.map(formatUSD) ?? "—"
            case .avgCostPerToken:
                value = b.avgCostPerToken.map(formatCostPerToken) ?? "—"
            }
            return "\(caption) · \(value)"
        }
        // total / overall avg with "total" / "avg" hint.
        switch selectedMetric {
        case .cost: return "\(formatUSD(totalCost)) total"
        case .sessions: return "\(totalSessions) total"
        case .turns: return "\(totalTurns) total"
        case .tokens: return "\(Self.formatTokens(totalTokens)) total"
        case .avgCostPerSession:
            return totalSessions > 0
                ? "avg \(formatUSD(totalCost / Double(totalSessions)))"
                : "—"
        case .avgCostPerToken:
            return totalTokens > 0
                ? "avg \(formatCostPerToken(totalCost / Double(totalTokens)))"
                : "—"
        }
    }

    private func barValue(
        _ b: UsageTimelineAnalyzer.DailyUsageBucket,
        metric: Metric
    ) -> Double {
        switch metric {
        case .cost: return b.costUSD
        case .sessions: return Double(b.sessionCount)
        case .turns: return Double(b.turnCount)
        case .tokens: return Double(b.tokenCount)
        case .avgCostPerSession, .avgCostPerToken:
            // never called — line metric — but keep total to silence
            // exhaustiveness without crashing on programming error.
            return 0
        }
    }

    /// Days with a 0 denominator are dropped so the line chart renders a
    /// gap rather than a misleading 0 dip.
    private func ratioPoints(_ metric: Metric) -> [RatioPoint] {
        buckets.compactMap { b in
            let v: Double?
            switch metric {
            case .avgCostPerSession: v = b.avgCostPerSession
            case .avgCostPerToken: v = b.avgCostPerToken
            default: v = nil
            }
            guard let v else { return nil }
            return RatioPoint(day: b.day, value: v)
        }
    }

    private struct RatioPoint: Identifiable, Hashable {
        let day: Date
        let value: Double
        var id: Date { day }
    }

    // MARK: - X-axis common

    private var xAxisMarks: AxisMarks<some AxisMark> {
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
            AxisGridLine()
            AxisTick()
            switch granularity {
            case .day:
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9))
            case .hour:
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                    .font(.system(size: 9))
            }
        }
    }

    private var chartUnit: Calendar.Component {
        granularity == .hour ? .hour : .day
    }

    private var xLabel: String {
        granularity == .hour ? "Hour" : "Day"
    }

    // MARK: - Formatters

    private func formatUSD(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1.0 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }

    private func formatUSDAxis(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.0fk", value / 1000) }
        if value >= 10 { return String(format: "$%.0f", value) }
        if value >= 1 { return String(format: "$%.1f", value) }
        if value == 0 { return "$0" }
        return String(format: "$%.2f", value)
    }

    /// $/token is typically 1e-5 ~ 1e-4 USD, unreadable as a raw value.
    /// Scale to per-million tokens, e.g. 0.0000234 USD/token → "$23.4/M".
    private func formatCostPerToken(_ value: Double) -> String {
        if value == 0 { return "—" }
        let perMillion = value * 1_000_000
        if perMillion >= 100 { return String(format: "$%.0f/M", perMillion) }
        if perMillion >= 10 { return String(format: "$%.1f/M", perMillion) }
        return String(format: "$%.2f/M", perMillion)
    }

    private func formatCostPerTokenAxis(_ value: Double) -> String {
        if value == 0 { return "$0" }
        let perMillion = value * 1_000_000
        if perMillion >= 10 { return String(format: "$%.0f/M", perMillion) }
        return String(format: "$%.1f/M", perMillion)
    }

    static func formatTokens(_ n: Int) -> String {
        if n >= 10_000_000 { return String(format: "%.0fM", Double(n) / 1_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 100_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        if n >= 10_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func formatTokensAxis(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
