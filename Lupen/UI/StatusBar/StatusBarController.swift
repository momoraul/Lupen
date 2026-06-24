import AppKit
import Observation

/// Manages NSStatusItem in the menubar.
/// Displays the two-lens binocular glyph + **today's total cost in
/// USD** (e.g. `$3.47`). Cost is the single headline number most
/// developers care about hour-to-hour; tokens were the v1 choice but
/// users consistently wanted to read dollars at a glance. Auto-
/// refreshes when AppStateStore changes via withObservationTracking.
@MainActor
final class StatusBarController {

    struct CostDisplayState: Equatable {
        let costText: String?
        let showsPlaceholder: Bool
    }

    private let statusItem: NSStatusItem
    private let store: AppStateStore
    private let settings: AppSettings
    private let rateLimitSampleStore: RateLimitSampleStore
    private var onButtonClick: ((NSStatusBarButton) -> Void)?

    var button: NSStatusBarButton? { statusItem.button }

    init(store: AppStateStore,
         settings: AppSettings,
         rateLimitSampleStore: RateLimitSampleStore) {
        self.store = store
        self.settings = settings
        self.rateLimitSampleStore = rateLimitSampleStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        startObserving()
        observeWallClockTicks()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setClickHandler(_ handler: @escaping (NSStatusBarButton) -> Void) {
        self.onButtonClick = handler
    }

    // MARK: - Button Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }

        // The icon now travels *inside* `attributedTitle` via an
        // `NSTextAttachment`. Setting `button.image` separately would
        // produce a duplicate glyph and reintroduce the inter-element
        // gap this class is trying to eliminate.
        button.image = nil
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseDown])  // React on mouse down, not mouse up

        applyAttributedTitle()
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        LoggerService.shared.info(
            "Menu bar icon clicked — NSApp.isActive=\(NSApp.isActive)",
            context: "StatusBar"
        )
        onButtonClick?(sender)
    }

    // MARK: - Observation

    private func startObserving() {
        withObservationTracking {
            _ = store.todayAggregateCost
            _ = store.hasInitialData
            // Initial-backfill placeholder: re-render when the full rebuild
            // starts and when it settles, so the cost flips placeholder ⇄
            // number on the same tick. `isInitialBackfill` reads these.
            _ = store.didRebuildThisLaunch
            _ = store.hasCompletedInitialIndex
            _ = store.launchProgress.phase
            _ = store.activeProvider
            _ = store.isRenderingActiveProviderSessions
            // 6.13 `$0` idle state gates on "any indexed sessions" —
            // re-render when the first shell projection lands so a fresh
            // install flips from icon-only to the dimmed zero.
            _ = store.sessions.isEmpty
            // Badge re-render: track the exact flags the composer consumes.
            _ = store.diagnostics.errorCount
            _ = store.diagnostics.warningCount
            // Preferences toggle — the menu-bar cost can be hidden by
            // the user. Tracking this property here means the title
            // updates immediately when the Preferences toggle flips.
            _ = settings.showTodayCostInMenuBar
            _ = settings.activeProvider
            // Compact-currency toggle — flipping in Preferences must
            // re-render the digit run on the same run-loop tick.
            _ = settings.compactCurrencyInMenuBar
            // Badge visibility toggles. Flipping either in Preferences
            // should retire / reveal the icon overlay on the very next
            // run-loop tick instead of waiting for the next diagnostic
            // event.
            _ = settings.showParseWarningBadge
            _ = settings.showParseErrorBadge
            // 5-hour-limit usage drives the ring tint. Reading
            // `.samples.last` here means a new statusline sample
            // re-tints the binocular icon on the same run-loop tick.
            _ = rateLimitSampleStore.samples.last?.fiveHour?.usedPercentage
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.applyAttributedTitle()
                self?.startObserving()
            }
        }
    }

    /// Wall-clock tick subscription. The today cost depends on
    /// `Calendar.isDateInToday`; without this, a quiet overnight (no new
    /// FSEvents) would leave yesterday's total frozen in the menu bar.
    /// Refresh cost is one computed-property read + one label update —
    /// once per hour, plus midnight crossings.
    ///
    /// Selector-based — block-based observers can't be released via
    /// `removeObserver(self)` and would leak their closure into
    /// `NotificationCenter` for the app's lifetime.
    private func observeWallClockTicks() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWallClockTick(_:)),
            name: WallClockCoordinator.wallClockTick,
            object: nil
        )
    }

    @objc private func handleWallClockTick(_ note: Notification) {
        applyAttributedTitle()
    }

    /// Single re-render path. Resolves both severities (parse + limit),
    /// chooses the cost-text variant, and assigns one `attributedTitle`
    /// + matching tooltip. Inlining the previous `updateButtonTitle` +
    /// `updateBadge` split is intentional: the icon and the digits are
    /// now one attributed run, so they must update atomically to avoid
    /// transient mismatched-tint frames.
    private func applyAttributedTitle() {
        guard let button = statusItem.button else { return }

        // Parse-diagnostics badge — gated by independent Preferences
        // toggles. Errors outrank warnings (red dot is louder).
        let badge: StatusBarIconComposer.BadgeSeverity
        let activeProvider = settings.activeProvider
        let providerMatchesRenderedData = store.activeProvider == activeProvider
            && store.isRenderingActiveProviderSessions
        let rendersClaudeData = activeProvider == .claudeCode

        badge = Self.diagnosticBadge(
            hasErrors: store.diagnostics.hasErrors,
            hasWarnings: store.diagnostics.hasWarnings,
            showErrors: settings.showParseErrorBadge,
            showWarnings: settings.showParseWarningBadge,
            providerMatchesRenderedData: providerMatchesRenderedData
        )

        // 5-hour-limit ring tint. `nil` percentage (API-key user with
        // no `fiveHour` window in payload) resolves to `.normal` via
        // `LimitSeverity.from`.
        let limit: StatusBarIconComposer.LimitSeverity = rendersClaudeData
            ? StatusBarIconComposer.LimitSeverity.from(
                usedPercentage: rateLimitSampleStore.samples.last?.fiveHour?.usedPercentage
            )
            : .normal

        // Cost text variant. The placeholder appears only during true
        // cold start (no index rows yet). On warm launches the
        // SQLite-first driver flips `hasInitialData` at the first shell
        // projection so the menu bar shows real numbers immediately
        // while background imports continue.
        let costDisplay = Self.costDisplayState(
            showTodayCostInMenuBar: settings.showTodayCostInMenuBar,
            hasInitialData: store.hasInitialData,
            providerMatchesRenderedData: providerMatchesRenderedData,
            cost: store.todayAggregateCost,
            compactCurrency: settings.compactCurrencyInMenuBar,
            todayUsagePending: store.isTodayUsagePending,
            hasIndexedSessions: !store.sessions.isEmpty,
            isInitialBackfill: store.isInitialBackfill
        )

        let composed = StatusBarAttributedTitle.compose(
            costText: costDisplay.costText,
            placeholder: costDisplay.showsPlaceholder,
            badge: badge,
            limit: limit
        )
        button.attributedTitle = composed.title
        button.toolTip = composed.toolTip ?? "Lupen · \(activeProvider.descriptor.displayName) mode"
    }

    static func costDisplayState(
        showTodayCostInMenuBar: Bool,
        hasInitialData: Bool,
        providerMatchesRenderedData: Bool,
        cost: Double,
        compactCurrency: Bool,
        todayUsagePending: Bool = false,
        hasIndexedSessions: Bool = false,
        isInitialBackfill: Bool = false
    ) -> CostDisplayState {
        guard showTodayCostInMenuBar else {
            return CostDisplayState(costText: nil, showsPlaceholder: false)
        }
        // A schema-bump rebuild (or first run) is backfilling the whole
        // corpus; even with shells loaded (`hasInitialData`) today's total is
        // still partial and would climb as history lands. Show the placeholder
        // so a mid-rebuild number isn't read as final. Latched to the initial
        // backfill only — ordinary incremental imports keep the live number
        // (no per-file flicker).
        guard !isInitialBackfill else {
            return CostDisplayState(costText: nil, showsPlaceholder: true)
        }
        guard hasInitialData else {
            return CostDisplayState(costText: nil, showsPlaceholder: true)
        }
        // Coverage-aware placeholder (plan 3.3): today's sources are
        // still importing — "..." beats a silently undercounted number.
        guard !todayUsagePending else {
            return CostDisplayState(costText: nil, showsPlaceholder: true)
        }
        guard providerMatchesRenderedData else {
            return CostDisplayState(costText: nil, showsPlaceholder: false)
        }
        guard cost > 0 else {
            // Idle day (6.13): a visible "$0" confirms the app is
            // alive and tracking — a bare icon is ambiguous between
            // "nothing spent" and "not working". Gated on the provider
            // having ANY indexed sessions so a fresh install stays
            // icon-only instead of advertising a meaningless zero.
            // Deliberately NOT the shared formatters: compact(0) says
            // "<$0.001" and compactWhole(0) says "<$1" — both assert
            // sub-precision spend that didn't happen.
            guard hasIndexedSessions else {
                return CostDisplayState(costText: nil, showsPlaceholder: false)
            }
            return CostDisplayState(
                costText: "$0",
                showsPlaceholder: false
            )
        }
        let costText = compactCurrency
            ? CostFormatter.compactWhole(cost)
            : CostFormatter.compact(cost)
        return CostDisplayState(costText: costText, showsPlaceholder: false)
    }

    static func diagnosticBadge(
        hasErrors: Bool,
        hasWarnings: Bool,
        showErrors: Bool,
        showWarnings: Bool,
        providerMatchesRenderedData: Bool
    ) -> StatusBarIconComposer.BadgeSeverity {
        guard providerMatchesRenderedData else { return .none }
        if hasErrors, showErrors {
            return .error
        }
        if hasWarnings, showWarnings {
            return .warning
        }
        return .none
    }
}
