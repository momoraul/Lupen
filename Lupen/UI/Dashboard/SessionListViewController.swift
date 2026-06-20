import AppKit
import Observation

private enum SidebarMetrics {
    static let horizontalInset: CGFloat = 12
    static let topInset: CGFloat = 10
    static let controlGap: CGFloat = 8
    static let providerHeight: CGFloat = 34
    static let searchHeight: CGFloat = 30
    static let filterButtonSize: CGFloat = 28
    static let searchTrailingReserve = filterButtonSize + controlGap + horizontalInset
    static let statusStripHeight: CGFloat = 34
    static let groupRowHeight: CGFloat = 24
    static let sessionRowHeight: CGFloat = 56
    static let branchedSessionRowHeight: CGFloat = 64
    static let loadMoreRowHeight: CGFloat = 28
}

/// Left sidebar: sessions grouped by project.
///
/// Renders with `NSOutlineView` in `.sourceList` style (Mail / Xcode Issue Navigator
/// idiom). Project headers are disclosure rows; individual sessions are the
/// leaves and the only selectable rows.
///
/// Ordering rules come from `SessionGrouping.groupByProject` — group order by
/// most-recent session DESC, Unknown group pinned to the bottom.
@MainActor
final class SessionListViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSPopoverDelegate {

    private let store: AppStateStore
    private let settings: AppSettings
    private let automaticSessionSelectionEnabled: Bool
    private let providerModeControl = ProviderModePopupButton(frame: .zero, pullsDown: false)
    private let searchField = NSSearchField()
    /// SF-Symbol-only button sitting to the right of the search field.
    /// Presents `FilterPopoverViewController` when clicked. Its icon
    /// toggles between outline and filled variants depending on
    /// `currentFilter.hasStructuredFilters`, so the user can tell at a
    /// glance whether a popover filter is applied.
    private let filterButton = NSButton()
    private let codexLoadSummaryView = CodexLoadSummaryPanel()
    private var codexLoadSummaryHeightConstraint: NSLayoutConstraint?
    /// Weak handle to the currently-open filter popover, if any, so
    /// repeated clicks toggle the popover closed instead of stacking a
    /// new one on top. Cleared on popover dismiss via the delegate
    /// callback — but we also defensively check `isShown` in the click
    /// handler in case the delegate hasn't fired yet.
    private var activeFilterPopover: NSPopover?
    private let outlineView = SessionListOutlineView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSView()
    private let emptyProgressIndicator = NSProgressIndicator()
    private let emptyImageView = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "")
    private let emptySubtitleLabel = NSTextField(labelWithString: "")

    var onSessionSelected: ((Session) -> Void)?
    var onSelectionCleared: (() -> Void)?
    /// Fired after the search-field debounce commits a new query
    /// value. `DashboardSplitViewController` forwards this to
    /// `TurnOutlineViewController.setHighlightQuery` so matching
    /// Turn rows in the conversation pane get a background tint.
    var onHighlightQueryChanged: ((String) -> Void)?

    /// Grouped nodes currently displayed. Top-level items are project headers
    /// (`.projectGroup`); their children are `.session` leaves.
    private var rootNodes: [SessionListNode] = []
    /// Flat lookup to re-find a session node after a reload.
    private var sessionNodesById: [String: SessionListNode] = [:]
    /// Last selected session per provider mode. Provider switches should
    /// restore the relevant context instead of clearing the conversation
    /// pane and waiting for the user to click a row again.
    private var selectedSessionIdByProvider: [ProviderKind: String] = [:]
    /// Provider switch target whose data was not visible yet when the mode
    /// changed. The next reload with rows for that provider auto-selects a
    /// session so the right pane recovers without another user click.
    private var pendingAutoSelectProvider: ProviderKind?
    /// Project keys currently expanded.
    ///
    /// On first launch (no persisted state) this defaults to empty — groups
    /// start collapsed and only the group containing the auto-selected first
    /// session (via `selectFirstSessionIfNeeded`) gets opened. On subsequent
    /// launches we rehydrate from `expandedGroupsStorage`, so the user's last
    /// expand/collapse shape is what they see. Any mutation must fan out to
    /// `scheduleSaveExpandedState()` so the persisted copy stays in sync.
    private var expandedProjectKeys: Set<String> = []
    /// Debounced JSON persistence for `expandedProjectKeys`. Kept as a
    /// free-standing helper struct (not MainActor) so the I/O is trivially
    /// unit-testable; the debouncing state lives here in the VC where the
    /// click lifecycle is.
    private let expandedGroupsStorage: ExpandedGroupsStorage
    /// Owns the `cd … && claude --resume` launch path. One instance per
    /// VC is fine — it holds no state, just the injected projects dir.
    private let sessionResumer = SessionResumer()
    /// Active filter applied to `store.sessions` before grouping. A
    /// default-empty filter is the "show everything" state — the store's
    /// `filteredSessions(_:)` short-circuits past every predicate in that
    /// case, so an empty filter has zero runtime cost compared to the
    /// pre-filter code path.
    private var currentFilter: SessionFilter = SessionFilter()
    /// Outstanding debounced search-text update. Cancel-and-reschedule on
    /// each keystroke so typing coalesces into a single filter change +
    /// reloadData after the user settles (300ms — same cadence as the
    /// expand-persistence save, and short enough that typing feels live).
    private var pendingFilterUpdate: DispatchWorkItem?
    /// Debounce window for `scheduleFilterUpdate`. 300ms feels live for
    /// keystroke feedback without rebuilding the sidebar on every
    /// character of a fast-typed multi-word query.
    private static let filterDebounce: TimeInterval = 0.3
    /// Outstanding debounced save, if any. Cancel-and-reschedule on each
    /// expand/collapse so rapid toggling coalesces into a single write.
    private var pendingExpandedSave: DispatchWorkItem?
    /// One-shot timer scheduled to fire a reload at the moment the active
    /// session's green dot should disappear (`lastAppend + idleThreshold`).
    /// Without this, the dot would persist until the next unrelated
    /// observation fire — there's no @Observable mutation that happens
    /// purely from the clock advancing. Cancel-and-reschedule on every
    /// reload so a fresh append pushes the window forward cleanly.
    private var pendingActiveDotInvalidation: DispatchWorkItem?
    /// Debounce window for `scheduleSaveExpandedState`. Long enough that a
    /// fast "expand → collapse → expand" triple-click writes once, short
    /// enough that the on-disk copy doesn't feel stale if the user quits
    /// shortly after toggling.
    private static let expandedSaveDebounce: TimeInterval = 0.3
    /// Per-project "how many sessions are visible in this group right now"
    /// window. Missing key ⇒ default (`pageSize`). "Show 5 more" clicks bump
    /// the value; we intentionally keep the window after a collapse so the
    /// user's explicit expand isn't silently thrown away.
    private var visibleCountByProject: [String: Int] = [:]
    /// Per-project "is the zero-cost hidden bucket currently expanded".
    /// Missing ⇒ collapsed (default). In-memory only: hidden sessions start
    /// collapsed on every launch, mirroring the pagination window's first
    /// page. Part of `RenderSnapshot` so a toggle invalidates the guard.
    private var expandedHiddenByProject: Set<String> = []
    /// Page size for the per-group paginated list. Five keeps the sidebar
    /// compact — a "heavy" project day (50+ sessions) doesn't dominate the
    /// pane just because one group got unlucky activity bursts.
    private static let pageSize = 5
    /// Suppress delegate selection callbacks during programmatic reloads.
    private var isProgrammaticSelectionChange: Bool = false
    // Phase 8.3 appearance animation — DISABLED in the sidebar.
    // The "active streaming session" green dot (rendered in the
    // session cell) already conveys "this row has activity"; layering
    // a fade-in tint on top reads as redundant noise rather than a
    // useful cue. The conversation outline still uses the animation
    // (TurnOutlineViewController) where there's no equivalent
    // indicator. If a sidebar-level highlight is wanted later, prefer
    // a derived `Session.lastUpdate` flag over re-introducing the
    // coordinator here.
    /// Snapshot of the last successful render. Used to skip
    /// `outlineView.reloadData` when nothing the sidebar would draw has
    /// actually changed. Streaming JSONL appends fire the store's
    /// `@Observable` tracking ~once per line, and rebuilding the entire node
    /// tree + reloadData on every event was causing the sidebar to flicker
    /// and burn CPU.
    ///
    /// **CRITICAL**: this snapshot must include *every* piece of VC state the
    /// node tree depends on, not just `store.sessions`. The first version
    /// only fingerprinted (id, endTime) and silently swallowed
    /// `expandNextPage` — the user clicked "Show 5 more" and nothing
    /// happened because the snapshot looked unchanged. The second time the
    /// trap bit us was `title`: on cold launch, `store.firstTurn(in:)`
    /// returns nil for sessions whose Turns haven't been assembled yet, so
    /// `sessionTitle(for:)` falls through to the slug; when Turns stream in
    /// and observation fires, (id, endTime) is still identical, so the
    /// guard swallowed the reload and the sidebar stayed stuck on slugs
    /// until the user touched pagination. Keep this struct in lockstep with
    /// whatever `reloadData` actually reads — if you add a new cell input,
    /// add it here first.
    struct RenderSnapshot: Equatable {
        /// Per-session (id, endTime, title). endTime catches "session got new
        /// requests" without us having to compare the full `requests` array;
        /// title catches "first Turn assembled / preview text changed" which
        /// doesn't move endTime.
        var sessionFingerprints: [SessionFingerprint]
        /// Pagination window per project key. Required so "Show N more"
        /// clicks invalidate the snapshot automatically.
        var visibleCounts: [String: Int]
        /// Per-project "is the zero-cost hidden bucket expanded". Must be in
        /// the fingerprint so toggling it invalidates the guard and rebuilds
        /// the tree (otherwise the show/hide click would silently no-op).
        var hiddenExpanded: Set<String>
        /// Current filter applied to the session list. Must be in the
        /// fingerprint so a query change (or any other filter tweak)
        /// automatically invalidates the guard and forces a rebuild.
        /// Without this, typing in the search field would silently no-op
        /// the reload because `sessionFingerprints` only tracks the *raw*
        /// store sessions, not the subset the filter chose to render.
        var filter: SessionFilter
        /// Sidebar layout (grouped vs flat). Flipping this swaps the whole
        /// tree shape, so the guard has to invalidate unconditionally.
        var layoutMode: SessionListLayoutMode
        /// Active provider mode. Switching modes changes the entire
        /// visible data set, even before non-Claude parsers are active.
        var activeProvider: ProviderKind
        /// Compact Codex load summary shown above the session list.
        /// Pinned session ids. Affects Flat ordering and the pin icon on
        /// every cell in both modes.
        var pinnedIds: Set<String>

        struct SessionFingerprint: Equatable {
            let id: String
            let endTime: Date?
            /// Resolved cell title at render time — either the first Turn's
            /// preview, the session slug, or the id-prefix fallback. Included
            /// explicitly because it's a derived value (not a `Session`
            /// property), so endTime alone can't tell us whether it changed.
            let title: String
            /// Origin of the title: when `customTitle` is set, the cell
            /// renders a `tag.fill` indicator. We must invalidate the
            /// snapshot when origin changes even if text coincidentally
            /// matches (e.g., `/rename` to the same string as the current
            /// firstTurn preview would otherwise silently skip the reload
            /// and the indicator wouldn't appear).
            let isCustomTitle: Bool
            /// Pinned state (from `AppSettings.pinnedSessionIds`). The
            /// pin icon renders in both layouts, so a toggle here must
            /// invalidate the guard even when id/endTime/title are stable.
            let isPinned: Bool
            /// Whether this session currently shows the green active dot
            /// (`store.isSessionActive(session)`, driven by endTime vs
            /// `idleThreshold`). Must be in the fingerprint so the
            /// dot-fade-out at the 10-minute mark doesn't get silently
            /// skipped — the fade-out doesn't change `sessions` itself,
            /// only the clock-vs-endTime comparison, so endTime alone
            /// can't detect it.
            let isActive: Bool
            /// Session total cost. Included so a cost-only backfill (the
            /// finalize pass reprices requests without moving endTime)
            /// still invalidates the guard and repaints the price label.
            let costUSD: Double
        }
    }
    private var lastRenderSnapshot: RenderSnapshot = RenderSnapshot(
        sessionFingerprints: [],
        visibleCounts: [:],
        hiddenExpanded: [],
        filter: SessionFilter(),
        layoutMode: .grouped,
        activeProvider: .claudeCode,
        pinnedIds: []
    )

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    init(
        store: AppStateStore,
        settings: AppSettings,
        expandedGroupsStorage: ExpandedGroupsStorage = ExpandedGroupsStorage(),
        automaticSessionSelectionEnabled: Bool = true
    ) {
        self.store = store
        self.settings = settings
        self.expandedGroupsStorage = expandedGroupsStorage
        self.automaticSessionSelectionEnabled = automaticSessionSelectionEnabled
        // Rehydrate before the first `reloadData()` runs so the initial
        // outline draw already reflects the persisted expand/collapse shape.
        // Empty set on first launch, corrupt file, or a user who collapsed
        // everything — all three degrade to "groups start collapsed", which
        // is the pre-persistence default.
        self.expandedProjectKeys = expandedGroupsStorage.load()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        self.view = container

        setupOutlineView()
        setupProviderModeControl(in: container)
        setupSearchField(in: container)
        setupFilterButton(in: container)
        setupCodexLoadSummary(in: container)
        setupScrollView(in: container)
        setupEmptyState(in: container)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.onLoadMoreClicked = { [weak self] projectKey in
            self?.expandNextPage(for: projectKey)
        }
        outlineView.onShowLessClicked = { [weak self] projectKey in
            self?.collapseToFirstPage(for: projectKey)
        }
        outlineView.onHiddenToggleClicked = { [weak self] projectKey in
            self?.toggleHiddenSessions(for: projectKey)
        }
        // Context menu on session rows: the outline view subclass handles
        // locating the row under the cursor; we build the menu here so all
        // target/action wiring stays with the VC that owns the store and
        // sessionResumer.
        outlineView.menuProvider = { [weak self] session in
            self?.makeContextMenu(for: session)
        }
        reloadData()
        startObserving()
        observeWallClockTicks()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Wall-clock tick subscription. Only acts on day rollover: sidebar
    /// grouping headers / sort order use `session.endTime`, and that
    /// interacts with `isDateInToday`-style predicates in the composed
    /// filter UI. Hourly ticks don't affect the sidebar (the active-dot
    /// fade-out is already handled by `scheduleActiveDotInvalidation()`).
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
        guard note.wallClockDidCrossMidnight else { return }
        reloadData()
    }

    // MARK: - Setup

    private func setupEmptyState(in container: NSView) {
        emptyProgressIndicator.style = .spinning
        emptyProgressIndicator.controlSize = .small
        emptyProgressIndicator.isDisplayedWhenStopped = false
        emptyProgressIndicator.isHidden = true

        // Icon
        if let img = NSImage(systemSymbolName: "tray", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .thin)
            emptyImageView.image = img.withSymbolConfiguration(config)
            emptyImageView.contentTintColor = .tertiaryLabelColor
        }

        let descriptor = settings.activeProvider.descriptor

        // Title
        emptyTitleLabel.stringValue = descriptor.emptySessionListTitle
        emptyTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyTitleLabel.textColor = .secondaryLabelColor
        emptyTitleLabel.alignment = .center

        // Subtitle
        emptySubtitleLabel.stringValue = descriptor.emptySessionListMessage
        emptySubtitleLabel.font = .systemFont(ofSize: 11)
        emptySubtitleLabel.textColor = .tertiaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            emptyProgressIndicator,
            emptyImageView,
            emptyTitleLabel,
            emptySubtitleLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(stack)
        container.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            // Empty state sits below the search field so the field stays
            // visible and usable even when the session list is empty —
            // otherwise a zero-match filter would hide the only control
            // the user needs to fix it.
            emptyStateView.topAnchor.constraint(equalTo: codexLoadSummaryView.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: emptyStateView.widthAnchor, constant: -32),
        ])

        emptyStateView.isHidden = true
    }

    private func showEmptyState(title: String, subtitle: String, loading: Bool = false) {
        emptyTitleLabel.stringValue = title
        emptySubtitleLabel.stringValue = subtitle
        emptyImageView.isHidden = loading
        emptyProgressIndicator.isHidden = !loading
        if loading {
            emptyProgressIndicator.startAnimation(nil)
        } else {
            emptyProgressIndicator.stopAnimation(nil)
        }
    }

    private func setupProviderModeControl(in container: NSView) {
        providerModeControl.target = self
        providerModeControl.action = #selector(providerModeChanged(_:))
        providerModeControl.controlSize = .regular
        providerModeControl.bezelStyle = .rounded
        providerModeControl.isBordered = false
        providerModeControl.font = .systemFont(ofSize: 14, weight: .semibold)
        providerModeControl.imagePosition = .imageLeading
        providerModeControl.setAccessibilityLabel("Provider mode")
        providerModeControl.toolTip = "Select provider mode"
        providerModeControl.removeAllItems()
        for provider in ProviderRegistry.all {
            let item = NSMenuItem(title: provider.displayName, action: nil, keyEquivalent: "")
            item.representedObject = provider.kind.rawValue
            item.toolTip = provider.displayName
            item.image = Self.providerModeImage(for: provider)
            providerModeControl.menu?.addItem(item)
        }
        updateProviderModeControlSelection()

        providerModeControl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerModeControl)

        NSLayoutConstraint.activate([
            providerModeControl.topAnchor.constraint(equalTo: container.topAnchor, constant: SidebarMetrics.topInset),
            providerModeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SidebarMetrics.horizontalInset),
            providerModeControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SidebarMetrics.horizontalInset),
            providerModeControl.heightAnchor.constraint(equalToConstant: SidebarMetrics.providerHeight),
        ])
    }

    private func setupSearchField(in container: NSView) {
        searchField.placeholderString = "Search sessions"
        searchField.delegate = self
        updateSearchCoverageHint()
        // `sendsWholeSearchString = false` and `sendsSearchStringImmediately
        // = false` is AppKit's default mode where `controlTextDidChange`
        // fires on every keystroke — exactly what we want so the
        // debounce below can decide when to commit.
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        // Accessibility: screen readers benefit from an explicit role
        // description since we're nesting the field inside a sidebar.
        searchField.setAccessibilityLabel("Search sessions")

        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        // Trailing edge sits *inside* the container by the filter button,
        // the inter-control gap, and the sidebar inset. `setupFilterButton`
        // places its button in that reserved strip, so the two controls
        // end up visually on the same horizontal line without needing
        // a wrapper view.
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: providerModeControl.bottomAnchor, constant: SidebarMetrics.controlGap),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SidebarMetrics.horizontalInset),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SidebarMetrics.searchTrailingReserve),
            searchField.heightAnchor.constraint(equalToConstant: SidebarMetrics.searchHeight),
        ])
    }

    private func setupFilterButton(in container: NSView) {
        // Plain borderless SF-Symbol button — no bezelStyle, so AppKit
        // doesn't draw a pill / rounded-rect background around the
        // icon. Previous iteration set `.accessoryBarAction` which
        // added a subtle highlight that made the button read as a
        // solid blue dot against a dark sidebar at small sizes.
        filterButton.isBordered = false
        filterButton.imagePosition = .imageOnly
        filterButton.setButtonType(.momentaryChange)
        filterButton.target = self
        filterButton.action = #selector(filterButtonClicked)
        filterButton.toolTip = "Filter sessions"
        filterButton.setAccessibilityLabel("Filter sessions")
        // Initial icon reflects whatever filter state the VC was
        // constructed with (empty by default, but persisted filter
        // would be restored here in a future follow-up).
        updateFilterButtonIcon()

        filterButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(filterButton)

        NSLayoutConstraint.activate([
            // Line up the button's vertical center with the search
            // field's so they read as one control row. Pinning to the
            // field's centerY (not top/bottom) keeps this stable even
            // if we ever bump the search field's vertical size.
            filterButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            filterButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: SidebarMetrics.controlGap),
            filterButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SidebarMetrics.horizontalInset),
            filterButton.widthAnchor.constraint(equalToConstant: SidebarMetrics.filterButtonSize),
            filterButton.heightAnchor.constraint(equalToConstant: SidebarMetrics.filterButtonSize),
        ])
    }

    private func setupCodexLoadSummary(in container: NSView) {
        codexLoadSummaryView.translatesAutoresizingMaskIntoConstraints = false
        codexLoadSummaryView.isHidden = true
        container.addSubview(codexLoadSummaryView)

        let height = codexLoadSummaryView.heightAnchor.constraint(equalToConstant: 0)
        codexLoadSummaryHeightConstraint = height
        NSLayoutConstraint.activate([
            codexLoadSummaryView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: SidebarMetrics.controlGap),
            codexLoadSummaryView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SidebarMetrics.horizontalInset),
            codexLoadSummaryView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SidebarMetrics.horizontalInset),
            height,
        ])
    }

    private func updateCodexLoadSummary(activeProvider: ProviderKind) {
        // The legacy Codex load-summary panel died with the in-memory
        // loader (5.3) — the view stays in the layout chain as a
        // permanently hidden zero-height spacer.
        codexLoadSummaryView.isHidden = true
        codexLoadSummaryHeightConstraint?.constant = 0
    }

    /// Refresh the filter button's icon to reflect whether any
    /// *popover-managed* filter is currently active. The search field
    /// visualizes `query` on its own, so the filter button explicitly
    /// ignores `query` when deciding whether to light up — otherwise
    /// typing in the search field would also tint the filter icon,
    /// which would falsely imply "a popover filter is on".
    private func updateFilterButtonIcon() {
        let active = currentFilter.hasStructuredFilters
        let symbolName = active
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
        if let img = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Filter sessions"
        ) {
            // 16pt matches NSSearchField's built-in glyph weight so
            // the two controls read as one row. Semibold weight makes
            // the outline strokes crisp enough to distinguish at
            // sidebar size without needing a bezel.
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            filterButton.image = img.withSymbolConfiguration(config)
        }
        filterButton.contentTintColor = active
            ? .controlAccentColor
            : .secondaryLabelColor
    }

    private func updateProviderModeControlSelection() {
        guard let index = ProviderRegistry.all.firstIndex(where: { $0.kind == settings.activeProvider }) else {
            return
        }
        providerModeControl.selectItem(at: index)
        applyProviderModeVisuals(for: ProviderRegistry.all[index])
    }

    @objc private func providerModeChanged(_ sender: NSPopUpButton) {
        if let rawValue = sender.selectedItem?.representedObject as? String,
           let provider = ProviderKind(rawValue: rawValue) {
            settings.activeProvider = provider
            return
        }
        let index = sender.indexOfSelectedItem
        guard ProviderRegistry.all.indices.contains(index) else { return }
        settings.activeProvider = ProviderRegistry.all[index].kind
    }

    private func applyProviderModeVisuals(for provider: ProviderDescriptor) {
        let accent = Self.providerModeAccentColor(for: provider.kind)
        providerModeControl.accentColor = accent
        providerModeControl.image = Self.providerModeImage(for: provider)
        providerModeControl.contentTintColor = accent
        providerModeControl.attributedTitle = NSAttributedString(
            string: provider.displayName,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    private static func providerModeAccentColor(for kind: ProviderKind) -> NSColor {
        switch kind {
        case .claudeCode:
            return NSColor(srgbRed: 0.98, green: 0.74, blue: 0.38, alpha: 1.0)
        case .codex:
            return NSColor(srgbRed: 0.22, green: 0.78, blue: 0.58, alpha: 1.0)
        }
    }

    private static func providerModeImage(for provider: ProviderDescriptor) -> NSImage {
        let accent = providerModeAccentColor(for: provider.kind)
        switch provider.kind {
        case .claudeCode:
            return claudeCodeProviderIcon(accent: accent, accessibilityDescription: provider.displayName)
        case .codex:
            return codexProviderIcon(accent: accent, accessibilityDescription: provider.displayName)
        }
    }

    private static func claudeCodeProviderIcon(
        accent: NSColor,
        accessibilityDescription: String
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            accent.setFill()
            sparklePath(center: CGPoint(x: rect.midX - 1, y: rect.midY + 1), outer: 7.0, inner: 2.2).fill()
            accent.withAlphaComponent(0.75).setFill()
            sparklePath(center: CGPoint(x: rect.maxX - 3.0, y: rect.minY + 4.0), outer: 3.0, inner: 1.0).fill()
            return true
        }
        image.accessibilityDescription = accessibilityDescription
        image.isTemplate = false
        return image
    }

    private static func codexProviderIcon(
        accent: NSColor,
        accessibilityDescription: String
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let stroke = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2.5, dy: 3.0),
                xRadius: 3.0,
                yRadius: 3.0
            )
            stroke.lineWidth = 1.4
            accent.withAlphaComponent(0.92).setStroke()
            stroke.stroke()

            let prompt = NSBezierPath()
            prompt.lineWidth = 1.5
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.move(to: CGPoint(x: rect.minX + 5.4, y: rect.midY + 2.8))
            prompt.line(to: CGPoint(x: rect.minX + 8.0, y: rect.midY))
            prompt.line(to: CGPoint(x: rect.minX + 5.4, y: rect.midY - 2.8))
            accent.setStroke()
            prompt.stroke()

            let cursor = NSBezierPath()
            cursor.lineWidth = 1.5
            cursor.lineCapStyle = .round
            cursor.move(to: CGPoint(x: rect.minX + 10.2, y: rect.midY - 3.0))
            cursor.line(to: CGPoint(x: rect.minX + 13.5, y: rect.midY - 3.0))
            accent.setStroke()
            cursor.stroke()
            return true
        }
        image.accessibilityDescription = accessibilityDescription
        image.isTemplate = false
        return image
    }

    private static func sparklePath(center: CGPoint, outer: CGFloat, inner: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: center.x, y: center.y + outer))
        path.line(to: CGPoint(x: center.x + inner, y: center.y + inner))
        path.line(to: CGPoint(x: center.x + outer, y: center.y))
        path.line(to: CGPoint(x: center.x + inner, y: center.y - inner))
        path.line(to: CGPoint(x: center.x, y: center.y - outer))
        path.line(to: CGPoint(x: center.x - inner, y: center.y - inner))
        path.line(to: CGPoint(x: center.x - outer, y: center.y))
        path.line(to: CGPoint(x: center.x - inner, y: center.y + inner))
        path.close()
        return path
    }

    private func setupOutlineView() {
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = false
        // 6pt per level — just enough to step the session row past the
        // group header's disclosure chevron area so the triangle doesn't
        // visually collide with the session's active-dot / title column.
        // Combined with the session cell's own 2pt leading padding this
        // yields ~8pt absolute, still noticeably tighter than the Apple
        // default but no longer overlapping the header's outline cell.
        outlineView.indentationPerLevel = 6
        // Expose a bit of the disclosure chevron without eating leading padding
        // from the child session cells.
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)

        let column = NSTableColumn(identifier: .init("session"))
        column.title = ""
        column.resizingMask = [.autoresizingMask]
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
    }

    private func setupScrollView(in container: NSView) {
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Selection-independent indexing footer pinned to the sidebar bottom.
        // Collapses to zero height (intrinsic-content sizing) when no scan or
        // import is in flight, so the outline fills the pane as before.
        let footer = IndexingStatusHostingView(store: store, style: .footer)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            // Top anchor sits under the search field with a small gap so
            // the outline doesn't touch the field's border.
            scrollView.topAnchor.constraint(equalTo: codexLoadSummaryView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Observation

    /// Number of times observation has been re-armed. Because
    /// `withObservationTracking` is one-shot, a re-subscription race
    /// during long-running operation will stop this counter from
    /// advancing — the first signal to check when debugging a
    /// sidebar freeze.
    private var observationArmCount: Int = 0

    private func startObserving() {
        observationArmCount += 1
        let armIndex = observationArmCount
        LoggerService.shared.debug(
            "observation armed (#\(armIndex))",
            context: "Sidebar"
        )
        withObservationTracking {
            _ = store.sessions
            // The green "active" dot is a pure function of each session's
            // endTime (see `AppStateStore.isSessionActive`), so we don't
            // need to observe `activeSessionId` / `activeSessionLastAppend`
            // anymore — `sessions` is reassigned whenever `endTime`
            // advances, which is the only signal that changes the dot's
            // state without a clock tick. The clock-tick case is handled
            // by `scheduleActiveDotInvalidation`.
            //
            // Cell metrics: cost/tokens/req/badge come from the SQL
            // sidebar aggregates (5.3); a backfill tick that changes
            // them without touching `sessions` must still redraw rows.
            _ = store.sessionListAggregates
            // Provider mode changes in two phases: settings updates
            // immediately, then AppStateStore swaps runtime state after any
            // provider-specific load. Track the store side too so the
            // sidebar redraws when the transition actually completes.
            _ = store.activeProvider
            // Sidebar layout toggle + pin toggles. Both come from
            // `AppSettings` and must drive an immediate rebuild — a pure
            // store change never fires for them.
            _ = settings.sessionListLayout
            _ = settings.activeProvider
            _ = settings.pinnedSessionIds
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                LoggerService.shared.debug(
                    "observation fired (from arm #\(armIndex))",
                    context: "Sidebar"
                )
                self?.reloadData()
                self?.startObserving()
            }
        }
    }

    // MARK: - Tree builders

    /// Builder result — factored into a tuple-struct pair so both layout
    /// modes can yield the same `(rootNodes, sessionNodesById)` shape for
    /// the caller to install without branching.
    private struct TreeBuild {
        let roots: [SessionListNode]
        let nodesById: [String: SessionListNode]
    }

    /// Grouped tree — project-header roots with paginated session children.
    ///
    /// Pagination window auto-grow: if the previously selected session
    /// still exists but has been pushed past its group's visible window
    /// (e.g. a few fresh sessions streamed in while the user was idle),
    /// bump the window so the selection stays in view. Without this,
    /// the sidebar would silently drop the selection and clear the
    /// detail pane even though nothing was actually deleted.
    private func buildGroupedTree(
        from sessions: [Session],
        previousSelectionId: String?
    ) -> TreeBuild {
        let groups = SessionGrouping.groupByProject(sessions)

        // Hiding is suppressed while a search/filter is active — the user is
        // looking for something and must see every match. The current
        // selection is always kept visible so a reload never drops the row
        // being viewed (it stays in the `shown` bucket via `keepShown`).
        let hidingEnabled = currentFilter.isEmpty
        let keepShown: Set<String> = previousSelectionId.map { [$0] } ?? []

        var roots: [SessionListNode] = []
        var nodesById: [String: SessionListNode] = [:]
        for group in groups {
            let projectKey = providerProjectKey(group.key)
            let partition = SessionListHiddenPartition.partition(
                sessions: group.sessions,
                hidingEnabled: hidingEnabled,
                keepShown: keepShown,
                isLowSignal: { self.isLowSignalSession($0) }
            )
            let hiddenCount = partition.hidden.count
            let expanded = expandedHiddenByProject.contains(projectKey)

            // Collapsed → only the non-hidden sessions. Expanded → low-signal
            // sessions rejoin the list in their natural endTime order (mixed
            // back in, not a separate section). Either way pagination applies
            // to the resulting list.
            let displaySessions = (hiddenCount == 0 || expanded)
                ? group.sessions
                : partition.shown

            // Pagination window auto-grow: if the previously selected session
            // is in this group's displayed list but past the visible window
            // (a few fresh sessions streamed in while the user was idle),
            // bump the window so the selection stays in view.
            if let prevId = previousSelectionId,
               let idx = displaySessions.firstIndex(where: { $0.id == prevId }) {
                let current = visibleCountByProject[projectKey] ?? Self.pageSize
                if idx >= current {
                    // Round up to the next page boundary so the window
                    // doesn't settle on an awkward "off-by-one" size.
                    let needed = idx + 1
                    let rounded = ((needed + Self.pageSize - 1) / Self.pageSize) * Self.pageSize
                    visibleCountByProject[projectKey] = rounded
                }
            }

            let windowSize = visibleCountByProject[projectKey] ?? Self.pageSize
            let win = SessionPagination.window(
                sessions: displaySessions,
                visibleCount: windowSize,
                pageSize: Self.pageSize
            )

            var children: [SessionListNode] = win.visibleSessions.map { session in
                let node = SessionListNode(kind: .session(session))
                nodesById[session.id] = node
                return node
            }
            if win.hasActionRow {
                children.append(SessionListNode(kind: .loadMore(
                    projectKey: projectKey,
                    nextStep: win.nextStep,
                    remainingAfterStep: win.remainingAfterStep,
                    canCollapse: win.canCollapse
                )))
            }

            // The hidden (zero-cost) sessions are toggled from a small button
            // in the group header (which carries `hiddenCount` / `expanded`),
            // not a separate row — so nothing extra is appended for them here.
            let header = SessionListNode(kind: .projectGroup(
                key: projectKey,
                label: group.label,
                count: group.sessions.count,
                hiddenCount: hiddenCount,
                expanded: expanded
            ))
            header.children = children
            roots.append(header)
        }
        return TreeBuild(roots: roots, nodesById: nodesById)
    }

    private func providerProjectKey(_ projectKey: String) -> String {
        "\(settings.activeProvider.rawValue):\(projectKey)"
    }

    /// Flat tree — a single 1-depth session list, pinned-first, then
    /// endTime DESC. No project headers, no pagination (pagination's whole
    /// purpose was to keep long project lists from dominating the sidebar;
    /// in flat mode we want to see the full recency ordering).
    private func buildFlatTree(
        from sessions: [Session],
        pinnedIds: Set<String>
    ) -> TreeBuild {
        let sorted = SessionGrouping.flatSorted(sessions, pinnedIds: pinnedIds)
        var nodesById: [String: SessionListNode] = [:]
        let roots: [SessionListNode] = sorted.map { session in
            let node = SessionListNode(kind: .session(session))
            nodesById[session.id] = node
            return node
        }
        return TreeBuild(roots: roots, nodesById: nodesById)
    }

    // MARK: - Data

    /// Coverage label (plan 4.3): while the background index is still
    /// importing, content search is honest-but-partial — say so where
    /// the user is about to type instead of silently under-matching.
    /// Title/slug/project matching is complete from the first scan.
    private func updateSearchCoverageHint() {
        // Placeholder stays short ("Search sessions"); the scope and the
        // import-coverage caveat live in the tooltip, and the live indexing
        // signal is already visible in the sidebar footer.
        searchField.placeholderString = "Search sessions"
        switch currentFilter.searchScope {
        case .sessions:
            searchField.toolTip = "Matching session names — title, slug, and project."
        case .everything:
            let progress = store.launchProgress
            if progress.phase == .indexing, progress.pendingUnits > 0 {
                searchField.toolTip =
                    "Also searches conversation content. Sessions are still importing — "
                    + "title/slug/project matches are complete; content matches cover "
                    + "imported sessions only."
            } else {
                searchField.toolTip = "Also searches conversation content (prompts, replies)."
            }
        }
    }

    private func reloadData() {
        updateSearchCoverageHint()
        // 1) Remember what was selected so we can restore after the reload.
        let previousSelection: (provider: ProviderKind, id: String)? = {
            let row = outlineView.selectedRow
            guard row >= 0,
                  let node = outlineView.item(atRow: row) as? SessionListNode,
                  case .session(let session) = node.kind
            else { return nil }
            return (session.provider, session.id)
        }()
        if let previousSelection {
            selectedSessionIdByProvider[previousSelection.provider] = previousSelection.id
        }
        let previousSelectionId = previousSelection?.id

        // 1a) Capture the selected row's *viewport-relative* y offset. This
        //     lets us keep the selected session pinned to the same on-screen
        //     position even when surrounding rows reorder (e.g. streaming
        //     updates change a sibling's endTime and the list resorts). An
        //     absolute-origin restore would keep the scroll coordinate the
        //     same but let the selected row slide off-screen — the Mail
        //     sidebar pattern is to keep the *selection* stable and let the
        //     other rows move.
        let savedScrollOrigin: NSPoint = scrollView.contentView.bounds.origin
        let selectionOffsetInViewport: CGFloat? = {
            let row = outlineView.selectedRow
            guard row >= 0 else { return nil }
            return outlineView.rect(ofRow: row).origin.y - savedScrollOrigin.y
        }()

        // 2) Snapshot guard: streaming JSONL appends can fire observation
        //    notifications without actually changing what the sidebar would
        //    render. Build a fingerprint of *every* render-relevant VC input
        //    — session list, resolved titles, AND pagination window — and
        //    bail out if it matches the last successful build. The
        //    pagination window has to be in this fingerprint or "Show N more"
        //    clicks would silently no-op; `title` has to be in here or the
        //    cold-launch "slugs stuck until you touch pagination" regression
        //    comes back (see `RenderSnapshot` doc comment).
        let filterChanged = currentFilter != lastRenderSnapshot.filter
        let pinnedIds = settings.pinnedSessionIds
        let layoutMode = settings.sessionListLayout
        let activeProvider = settings.activeProvider
        updateProviderModeControlSelection()
        if activeProvider != store.activeProvider {
            pendingAutoSelectProvider = automaticSessionSelectionEnabled ? activeProvider : nil
            rootNodes = []
            sessionNodesById = [:]
            lastRenderSnapshot = RenderSnapshot(
                sessionFingerprints: [],
                visibleCounts: [:],
                hiddenExpanded: [],
                filter: currentFilter,
                layoutMode: layoutMode,
                activeProvider: store.activeProvider,
                pinnedIds: pinnedIds
            )
            isProgrammaticSelectionChange = true
            outlineView.reloadData()
            isProgrammaticSelectionChange = false
            let descriptor = activeProvider.descriptor
            showEmptyState(
                title: "Loading \(descriptor.shortDisplayName) Sessions",
                subtitle: "Preparing \(descriptor.shortDisplayName) data...",
                loading: true
            )
            emptyStateView.isHidden = false
            scrollView.isHidden = true
            updateCodexLoadSummary(activeProvider: activeProvider)
            onSelectionCleared?()
            LoggerService.shared.debug(
                "reloadData deferred — settings provider \(activeProvider.rawValue) waiting for store provider \(store.activeProvider.rawValue)",
                context: "Sidebar"
            )
            return
        }
        // Capture the layout-mode flip before the snapshot gets
        // overwritten below. Grouped ↔ Flat changes the entire row
        // tree shape (project-header roots vs. flat session rows),
        // so any pre-reload scroll coordinate is meaningless after
        // the swap — see the layout-mode branch in §8 for the reset.
        let layoutModeChanged = lastRenderSnapshot.layoutMode != layoutMode
        let providerModeChanged = lastRenderSnapshot.activeProvider != activeProvider
        let sessionsVisibleInCurrentMode = sessionsVisibleForActiveProvider()
        // Evaluate `isSessionActive` once per reload against a single `now`
        // timestamp so the fingerprint + cell factory both see the same
        // "active or not" decision. Calling `isSessionActive` per-cell
        // against `Date()` would risk a boundary flip mid-render.
        let now = Date()
        let snapshot = RenderSnapshot(
            sessionFingerprints: sessionsVisibleInCurrentMode.map { session in
                let resolved = sessionTitleResolved(for: session)
                return .init(
                    id: session.id,
                    endTime: session.endTime,
                    // O(1) firstTurn lookup + tiny string processing; cheap
                    // enough to run over every session on every render.
                    title: resolved.text,
                    isCustomTitle: resolved.origin == .custom,
                    isPinned: pinnedIds.contains(session.id),
                    isActive: store.isSessionActive(session, now: now),
                    costUSD: store.sessionListAggregates[session.id]?.costUSD ?? 0
                )
            },
            visibleCounts: visibleCountByProject,
            hiddenExpanded: expandedHiddenByProject,
            filter: currentFilter,
            layoutMode: layoutMode,
            activeProvider: activeProvider,
            pinnedIds: pinnedIds
        )
        updateCodexLoadSummary(activeProvider: activeProvider)
        if snapshot == lastRenderSnapshot && !rootNodes.isEmpty {
            LoggerService.shared.debug(
                "reloadData skipped — snapshot unchanged (sessions=\(store.sessions.count) rootGroups=\(rootNodes.count))",
                context: "Sidebar"
            )
            return
        }
        // Diagnostic for sidebar-freeze suspicion: when snapshot differs
        // we log what changed in broad strokes (count / filter diff) so a
        // long-running session's log file shows the exact moment updates
        // stopped taking effect vs. kept flowing.
        let prevCount = lastRenderSnapshot.sessionFingerprints.count
        let newCount = snapshot.sessionFingerprints.count
        LoggerService.shared.debug(
            "reloadData proceed — sessions \(prevCount)→\(newCount) filterChanged=\(filterChanged)",
            context: "Sidebar"
        )
        lastRenderSnapshot = snapshot

        // 3) Rebuild node tree from store.
        //    `filteredSessions` short-circuits past every predicate when
        //    `currentFilter.isEmpty`, so the pre-filter fast path stays
        //    free at zero extra cost. The resulting set then feeds either
        //    the grouped (project-header) or flat (1-depth, pinned-first)
        //    tree builder depending on the user's layout preference.
        let sessionsForGrouping = store.filteredSessions(
            currentFilter,
            provider: activeProvider
        )
        let newRoots: [SessionListNode]
        let newSessionNodes: [String: SessionListNode]
        let selectionToRestore = providerModeChanged
            ? selectedSessionIdByProvider[activeProvider]
            : previousSelectionId
        // Flat layout removes the level-1 offset entirely so session rows
        // sit flush-left. Grouped keeps the tight 6pt step set up in
        // `setupOutlineView`. Done before reloadData so the first layout
        // pass uses the correct metric.
        outlineView.indentationPerLevel = (layoutMode == .flat) ? 0 : 6
        switch layoutMode {
        case .grouped:
            let built = buildGroupedTree(
                from: sessionsForGrouping,
                previousSelectionId: selectionToRestore
            )
            newRoots = built.roots
            newSessionNodes = built.nodesById
        case .flat:
            let built = buildFlatTree(
                from: sessionsForGrouping,
                pinnedIds: pinnedIds
            )
            newRoots = built.roots
            newSessionNodes = built.nodesById
        }
        rootNodes = newRoots
        sessionNodesById = newSessionNodes

        @discardableResult
        func restoreSelection(sessionId: String?) -> Bool {
            guard let sessionId,
                  let node = sessionNodesById[sessionId] else {
                return false
            }
            // Find the owning group and expand it if currently collapsed.
            if let parent = rootNodes.first(where: { $0.children.contains(where: { $0 === node }) }),
               let parentKey = parent.projectKey,
               !expandedProjectKeys.contains(parentKey) {
                outlineView.expandItem(parent)
                expandedProjectKeys.insert(parentKey)
                // Persist: the user's "selection is in this group" is
                // semantically the same expand the outline delegate callback
                // would have fired, and we want it remembered across quits.
                scheduleSaveExpandedState()
            }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return false }

            isProgrammaticSelectionChange = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isProgrammaticSelectionChange = false
            if case .session(let refreshed) = node.kind {
                selectedSessionIdByProvider[refreshed.provider] = refreshed.id
                onSessionSelected?(refreshed)
            }
            return true
        }

        @discardableResult
        func selectFirstVisibleSession() -> Bool {
            for root in rootNodes {
                let candidate: SessionListNode?
                switch root.kind {
                case .session:
                    candidate = root
                case .projectGroup:
                    candidate = root.children.first { child in
                        if case .session = child.kind { return true }
                        return false
                    }
                case .loadMore:
                    candidate = nil
                }
                guard let candidate else { continue }
                if restoreSelection(sessionId: candidate.sessionId) {
                    let row = outlineView.row(forItem: candidate)
                    if row >= 0 { outlineView.scrollRowToVisible(row) }
                    return true
                }
            }
            return false
        }

        // 5) reloadData → delegate can fire selectionDidChange during the
        //    programmatic repopulation; guard it.
        isProgrammaticSelectionChange = true
        outlineView.reloadData()

        for node in rootNodes {
            if let key = node.projectKey, expandedProjectKeys.contains(key) {
                outlineView.expandItem(node)
            }
        }
        isProgrammaticSelectionChange = false

        // 6) Show empty state iff there are no groups at all. The message
        //    differs depending on *why* it's empty: a truly empty store
        //    says "No Sessions Found", a filter with zero matches says
        //    "No Matches" so the user knows the filter (not an absence of
        //    sessions) is what's hiding everything.
        let isEmpty = rootNodes.isEmpty
        if isEmpty {
            if store.isLoading && store.activeProvider == activeProvider {
                let descriptor = activeProvider.descriptor
                let subtitle = store.loadingProgress.isEmpty
                    ? "Reading local \(descriptor.shortDisplayName) data..."
                    : store.loadingProgress
                showEmptyState(
                    title: "Loading \(descriptor.shortDisplayName) Sessions",
                    subtitle: subtitle,
                    loading: true
                )
            } else if currentFilter.isEmpty {
                let descriptor = activeProvider.descriptor
                showEmptyState(
                    title: descriptor.emptySessionListTitle,
                    subtitle: descriptor.emptySessionListMessage
                )
            } else {
                showEmptyState(
                    title: "No Matches",
                    subtitle: "Try a different search term\nor clear the filter."
                )
            }
        } else {
            showEmptyState(title: "", subtitle: "")
        }
        emptyStateView.isHidden = !isEmpty
        scrollView.isHidden = isEmpty

        // 7) Restore selection by session id. On provider switches, restore
        //    that provider's last session; if none exists yet, select the
        //    first visible session once data arrives. This keeps the right
        //    panes populated instead of flashing "No Conversation".
        let restoredSelection = restoreSelection(sessionId: selectionToRestore)
        if !restoredSelection, providerModeChanged {
            if automaticSessionSelectionEnabled, selectFirstVisibleSession() {
                pendingAutoSelectProvider = nil
            } else {
                pendingAutoSelectProvider = automaticSessionSelectionEnabled ? activeProvider : nil
                onSelectionCleared?()
            }
        } else if !restoredSelection,
                  automaticSessionSelectionEnabled,
                  pendingAutoSelectProvider == activeProvider {
            if selectFirstVisibleSession() {
                pendingAutoSelectProvider = nil
            }
        } else if !restoredSelection, previousSelectionId != nil {
            onSelectionCleared?()
        }

        // 8) Scroll position restoration — four strategies depending on
        //    where the user was and what changed:
        //
        //    a) **Layout mode changed** (Grouped ↔ Flat toggle): the row
        //       tree shape, total contentHeight, and per-row indices all
        //       change in one pass. The pre-reload `savedScrollOrigin`
        //       no longer maps to anything meaningful in the new layout —
        //       a pixel-offset restore can land past the new contentHeight
        //       and leave the contentView showing blank space at the top
        //       (AppKit doesn't auto-clamp). Reset to top so the user
        //       starts from a consistent place after the swap. Selected
        //       row stays selected; if it's now off-screen the user can
        //       scroll back, same as in any list-mode toggle in Mail or
        //       Finder.
        //
        //    b) **Filter changed** (user typed in the search field or
        //       toggled a popover control): the item count shrunk or grew,
        //       so the pre-reload `savedScrollOrigin` may be past the new
        //       content height. Pixel-offset restoration would scroll into
        //       the void and cause a visible jump. Instead, just make sure
        //       the selected row is visible — `scrollRowToVisible` clamps
        //       to the content bounds automatically. If there's no
        //       selection (filtered-out), scroll to top so the user sees
        //       the first group header.
        //
        //    c) **Filter unchanged, user was scrolled to the top**: stay at
        //       the top. The old "preserve selection at its viewport-y"
        //       rule was wrong here — if the selection was at y=0 and a
        //       sibling's append promotes a different session to row 0
        //       (endTime DESC reshuffle), the rule scrolls the viewport
        //       down by one row to keep the selection at y=0, pushing the
        //       newly-promoted row above the viewport. Result: the user
        //       sees nothing new and has to manually scroll back up.
        //       Messages.app / Finder's "Recent" list behave the way the
        //       user expects — top stays top, new rows slide in visibly.
        //
        //    d) **Filter unchanged, user has scrolled below the top**:
        //       preserve the selected row's viewport-relative y. This is
        //       still the right behaviour when the user picked a specific
        //       session deep in the list and other rows reorder around
        //       them — they want their context stable, not jumped to top.
        //
        //    Floating-point tolerance `<= 0.5`: AppKit produces exact 0.0
        //    for a clean "at top" origin, but trackpad inertia + split-view
        //    reflow can leave sub-pixel residue. Anything under half a
        //    point reads as "at top" to the user.
        let wasScrolledToTop = savedScrollOrigin.y <= 0.5
        if layoutModeChanged || providerModeChanged {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if filterChanged {
            if let prevId = previousSelectionId,
               let node = sessionNodesById[prevId] {
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    outlineView.scrollRowToVisible(row)
                }
            } else {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else if wasScrolledToTop {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            if let offset = selectionOffsetInViewport,
               let prevId = previousSelectionId,
               let node = sessionNodesById[prevId] {
                let newRow = outlineView.row(forItem: node)
                if newRow >= 0 {
                    let newRowY = outlineView.rect(ofRow: newRow).origin.y
                    let targetOrigin = NSPoint(x: savedScrollOrigin.x, y: newRowY - offset)
                    scrollView.contentView.scroll(to: targetOrigin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    scheduleActiveDotInvalidation()
                    return
                }
            }
            scrollView.contentView.scroll(to: savedScrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        // 9) Schedule a reload at the exact moment the current active
        //    session's green dot should go dark. Without this, the fade-out
        //    would wait for the next unrelated observation fire.
        scheduleActiveDotInvalidation()
    }

    /// Schedule a one-shot reload at the earliest moment any currently-
    /// active session's dot should go dark. Walk every session, compute its
    /// `endTime + idleThreshold` (the instant it stops being "active"), and
    /// take the **minimum** of those that haven't elapsed yet — that's the
    /// nearest fade-out deadline. When the timer fires, reload picks up the
    /// now-false `isActive` in the fingerprint and that cell repaints
    /// without the dot. Any still-active sessions reschedule a fresh timer
    /// at the next nearest deadline.
    ///
    /// No active session ⇒ no work item — we don't want a no-op
    /// perpetually sitting on the main run loop.
    private func scheduleActiveDotInvalidation() {
        pendingActiveDotInvalidation?.cancel()
        pendingActiveDotInvalidation = nil
        let now = Date()
        let threshold = AppStateStore.idleThreshold
        var nextExpiry: Date?
        for session in store.sessions where session.provider == settings.activeProvider {
            guard let endTime = session.endTime else { continue }
            let expiry = endTime.addingTimeInterval(threshold)
            guard expiry > now else { continue }
            if nextExpiry.map({ expiry < $0 }) ?? true {
                nextExpiry = expiry
            }
        }
        guard let nextExpiry else { return }
        let remaining = nextExpiry.timeIntervalSince(now)
        let work = DispatchWorkItem { [weak self] in
            self?.reloadData()
        }
        pendingActiveDotInvalidation = work
        // Small padding so we fire *just past* the boundary rather than
        // right on it — avoids a floating-point tie where the cell
        // factory might still see the session as active.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + remaining + 0.05,
            execute: work
        )
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SessionListNode else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SessionListNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SessionListNode else { return false }
        return !node.children.isEmpty
    }

    // MARK: - NSOutlineViewDelegate

    // NOTE: `rowViewForItem` is intentionally NOT overridden — the
    // sidebar uses the default `NSTableRowView`. The Phase 8.3
    // appearance animation was tried here previously but read as
    // redundant noise on top of the existing "active streaming"
    // green dot in the session cell. The conversation outline still
    // uses LupenAnimatedRowView (TurnOutlineViewController) where
    // there is no equivalent indicator.

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SessionListNode else { return nil }
        switch node.kind {
        case .projectGroup(_, let label, let count, let hiddenCount, let expanded):
            return headerCell(label: label, count: count, hiddenCount: hiddenCount, expanded: expanded)
        case .session(let session):
            return sessionCell(for: session)
        case .loadMore(_, let nextStep, let remainingAfterStep, let canCollapse):
            return loadMoreCell(
                nextStep: nextStep,
                remainingAfterStep: remainingAfterStep,
                canCollapse: canCollapse
            )
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SessionListNode else { return SidebarMetrics.groupRowHeight }
        switch node.kind {
        case .projectGroup: return SidebarMetrics.groupRowHeight
        // Most sessions show two lines. Rows with a branch need the third
        // line, so they keep the taller height without making the whole list
        // look inflated.
        case .session(let session):
            return (session.lastGitBranch?.isEmpty == false)
                ? SidebarMetrics.branchedSessionRowHeight
                : SidebarMetrics.sessionRowHeight
        // Compact hint row — smaller than sessions so it visually steps back.
        case .loadMore:     return SidebarMetrics.loadMoreRowHeight
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SessionListNode else { return false }
        switch node.kind {
        // Only sessions are real selections. Group headers and load-more rows
        // are handled by `SessionListOutlineView.mouseDown` — it either
        // toggles expand/collapse (header) or invokes the load-more closure
        // (load-more). Keeping them non-selectable preserves the user's
        // current session selection while those actions run.
        case .session:      return true
        case .projectGroup,
             .loadMore:     return false
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if isProgrammaticSelectionChange { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SessionListNode,
              case .session(let session) = node.kind else {
            return
        }
        onSessionSelected?(session)
        selectedSessionIdByProvider[session.provider] = session.id
        pendingAutoSelectProvider = nil
    }

    /// Grow this group's visible window by one page and rebuild.
    ///
    /// `visibleCountByProject` is part of `RenderSnapshot`, so just bumping
    /// it is enough — the snapshot guard inside `reloadData` will detect the
    /// change automatically. No explicit invalidation needed.
    private func expandNextPage(for projectKey: String) {
        let current = visibleCountByProject[projectKey] ?? Self.pageSize
        visibleCountByProject[projectKey] = current + Self.pageSize
        reloadData()
    }

    /// Reset this group's visible window back to the default first page
    /// ("Show less"). Removing the key (instead of writing `pageSize`)
    /// restores the missing-key default and keeps the dictionary from
    /// accumulating dead entries.
    ///
    /// If the current selection lives in the tail this collapse would hide,
    /// the auto-grow clamp in `buildGroupedTree` re-expands the window just
    /// enough (rounded up to a page boundary) to keep the selection
    /// visible — collapsing never silently drops the selection or clears
    /// the detail pane.
    private func collapseToFirstPage(for projectKey: String) {
        visibleCountByProject.removeValue(forKey: projectKey)
        reloadData()
    }

    /// A session is a "low-signal" hide candidate when its cost aggregate is
    /// present and non-positive — Codex auto-review assessment threads, empty
    /// `/clear` sessions, etc., where nothing billable happened. A *missing*
    /// aggregate (not yet imported) is deliberately NOT hidden: during a cold
    /// load every aggregate is absent, and hiding on absence would blank the
    /// sidebar. `costUSD` already feeds the render fingerprint, so a session
    /// flips between shown/hidden automatically once its cost lands.
    private func isLowSignalSession(_ session: Session) -> Bool {
        guard let aggregate = store.sessionListAggregates[session.id] else {
            return false
        }
        return aggregate.costUSD <= 0
    }

    /// Flip this group's hidden (zero-cost) bucket open/closed and rebuild.
    /// `expandedHiddenByProject` is part of `RenderSnapshot`, so mutating it
    /// is enough — the snapshot guard inside `reloadData` detects the change.
    private func toggleHiddenSessions(for projectKey: String) {
        if expandedHiddenByProject.contains(projectKey) {
            expandedHiddenByProject.remove(projectKey)
        } else {
            expandedHiddenByProject.insert(projectKey)
        }
        reloadData()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SessionListNode,
              let key = node.projectKey else { return }
        expandedProjectKeys.insert(key)
        scheduleSaveExpandedState()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SessionListNode,
              let key = node.projectKey else { return }
        expandedProjectKeys.remove(key)
        scheduleSaveExpandedState()
    }

    /// Debounced persistence for `expandedProjectKeys`. Cancels any
    /// previously-scheduled save and reschedules a new one, so a burst of
    /// click activity coalesces into a single JSON write after the user
    /// settles. The work item reads `expandedProjectKeys` at fire time (not
    /// schedule time), so whichever state we happen to be in when the window
    /// elapses is what lands on disk — even if the set changed again between
    /// schedule and fire.
    private func scheduleSaveExpandedState() {
        pendingExpandedSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.expandedGroupsStorage.save(self.expandedProjectKeys)
        }
        pendingExpandedSave = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.expandedSaveDebounce,
            execute: work
        )
    }

    // MARK: - Search

    /// Fires on every keystroke in `searchField`. We cancel any pending
    /// filter update and reschedule one 300ms out, so typing coalesces
    /// into a single filter commit + reload after the user pauses. This
    /// is the standard AppKit text-control delegate hook and covers
    /// paste, Esc (which sends an empty string), and the little `x`
    /// clear button in the search field.
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === searchField else { return }
        scheduleFilterUpdate(query: searchField.stringValue)
    }

    /// Debounced bridge from search text to `currentFilter.query`. The
    /// workItem reads `searchField.stringValue` at fire time rather than
    /// capturing the snapshot passed in, so a quick burst of keystrokes
    /// always commits the latest value and never a mid-burst stale one.
    /// Clearing back to empty still goes through the same path so the
    /// debounce stays uniform — snappier-feeling "clear" (skip debounce)
    /// is easy to add later if it becomes a real annoyance.
    private func scheduleFilterUpdate(query: String) {
        pendingFilterUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let newQuery = self.searchField.stringValue
            guard newQuery != self.currentFilter.query else { return }
            self.currentFilter.query = newQuery
            self.reloadData()
            self.onHighlightQueryChanged?(newQuery)
        }
        pendingFilterUpdate = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.filterDebounce,
            execute: work
        )
    }

    /// Read-only exposure of the live search query so the split VC
    /// can push it into `TurnOutlineViewController.setHighlightQuery`
    /// when a new session is selected (the new session's Turn rows
    /// need to inherit the current highlighting).
    var currentQuery: String { currentFilter.query }

    // MARK: - Filter popover

    /// Toggle the filter popover on the filter button. A repeat click
    /// on the button while the popover is already open closes it —
    /// matches AppKit's standard popover-anchor behaviour and lets the
    /// user dismiss without having to click outside.
    @objc private func filterButtonClicked() {
        if let active = activeFilterPopover, active.isShown {
            active.performClose(nil)
            return
        }

        let vc = FilterPopoverViewController(
            initialFilter: currentFilter,
            projectOptions: FilterOptionsBuilder.distinctProjects(from: sessionsVisibleForActiveProvider()),
            modelOptions: FilterOptionsBuilder.distinctModels(
                from: sessionsVisibleForActiveProvider(),
                // Shells carry no requests (6.2) — model facts come
                // from the SQL sidebar aggregates.
                modelsBySession: store.sessionListAggregates.mapValues(\.models)
            )
        )
        vc.onFilterChanged = { [weak self] newFilter in
            guard let self = self else { return }
            // The popover only *manages* projectFilter / dateRange /
            // models. Its `newFilter.query` is a snapshot of whatever
            // the search field happened to hold when the popover
            // opened, and it never updates while the popover is live
            // — so a blind `self.currentFilter = newFilter` would
            // roll back any characters the user has typed since. Use
            // the `applyStructuredFields` helper to merge only the
            // popover-owned fields and leave the live query alone.
            self.currentFilter.applyStructuredFields(from: newFilter)
            self.updateFilterButtonIcon()
            self.reloadData()
        }

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // `.minY` = position below the button in AppKit's default
        // bottom-up coordinate system (minY edge = bottom of the
        // positioning rect). We want the popover to drop *down* from
        // the filter button with its arrow pointing up at the button
        // — Mail, Messages, and Finder's sidebar filter popovers all
        // use this geometry. `.maxY` (the previous value) asked for
        // "above the button", which AppKit then fell back through to
        // an awkward side placement because there's no room above a
        // button sitting 8pt from the window's top edge.
        popover.show(
            relativeTo: filterButton.bounds,
            of: filterButton,
            preferredEdge: .minY
        )
        activeFilterPopover = popover
    }

    // MARK: - NSPopoverDelegate

    /// Called when the popover finishes dismissing. Clear our handle so
    /// the next click opens a fresh popover instead of trying to
    /// close-then-fail on a stale reference.
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover,
              closed === activeFilterPopover else { return }
        activeFilterPopover = nil
    }

    // MARK: - Cell factories

    private func headerCell(label: String, count: Int, hiddenCount: Int, expanded: Bool) -> NSView {
        let id = NSUserInterfaceItemIdentifier("SessionGroupHeaderCell")
        let cell: SessionListGroupHeaderView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? SessionListGroupHeaderView {
            cell = reused
        } else {
            cell = SessionListGroupHeaderView()
            cell.identifier = id
        }
        cell.configure(label: label, count: count, hiddenCount: hiddenCount, expanded: expanded)
        return cell
    }

    private func loadMoreCell(nextStep: Int, remainingAfterStep: Int, canCollapse: Bool) -> NSView {
        let id = NSUserInterfaceItemIdentifier("SessionLoadMoreCell")
        let cell: SessionListLoadMoreCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? SessionListLoadMoreCellView {
            cell = reused
        } else {
            cell = SessionListLoadMoreCellView()
            cell.identifier = id
        }
        cell.configure(
            nextStep: nextStep,
            remainingAfterStep: remainingAfterStep,
            canCollapse: canCollapse
        )
        return cell
    }

    private func sessionCell(for session: Session) -> NSView {
        let id = NSUserInterfaceItemIdentifier("SessionCell")
        let cell: SessionCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? SessionCellView {
            cell = reused
        } else {
            cell = SessionCellView()
            cell.identifier = id
        }

        let isActive = store.isSessionActive(session)
        // Cell metrics come from the SQL sidebar aggregates (plan 5.3)
        // — shell sessions carry no request rows to sum.
        let aggregate = store.sessionListAggregates[session.id]
        let requestCount = aggregate?.requestCount ?? 0
        let totalTokens = aggregate?.contextTokens ?? 0
        let totalCost = aggregate?.costUSD ?? 0
        let costConfidence = CostConfidence.evaluate(
            provider: session.provider,
            billableRequestCount: aggregate?.billableRequestCount ?? 0,
            unavailableRequestCount: aggregate?.unavailableRequestCount ?? 0
        )
        let startTime = session.startTime

        // "What was this session about?" — use the first Turn's preview text.
        // Falls back to the session slug (Claude Code's human-friendly
        // identifier like "harmonic-nibbling-meerkat") and finally to a
        // timestamp stub so the row never looks blank.
        //
        // Use the full `resolve(...)` (not `sessionTitle`) so the cell
        // knows whether to render the `/rename` tag indicator.
        let resolved = sessionTitleResolved(for: session)

        // Flat layout surfaces the project name inside the cell (there's
        // no project header wrapping sessions in that mode). Grouped keeps
        // the cell lean — the project name is up one level in the header.
        let projectLabel: String? = {
            guard settings.sessionListLayout == .flat else { return nil }
            let raw = session.projectPath ?? ""
            if raw.isEmpty { return "Unknown" }
            return ProjectLabelFormatter.decode(raw)
        }()

        cell.configure(
            title: resolved.text,
            isCustomTitle: resolved.origin == .custom,
            branch: session.lastGitBranch,
            startTime: (session.endTime ?? startTime).map { Self.timeFormatter.string(from: $0) } ?? "",
            requestCount: requestCount,
            totalTokens: totalTokens,
            totalCost: totalCost,
            costConfidence: costConfidence,
            provider: session.provider,
            isActive: isActive,
            subAgentCount: aggregate?.subagentLinkCount ?? 0,
            projectLabel: projectLabel,
            isPinned: settings.isPinned(session.id)
        )
        return cell
    }

    private func sessionsVisibleForActiveProvider() -> [Session] {
        store.sessions.filter { $0.provider == settings.activeProvider }
    }

    /// Thin wrapper over `SessionTitleResolver.resolve` — supplies the
    /// live `firstTurn` preview from the store. See
    /// `SessionTitleResolver` for the full priority ladder and rationale.
    ///
    /// Kept as an instance method because snapshot fingerprinting needs
    /// to call it per-session on every reload; the heavy lifting is in
    /// the pure helper so the priority order is unit-tested.
    private func sessionTitleResolved(for session: Session) -> SessionTitleResolver.Resolved {
        // The legacy in-memory Turn preview died with the graphs (5.3), so
        // `firstTurnPreview` stays nil here. The first-prompt fallback now
        // rides on the session shell (`session.firstPrompt`, from
        // `sessions.first_prompt`) and is applied inside the resolver's
        // ladder, below `slug` — so Codex sessions with no thread-name
        // index entry show their first prompt instead of the id prefix.
        SessionTitleResolver.resolve(session: session, firstTurnPreview: nil)
    }

    /// Convenience for callers that only need the text (snapshot
    /// fingerprint, etc.) — avoids the origin-comparison-always-matches
    /// dead branch at read-sites.
    private func sessionTitle(for session: Session) -> String {
        sessionTitleResolved(for: session).text
    }

    // MARK: - Context menu

    /// Build a per-row context menu. Target/action wiring uses
    /// `representedObject` to pin each menu item to the *session the user
    /// right-clicked*, not the session the outline view happens to select
    /// afterwards — right-click in AppKit selects the row under the
    /// cursor, and if the menu holds a pre-captured Session we're robust
    /// either way.
    private func makeContextMenu(for session: Session) -> NSMenu {
        let menu = NSMenu()

        // Pin toggle — first entry so it's the default muscle-memory target
        // for the right-click → enter gesture. Title flips between
        // "Pin to Top" and "Unpin" to mirror the session's current state.
        let isPinned = settings.isPinned(session.id)
        let pinItem = NSMenuItem(
            title: isPinned ? "Unpin" : "Pin to Top",
            action: #selector(togglePinClicked(_:)),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.representedObject = session.id
        menu.addItem(pinItem)

        // Resume is supported for both providers: Claude via
        // `claude --resume`, Codex via `codex resume`. The verb in the
        // title follows the session's provider ("Resume in Claude Code" /
        // "Resume in Codex").
        menu.addItem(.separator())

        let resumeItem = NSMenuItem(
            title: "Resume in \(session.provider.descriptor.displayName)",
            action: #selector(resumeClicked(_:)),
            keyEquivalent: "r"
        )
        resumeItem.keyEquivalentModifierMask = [.command]
        resumeItem.target = self
        resumeItem.representedObject = session
        menu.addItem(resumeItem)

        let copyCommandItem = NSMenuItem(
            title: "Copy Resume Command",
            action: #selector(copyResumeCommandClicked(_:)),
            keyEquivalent: "c"
        )
        copyCommandItem.keyEquivalentModifierMask = [.command, .shift]
        copyCommandItem.target = self
        copyCommandItem.representedObject = session
        menu.addItem(copyCommandItem)

        let copyItem = NSMenuItem(
            title: "Copy Session ID",
            action: #selector(copySessionIdClicked(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.representedObject = session
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let revealItem = NSMenuItem(
            title: session.provider == .codex ? "Reveal Codex JSONL in Finder" : "Reveal JSONL in Finder",
            action: #selector(revealJSONLClicked(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        revealItem.representedObject = session
        menu.addItem(revealItem)

        // Open the actual project working directory (the cwd Claude
        // Code recorded for this session) in Finder. Distinct from
        // "Reveal JSONL" which highlights the cache JSONL — this one
        // takes the user to the real source-of-truth folder. cwd
        // resolution can fail (project moved/deleted) so the click
        // handler shows an alert in that case rather than silently
        // no-op'ing.
        let openProjectItem = NSMenuItem(
            title: "Open Project Folder in Finder",
            action: #selector(openProjectFolderClicked(_:)),
            keyEquivalent: ""
        )
        openProjectItem.target = self
        openProjectItem.representedObject = session
        menu.addItem(openProjectItem)

        // Same target as "Open in Finder", but lands in Terminal.app
        // with the project as the working directory. Useful pair
        // when the user wants to inspect / build / git-status from
        // a shell without the full `claude --resume` ceremony of
        // the Resume action above.
        let openTerminalItem = NSMenuItem(
            title: "Open Project Folder in Terminal",
            action: #selector(openProjectInTerminalClicked(_:)),
            keyEquivalent: ""
        )
        openTerminalItem.target = self
        openTerminalItem.representedObject = session
        menu.addItem(openTerminalItem)

        return menu
    }

    @objc private func resumeClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        do {
            try sessionResumer.resume(session: session)
        } catch {
            presentResumeError(error)
        }
    }

    @objc private func copySessionIdClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(session.rawSessionId, forType: .string)
    }

    /// Put a ready-to-paste `cd '<cwd>' && claude --resume '<sid>'` onto
    /// the pasteboard. Useful when Automation permission or PATH issues
    /// prevent the in-process Terminal launch — the user can paste into
    /// their preferred terminal (iTerm, Warp, Ghostty, tmux, etc.) and
    /// run it by hand.
    @objc private func copyResumeCommandClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        do {
            try sessionResumer.copyResumeCommand(for: session)
        } catch {
            presentResumeError(error)
        }
    }

    // MARK: - Main-menu wiring (keyboard shortcuts)

    /// The session currently highlighted in the outline. `nil` when the
    /// selection is on a group header, a "more" row, or when nothing is
    /// selected — used by the main-menu shortcut handlers to decide
    /// whether the action applies right now.
    private func selectedSessionFromList() -> Session? {
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SessionListNode,
              case .session(let session) = node.kind else {
            return nil
        }
        return session
    }

    /// Main-menu target for Session → "Resume in Claude Code" (⌘R).
    /// The context menu's own item calls `resumeClicked(_:)` with a
    /// captured representedObject; this variant runs on the outline's
    /// current selection so the shortcut works even when no menu is
    /// open. AppKit disables the menu item (via `validateMenuItem`)
    /// when there is no session selection, which prevents the beep.
    @objc func resumeSelectedSession(_ sender: Any?) {
        guard let session = selectedSessionFromList() else { return }
        do {
            try sessionResumer.resume(session: session)
        } catch {
            presentResumeError(error)
        }
    }

    /// Main-menu target for Session → "Copy Resume Command" (⇧⌘C).
    /// Same selection semantics as `resumeSelectedSession(_:)`.
    @objc func copyResumeCommandForSelectedSession(_ sender: Any?) {
        guard let session = selectedSessionFromList() else { return }
        do {
            try sessionResumer.copyResumeCommand(for: session)
        } catch {
            presentResumeError(error)
        }
    }

    /// Disable the session-level menu items when the outline has no
    /// session selection, which is what stops the system bell on ⌘R.
    /// `focusSearchField(_:)` is always valid as long as this VC is in
    /// the responder chain, so it isn't gated here.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(resumeSelectedSession(_:)),
             #selector(copyResumeCommandForSelectedSession(_:)):
            // Both providers resume now; enable only when a session row
            // is actually selected. The resume item's title tracks the
            // selection's provider ("Resume in Claude Code" / "Resume in
            // Codex") so the main-menu label matches the context menu,
            // and falls back to a neutral label when nothing is selected.
            let session = selectedSessionFromList()
            if menuItem.action == #selector(resumeSelectedSession(_:)) {
                menuItem.title = session
                    .map { "Resume in \($0.provider.descriptor.displayName)" }
                    ?? "Resume Session"
            }
            return session != nil
        default:
            return true
        }
    }

    @objc private func togglePinClicked(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        settings.togglePin(sessionId: sessionId)
        // Observation fires synchronously on the same run loop tick — the
        // sidebar rebuild picks up the new pinned set and reorders (flat)
        // / refreshes icons (grouped) on the same click. No manual reload
        // needed here.
    }

    @objc private func revealJSONLClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session,
              let url = store.jsonlFileURL(for: session.id) else { return }
        // Matches DetailViewController.revealInFinder: `open -R` is
        // sandbox-friendlier than NSWorkspace.activateFileViewerSelecting
        // and doesn't require a Finder-specific entitlement.
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-R", url.path]
        try? process.run()
    }

    /// Open the session's recorded working directory (the project
    /// folder where Claude Code was running) in Finder. Reuses
    /// `SessionResumer.resolveCwd` so the lookup matches Resume's
    /// two-stage fallback (decoder fast-path → JSONL `cwd` lookup),
    /// which means the menu item works for any session Resume can
    /// also handle. `open <dir>` (without `-R`) lands the user
    /// inside the folder, not on it.
    @objc private func openProjectFolderClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        do {
            let cwd = try resolveProjectFolder(for: session)
            let process = Process()
            process.launchPath = "/usr/bin/open"
            process.arguments = [cwd]
            try process.run()
        } catch {
            presentSessionError(messageText: "Couldn't Open Project Folder", error: error)
        }
    }

    /// Twin of `openProjectFolderClicked` for Terminal.app. `open -a
    /// Terminal <dir>` opens a new Terminal window with the directory
    /// as its working directory — no AppleScript / Automation
    /// permission needed (unlike `SessionResumer.resume` which has to
    /// inject a `claude --resume` command into the new shell).
    @objc private func openProjectInTerminalClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        do {
            let cwd = try resolveProjectFolder(for: session)
            let process = Process()
            process.launchPath = "/usr/bin/open"
            process.arguments = ["-a", "Terminal", cwd]
            try process.run()
        } catch {
            presentSessionError(messageText: "Couldn't Open Project Folder", error: error)
        }
    }

    /// Surface a SessionResumer failure to the user. Uses the error's
    /// `LocalizedError` description when available (SessionResumer's
    /// ResumeError conforms) so the text is already written for humans.
    private func presentResumeError(_ error: Swift.Error) {
        presentSessionError(messageText: "Couldn't Resume Session", error: error)
    }

    private func resolveProjectFolder(for session: Session) throws -> String {
        if session.provider == .codex,
           let path = session.projectPath,
           FileManager.default.fileExists(atPath: path) {
            return path
        }
        return try sessionResumer.resolveCwd(for: session)
    }

    /// Single source of truth for session-action failure alerts.
    /// `messageText` is the action-specific title ("Couldn't Resume
    /// Session" / "Couldn't Open Project Folder"), the body comes
    /// from the error's `LocalizedError.errorDescription` so each
    /// caller doesn't re-write the human-readable explanation.
    private func presentSessionError(messageText: String, error: Swift.Error) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Public API

    /// Move keyboard focus to the sidebar's search field and select
    /// whatever text is already in it, so ⌘F in the Edit menu behaves
    /// like Mail and Finder — the user can immediately start typing
    /// a new query or replace the one they already have.
    ///
    /// Wired up through the responder chain: `AppDelegate` installs a
    /// `Find` menu item with a `nil` target and this selector. AppKit
    /// walks the first-responder chain looking for anyone that
    /// implements `focusSearchField(_:)`, which lands here when focus
    /// is in the sidebar, and lands on `DashboardSplitViewController`
    /// (which forwards back to us) when focus is anywhere else inside
    /// the dashboard. Exposing the method as `@objc` is required for
    /// the selector match.
    @objc func focusSearchField(_ sender: Any?) {
        guard let window = view.window else { return }
        window.makeFirstResponder(searchField)
        // `selectText(_:)` on NSSearchField selects the entire current
        // contents, matching the Mail/Finder convention where ⌘F on a
        // non-empty field replaces the query with the first keystroke.
        searchField.selectText(nil)
    }

    /// Select the "most relevant" session if nothing is currently selected,
    /// and expand only the group that owns it. Everything else stays collapsed.
    ///
    /// Priority:
    /// 1. The active session (currently streaming / most recently appended),
    ///    because that's the one the user is actually working in right now.
    /// 2. Otherwise, the first session of the first (most-recent activity) group.
    func selectFirstSessionIfNeeded() {
        guard automaticSessionSelectionEnabled else { return }
        guard outlineView.selectedRow < 0 else { return }

        // Prefer the active session's node if it's in the tree.
        if let activeId = store.activeSession?.id,
           let activeNode = sessionNodesById[activeId],
           let parentRoot = rootNodes.first(where: { $0.children.contains(where: { $0 === activeNode }) }),
           case .session(let session) = activeNode.kind {
            autoExpandAndSelect(parent: parentRoot, child: activeNode, session: session)
            return
        }

        // Fallback: first session of the first group.
        for root in rootNodes {
            if let firstChild = root.children.first,
               case .session(let session) = firstChild.kind {
                autoExpandAndSelect(parent: root, child: firstChild, session: session)
                return
            }
        }
    }

    private func autoExpandAndSelect(
        parent: SessionListNode,
        child: SessionListNode,
        session: Session
    ) {
        outlineView.expandItem(parent)
        if let key = parent.projectKey {
            let wasCollapsed = expandedProjectKeys.insert(key).inserted
            // Persist the auto-expand so next launch remembers the group
            // that contained the active session — avoids "why is my
            // selected session's group collapsed every cold start?".
            if wasCollapsed { scheduleSaveExpandedState() }
        }
        let row = outlineView.row(forItem: child)
        if row >= 0 {
            isProgrammaticSelectionChange = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isProgrammaticSelectionChange = false
            outlineView.scrollRowToVisible(row)
            onSessionSelected?(session)

            // Steal first-responder status from whatever control
            // AppKit picked during automatic key-loop recalculation.
            // Without this, `NSSearchField` — as an editable text
            // control — wins the first-responder contest on cold
            // launch, so the dashboard opens with the cursor in the
            // search field instead of the selected session row. That
            // reads as "focus on search" and steals keyboard
            // navigation from the user. We claim it here because
            // this method is only called when we've just
            // *programmatically* moved the selection (either via
            // `selectFirstSessionIfNeeded` on launch or an explicit
            // active-session auto-select), which is exactly the
            // moment we want keyboard focus on the sidebar.
            if let window = view.window {
                window.makeFirstResponder(outlineView)
            }
        }
    }
}

