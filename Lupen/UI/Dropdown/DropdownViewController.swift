import AppKit
import Observation

final class DropdownViewController: NSViewController {

    private let store: AppStateStore

    private let headerTitleLabel = NSTextField(labelWithString: "Today")
    private let headerCostLabel = NSTextField(labelWithString: "")
    private let headerTokensLabel = NSTextField(labelWithString: "")

    private let requestContainer = NSView()
    private var requestRows: [NSView] = []

    private let footerDivider = NSBox()
    private let openDashboardButton = NSButton(title: "Open Dashboard", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit Lupen", target: nil, action: nil)

    /// Visible only when `diagnostics.hasAnyIssues`. Taps open the
    /// Parse Diagnostics window via `.openParseDiagnostics` notification.
    private let diagnosticsBanner = DiagnosticsBannerView()

    init(store: AppStateStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        self.view = container
        setupSubviews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshContent()
        startObserving()
        observeWallClockTicks()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Wall-clock tick subscription. Only refreshes when the popover is
    /// actually visible — `view.window == nil` means the popover isn't
    /// mounted, so the next `PanelController.show()` will call
    /// `refreshContent()` anyway and we'd just waste work.
    ///
    /// Selector-based — block-based observers can't be released via
    /// `removeObserver(self)` and would leak their closure.
    private func observeWallClockTicks() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWallClockTick(_:)),
            name: WallClockCoordinator.wallClockTick,
            object: nil
        )
    }

    @objc private func handleWallClockTick(_ note: Notification) {
        guard isViewLoaded, view.window != nil else { return }
        refreshContent()
    }

    private func startObserving() {
        withObservationTracking {
            _ = store.activeProvider
            _ = store.sessions
            _ = store.todayAggregateCost
            _ = store.todayAggregateTokens
            _ = store.diagnostics.errorCount
            _ = store.diagnostics.warningCount
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.refreshContent()
                self?.startObserving()
            }
        }
    }

    // MARK: - Setup

    private func setupSubviews() {
        headerTitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        headerTitleLabel.textColor = .secondaryLabelColor

        headerCostLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        headerCostLabel.textColor = .labelColor

        headerTokensLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        headerTokensLabel.textColor = .secondaryLabelColor

        footerDivider.boxType = .separator

        openDashboardButton.bezelStyle = .push
        openDashboardButton.controlSize = .large
        openDashboardButton.target = self
        openDashboardButton.action = #selector(openDashboardClicked)

        quitButton.bezelStyle = .accessoryBarAction
        quitButton.controlSize = .small
        quitButton.contentTintColor = .secondaryLabelColor
        quitButton.target = self
        quitButton.action = #selector(quitClicked)

        diagnosticsBanner.isHidden = true  // visibility driven by refreshContent()

        let allViews: [NSView] = [
            headerTitleLabel, headerCostLabel, headerTokensLabel,
            diagnosticsBanner,
            requestContainer,
            footerDivider, openDashboardButton, quitButton
        ]
        for v in allViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        let pad: CGFloat = 16
        NSLayoutConstraint.activate([
            headerTitleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: pad),
            headerTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),

            headerCostLabel.topAnchor.constraint(equalTo: headerTitleLabel.bottomAnchor, constant: 2),
            headerCostLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),

            headerTokensLabel.firstBaselineAnchor.constraint(equalTo: headerCostLabel.firstBaselineAnchor),
            headerTokensLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),

            // Diagnostics banner sits between header and requests. Hidden
            // via isHidden when clean — layout preserves space around it
            // by anchoring requestContainer to headerCostLabel, not the
            // banner itself.
            diagnosticsBanner.topAnchor.constraint(equalTo: headerCostLabel.bottomAnchor, constant: 10),
            diagnosticsBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            diagnosticsBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),

            requestContainer.topAnchor.constraint(equalTo: headerCostLabel.bottomAnchor, constant: 12),
            requestContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            requestContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            footerDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),

            openDashboardButton.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 10),
            openDashboardButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openDashboardButton.widthAnchor.constraint(equalToConstant: 200),

            quitButton.topAnchor.constraint(equalTo: openDashboardButton.bottomAnchor, constant: 6),
            quitButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            quitButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),

            footerDivider.topAnchor.constraint(equalTo: requestContainer.bottomAnchor, constant: 8),
        ])
    }

    // MARK: - Content

    func refreshContent() {
        headerTitleLabel.stringValue = "\(store.activeProvider.descriptor.displayName) Today"
        headerCostLabel.stringValue = CostFormatter.compact(store.todayAggregateCost)
        headerTokensLabel.stringValue = "\(CompactNumber.compact(store.todayAggregateTokens)) tokens"
        rebuildRequestRows()
        refreshDiagnosticsBanner()
    }

    private func refreshDiagnosticsBanner() {
        let errors = store.diagnostics.errorCount
        let warnings = store.diagnostics.warningCount
        let shouldShow = errors > 0 || warnings > 0
        diagnosticsBanner.isHidden = !shouldShow
        if shouldShow {
            diagnosticsBanner.configure(errors: errors, warnings: warnings)
        }
    }

    /// A group of API requests triggered by a single user prompt.
    private struct ConversationTurn {
        let prompt: String?
        let timestamp: Date
        let totalOutputTokens: Int
        let totalCost: Double?
        let requestCount: Int
    }

    private func rebuildRequestRows() {
        for row in requestRows { row.removeFromSuperview() }
        requestRows.removeAll()

        let turns = groupIntoTurns().prefix(5)

        if turns.isEmpty {
            let providerName = store.activeProvider.descriptor.displayName
            let label = NSTextField(labelWithString: "No \(providerName) requests today")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            requestContainer.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: requestContainer.centerXAnchor),
                label.topAnchor.constraint(equalTo: requestContainer.topAnchor, constant: 20),
                label.bottomAnchor.constraint(equalTo: requestContainer.bottomAnchor, constant: -20),
            ])
            requestRows.append(label)
            return
        }

        var previousBottom = requestContainer.topAnchor
        for turn in turns {
            let row = makeRow(turn)
            row.translatesAutoresizingMaskIntoConstraints = false
            requestContainer.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: previousBottom),
                row.leadingAnchor.constraint(equalTo: requestContainer.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: requestContainer.trailingAnchor),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
            previousBottom = row.bottomAnchor
            requestRows.append(row)
        }
        // Pin last row bottom
        if let last = requestRows.last {
            last.bottomAnchor.constraint(equalTo: requestContainer.bottomAnchor).isActive = true
        }
    }

    /// Today's turns straight from the SQLite index (plan 5.3): the
    /// turns table already IS the prompt-grouped view the legacy code
    /// reconstructed from request rows, and the shell sessions in
    /// `store.sessions` carry no requests to group.
    private func groupIntoTurns() -> [ConversationTurn] {
        guard let source = store.sqliteConversationSource else { return [] }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        guard let rows = try? source.store.recentTurns(since: startOfToday, limit: 5) else {
            return []
        }
        return rows.map { row in
            let prompt = row.promptPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cost = row.aggCostUSD ?? 0
            return ConversationTurn(
                prompt: (prompt?.isEmpty ?? true) ? nil : prompt,
                timestamp: row.endTime ?? row.startTime ?? startOfToday,
                totalOutputTokens: row.aggTokens.outputTokens + row.aggTokens.reasoningOutputTokens,
                totalCost: cost > 0 ? cost : nil,
                requestCount: 1
            )
        }
    }

    private func makeRow(_ turn: ConversationTurn) -> NSView {
        let row = NSView()

        let promptText = truncate(ImageSourceFormatter.cleanForDisplay(turn.prompt ?? "..."), max: 60)
        let prompt = NSTextField(labelWithString: promptText)
        prompt.font = .systemFont(ofSize: 12)
        prompt.textColor = .labelColor
        prompt.lineBreakMode = .byTruncatingTail
        prompt.maximumNumberOfLines = 1

        let timeText = RelativeTimeFormatter.compact(turn.timestamp)
        let subtitle = turn.requestCount > 1
            ? "\(timeText) · \(turn.requestCount) requests"
            : timeText
        let time = NSTextField(labelWithString: subtitle)
        time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        time.textColor = .tertiaryLabelColor

        let tokens = NSTextField(labelWithString: CompactNumber.compact(turn.totalOutputTokens))
        tokens.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        tokens.textColor = .secondaryLabelColor
        tokens.alignment = .right

        let cost = NSTextField(labelWithString: CostFormatter.compact(turn.totalCost))
        cost.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        cost.textColor = .secondaryLabelColor
        cost.alignment = .right

        for v in [prompt, time, tokens, cost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }

        let h: CGFloat = 16, v: CGFloat = 6
        NSLayoutConstraint.activate([
            prompt.topAnchor.constraint(equalTo: row.topAnchor, constant: v),
            prompt.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: h),
            prompt.trailingAnchor.constraint(lessThanOrEqualTo: tokens.leadingAnchor, constant: -8),

            time.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 1),
            time.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: h),
            time.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -v),

            tokens.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            tokens.widthAnchor.constraint(equalToConstant: 52),

            cost.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            cost.leadingAnchor.constraint(equalTo: tokens.trailingAnchor, constant: 4),
            cost.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -h),
            cost.widthAnchor.constraint(equalToConstant: 56),
        ])

        return row
    }

    private func truncate(_ text: String, max: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.count <= max ? cleaned : String(cleaned.prefix(max)) + "..."
    }

    @objc private func openDashboardClicked() {
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
