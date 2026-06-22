import AppKit

/// Verify Costs main view controller. AppKit (`NSTableView` with
/// `NSSortDescriptor`-based sorting). Uses `GroundTruthVerifier` via
/// `AppStateStore.verifyActiveProviderUsage` to compare the live
/// provider view against an independent JSONL re-scan.
@MainActor
final class VerifyCostsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let store: AppStateStore

    /// Severity-based result filter for the table. `all` shows every row;
    /// `warningsAndErrors` hides clean rows (the old "show only mismatches");
    /// `errors` shows only accounting drift. Pending rows stay visible under
    /// every filter — they're unresolved attention items, not clean rows.
    enum FilterLevel: Int, CaseIterable {
        case all
        case warningsAndErrors
        case errors

        /// Short segment label. The "Warnings" tab also includes errors —
        /// spelled out in `tooltip` to keep the control compact.
        var label: String {
            switch self {
            case .all: return "All"
            case .warningsAndErrors: return "Warnings"
            case .errors: return "Errors"
            }
        }

        /// Hover tooltip clarifying what each segment surfaces.
        var tooltip: String {
            switch self {
            case .all: return "Show every session"
            case .warningsAndErrors: return "Show sessions with warnings or errors"
            case .errors: return "Show only sessions with errors"
            }
        }
    }

    // State
    private var result: VerifyCostsResult?
    private var rollups: [VerifyCostsResult.SessionRollup] = []
    private var filtered: [VerifyCostsResult.SessionRollup] = []
    private var filterLevel: FilterLevel = .all
    private var isRunning: Bool = false

    // UI
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let filterControl = NSSegmentedControl(
        labels: FilterLevel.allCases.map(\.label),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let tableView = NSTableView()
    private let detailTextView = NSTextView()

    init(store: AppStateStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 560))
        view.wantsLayer = true
        statusLabel.stringValue = idleStatusText(for: store.activeProvider)

        // MARK: Toolbar strip
        runButton.bezelStyle = .push
        runButton.controlSize = .large
        runButton.keyEquivalent = "\r"
        runButton.target = self
        runButton.action = #selector(runTapped)

        // Serialises the visible rollups + divergence details as a
        // Markdown report for pasting into chat / issue trackers.
        copyButton.bezelStyle = .push
        copyButton.controlSize = .regular
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.isEnabled = false
        copyButton.toolTip = "Copy visible results (Markdown) to clipboard"

        filterControl.target = self
        filterControl.action = #selector(filterLevelChanged)
        filterControl.segmentStyle = .rounded
        filterControl.selectedSegment = filterLevel.rawValue
        for level in FilterLevel.allCases {
            filterControl.setToolTip(level.tooltip, forSegment: level.rawValue)
        }

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        summaryLabel.textColor = .labelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let toolbarStack = NSStackView(views: [runButton, copyButton, progressIndicator, statusLabel, NSView(), filterControl, summaryLabel])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 10
        toolbarStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        // Push the right-side mismatches/summary group to the trailing edge.
        toolbarStack.setHuggingPriority(.defaultHigh, for: .horizontal)

        // "Results are preliminary" banner while the index is still building —
        // collapses to zero height when idle (intrinsic-content sizing).
        let indexingBanner = IndexingStatusHostingView(store: store, style: .banner)
        view.addSubview(indexingBanner)
        view.addSubview(toolbarStack)

        configureTable()
        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.borderType = .noBorder
        tableScroll.autohidesScrollers = true
        view.addSubview(tableScroll)

        configureDetailTextView()
        let detailScroll = NSScrollView()
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = detailTextView
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .noBorder
        view.addSubview(detailScroll)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        NSLayoutConstraint.activate([
            indexingBanner.topAnchor.constraint(equalTo: view.topAnchor),
            indexingBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            indexingBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbarStack.topAnchor.constraint(equalTo: indexingBanner.bottomAnchor),
            toolbarStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tableScroll.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableScroll.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.55),

            divider.topAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            detailScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private enum Column: String, CaseIterable {
        case sessionId, rawLines, dedupLines, viewRequests, truthCost, viewCost, delta, match

        var title: String {
            switch self {
            case .sessionId: return "Session"
            case .rawLines: return "Raw"
            case .dedupLines: return "Dedup"
            case .viewRequests: return "View"
            case .truthCost: return "Truth $"
            case .viewCost: return "View $"
            case .delta: return "Δ"
            case .match: return "Match"
            }
        }

        var width: CGFloat {
            switch self {
            case .sessionId: return 220
            case .rawLines, .dedupLines, .viewRequests: return 60
            case .truthCost, .viewCost: return 90
            case .delta: return 80
            case .match: return 60
            }
        }
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        for col in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = col.title
            c.width = col.width
            c.minWidth = col.width
            c.headerCell.alignment = (col == .sessionId) ? .left : .right
            c.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: col == .sessionId)
            tableView.addTableColumn(c)
        }
    }

    private func configureDetailTextView() {
        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailTextView.textContainerInset = NSSize(width: 16, height: 10)
        detailTextView.string = "(Select a session to see divergences.)"
        detailTextView.textColor = .secondaryLabelColor
        detailTextView.autoresizingMask = [.width]
    }

    @objc private func runTapped() {
        guard !isRunning else { return }
        isRunning = true
        runButton.isEnabled = false
        copyButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "Scanning \(store.activeProvider.descriptor.displayName) JSONL files independently…"
        summaryLabel.stringValue = ""
        detailTextView.string = ""
        tableView.deselectAll(nil)

        store.verifyActiveProviderUsage { [weak self] result in
            guard let self else { return }
            self.isRunning = false
            self.runButton.isEnabled = true
            self.progressIndicator.stopAnimation(nil)
            self.result = result
            self.rollups = result.rollups(withStore: self.store)
            self.applyFilter()
            self.updateSummary(for: result)
            self.tableView.reloadData()
            self.copyButton.isEnabled = !self.filtered.isEmpty
        }
    }

    @objc private func copyTapped() {
        guard let result else { return }
        let markdown = Self.buildMarkdownReport(
            result: result,
            rollups: filtered,
            filterLevel: filterLevel
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        // Momentary button feedback so the user knows the click landed
        // without having to switch focus to the clipboard.
        let original = copyButton.title
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.copyButton.title == "Copied" else { return }
            self.copyButton.title = original
        }
    }

    @objc private func filterLevelChanged() {
        filterLevel = FilterLevel(rawValue: filterControl.selectedSegment) ?? .all
        applyFilter()
        tableView.reloadData()
        // Copy reflects the currently visible rollups, so its enabled
        // state follows the filter's resulting row count.
        copyButton.isEnabled = result != nil && !filtered.isEmpty
    }

    private func applyFilter() {
        // Pending rows stay visible under every filter — they're unresolved
        // attention items, not clean rows.
        switch filterLevel {
        case .all:
            filtered = rollups
        case .warningsAndErrors:
            filtered = rollups.filter { !$0.matchesView || $0.indexPending }
        case .errors:
            filtered = rollups.filter { $0.hasError || $0.indexPending }
        }
    }

    private func updateSummary(for result: VerifyCostsResult) {
        let pending = rollups.filter(\.indexPending).count
        let errors = rollups.filter { $0.hasError && !$0.indexPending }.count
        let warnings = rollups.filter { $0.hasWarningsOnly && !$0.indexPending }.count
        let clean = rollups.count - errors - warnings - pending
        summaryLabel.stringValue = Self.summaryText(
            clean: clean, warnings: warnings, errors: errors, pending: pending, result: result
        )
        let shortName = result.provider.descriptor.shortDisplayName
        if errors == 0, warnings == 0, pending == 0 {
            statusLabel.stringValue = "All \(shortName) sessions match independent ground truth."
            statusLabel.textColor = .systemGreen
        } else if errors == 0 {
            // Only warnings (estimation limits) and/or pending — nothing drifted.
            var note = "No errors"
            if warnings > 0 { note += " — \(warnings) warning(s)" }
            if pending > 0 { note += "\(warnings > 0 ? "," : " —") \(pending) still indexing" }
            statusLabel.stringValue = note + "."
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "\(errors) \(shortName) session(s) differ from independent ground truth."
            statusLabel.textColor = .systemOrange
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn,
              let col = Column(rawValue: column.identifier.rawValue),
              row < filtered.count else {
            return nil
        }
        let rollup = filtered[row]
        let cell = tableCellView(for: col, rollup: rollup)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first else { return }
        applySort(sort)
        tableView.reloadData()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count, let result else {
            detailTextView.string = ""
            return
        }
        let rollup = filtered[row]
        let sessionDivs = result.divergences.filter { $0.sessionId == rollup.sessionId }
        if rollup.indexPending {
            detailTextView.string = "Session \(rollup.sessionId) is still being indexed — "
                + "comparisons are skipped until its import completes. Re-run afterwards."
        } else if sessionDivs.isEmpty {
            detailTextView.string = "Session \(rollup.sessionId) matches ground truth — no divergences."
        } else {
            var lines: [String] = [
                "Session \(rollup.sessionId)",
                Self.detailUsageLine(for: rollup, provider: result.provider),
                Self.detailCostLine(for: rollup, provider: result.provider),
                "",
                "Divergences (\(sessionDivs.count)):"
            ]
            // Cap displayed lines so a 10k-entry session doesn't drown the pane.
            let cap = 200
            for d in sessionDivs.prefix(cap) {
                lines.append("  · \(d.humanDescription)")
            }
            if sessionDivs.count > cap {
                lines.append("  … \(sessionDivs.count - cap) more")
            }
            detailTextView.string = lines.joined(separator: "\n")
        }
    }

    private func tableCellView(for col: Column, rollup: VerifyCostsResult.SessionRollup) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        switch col {
        case .sessionId:
            label.stringValue = rollup.sessionId
            label.alignment = .left
        case .rawLines:
            label.stringValue = String(rollup.rawLineCount)
            label.alignment = .right
        case .dedupLines:
            label.stringValue = String(rollup.dedupedLineCount)
            label.alignment = .right
        case .viewRequests:
            label.stringValue = rollup.viewRequestCount.map(String.init) ?? "—"
            label.alignment = .right
        case .truthCost:
            label.stringValue = String(format: "$%.4f", rollup.truthCostUSD)
            label.alignment = .right
        case .viewCost:
            label.stringValue = rollup.viewCostUSD.map { String(format: "$%.4f", $0) } ?? "—"
            label.alignment = .right
        case .delta:
            let (text, isMeaningful) = Self.formatDeltaForDisplay(rollup.costDelta)
            label.stringValue = text
            if !isMeaningful {
                // Below the 4-decimal display precision — render as a
                // neutral em-dash in tertiary tint instead of the
                // misleading "$+0.0000" / "$-0.0000" that exposed
                // float sign noise on perfectly-matched rows.
                label.textColor = .tertiaryLabelColor
            } else if abs(rollup.costDelta ?? 0) > 0.001 {
                label.textColor = .systemRed
            }
            label.alignment = .right
        case .match:
            label.alignment = .center
            if rollup.indexPending {
                label.stringValue = "⋯ indexing"
                label.textColor = .secondaryLabelColor
            } else if rollup.hasError {
                label.stringValue = "✗ \(rollup.errorCount)"
                label.textColor = .systemRed
            } else if rollup.hasWarningsOnly {
                label.stringValue = "⚠ \(rollup.warningCount)"
                label.textColor = .systemOrange
            } else {
                label.stringValue = "✓"
                label.textColor = .systemGreen
            }
        }

        return cell
    }

    private func applySort(_ sort: NSSortDescriptor) {
        guard let key = sort.key, let col = Column(rawValue: key) else { return }
        let asc = sort.ascending
        rollups.sort { a, b in
            switch col {
            case .sessionId:
                return asc ? (a.sessionId < b.sessionId) : (a.sessionId > b.sessionId)
            case .rawLines:
                return asc ? (a.rawLineCount < b.rawLineCount) : (a.rawLineCount > b.rawLineCount)
            case .dedupLines:
                return asc ? (a.dedupedLineCount < b.dedupedLineCount) : (a.dedupedLineCount > b.dedupedLineCount)
            case .viewRequests:
                let av = a.viewRequestCount ?? -1
                let bv = b.viewRequestCount ?? -1
                return asc ? (av < bv) : (av > bv)
            case .truthCost:
                return asc ? (a.truthCostUSD < b.truthCostUSD) : (a.truthCostUSD > b.truthCostUSD)
            case .viewCost:
                let av = a.viewCostUSD ?? -1
                let bv = b.viewCostUSD ?? -1
                return asc ? (av < bv) : (av > bv)
            case .delta:
                let av = a.costDelta.map { abs($0) } ?? -1
                let bv = b.costDelta.map { abs($0) } ?? -1
                return asc ? (av < bv) : (av > bv)
            case .match:
                return asc ? (!a.matchesView && b.matchesView) : (a.matchesView && !b.matchesView)
            }
        }
        applyFilter()
    }

    /// Formats a cost delta for the Δ column / Markdown report.
    /// Returns an em-dash for nil (session missing in view) and for
    /// values that round to zero at the 4-decimal display precision —
    /// otherwise the table would fill with `$+0.0000` / `$-0.0000`
    /// rows where the sign is just float noise from accumulator drift.
    /// `isMeaningful` lets the caller dim the cell so the eye skips it.
    ///
    /// The 0.00005 threshold matches `String(format: "$%.4f", x)`'s
    /// own rounding boundary — anything below it prints as `0.0000`
    /// regardless, so collapsing to em-dash loses no information.
    nonisolated static func formatDeltaForDisplay(
        _ delta: Double?
    ) -> (text: String, isMeaningful: Bool) {
        guard let d = delta else { return ("—", false) }
        if abs(d) < 0.00005 { return ("—", false) }
        return (String(format: "$%+.4f", d), true)
    }

    nonisolated static func buildMarkdownReport(
        result: VerifyCostsResult,
        rollups: [VerifyCostsResult.SessionRollup],
        filterLevel: FilterLevel
    ) -> String {
        let pending = rollups.filter(\.indexPending).count
        let errors = rollups.filter { $0.hasError && !$0.indexPending }.count
        let warnings = rollups.filter { $0.hasWarningsOnly && !$0.indexPending }.count
        let clean = rollups.count - errors - warnings - pending
        var out: [String] = []
        out.append("# \(Self.reportTitle(for: result.provider))")
        out.append("")
        out.append("Provider: \(result.provider.descriptor.displayName)")
        out.append("")
        out.append(Self.summaryText(clean: clean, warnings: warnings, errors: errors, pending: pending, result: result))
        if result.provider == .codex {
            out.append("")
            out.append("Codex cost note: dollar totals are estimated from local token counts and Lupen's pricing table. Unknown-pricing usage remains visible, but its dollar cost is not included.")
        }
        if filterLevel != .all {
            out.append("")
            out.append("_Filter: \(filterLevel.label) shown below._")
        }
        out.append("")
        if result.provider == .codex {
            Self.appendCodexUsageTable(to: &out, rollups: rollups)
        } else {
            Self.appendClaudeCostTable(to: &out, rollups: rollups)
        }

        // Per-row divergence detail mirrors the detail-pane layout so a
        // paste round-trips the information needed to localise drift.
        // Fenced code blocks keep the monospaced layout intact across
        // chat renderers.
        let bySession = Dictionary(grouping: result.divergences, by: { $0.sessionId })
        let rowsWithDivergences = rollups.filter { !$0.matchesView && !$0.indexPending }
        if !rowsWithDivergences.isEmpty {
            out.append("")
            out.append("## Divergences")
            for r in rowsWithDivergences {
                let divs = bySession[r.sessionId] ?? []
                out.append("")
                out.append("### \(r.sessionId)")
                out.append("")
                out.append("```")
                out.append(Self.detailUsageLine(for: r, provider: result.provider))
                out.append(Self.detailCostLine(for: r, provider: result.provider))
                if divs.isEmpty {
                    out.append("(no line-level divergences — cost mismatch only)")
                } else {
                    let cap = 200
                    out.append("Divergences (\(divs.count)):")
                    for d in divs.prefix(cap) {
                        out.append("  · \(d.humanDescription)")
                    }
                    if divs.count > cap {
                        out.append("  … \(divs.count - cap) more")
                    }
                }
                out.append("```")
            }
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    nonisolated static func summaryText(
        clean: Int,
        warnings: Int,
        errors: Int,
        pending: Int = 0,
        result: VerifyCostsResult
    ) -> String {
        var counts = "Clean \(clean)"
        if warnings > 0 { counts += " · Warning \(warnings)" }
        counts += " · Error \(errors)"
        if pending > 0 { counts += " · Pending \(pending)" }
        var parts = [
            counts + String(
                format: " · Scan %.1fs · Verify %.2fs",
                result.scanElapsed, result.verifyElapsed
            )
        ]
        if result.provider == .codex {
            parts.append("Unknown pricing \(result.unknownPricingIssueCount)")
        }
        if result.missingUsageIssueCount > 0 {
            parts.append("Missing usage \(result.missingUsageIssueCount)")
        }
        if result.sourceRejectedIssueCount > 0 {
            parts.append("Rejected sources \(result.sourceRejectedIssueCount)")
        }
        if result.parserRejectedIssueCount > 0 {
            parts.append("Parser issues \(result.parserRejectedIssueCount)")
        }
        return parts.joined(separator: " · ")
    }

    nonisolated private static func appendClaudeCostTable(
        to out: inout [String],
        rollups: [VerifyCostsResult.SessionRollup]
    ) {
        out.append("| Session | Raw | Dedup | View | Truth $ | View $ | Δ | Match |")
        out.append("|---|---:|---:|---:|---:|---:|---:|:---:|")
        for r in rollups {
            let view = r.viewRequestCount.map(String.init) ?? "—"
            let viewCost = r.viewCostUSD.map { String(format: "$%.4f", $0) } ?? "—"
            let delta = Self.formatDeltaForDisplay(r.costDelta).text
            // Pending mirrors the table's "⋯ indexing" — a bare ✓ on a
            // skipped session read as "verified clean" in the export.
            let match = Self.matchCell(for: r)
            out.append(
                "| \(r.sessionId) | \(r.rawLineCount) | \(r.dedupedLineCount) | \(view) | "
                + String(format: "$%.4f", r.truthCostUSD)
                + " | \(viewCost) | \(delta) | \(match) |"
            )
        }
    }

    nonisolated private static func appendCodexUsageTable(
        to out: inout [String],
        rollups: [VerifyCostsResult.SessionRollup]
    ) {
        out.append("| Session | Raw | Dedup | App | Input | Cached | Output | Reasoning | Est. Cost | App Est. Cost | Δ | Status |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|")
        for r in rollups {
            let app = r.viewRequestCount.map(String.init) ?? "—"
            let truthCost = Self.formatCodexCost(r.truthCostUSD, hasUnknownPricing: r.hasUnknownPricing)
            let viewCost = Self.formatCodexCost(r.viewCostUSD, hasUnknownPricing: r.hasUnknownPricing)
            let delta = r.hasUnknownPricing ? "N/A" : Self.formatDeltaForDisplay(r.costDelta).text
            let status = Self.codexStatusText(for: r)
            out.append(
                "| \(r.sessionId) | \(r.rawLineCount) | \(r.dedupedLineCount) | \(app) | "
                + "\(r.truthInputTokens) | \(r.truthCacheReadInputTokens) | \(r.truthOutputTokens) | \(r.truthReasoningOutputTokens) | "
                + "\(truthCost) | \(viewCost) | \(delta) | \(status) |"
            )
        }
    }

    nonisolated private static func detailUsageLine(
        for rollup: VerifyCostsResult.SessionRollup,
        provider: ProviderKind
    ) -> String {
        switch provider {
        case .claudeCode:
            return "raw=\(rollup.rawLineCount)  dedup=\(rollup.dedupedLineCount)  view=\(rollup.viewRequestCount.map(String.init) ?? "—")"
        case .codex:
            return "usage: raw=\(rollup.rawLineCount)  dedup=\(rollup.dedupedLineCount)  app=\(rollup.viewRequestCount.map(String.init) ?? "—")  input=\(rollup.truthInputTokens)  cached=\(rollup.truthCacheReadInputTokens)  output=\(rollup.truthOutputTokens)  reasoning=\(rollup.truthReasoningOutputTokens)"
        }
    }

    nonisolated private static func detailCostLine(
        for rollup: VerifyCostsResult.SessionRollup,
        provider: ProviderKind
    ) -> String {
        switch provider {
        case .claudeCode:
            return String(
                format: "cost: truth=$%.6f  view=%@  delta=%@",
                rollup.truthCostUSD,
                rollup.viewCostUSD.map { String(format: "$%.6f", $0) } ?? "—",
                rollup.costDelta.map { String(format: "$%+.6f", $0) } ?? "—"
            )
        case .codex:
            return "cost: estimate=\(Self.formatCodexCost(rollup.truthCostUSD, hasUnknownPricing: rollup.hasUnknownPricing))  app=\(Self.formatCodexCost(rollup.viewCostUSD, hasUnknownPricing: rollup.hasUnknownPricing))  delta=\(rollup.hasUnknownPricing ? "N/A" : Self.formatDeltaForDisplay(rollup.costDelta).text)"
        }
    }

    nonisolated private static func formatCodexCost(
        _ value: Double?,
        hasUnknownPricing: Bool
    ) -> String {
        guard !hasUnknownPricing else { return "N/A" }
        return value.map { String(format: "$%.4f", $0) } ?? "—"
    }

    /// 3-state cell for the Markdown "Match" column (Claude). Mirrors the
    /// table's ✓ / ⚠ / ✗ / pending rendering.
    nonisolated private static func matchCell(
        for rollup: VerifyCostsResult.SessionRollup
    ) -> String {
        if rollup.indexPending { return "⋯ indexing" }
        if rollup.matchesView { return "✓" }
        if rollup.hasError { return "✗ \(rollup.errorCount)" }
        return "⚠ \(rollup.warningCount)"
    }

    nonisolated private static func codexStatusText(
        for rollup: VerifyCostsResult.SessionRollup
    ) -> String {
        if rollup.indexPending { return "⋯ indexing" }
        if rollup.matchesView { return "✓" }
        if rollup.hasError { return "✗ \(rollup.errorCount)" }
        // Warnings only — unknown pricing is the common Codex case.
        if rollup.hasUnknownPricing {
            return "⚠ \(rollup.warningCount) pricing"
        }
        return "⚠ \(rollup.warningCount)"
    }

    private func idleStatusText(for provider: ProviderKind) -> String {
        "Click Run to verify \(provider.descriptor.shortDisplayName) usage."
    }

    nonisolated private static func reportTitle(for provider: ProviderKind) -> String {
        provider.verificationWindowTitle
    }
}