// MARK: - SessionListNode

/// NSOutlineView item wrapper for the sidebar tree.
///
/// NSOutlineView requires items to be reference types with stable identity, so
/// we wrap the `Session` value type (and the synthetic project-group header) in
/// an `NSObject` subclass keyed by `identityKey`.
private final class SessionListNode: NSObject {

    enum Kind {
        case projectGroup(key: String, label: String, count: Int, hiddenCount: Int, expanded: Bool)
        case session(Session)
        /// "Show N more" / "Show less" action row at the bottom of a
        /// paginated group. Clicking the main area bumps the group's
        /// visible-session window by one page; when `canCollapse` is true
        /// a trailing "Show less" control (or, with nothing left to
        /// reveal, the whole row) resets the window back to one page.
        /// `nextStep`/`remainingAfterStep`/`canCollapse` are captured from
        /// `SessionPagination.Window` so the cell can render the caption
        /// without recomputing.
        case loadMore(projectKey: String, nextStep: Int, remainingAfterStep: Int, canCollapse: Bool)
    }

    let kind: Kind
    /// Only populated for `.projectGroup` nodes.
    var children: [SessionListNode] = []

    init(kind: Kind) {
        self.kind = kind
        super.init()
    }

    var identityKey: String {
        switch kind {
        case .projectGroup(let key, _, _, _, _): return "group:\(key)"
        case .session(let s):                return "session:\(s.id)"
        case .loadMore(let key, _, _, _):    return "loadMore:\(key)"
        }
    }

