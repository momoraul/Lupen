import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Cost Reports window. Tabs (Overview / Projects / Skills / Models /
/// Hours) share a date-range filter. Reads `AppStateStore` via
/// Observation so rollups recompute when the store changes.
///
/// Each tab keeps its own sort state so switching tabs doesn't reset
/// the user's choice on the others. The Primary model column is
/// intentionally non-sortable — `Optional<String>` isn't directly
/// `Comparable` and the sort order there rarely matters to users.
@MainActor
struct ReportsView: View {

    @Bindable var store: AppStateStore
    /// Optional so tests and constrained host paths (e.g. opening
    /// Reports before the statusline tap is wired) still work — Hours
    /// just renders an empty 24-bucket strip when nil.
    var sampleStore: RateLimitSampleStore?
    let onDismiss: () -> Void

    @State private var selectedTab: Tab = .overview
    @State private var dateRange: DateRangeOption = .allTime
    /// From/To for the `.custom` range. Default to the last 30 days so the
    /// pickers open on a sensible non-empty window.
    @State private var customFrom: Date =
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customTo: Date = Date()
    /// Whether the date-range popover (presets + custom From/To) is open.
    @State private var showRangePopover: Bool = false
    /// Bumped on every local-day rollover. Referenced in `body` so the
    /// view re-evaluates `requestBounds` (and downstream computed rows)
    /// when the day changes while the window is open — otherwise
    /// "Today" / "Yesterday" pickers would keep resolving against the
    /// original open-time date.
    @State private var midnightVersion: Int = 0

    // Default cost DESC — mirrors `CostAnalyzer`'s default return order.
    @State private var projectSort: [KeyPathComparator<CostAnalyzer.ProjectSummary>] = [
        KeyPathComparator(\.totalCost.totalCostUSD, order: .reverse)
    ]
    @State private var skillSort: [KeyPathComparator<CostAnalyzer.SkillSummary>] = [
        KeyPathComparator(\.totalCost.totalCostUSD, order: .reverse)
    ]
    @State private var modelSort: [KeyPathComparator<CostAnalyzer.ModelSummary>] = [
        KeyPathComparator(\.totalCost.totalCostUSD, order: .reverse)
    ]
    @State private var codexSkillNames: Set<String>?
    @State private var skillRowsSnapshot: [CostAnalyzer.SkillSummary] = []
    @State private var skillRowsIsLoading: Bool = false

    // MARK: - Derived data

    /// Per-request timestamp bounds for the current date range. `nil`
    /// means no filter (All time). All Reports aggregators
    /// (`CostAnalyzer`, `UsageTimelineAnalyzer`) share this so the
    /// Overview chart, tabs, and footer totals agree on a given range.
    /// Bounds evaluate against `request.timestamp` (not
    /// `session.startTime`) so a session that spans midnight contributes
    /// to whichever day(s) its requests actually fired.
    private var requestBounds: ClosedRange<Date>? {
        let range: SessionFilter.DateRange? = dateRange == .custom
            ? SessionFilter.DateRange.customSpanning(customFrom, customTo)
            : dateRange.filterCase
        guard let range else { return nil }
        let (start, end) = range.resolveBounds()
        guard start <= end else { return nil }
        return start...end
    }

    /// Overview-chart granularity. Custom ranges render daily bars; presets
    /// keep their own hour/day choice.
    private var effectiveGranularity: UsageTimelineAnalyzer.Granularity {
        dateRange == .custom ? .day : dateRange.granularity
    }

    /// Zero-fill window for the Overview chart. Custom fills day-by-day
    /// across the picked span; presets defer to the enum.
    private var effectiveZeroFillRange: UsageTimelineAnalyzer.DayRange? {
        guard dateRange == .custom,
              let bounds = requestBounds else {
            return dateRange == .custom ? nil : dateRange.zeroFillRange
        }
        let cal = Calendar.autoupdatingCurrent
        return .init(
            from: cal.startOfDay(for: bounds.lowerBound),
            to: cal.startOfDay(for: bounds.upperBound)
        )
    }

    /// Human label for the active range — the picked span for custom.
    private var effectiveRangeLabel: String {
        guard dateRange == .custom, let bounds = requestBounds else {
            return dateRange.title
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: bounds.lowerBound)) – \(formatter.string(from: bounds.upperBound))"
    }

    private var activeProvider: ProviderKind {
        store.activeProvider
    }

    private var activeProviderName: String {
        activeProvider.descriptor.displayName
    }

    private var activeSessions: [Session] {
        store.sessions.filter { $0.provider == activeProvider }
    }

    private var activeSessionIds: Set<String> {
        Set(activeSessions.map(\.id))
    }


    private var activeSampleStore: RateLimitSampleStore? {
        activeProvider == .claudeCode ? sampleStore : nil
    }

    private var codexSkillCatalogTaskID: String {
        guard activeProvider == .codex else {
            return "\(ProviderKind.claudeCode.providerID.rawValue):disabled"
        }
        let rootsKey = activeCodexProjectSkillRoots
            .map { $0.standardizedFileURL.path }
            .sorted()
            .joined(separator: "\n")
        return [
            store.codexHomeForSkillCatalog.standardizedFileURL.path,
            rootsKey
        ].joined(separator: "|")
    }

    private var knownCodexSkillNames: Set<String>? {
        activeProvider == .codex ? codexSkillNames : nil
    }

    private var activeCodexProjectSkillRoots: [URL] {
        guard activeProvider == .codex else { return [] }
        return CodexSkillCatalog.projectLocalSkillRoots(
            forProjectPaths: activeSessions.compactMap(\.projectPath)
        )
    }

    private var activeTurnsFingerprint: String {
        // The in-memory turn graphs died with 5.3 — the SQL refresh
        // generation is the change signal now.
        String(store.sqliteConversationGeneration)
    }

    private var requestBoundsFingerprint: String {
        guard let bounds = requestBounds else { return "all" }
        return "\(bounds.lowerBound.timeIntervalSinceReferenceDate)-\(bounds.upperBound.timeIntervalSinceReferenceDate)"
    }

    private var codexSkillNamesFingerprint: String {
        guard activeProvider == .codex else { return "disabled" }
        guard let codexSkillNames else { return "loading" }
        var hasher = Hasher()
        for name in codexSkillNames.sorted() {
            hasher.combine(name)
        }
        return String(hasher.finalize())
    }

    private var skillMetricsTaskID: String {
        [
            activeProvider.providerID.rawValue,
            requestBoundsFingerprint,
            // SQLite mode: imports (not in-memory turns) change the
            // answer — key on the driver's refresh generation.
            store.sqliteConversationSource != nil
                ? "sqlite:\(store.sqliteConversationGeneration)"
                : activeTurnsFingerprint,
            codexSkillNamesFingerprint
        ].joined(separator: "|")
    }

    /// SQLite-first reports source (plan 4.4): non-nil routes every tab
    /// to SQL aggregates — the legacy in-memory inputs are empty shells
    /// in that mode.
    private var sqliteReportsStore: ProviderStore? {
        guard let source = store.sqliteConversationSource else { return nil }
        // Touch the generation so SwiftUI re-renders (and the skill task
        // id changes) as background imports land.
        _ = store.sqliteConversationGeneration
        return source.store
    }

    /// Coverage note (4.4): totals are honest-but-partial while the
    /// background index is still importing sources.
    private var indexingCoverageNote: String? {
        guard sqliteReportsStore != nil else { return nil }
        let progress = store.launchProgress
        guard progress.phase == .indexing, progress.pendingUnits > 0 else { return nil }
        let done = min(progress.processedUnits, progress.pendingUnits)
        return "Indexing \(done)/\(progress.pendingUnits) sessions — totals update as imports land"
    }

    private var projectRows: [CostAnalyzer.ProjectSummary] {
        guard let sqlStore = sqliteReportsStore else { return [] }
        return SQLiteReportsProjection.projectSummaries(
            store: sqlStore,
            from: requestBounds?.lowerBound,
            to: requestBounds?.upperBound
        ).sorted(using: projectSort)
    }

    private var skillRows: [CostAnalyzer.SkillSummary] {
        skillRowsSnapshot.sorted(using: skillSort)
    }

    private var skillCommandPrefix: String {
        ReportsSkillMetrics.commandPrefix(for: activeProvider)
    }

    private var modelRows: [CostAnalyzer.ModelSummary] {
        guard let sqlStore = sqliteReportsStore else { return [] }
        return SQLiteReportsProjection.modelSummaries(
            store: sqlStore,
            from: requestBounds?.lowerBound,
            to: requestBounds?.upperBound
        ).sorted(using: modelSort)
    }

    /// Overview tab data. Zero-filled to the explicit range when set;
    /// for `allTime` the analyzer infers min/max from observed data.
    /// "Today" switches to hourly granularity so the user sees an
    /// intraday breakdown rather than a single daily bar.
    private var timelineBuckets: [UsageTimelineAnalyzer.DailyUsageBucket] {
        guard let sqlStore = sqliteReportsStore else { return [] }
        return SQLiteReportsProjection.timelineBuckets(
            store: sqlStore,
            granularity: effectiveGranularity,
            range: effectiveZeroFillRange
        )
    }

    // MARK: - Body

    var body: some View {
        // Touching `midnightVersion` here ties the whole body's
        // re-evaluation to the wall-clock tick so `requestBounds` (which
        // calls `Date()` at resolve time) picks up the new day.
        let _ = midnightVersion
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        // ideal 920×600 fits the Overview cards in one row plus the hero
        // chart; smaller sizes fall back to a ScrollView.
        .frame(minWidth: 680, idealWidth: 920, minHeight: 480, idealHeight: 600)
        .onReceive(
            NotificationCenter.default.publisher(for: WallClockCoordinator.wallClockTick)
        ) { note in
            if note.wallClockDidCrossMidnight {
                midnightVersion &+= 1
            }
        }
        .task(id: codexSkillCatalogTaskID) {
            await refreshCodexSkillNames(taskID: codexSkillCatalogTaskID)
        }
        .task(id: skillMetricsTaskID) {
            await refreshSkillRows(taskID: skillMetricsTaskID)
        }
    }

    private func refreshCodexSkillNames(taskID: String) async {
        guard activeProvider == .codex else {
            codexSkillNames = nil
            return
        }
        codexSkillNames = nil
        let codexHome = store.codexHomeForSkillCatalog.standardizedFileURL
        let additionalRoots = activeCodexProjectSkillRoots
        let names = await Task.detached(priority: .utility) {
            CodexSkillCatalog.currentSkillNames(
                codexHome: codexHome,
                additionalRoots: additionalRoots
            )
        }.value
        guard activeProvider == .codex,
              codexSkillCatalogTaskID == taskID else { return }
        codexSkillNames = names
    }

    private func refreshSkillRows(taskID: String) async {
        if activeProvider == .codex, codexSkillNames == nil {
            skillRowsIsLoading = true
            skillRowsSnapshot = []
            return
        }

        skillRowsIsLoading = true
        let bounds = requestBounds

        // SQLite-first: skills were extracted at import (4.4) — one SQL
        // aggregate replaces the turn walk.
        if let sqlStore = sqliteReportsStore {
            let rows = await Task.detached(priority: .utility) {
                SQLiteReportsProjection.skillSummaries(
                    store: sqlStore,
                    from: bounds?.lowerBound,
                    to: bounds?.upperBound
                )
            }.value
            guard skillMetricsTaskID == taskID else { return }
            skillRowsSnapshot = rows
            skillRowsIsLoading = false
            return
        }

        // No SQL store installed (5.3: the in-memory graphs are gone)
        // — nothing to compute.
        skillRowsSnapshot = []
        skillRowsIsLoading = false
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(activeProviderName) Reports")
                .font(.system(size: 16, weight: .semibold))

            if let note = indexingCoverageNote {
                Label(note, systemImage: "clock.arrow.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                dateRangeButton
            }
        }
    }

    /// Single date-range control: a button labelled with the active range
    /// that opens a popover holding the presets + (for Custom) the From/To
    /// pickers. Keeps the toolbar to one compact control — the standard
    /// dashboard pattern, and consistent with the sidebar's filter popover.
    private var dateRangeButton: some View {
        Button {
            showRangePopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(effectiveRangeLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .popover(isPresented: $showRangePopover, arrowEdge: .bottom) {
            dateRangePopover
        }
    }

    private var dateRangePopover: some View {
        Form {
            Picker("Range", selection: $dateRange) {
                ForEach(DateRangeOption.allCases) { opt in
                    Text(opt.title).tag(opt)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .onChange(of: dateRange) { _, new in
                // A concrete preset answers the question — close. Custom
                // keeps the popover open so the user can pick From/To.
                if new != .custom { showRangePopover = false }
            }

            if dateRange == .custom {
                Section {
                    DatePicker("From", selection: $customFrom, displayedComponents: .date)
                    DatePicker("To", selection: $customTo, displayedComponents: .date)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 240, idealWidth: 250)
        .frame(maxHeight: 480)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .overview:
            TimelineOverviewView(
                buckets: timelineBuckets,
                rangeLabel: effectiveRangeLabel,
                granularity: effectiveGranularity
            )
        case .projects:
            projectsTable
        case .skills:
            skillsTable
        case .models:
            modelsTable
        case .hours:
            hoursTab
        }
    }

    /// Hours-tab rolling window. Independent of the global date-range
    /// picker (which targets per-day rollups, not per-hour patterns).
    /// 7 days is short enough that the user's recent rhythm dominates
    /// while still gathering enough pairs per hour for stable
    /// percentiles.
    private static let hoursWindowDays: Int = 7

    @ViewBuilder
    private var hoursTab: some View {
        let timeZone = TimeZone.current
        // Time series for the chart — 168 chronological hour bars
        // ending at the current hour. Empty hours stay blank so the
        // user sees their actual usage rhythm against real time.
        let timeSeriesBuckets = HourlyEfficiencyAggregator.aggregateTimeSeries(
            samples: activeSampleStore?.samples ?? [],
            requestsWithCost: requestsWithCostFlat,
            now: Date(),
            windowHours: Self.hoursWindowDays * 24,
            timeZone: timeZone
        )
        // Hour-of-day rollup for the anomaly callouts — different
        // question from the chart ("which hour-of-day is tight on
        // average?" vs "when did I work this week?").
        let hourOfDayBuckets = HourlyEfficiencyAggregator.aggregate(
            samples: activeSampleStore?.samples ?? [],
            requestsWithCost: requestsWithCostFlat,
            now: Date(),
            windowDays: Self.hoursWindowDays,
            timeZone: timeZone
        )
        let anomalies = HourlyAnomalyDetector.detect(buckets: hourOfDayBuckets)
        HourlyEfficiencyView(
            buckets: timeSeriesBuckets,
            anomalies: anomalies,
            dataSourceLine: hoursDataSourceLine,
            timeZone: timeZone,
            windowDays: Self.hoursWindowDays
        )
    }

    /// Flattens `store.sessions` into `(timestamp, costUSD)` so the
    /// aggregator doesn't need the full Session/ParsedRequest shape.
    /// Synthetic models and null costs are filtered out here so the
    /// math downstream doesn't have to.
    private var requestsWithCostFlat: [(timestamp: Date, costUSD: Double)] {
        if let sqlStore = sqliteReportsStore {
            let windowStart = Calendar.current.date(
                byAdding: .day, value: -Self.hoursWindowDays, to: Date()
            )
            let points = (try? sqlStore.requestCostPoints(from: windowStart, to: nil)) ?? []
            return points.map { ($0.timestamp, $0.costUSD) }
        }
        return []   // 5.3: no SQL store, no data — the graphs are gone
    }

    private var hoursDataSourceLine: String {
        guard activeProvider == .claudeCode else {
            return "Hourly statusline data is available for Claude Code only."
        }
        if let store = activeSampleStore {
            let n = store.samples.count
            if n == 0 {
                return "No samples yet — Connect Lupen to Claude Code statusline in Settings."
            }
            return "Source: ✓ statusline · \(n) samples in 14 days"
        } else {
            return "Statusline not connected — Connect in Settings for accurate data."
        }
    }

    @ViewBuilder
    private var projectsTable: some View {
        if projectRows.isEmpty {
            emptyState(
                title: "No project data",
                subtitle: "No \(activeProviderName) sessions match the selected date range."
            )
        } else {
            Table(projectRows, sortOrder: $projectSort) {
                TableColumn("Project", value: \.projectLabel) { row in
                    Text(row.projectLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                TableColumn("Sessions", value: \.sessionCount) { row in
                    Text("\(row.sessionCount)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 64, ideal: 80, max: 100)
                TableColumn("Primary model") { row in
                    Text(row.primaryModel.map(ModelNameFormatter.short(_:))
                         ?? "—")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140)
                TableColumn("Cost", value: \.totalCost.totalCostUSD) { row in
                    Text(formatUSD(row.totalCost.totalCostUSD))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .width(min: 80, ideal: 100)
            }
        }
    }

    @ViewBuilder
    private var skillsTable: some View {
        if skillRowsIsLoading {
            loadingState(
                title: "Loading skill report",
                subtitle: "Aggregating \(activeProviderName) skill usage."
            )
        } else if skillRows.isEmpty {
            emptyState(
                title: "No skill invocations",
                subtitle: "No \(activeProviderName) skill commands ran in the selected date range."
            )
        } else {
            Table(skillRows, sortOrder: $skillSort) {
                TableColumn("Skill", value: \.skillName) { row in
                    HStack(spacing: 4) {
                        Text(skillCommandPrefix)
                            .foregroundStyle(.secondary)
                        Text(row.skillName)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                TableColumn("Invocations", value: \.invocationCount) { row in
                    Text("\(row.invocationCount)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100, max: 120)
                TableColumn("Avg / call", value: \.avgCostPerInvocation) { row in
                    Text(formatUSD(row.avgCostPerInvocation))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Primary model") { row in
                    Text(row.primaryModel.map(ModelNameFormatter.short(_:))
                         ?? "—")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140)
                TableColumn("Total", value: \.totalCost.totalCostUSD) { row in
                    Text(formatUSD(row.totalCost.totalCostUSD))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .width(min: 80, ideal: 100)
            }
        }
    }

    @ViewBuilder
    private var modelsTable: some View {
        if modelRows.isEmpty {
            emptyState(
                title: "No model usage",
                subtitle: "No \(activeProviderName) billable requests match the selected date range."
            )
        } else {
            Table(modelRows, sortOrder: $modelSort) {
                TableColumn("Model", value: \.modelName) { row in
                    Text(ModelNameFormatter.short(row.modelName))
                        .font(.system(size: 12, weight: .medium))
                }
                TableColumn("Requests", value: \.usageCount) { row in
                    Text("\(row.usageCount)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 72, ideal: 90, max: 110)
                if activeProvider == .claudeCode {
                    TableColumn("Fast", value: \.fastCount) { row in
                        if row.fastCount > 0 {
                            Text("\(row.fastCount)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.orange)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 52, ideal: 64, max: 80)
                }
                TableColumn("Avg / req", value: \.avgCostPerRequest) { row in
                    Text(formatUSD(row.avgCostPerRequest))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Total", value: \.totalCost.totalCostUSD) { row in
                    Text(formatUSD(row.totalCost.totalCostUSD))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .width(min: 80, ideal: 100)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(totalsLine)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export CSV…") { exportCurrentTabAsCSV() }
                .disabled(currentTabIsEmpty)
            Button("Close") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Footer totals — tab-specific so switching tabs swaps the summary
    /// unit (sessions vs skill invocations vs requests) rather than
    /// showing the same number three times. All counters respect
    /// `requestBounds` so the footer agrees with the tabs and Overview;
    /// e.g. "Today" counts requests/turns/sessions whose requests fired
    /// today even if the session itself started yesterday.
    private var totalsLine: String {
        let bounds = requestBounds
        var total: Double = 0
        var reqCount = 0
        var sessionCount = 0
        var turnCount = 0
        if let sqlStore = sqliteReportsStore {
            total = (try? sqlStore.totalCostUSD(
                from: bounds?.lowerBound, to: bounds?.upperBound
            )) ?? 0
            if let counts = try? sqlStore.requestActivityCounts(
                from: bounds?.lowerBound, to: bounds?.upperBound
            ) {
                reqCount = counts.requestCount
                sessionCount = counts.sessionCount
                turnCount = counts.turnCount
            }
        }
        let scope = dateRange == .allTime ? "all time" : effectiveRangeLabel.lowercased()
        switch selectedTab {
        case .overview:
            return "\(formatUSD(total)) · \(sessionCount) sessions · \(turnCount) turns · \(scope)"
        case .projects:
            return "\(formatUSD(total)) across \(sessionCount) sessions · \(scope)"
        case .skills:
            if skillRowsIsLoading {
                return "Loading skill report · \(scope)"
            }
            let footer = ReportsSkillMetrics.footerSummary(for: skillRows)
            return "\(formatUSD(footer.totalCostUSD)) total · \(footer.invocationCount) skill invocations · \(scope)"
        case .models:
            return "\(formatUSD(total)) across \(reqCount) requests · \(scope)"
        case .hours:
            // Hours uses its own rolling window; the footer reports
            // sample count rather than dollar totals.
            guard activeProvider == .claudeCode else {
                return "Claude Code statusline samples only · 14-day rolling window"
            }
            let n = activeSampleStore?.samples.count ?? 0
            return "\(n) statusline samples · 14-day rolling window"
        }
    }

    private var currentTabIsEmpty: Bool {
        switch selectedTab {
        case .overview: return timelineBuckets.isEmpty
        case .projects: return projectRows.isEmpty
        case .skills:   return skillRowsIsLoading || skillRows.isEmpty
        case .models:   return modelRows.isEmpty
        case .hours:    return (activeSampleStore?.samples.isEmpty ?? true)
        }
    }

    // MARK: - CSV export

    private func exportCurrentTabAsCSV() {
        let csv: String
        switch selectedTab {
        case .overview:
            csv = ReportsCSVExporter.timelineCSV(timelineBuckets)
        case .projects:
            csv = ReportsCSVExporter.projectsCSV(projectRows)
        case .skills:
            csv = ReportsCSVExporter.skillsCSV(skillRows, provider: activeProvider)
        case .models:
            csv = ReportsCSVExporter.modelsCSV(modelRows)
        case .hours:
            // CSV export for Hours not implemented; button disabled.
            csv = ""
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReportsCSVExporter.suggestedFilename(
            tab: selectedTab.title,
            provider: activeProvider)
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export \(selectedTab.title) CSV"

        // NSSavePanel fires its completion on the main thread
        // (documented AppKit behavior), so `assumeIsolated` lets us
        // call MainActor-isolated APIs like `NSAlert(error:)` without
        // Swift 6 cross-actor warnings.
        let completion: @Sendable (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try csv.data(using: .utf8)?.write(to: url, options: .atomic)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding()
    }

    @ViewBuilder
    private func loadingState(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding()
    }

    /// Scales precision to magnitude: sub-dollar amounts keep extra
    /// decimals so `$0.007` doesn't round to `$0.01` (material for
    /// skill-call averages); dollar-plus amounts round to cents.
    private func formatUSD(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1.0 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }

    // MARK: - Enums

    enum Tab: String, CaseIterable, Identifiable {
        case overview, projects, skills, models, hours
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .projects: return "Projects"
            case .skills: return "Skills"
            case .models: return "Models"
            case .hours: return "Hours"
            }
        }
    }

    enum DateRangeOption: String, CaseIterable, Identifiable {
        case allTime, today, yesterday, last24h, thisWeek, last30days, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .allTime: return "All time"
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .last24h: return "Last 24h"
            case .thisWeek: return "This Week"
            case .last30days: return "Last 30 days"
            case .custom: return "Custom…"
            }
        }
        /// `.custom` returns nil — its bounds come from the view's From/To
        /// pickers (`ReportsView.requestBounds`), not a preset rule.
        var filterCase: SessionFilter.DateRange? {
            switch self {
            case .allTime: return nil
            case .today: return .today
            case .yesterday: return .yesterday
            case .last24h: return .last24h
            case .thisWeek: return .thisWeek
            case .last30days: return .last30days
            case .custom: return nil
            }
        }

        /// Sub-day ranges (Today / Last 24h) use hourly so the user
        /// sees an intraday distribution — collapsing 24 hours into
        /// 1–2 daily bars defeats the point of a short window.
        var granularity: UsageTimelineAnalyzer.Granularity {
            switch self {
            case .today, .yesterday, .last24h: return .hour
            default: return .day
            }
        }

        /// Zero-fill range for the Overview chart. Returns nil for
        /// `allTime` so the analyzer infers min/max from observed data.
        var zeroFillRange: UsageTimelineAnalyzer.DayRange? {
            let cal = Calendar.autoupdatingCurrent
            let now = Date()
            switch self {
            case .allTime:
                return nil
            case .today:
                // Today 00:00 → current hour-start. Analyzer floors
                // `to` to the enclosing hour anyway; explicit hour
                // start keeps the intent legible.
                let start = cal.startOfDay(for: now)
                let currentHour = cal.dateInterval(of: .hour, for: now)?.start ?? now
                return .init(from: start, to: currentHour)
            case .yesterday:
                // 24 hourly buckets: [yesterday 00:00, yesterday 23:00]
                // inclusive on both ends. Unlike today (running up to
                // the current hour), yesterday is a completed 24-hour
                // window.
                let todayStart = cal.startOfDay(for: now)
                let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)
                    ?? todayStart.addingTimeInterval(-86_400)
                let yesterdayLastHour = cal.date(byAdding: .hour, value: 23, to: yesterdayStart)
                    ?? todayStart.addingTimeInterval(-3600)
                return .init(from: yesterdayStart, to: yesterdayLastHour)
            case .last24h:
                // Rolling 24 hourly buckets: [currentHour - 23h,
                // currentHour] inclusive. Matches
                // `SessionFilter.DateRange.last24h.resolveBounds()`'s
                // (now - 24h, now) semantic, snapped to hour boundaries.
                let currentHour = cal.dateInterval(of: .hour, for: now)?.start ?? now
                let start = cal.date(byAdding: .hour, value: -23, to: currentHour)
                    ?? currentHour.addingTimeInterval(-23 * 3600)
                return .init(from: start, to: currentHour)
            case .thisWeek:
                let comps = cal.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear], from: now)
                let start = cal.date(from: comps) ?? cal.startOfDay(for: now)
                let end = cal.startOfDay(for: now)
                return .init(from: cal.startOfDay(for: start), to: end)
            case .last30days:
                let start = cal.startOfDay(
                    for: now.addingTimeInterval(-30 * 24 * 3600))
                let end = cal.startOfDay(for: now)
                return .init(from: start, to: end)
            case .custom:
                // Bounds depend on the user's From/To pickers, which the
                // enum can't see — `ReportsView.effectiveZeroFillRange`
                // supplies them.
                return nil
            }
        }
    }
}

enum ReportsSkillMetrics {
    static func rows(
        turnsBySession: [String: [Turn]],
        provider: ProviderKind,
        knownCodexSkillNames: Set<String>? = nil,
        turnTimestampRange: ClosedRange<Date>? = nil
    ) -> [CostAnalyzer.SkillSummary] {
        CostAnalyzer.bySkill(
            turnsBySession,
            provider: provider,
            knownCodexSkillNames: provider == .codex ? knownCodexSkillNames : nil,
            turnTimestampRange: turnTimestampRange
        )
    }

    static func invocationCount(
        turnsBySession: [String: [Turn]],
        provider: ProviderKind,
        knownCodexSkillNames: Set<String>? = nil,
        turnTimestampRange: ClosedRange<Date>? = nil
    ) -> Int {
        var count = 0
        let effectiveKnownCodexSkillNames = provider == .codex ? knownCodexSkillNames : nil
        for (_, turns) in turnsBySession {
            for turn in turns {
                if let range = turnTimestampRange {
                    guard let start = turn.startTime,
                          range.contains(start)
                    else { continue }
                }
                guard let text = turn.promptStep?.text,
                      CostAnalyzer.extractSkillName(
                        from: text,
                        provider: provider,
                        knownCodexSkillNames: effectiveKnownCodexSkillNames
                      ) != nil
                else { continue }
                count += 1
            }
        }
        return count
    }

    static func footerSummary(
        for rows: [CostAnalyzer.SkillSummary]
    ) -> (totalCostUSD: Double, invocationCount: Int) {
        rows.reduce(into: (totalCostUSD: 0, invocationCount: 0)) { partial, row in
            partial.totalCostUSD += row.totalCost.totalCostUSD
            partial.invocationCount += row.invocationCount
        }
    }

    static func commandPrefix(for provider: ProviderKind) -> String {
        CostAnalyzer.skillCommandPrefix(for: provider)
    }
}