    /// Project key iff this node is a group header.
    var projectKey: String? {
        if case .projectGroup(let k, _, _, _, _) = kind { return k }
        return nil
    }

    var sessionId: String? {
        if case .session(let s) = kind { return s.id }
        return nil
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SessionListNode else { return false }
        return identityKey == other.identityKey
    }

    override var hash: Int { identityKey.hashValue }
}

// MARK: - Session Cell View

/// Single-session row rendered as a three-line stack:
///
///   ● Session title           <-- first Turn's TurnPreview or slug (13pt semibold)
///    ⎇ branch-name            <-- last known gitBranch, monospace 11pt secondary
///    04/14 11:52 · 71 req · $10.02
///
/// The layout deliberately pulls the active-session dot to the left of the
/// *title* row only, matching Mail's unread indicator. Metadata lines sit
/// flush to the dot's right edge so the three lines form a single column.
/// All three lines share the same leading anchor, which keeps the eye tracking
/// vertically even as row contents differ in length.
///
/// The project name is not shown here anymore — it lives in the group header
/// above (and collapses with the group).
final class SessionCellView: NSTableCellView {

    private let titleLabel = NSTextField(labelWithString: "")
    /// Filled `tag.fill` SF Symbol rendered in front of the title for
    /// sessions the user named via Claude Code's `/rename`. Semantic:
    /// "user-assigned label." We considered `pencil` for the
    /// "hand-edited" metaphor but its thin line-drawing rendered too
    /// faint against the dark sidebar even with accent colour — the
    /// filled tag shape is large enough to be scannable at a glance.
    /// Tinted in the system accent colour to make "labels I chose"
    /// immediately visible.
    ///
    /// Always in the view hierarchy so we only toggle `isHidden` on
    /// reuse; the layout width is controlled by an active/inactive
    /// constraint swap (see `titleLeadingWithTag` / `titleLeadingNoTag`
    /// in `setupSubviews`) so the title slides seamlessly between
    /// "flush to dot" and "after icon" positions.
    private let customTitleIcon = NSImageView()
    /// `pin.fill` glyph rendered between the customTitle icon and title
    /// when the session is pinned. Visible in both layout modes — in
    /// Grouped it's purely informational (order unaffected), in Flat it
    /// indicates "this is why the row sits above more-recent ones."
    /// Kept in the hierarchy always; hidden via `isHidden` on reuse.
    private let pinIcon = NSImageView()
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    /// Dedicated cost label pinned to the title row's trailing edge.
    /// Carries the session total so it survives sidebar narrowing — the
    /// title truncates first (lower compression resistance), the price
    /// stays. Mirrors the turn outline's Cost column tinting via CostColor.
    private let costLabel = NSTextField(labelWithString: "")
    private let activeDot = NSView()
    /// `person.2.fill` glyph + small count rendered as a paired view in the
    /// trailing edge of the meta row when the session has spawned at least
    /// one sub-agent (Plan 9 Phase B sidebar visibility). Hidden otherwise.
    private let subAgentIcon = NSImageView()
    private let subAgentCountLabel = NSTextField(labelWithString: "")

    // Branch row is conditional — some sessions have no gitBranch value at all
    // (legacy cached sessions, or entries from before we started parsing it).
    // We keep the view in the hierarchy but toggle its `isHidden` and zero out
    // its height constraints so the title sits right above the meta line.
    private var branchTopToTitle: NSLayoutConstraint!
    private var metaTopToBranch: NSLayoutConstraint!
    private var metaTopToTitleDirect: NSLayoutConstraint!
    /// Title leading toggles between "after active dot" (no tag) and
    /// "after tag icon" (user-named). The same active/inactive pair
    /// pattern as the branch row keeps layout predictable and avoids
    /// zero-width ghost constraints.
    private var titleLeadingNoTag: NSLayoutConstraint!
    private var titleLeadingWithTag: NSLayoutConstraint!
    /// Title leading when the pin icon is shown. Pin sits to the right of
    /// either the active dot (no tag) or the custom-title tag, so the pin
    /// icon's leading anchor toggles via the pair below; the title just
    /// follows the pin's trailing.
    private var titleLeadingWithPin: NSLayoutConstraint!
    /// Pin leading when there's no custom-title icon in front of it.
    private var pinLeadingAfterDot: NSLayoutConstraint!
    /// Pin leading when the custom-title tag is also visible.
    private var pinLeadingAfterTag: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Indicator weight: user explicitly chose to name this session, so
        // the glyph is tinted in the system accent colour (same blue as
        // selection highlights, sidebar focus rings, and Finder tag dots).
        // That makes user-named sessions scannable at a glance — the
        // previous tertiary-grey rendering blended into the meta row.
        // `tag.fill` over `pencil`: the filled glyph has enough ink
        // density to remain legible at small sizes; the pencil line
        // drawing was too faint against dark-mode sidebar backgrounds.
        if let img = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: "Custom title") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            customTitleIcon.image = img.withSymbolConfiguration(config)
        }
        customTitleIcon.contentTintColor = .controlAccentColor
        customTitleIcon.toolTip = "Renamed via /rename"
        // VoiceOver already reads the title; the icon's semantic is
        // folded into the cell's accessibilityLabel below, so the icon
        // itself should be skipped.
        customTitleIcon.setAccessibilityElement(false)

        // Pin indicator — subdued (tertiary) tint so it reads as a status
        // glyph, not a call to action. 10pt fits between the custom-title
        // tag (11pt accent) and the sub-agent indicator (9pt tertiary) in
        // the visual weight hierarchy. Pin is semantically "this row is
        // anchored to the top in Flat layout."
        if let img = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            pinIcon.image = img.withSymbolConfiguration(config)
        }
        pinIcon.contentTintColor = .tertiaryLabelColor
        pinIcon.toolTip = "Pinned to top"
        pinIcon.setAccessibilityElement(false)

        if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Git branch") {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            branchIcon.image = img.withSymbolConfiguration(config)
        }
        branchIcon.contentTintColor = .tertiaryLabelColor

        branchLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.maximumNumberOfLines = 1

        metaLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        // Match the branch row (`.secondaryLabelColor`) — the project meta
        // row sits in the same visual column as the branch label and the
        // two are read together ("which project / which branch / which
        // cost-slice"). The previous `.tertiaryLabelColor` was a step too
        // dim and made the cost figure hard to scan against the title.
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1

        costLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        costLabel.textColor = .labelColor
        costLabel.alignment = .right
        costLabel.lineBreakMode = .byClipping
        costLabel.maximumNumberOfLines = 1
        // 비용은 핵심 지표 — 절대 안 잘리고 폭도 안 늘어남. 제목이 먼저 …로 양보.
        costLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        costLabel.setContentHuggingPriority(.required, for: .horizontal)

        activeDot.wantsLayer = true
        activeDot.layer?.cornerRadius = 3
        activeDot.layer?.backgroundColor = NSColor.systemGreen.cgColor

        // Sub-agent indicator — 9pt `person.2.fill` + small count, both
        // tertiary-tinted so they sit quietly in the meta row instead of
        // competing visually with the accent-colored `tag.fill`. Always in
        // the hierarchy; toggled via `isHidden` per session.
        if let img = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Sub-agent") {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            subAgentIcon.image = img.withSymbolConfiguration(config)
        }
        subAgentIcon.contentTintColor = .tertiaryLabelColor
        subAgentIcon.setAccessibilityElement(false)
        subAgentCountLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        subAgentCountLabel.textColor = .tertiaryLabelColor
        subAgentCountLabel.setAccessibilityElement(false)

        for v in [activeDot, customTitleIcon, pinIcon, titleLabel, branchIcon, branchLabel, metaLabel,
                  costLabel, subAgentIcon, subAgentCountLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // Shared leading column for ALL sub-rows (branch, meta). Anchored
        // to the active-dot trailing edge, NOT the title — so when the
        // customTitle indicator pushes the title right, branch/meta stay
        // put and the sidebar retains a clean vertical left edge.
        // Matches the Finder pattern where tagged files don't misalign
        // metadata columns across rows.
        let leftColumnAnchor = activeDot.trailingAnchor
        let leftColumnInset: CGFloat = 6

        branchTopToTitle = branchLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        metaTopToBranch = metaLabel.topAnchor.constraint(equalTo: branchLabel.bottomAnchor, constant: 2)
        metaTopToTitleDirect = metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)

        titleLeadingNoTag = titleLabel.leadingAnchor.constraint(equalTo: activeDot.trailingAnchor, constant: leftColumnInset)
        titleLeadingWithTag = titleLabel.leadingAnchor.constraint(equalTo: customTitleIcon.trailingAnchor, constant: 4)
        titleLeadingWithPin = titleLabel.leadingAnchor.constraint(equalTo: pinIcon.trailingAnchor, constant: 4)
        pinLeadingAfterDot = pinIcon.leadingAnchor.constraint(equalTo: activeDot.trailingAnchor, constant: leftColumnInset)
        pinLeadingAfterTag = pinIcon.leadingAnchor.constraint(equalTo: customTitleIcon.trailingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            // Active indicator — small square dot flush-left, aligned with the title row.
            activeDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            activeDot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            activeDot.widthAnchor.constraint(equalToConstant: 6),
            activeDot.heightAnchor.constraint(equalToConstant: 6),

            // Custom-title indicator — rendered only when session.customTitle
            // wins the priority ladder (see SessionTitleResolver.Origin.custom).
            // `firstBaselineAnchor` aligns the pencil's optical center with
            // the title's cap-height midline. Pure centerY leaves the icon
            // visually floating above the text because SF Symbol `pencil`
            // has extra top padding in its bounding box.
            customTitleIcon.leadingAnchor.constraint(equalTo: activeDot.trailingAnchor, constant: leftColumnInset),
            customTitleIcon.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -1),
            customTitleIcon.widthAnchor.constraint(equalToConstant: 12),
            customTitleIcon.heightAnchor.constraint(equalToConstant: 12),

            // Pin indicator — baseline-aligned with the title. Leading
            // anchor toggles between "after dot" and "after tag icon" via
            // the pinLeadingAfterDot / pinLeadingAfterTag pair at configure
            // time. Hidden + both constraints inactive when the session
            // isn't pinned.
            pinIcon.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -1),
            pinIcon.widthAnchor.constraint(equalToConstant: 10),
            pinIcon.heightAnchor.constraint(equalToConstant: 10),

            // Title row — title yields to the cost label on the right.
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLeadingNoTag,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: costLabel.leadingAnchor, constant: -8),

            // Dedicated cost label — title-row trailing, baseline-aligned to title.
            costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            costLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            // Branch row — icon + label aligned to the shared left column.
            branchTopToTitle,
            branchIcon.leadingAnchor.constraint(equalTo: leftColumnAnchor, constant: leftColumnInset),
            branchIcon.centerYAnchor.constraint(equalTo: branchLabel.centerYAnchor),
            branchIcon.widthAnchor.constraint(equalToConstant: 11),
            branchIcon.heightAnchor.constraint(equalToConstant: 11),
            branchLabel.leadingAnchor.constraint(equalTo: branchIcon.trailingAnchor, constant: 3),
            branchLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            // Meta row — shared left column. Trailing edge reserves space
            // for the sub-agent indicator pair (icon + count) so the meta
            // text truncates before colliding with the indicator.
            metaTopToBranch,
            metaLabel.leadingAnchor.constraint(equalTo: leftColumnAnchor, constant: leftColumnInset),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: subAgentIcon.leadingAnchor, constant: -6),

            // Sub-agent indicator pair — pinned to the trailing edge,
            // baseline-aligned with the meta row.
            subAgentCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subAgentCountLabel.firstBaselineAnchor.constraint(equalTo: metaLabel.firstBaselineAnchor),
            subAgentIcon.trailingAnchor.constraint(equalTo: subAgentCountLabel.leadingAnchor, constant: -2),
            subAgentIcon.firstBaselineAnchor.constraint(equalTo: metaLabel.firstBaselineAnchor, constant: -1),
            subAgentIcon.widthAnchor.constraint(equalToConstant: 12),
            subAgentIcon.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    func configure(
        title: String,
        isCustomTitle: Bool,
        branch: String?,
        startTime: String,
        requestCount: Int,
        totalTokens: Int,
        totalCost: Double,
        costConfidence: CostConfidence,
        provider: ProviderKind,
        isActive: Bool,
        subAgentCount: Int = 0,
        projectLabel: String? = nil,
        isPinned: Bool = false
    ) {
        // Promote any `🖼` marker embedded by `TurnPreview.make` into an
        // inline SF Symbol `photo` attachment so the glyph's weight /
        // tone matches the Conversation detail tab and the Turn outline.
        // Plain `stringValue` would fall through to Apple Color Emoji,
        // which reads visually distinct from surrounding system-font
        // text. Tint is dim (tertiary) so the marker is a quiet cue,
        // not a decoration that pulls the eye off the title.
        titleLabel.attributedStringValue = InlineImageSymbol.promotingImageGlyphs(
            title,
            font: titleLabel.font ?? .systemFont(ofSize: 13, weight: .semibold),
            color: titleLabel.textColor ?? .labelColor,
            attachmentColor: InlineImageSymbol.defaultDimTint
        )

        // Toggle the /rename tag icon + pin icon + title leading constraint
        // combo. Four mutually-exclusive states keep the title's leading
        // edge deterministic:
        //   (tag, pin) → title after pin,    pin after tag,  tag shown
        //   (tag, —)   → title after tag,    pin hidden,     tag shown
        //   (—, pin)   → title after pin,    pin after dot,  tag hidden
        //   (—, —)     → title after dot,    pin hidden,     tag hidden
        customTitleIcon.isHidden = !isCustomTitle
        pinIcon.isHidden = !isPinned

        // Deactivate every pair first so stacked re-configures (cell reuse)
        // don't leave a stale constraint active alongside a new one.
        titleLeadingNoTag.isActive = false
        titleLeadingWithTag.isActive = false
        titleLeadingWithPin.isActive = false
        pinLeadingAfterDot.isActive = false
        pinLeadingAfterTag.isActive = false

        switch (isCustomTitle, isPinned) {
        case (true, true):
            pinLeadingAfterTag.isActive = true
            titleLeadingWithPin.isActive = true
        case (true, false):
            titleLeadingWithTag.isActive = true
        case (false, true):
            pinLeadingAfterDot.isActive = true
            titleLeadingWithPin.isActive = true
        case (false, false):
            titleLeadingNoTag.isActive = true
        }

        // Dedicated cost label on the title row.
        let costDisplay = CostColor.display(cost: totalCost, confidence: costConfidence)
        costLabel.stringValue = costDisplay.text
        costLabel.textColor = costDisplay.color
        // Codex 신뢰도 설명 툴팁은 비용 라벨로 이동(이전엔 metaLabel에 붙였음).
        costLabel.toolTip = Self.costTooltip(provider: provider, confidence: costConfidence)

        // Format numbers tersely. "·" is a middle-dot separator — more compact
        // than " · " or "  " and reads well at 10pt.
        let requests = CompactNumber.compact(requestCount)
        // Flat layout surfaces the project in the meta row (Grouped shows it
        // in the group header, so we skip it there). Cost has moved to the
        // dedicated costLabel on the title row; meta now shows project, time, req.
        let metaParts = [
            projectLabel,
            startTime,
            "\(requests) req",
        ].compactMap { $0 }.filter { !$0.isEmpty }
        metaLabel.stringValue = metaParts.joined(separator: " · ")
        metaLabel.toolTip = Self.metadataTooltip(
            requestCount: requestCount,
            totalTokens: totalTokens
        )

        // Toggle branch row presence.
        if let branch, !branch.isEmpty {
            branchIcon.isHidden = false
            branchLabel.isHidden = false
            branchLabel.stringValue = branch
            branchTopToTitle.isActive = true
            metaTopToTitleDirect.isActive = false
            metaTopToBranch.isActive = true
        } else {
            branchIcon.isHidden = true
            branchLabel.isHidden = true
            branchLabel.stringValue = ""
            branchTopToTitle.isActive = false
            metaTopToBranch.isActive = false
            metaTopToTitleDirect.isActive = true
        }

        activeDot.isHidden = !isActive
        // (Background colour is set once in setupSubviews — the previous
        // duplicate assignment here was dead code. Reuse pool reuses the
        // same NSView instance so we don't need to re-paint.)

        // Sub-agent indicator — only visible when the session has at
        // least one Agent invocation linked. The count helps users
        // gauge "how much extra burn lives inside this row" before
        // they open it (Phase B sidebar visibility for Plan 9).
        if subAgentCount > 0 {
            subAgentIcon.isHidden = false
            subAgentCountLabel.isHidden = false
            subAgentCountLabel.stringValue = "\(subAgentCount)"
            subAgentIcon.toolTip = "\(subAgentCount) sub-agent invocation\(subAgentCount == 1 ? "" : "s")"
        } else {
            subAgentIcon.isHidden = true
            subAgentCountLabel.isHidden = true
            subAgentCountLabel.stringValue = ""
            subAgentIcon.toolTip = nil
        }

        // VoiceOver: fold the user-renamed state and branch/meta into a
        // single synthesized label so the row reads as one coherent
        // description instead of multiple disjoint elements. The icon
        // itself is marked non-accessible in setupSubviews.
        var a11yParts: [String] = [title]
        if isPinned { a11yParts.append("pinned") }
        if isCustomTitle { a11yParts.append("renamed") }
        if let branch, !branch.isEmpty { a11yParts.append("branch \(branch)") }
        if !metaParts.isEmpty { a11yParts.append(metaParts.joined(separator: ", ")) }
        if totalTokens > 0 {
            a11yParts.append("\(Self.formatCount(totalTokens)) tokens")
        }
        if provider == .codex {
            switch costConfidence {
            case .partial:
                a11yParts.append("estimated Codex cost")
            case .unavailable:
                a11yParts.append("Codex cost unavailable")
            case .notBillable, .exact:
                break
            }
        }
        if subAgentCount > 0 {
            a11yParts.append("\(subAgentCount) sub-agent\(subAgentCount == 1 ? "" : "s")")
        }
        self.setAccessibilityLabel(a11yParts.joined(separator: ", "))
    }

    private static func costTooltip(provider: ProviderKind, confidence: CostConfidence) -> String? {
        CostConfidencePresentation.sidebarTooltip(provider: provider, confidence: confidence)
    }

    private static func metadataTooltip(
        requestCount: Int,
        totalTokens: Int
    ) -> String? {
        let lines = [
            "Requests: \(formatCount(requestCount))",
            "Tokens: \(formatCount(totalTokens))",
        ]
        return lines.joined(separator: "\n")
    }

    private static func formatCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    // MARK: - Test seams

    func costDisplayForTesting(totalCost: Double, confidence: CostConfidence) -> (text: String, color: NSColor) {
        let d = CostColor.display(cost: totalCost, confidence: confidence)
        return (d.text, d.color)
    }
    var costLabelCompressionResistanceForTesting: Float {
        costLabel.contentCompressionResistancePriority(for: .horizontal).rawValue
    }
    var titleLabelCompressionResistanceForTesting: Float {
        titleLabel.contentCompressionResistancePriority(for: .horizontal).rawValue
    }
    func metaTooltipForTesting(requestCount: Int, totalTokens: Int) -> String? {
        Self.metadataTooltip(requestCount: requestCount, totalTokens: totalTokens)
    }
}

// MARK: - Group Header Cell

/// Project group header row — folder glyph + label + session-count badge.
/// Layout matches the Mail sidebar "Smart Mailboxes" header style.
private final class SessionListGroupHeaderView: NSTableCellView {

    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    /// Right-aligned [count][hiddenToggle] row. The stack drops the toggle
    /// from layout when hidden, so the count sits flush right when a group
    /// has no low-signal sessions.
    private let rightStack = NSStackView()

    /// To the RIGHT of the count: "(N)" — how many low-signal (zero-cost)
    /// sessions are collapsed; clicking toggles them in place. Detached from
    /// the stack (isHidden) when the group has none.
    /// `SessionListOutlineView.mouseDown` hit-tests `isHiddenToggleHit(at:)`
    /// to route a click here instead of expand/collapse.
    private let hiddenToggle = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        if let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown

        labelField.font = .systemFont(ofSize: 11, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        labelField.lineBreakMode = .byTruncatingMiddle
        labelField.maximumNumberOfLines = 1

        countField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countField.textColor = .tertiaryLabelColor
        countField.alignment = .right

        hiddenToggle.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        hiddenToggle.alignment = .right

        rightStack.orientation = .horizontal
        rightStack.spacing = 5
        rightStack.alignment = .centerY
        rightStack.addArrangedSubview(countField)
        rightStack.addArrangedSubview(hiddenToggle)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)
        rightStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [iconView, labelField, rightStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            labelField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -6),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(label: String, count: Int, hiddenCount: Int, expanded: Bool) {
        labelField.stringValue = label.uppercased()
        countField.stringValue = "\(count)"

        if hiddenCount > 0 {
            hiddenToggle.isHidden = false
            // Brighter when expanded (sessions shown), dimmer when collapsed.
            // Parenthesised so it reads apart from the group's session count.
            hiddenToggle.textColor = expanded ? .secondaryLabelColor : .tertiaryLabelColor
            hiddenToggle.stringValue = "(\(hiddenCount))"
            let action = expanded ? "Hide" : "Show"
            setAccessibilityLabel("\(label), \(count) sessions, \(action) \(hiddenCount) hidden")
        } else {
            hiddenToggle.isHidden = true
            hiddenToggle.stringValue = ""
            setAccessibilityLabel("\(label), \(count) sessions")
        }
        setAccessibilityRole(.disclosureTriangle)
    }

    /// True when `point` (in this cell's coordinate space) lands on the
    /// hidden-toggle. `SessionListOutlineView.mouseDown` uses this to route
    /// the click to the toggle instead of expanding/collapsing.
    func isHiddenToggleHit(at point: NSPoint) -> Bool {
        guard !hiddenToggle.isHidden else { return false }
        // Convert the toggle's bounds into cell coordinates (it lives inside
        // `rightStack`), plus a few points of horizontal grace.
        let rect = convert(hiddenToggle.bounds, from: hiddenToggle)
        return point.x >= rect.minX - 4 && point.x <= rect.maxX + 4
    }
}

// MARK: - Codex Load Summary

private final class CodexLoadSummaryPanel: NSView {
    private let titleLabel = NSTextField(labelWithString: "Codex index")
    private let cacheLabel = NSTextField(labelWithString: "")
    private let primaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func setupSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        cacheLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        cacheLabel.alignment = .right
        cacheLabel.lineBreakMode = .byTruncatingTail

        primaryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        primaryLabel.textColor = .secondaryLabelColor
        primaryLabel.lineBreakMode = .byTruncatingTail

        for view in [titleLabel, cacheLabel, primaryLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.widthAnchor.constraint(equalToConstant: 72),

            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            primaryLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            primaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: cacheLabel.leadingAnchor, constant: -8),

            cacheLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            cacheLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            cacheLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
    }

    func apply(_ summary: CodexLoadSummary?) {
        guard let summary else { return }

        cacheLabel.stringValue = Self.cacheText(summary.cacheStatus)
        cacheLabel.textColor = Self.cacheColor(summary.cacheStatus)
        primaryLabel.stringValue = [
            "\(Self.format(summary.sessionCount)) sessions",
            "\(Self.format(summary.tokenEventCount)) events"
        ].joined(separator: " · ")

        let hasWarnings = summary.rejectedLineCount > 0 || summary.unknownPricingCount > 0
        if hasWarnings {
            titleLabel.textColor = .systemOrange
            primaryLabel.stringValue = [
                "\(Self.format(summary.rejectedLineCount)) rejected",
                "\(Self.format(summary.unknownPricingCount)) unknown pricing"
            ].joined(separator: " · ")
        } else {
            titleLabel.textColor = .secondaryLabelColor
        }
        toolTip = """
        Codex load result
        Files: \(summary.discoveredFileCount)
        Parsed rollout files: \(summary.parsedRolloutFileCount)
        Sessions: \(summary.sessionCount)
        Token events: \(summary.tokenEventCount)
        Rejected lines: \(summary.rejectedLineCount)
        Unknown pricing: \(summary.unknownPricingCount)
        Cache: \(summary.cacheStatus.rawValue)
        """
    }

    private func updateLayerColors() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
    }

    private static func cacheText(_ status: CodexUsageCacheStatus) -> String {
        switch status {
        case .hit: return "Cache hit"
        case .partial: return "Partial"
        case .miss: return "Parsed"
        }
    }

    private static func cacheColor(_ status: CodexUsageCacheStatus) -> NSColor {
        switch status {
        case .hit: return .systemGreen
        case .partial: return .secondaryLabelColor
        case .miss: return .tertiaryLabelColor
        }
    }

    private static func format(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

// MARK: - Load More Cell

/// "Show N more" / "Show less" action row at the bottom of a paginated
/// group.
///
/// Visually positioned as a subtle hint — smaller than session rows, left
/// indented to line up under the sessions, monospaced chevron icon to
/// match the branch icon's visual weight from `SessionCellView`.
/// Not a real button: `SessionListOutlineView.mouseDown` routes clicks,
/// asking this cell (via `isShowLessHit`) whether the click landed on the
/// trailing "Show less" control.
///
/// Three render modes, all reusing the same row identity so the outline
/// reload diffing treats mode flips as a reconfigure, not a row swap:
///   * more-only  (`nextStep > 0`, `canCollapse == false`) — the original
///     "Show 5 more (42 left)" hint, whole row loads more.
///   * more+less  (`nextStep > 0`, `canCollapse == true`)  — same leading
///     hint plus a trailing "Show less" control.
///   * less-only  (`nextStep == 0`, `canCollapse == true`) — everything is
///     revealed; the leading hint becomes "Show less" (chevron up) and the
///     whole row collapses.
private final class SessionListLoadMoreCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let showLessLabel = NSTextField(labelWithString: "Show less")

    /// Whether the whole row currently acts as "Show less" (less-only mode).
    private var isCollapseOnly = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        showLessLabel.font = .systemFont(ofSize: 11, weight: .medium)
        showLessLabel.textColor = .tertiaryLabelColor
        showLessLabel.maximumNumberOfLines = 1
        showLessLabel.setAccessibilityRole(.button)
        showLessLabel.setAccessibilityLabel("Show less")

        for v in [iconView, label, showLessLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            // Indent to roughly match the active dot of SessionCellView, so
            // the hint visually nests under the sessions instead of snapping
            // back to the header's leading edge.
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 10),
            iconView.heightAnchor.constraint(equalToConstant: 10),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: showLessLabel.leadingAnchor, constant: -8
            ),

            showLessLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            showLessLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func setIcon(systemName: String, description: String) {
        if let img = NSImage(systemSymbolName: systemName, accessibilityDescription: description) {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
        }
    }

    /// - Parameters:
    ///   - nextStep: how many rows the next click will add (typically the
    ///     pageSize, or fewer if we're on the final partial page). `0`
    ///     means nothing is left to reveal — the row exists purely as a
    ///     collapse affordance.
    ///   - remainingAfterStep: how many sessions will *still* be hidden after
    ///     this click — used to surface "(42 left)" in subdued parens so the
    ///     user knows roughly how much is left without having to count.
    ///   - canCollapse: the group's window has grown past one page, so a
    ///     "Show less" control is meaningful.
    func configure(nextStep: Int, remainingAfterStep: Int, canCollapse: Bool) {
        isCollapseOnly = canCollapse && nextStep == 0
        if isCollapseOnly {
            setIcon(systemName: "chevron.up", description: "Show less")
            label.stringValue = "Show less"
            showLessLabel.isHidden = true
        } else {
            setIcon(systemName: "chevron.down", description: "Show more")
            if remainingAfterStep > 0 {
                label.stringValue = "Show \(nextStep) more (\(remainingAfterStep) left)"
            } else {
                label.stringValue = "Show \(nextStep) more"
            }
            showLessLabel.isHidden = !canCollapse
        }
        setAccessibilityLabel(label.stringValue)
        setAccessibilityRole(.button)
    }

    /// Hit test used by `SessionListOutlineView.mouseDown` to decide which
    /// of the two actions a click on this row means. `point` is in this
    /// cell's coordinate space. In less-only mode the whole row collapses;
    /// otherwise only the trailing control (with a small grace margin for
    /// its 11pt hit target) does.
    func isShowLessHit(at point: NSPoint) -> Bool {
        if isCollapseOnly { return true }
        guard !showLessLabel.isHidden else { return false }
        return point.x >= showLessLabel.frame.minX - 6
    }
}

#if DEBUG
extension SessionListViewController {
    func emptyStateTitleForTesting() -> String {
        emptyTitleLabel.stringValue
    }

    func emptyStateSubtitleForTesting() -> String {
        emptySubtitleLabel.stringValue
    }

    func isEmptyStateVisibleForTesting() -> Bool {
        !emptyStateView.isHidden
    }

    func isEmptyStateLoadingForTesting() -> Bool {
        !emptyProgressIndicator.isHidden
    }

    func lastRenderedProviderForTesting() -> ProviderKind {
        lastRenderSnapshot.activeProvider
    }

    func reloadDataForTesting() {
        reloadData()
    }

    func pendingAutoSelectProviderForTesting() -> ProviderKind? {
        pendingAutoSelectProvider
    }

    func selectedSessionIdForTesting() -> String? {
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SessionListNode,
              case .session(let session) = node.kind else {
            return nil
        }
        return session.id
    }

    // MARK: Pagination seams (task 6.11)

    /// Session ids currently rendered inside the given group, in row order.
    /// `projectKey` is the provider-scoped key (`"<provider>:<projectPath>"`).
    func visibleSessionIdsForTesting(projectKey: String) -> [String] {
        guard let group = rootNodes.first(where: { $0.projectKey == projectKey }) else {
            return []
        }
        return group.children.compactMap(\.sessionId)
    }

    /// The group's action-row state, or nil when no row is rendered.
    func loadMoreRowStateForTesting(
        projectKey: String
    ) -> (nextStep: Int, remainingAfterStep: Int, canCollapse: Bool)? {
        guard let group = rootNodes.first(where: { $0.projectKey == projectKey }) else {
            return nil
        }
        for child in group.children {
            if case .loadMore(_, let nextStep, let remainingAfterStep, let canCollapse) = child.kind {
                return (nextStep, remainingAfterStep, canCollapse)
            }
        }
        return nil
    }

    /// Drives the same path as a click on the load-more row's primary area.
    func clickLoadMoreForTesting(projectKey: String) {
        expandNextPage(for: projectKey)
    }

    /// Drives the same path as a click on the "Show less" control.
    func clickShowLessForTesting(projectKey: String) {
        collapseToFirstPage(for: projectKey)
    }

    /// Selects the session row like a user click would (expanding its group
    /// first), so `reloadData`'s selection capture/restore sees a real
    /// outline selection.
    @discardableResult
    func selectSessionForTesting(id: String) -> Bool {
        guard let node = sessionNodesById[id] else { return false }
        if let parent = rootNodes.first(where: { root in
            root.children.contains(where: { $0 === node })
        }) {
            outlineView.expandItem(parent)
            if let key = parent.projectKey { expandedProjectKeys.insert(key) }
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        isProgrammaticSelectionChange = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isProgrammaticSelectionChange = false
        if case .session(let session) = node.kind {
            selectedSessionIdByProvider[session.provider] = session.id
        }
        return true
    }
}
#endif

// MARK: - ProviderModePopupButton

@MainActor
private final class ProviderModePopupButton: NSPopUpButton {
    var accentColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        accentColor.withAlphaComponent(isDark ? 0.22 : 0.13).setFill()
        path.fill()

        super.draw(dirtyRect)

        accentColor.withAlphaComponent(isDark ? 0.55 : 0.34).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - SessionListOutlineView

/// `NSOutlineView` subclass that routes clicks on the two "action" row kinds
/// in the sidebar without touching the user's current session selection:
///
///   * `.projectGroup` header row → toggle expand/collapse on any click
///     location inside the row (not only the tiny disclosure chevron).
///   * `.loadMore` row → invoke `onLoadMoreClicked` with the owning project
///     key so the VC can grow its pagination window.
///
/// Routing happens in `mouseDown(with:)` before AppKit's default hit-test
/// machinery runs, so the previously selected session row never loses its
/// highlight. Session rows fall through to the default handler and keep
/// single-click selection.
final class SessionListOutlineView: NSOutlineView {
    /// Invoked when the user clicks a `.loadMore` row. Argument is the
    /// owning project key. Wired up by `SessionListViewController.viewDidLoad`.
    var onLoadMoreClicked: ((String) -> Void)?

    /// Invoked when the user clicks the "Show less" control on a `.loadMore`
    /// row (or anywhere on the row when nothing is left to reveal). Argument
    /// is the owning project key. Wired up by
    /// `SessionListViewController.viewDidLoad`.
    var onShowLessClicked: ((String) -> Void)?

    /// Invoked when the user clicks a `.hiddenToggle` row. Argument is the
    /// owning project key. Wired up by `SessionListViewController.viewDidLoad`.
    var onHiddenToggleClicked: ((String) -> Void)?

    /// Builds the right-click context menu for a session leaf. Wired up by
    /// `SessionListViewController.viewDidLoad` — returning `nil` from the
    /// closure (or leaving it unset) suppresses the menu for that row.
    /// The outline view subclass only knows how to locate the row under
    /// the cursor; the VC owns the actual NSMenu construction and all
    /// target/action wiring, which keeps Session / store types out of
    /// this subclass.
    var menuProvider: ((Session) -> NSMenu?)?

    /// AppKit calls this on every right-click / control-click over the
    /// outline view. We look up the row under the cursor, check whether
    /// it's a selectable session leaf, and hand the hit to the VC's
    /// `menuProvider`. Returning nil for non-session rows (headers and
    /// load-more rows) suppresses the menu cleanly — neither of those
    /// kinds has meaningful per-row actions.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0,
              let node = self.item(atRow: row) as? SessionListNode,
              case .session(let session) = node.kind
        else { return nil }
        return menuProvider?(session)
    }

    override func mouseDown(with event: NSEvent) {
        // Ignore double-clicks so a sloppy click doesn't toggle twice in a row.
        guard event.clickCount == 1 else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, let node = self.item(atRow: row) as? SessionListNode {
            switch node.kind {
            case .projectGroup(let key, _, _, let hiddenCount, _):
                // A click on the header's hidden-toggle button flips the
                // group's zero-cost bucket; clicks elsewhere on the header
                // expand/collapse the group as usual.
                if hiddenCount > 0,
                   let cell = view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? SessionListGroupHeaderView,
                   cell.isHiddenToggleHit(at: cell.convert(point, from: self)) {
                    onHiddenToggleClicked?(key)
                } else if isItemExpanded(node) {
                    animator().collapseItem(node)
                } else {
                    animator().expandItem(node)
                }
                return
            case .loadMore(let projectKey, let nextStep, _, let canCollapse):
                // Which of the row's (up to) two actions does this click
                // mean? The cell view owns the trailing-control geometry, so
                // delegate the hit test to it. A missing cell view (never
                // expected for a clicked, thus visible, row) falls back to
                // the row's primary action.
                let isShowLess: Bool
                if !canCollapse {
                    isShowLess = false
                } else if nextStep == 0 {
                    isShowLess = true
                } else if let cell = view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? SessionListLoadMoreCellView {
                    isShowLess = cell.isShowLessHit(at: cell.convert(point, from: self))
                } else {
                    isShowLess = false
                }
                if isShowLess {
                    onShowLessClicked?(projectKey)
                } else {
                    onLoadMoreClicked?(projectKey)
                }
                return
            case .session:
                break  // fall through to super
            }
        }
        super.mouseDown(with: event)
    }
}
