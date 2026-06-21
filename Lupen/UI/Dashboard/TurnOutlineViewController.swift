import AppKit
import Observation

@MainActor
enum TurnOutlineCellTextLayout {
    static let verticalInset: CGFloat = 2

    static func applySingleLineBehavior(to textField: NSTextField) {
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byTruncatingTail
        textField.allowsDefaultTighteningForTruncation = true
        textField.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textField.setContentHuggingPriority(.defaultLow, for: .vertical)

        textField.cell?.wraps = false
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.cell?.truncatesLastVisibleLine = true
        (textField.cell as? NSTextFieldCell)?.usesSingleLineMode = true
    }

    static func verticalBoundsConstraints(
        for textField: NSTextField,
        in container: NSView,
        inset: CGFloat = verticalInset
    ) -> [NSLayoutConstraint] {
        [
            textField.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: inset),
            textField.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -inset),
        ]
    }
}

/// Top-right Dashboard panel — Turn is the primary row, Step is its child.
@MainActor
final class TurnOutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let store: AppStateStore
    private let columnStateDefaults: UserDefaults
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    // Empty state
    private let emptyStateView = NSView()
    private let emptyImageView = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "")
    private let emptySubtitleLabel = NSTextField(labelWithString: "")

    // Launch progress overlay (shown while `store.launchProgress` is in any
    // non-terminal phase — `.scanningFiles` / `.indexing`). Lives as a
    // SwiftUI hosting view so we get the determinate progress bar and
    // `.ultraThinMaterial` card for free. Empty state and the overlay are
    // mutually exclusive — see `updateStateVisibility()`.
    private let launchProgressContainer = NSView()

    // Selection callbacks
    var onStepSelected: ((Step, Turn) -> Void)?
    /// Fired when a user clicks a Turn header row (as opposed to an individual
    /// Step row). The detail pane displays a Turn-level summary (aggregate
    /// tokens/cost + the prompt Step's text and attachments).
    ///
    /// Second argument is the same cost the outline header just
    /// displayed (`aggregateCostIncludingSubAgents`) — passed through
    /// so the detail Tokens tab matches the outline value byte-for-
    /// byte instead of falling back to bare `aggregateCost`.
    /// Third argument is the analogous token rollup
    /// (`aggregateTokensIncludingSubAgents`) — same anti-drift
    /// motivation, applied to the 4 token columns.
    var onTurnSelected: ((Turn, CostBreakdown, TokenBreakdown) -> Void)?
    /// Fired when a synthetic SkillGroup header row is selected. The detail
    /// pane receives the group's own step span and aggregate metrics instead
    /// of the whole parent Turn, so selecting `/flow-all` explains that phase.
    var onSkillGroupSelected: ((SkillGroupBuilder.SkillGroup, CostBreakdown, TokenBreakdown) -> Void)?
    var onSelectionCleared: (() -> Void)?

    // State
    private var currentSessionId: String?
    private var turns: [Turn] = []
    /// turnId → TurnOutlineNode (stable identity across reloads)
    private var turnNodes: [String: TurnOutlineNode] = [:]
    /// (turnId, stepUuid) → node
    private var stepNodes: [String: TurnOutlineNode] = [:]
    /// tool_use_id → skillGroup node. Skill group nodes live inside a Turn
    /// but keep their identity across reloads via the stable tool_use_id.
    private var skillGroupNodes: [String: TurnOutlineNode] = [:]
    /// turnId → ordered top-level rows under that Turn (mix of `.step` and
    /// `.skillGroup` per `SkillGroupBuilder.group`). Cached so the
    /// NSOutlineView data source doesn't recompute grouping on every
    /// `numberOfChildrenOfItem` / `child:ofItem:` probe.
    private var groupedRowsByTurn: [String: [SkillGroupBuilder.OutlineRow]] = [:]
    /// agentId → the sub-agent's full Turn (sidechain). Built at
    /// `reloadTurns` from the unfiltered turn list so the parent
    /// Step grafting can resolve `Link.agentId` → sub-agent body
    /// in O(1). Source of truth for `.subAgent` Kind children.
    private var subAgentTurnsByAgentId: [String: Turn] = [:]
    /// parent Step uuid → sub-agent links spawned from that step's
    /// `Agent` tool_use blocks. Built at `reloadTurns` so children
    /// of a `.step` node are O(1) — no per-probe link scanning.
    private var subAgentLinksByStepUuid: [String: [SubAgentLinker.Link]] = [:]
    /// (parentTurnId, parentStepUuid, agentId) → reusable subAgent
    /// node so identity stays stable across reloads (preserves
    /// expansion state).
    private var subAgentNodes: [String: TurnOutlineNode] = [:]
    /// User-expanded subAgent nodes for restoration after reload.
    private var expandedSubAgentKeys: Set<String> = []
    /// Last selected Turn/Step identity per session. Session selection is
    /// restored per provider in the sidebar; this mirrors that behavior for
    /// the conversation outline so switching modes returns to the same row.
    private var selectedIdentityKeyBySessionId: [String: String] = [:]

    /// Per-Turn flattened child list. Each entry is a node that
    /// renders directly under the Turn header in display order:
    /// `.step` / `.skillGroup` from `SkillGroupBuilder`, plus any
    /// `.subAgent` nodes inserted as **siblings** immediately after
    /// the parent step that issued the matching `Agent` toolCall.
    /// Keeps NSOutlineView's `numberOfChildrenOfItem` /
    /// `child:ofItem:` answers O(1) and identity-stable across
    /// reloads. Phase B graft layout (Option B — sibling).
    private var flatChildrenByTurnId: [String: [TurnOutlineNode]] = [:]
    /// Same shape as `flatChildrenByTurnId` but scoped to a
    /// SkillGroup's interior. Surfaces sub-agents spawned from an
    /// `Agent` toolCall that lives inside a Skill span.
    private var flatChildrenBySkillGroupId: [String: [TurnOutlineNode]] = [:]
    /// User-expanded Turn IDs — restored after a reload.
    private var expandedTurnIds: Set<String> = []
    /// Expanded skillGroup tool_use_ids. Parallel to `expandedTurnIds`
    /// but keyed by tool_use_id (unique across all Turns, so no need
    /// for a compound key).
    private var expandedSkillGroupIds: Set<String> = []
    /// Snapshot of the previous load — skip reload when unchanged.
    private var lastTurnsSnapshot: [Turn] = []
    /// Phase 8.3 — drives the subtle fade-in tint on newly-arrived /
    /// reordered Turn and Step rows. Lives at VC scope because the
    /// engine state (last snapshot, throttle cooldowns) is per-outline.
    private let appearanceCoordinator = AppearanceAnimationCoordinator()
    /// Session-scoped classification used to distinguish a cache-miss
    /// warning between "cold-cache OK" (orange) and "hot miss" (red).
    /// Computed in `reloadTurns` whenever `turns` changes and consumed
    /// by `configureTurnCell` / `configureStepCell` as an O(1) lookup.
    private var cacheClassification = CacheClassification()
    /// Turn IDs that lost their assistant follow-up to a `/compact`
    /// (Claude Code wiped the prior assistant entries from the JSONL
    /// and replaced them with a synthetic `isCompactSummary: true`
    /// user prompt that starts the next Turn). Computed once per
    /// `reloadTurns` and consumed by `configureTurnCell` to render a
    /// `✂ compacted` badge on the affected Turn header. See
    /// `Turn.wasCompactedAway` for the detection rule.
    private var compactedAwayTurnIds: Set<String> = []
    /// Suppresses delegate callbacks during programmatic select/deselect.
    private var isProgrammaticSelectionChange: Bool = false
    /// Indices into `turns` whose prompt matches `highlightQuery`.
    /// Rebuilt on every `setHighlightQuery` and `reloadTurns`. Used
    /// by ⌘G / ⇧⌘G to jump between matches without re-scanning.
    private var matchedTurnIndices: [Int] = []
    /// Position within `matchedTurnIndices` for ⌘G / ⇧⌘G cycling.
    /// `nil` = no match visited yet; first ⌘G starts at index 0.
    private var currentMatchIndex: Int? = nil

    /// Free-text query currently driving Turn-row highlighting.
    /// Empty = no highlighting (the search field is clear). Mutated
    /// exclusively via `setHighlightQuery` — the sidebar pushes it
    /// through `DashboardSplitViewController`'s bridge closure.
    private var highlightQuery: String = ""

    // MARK: - Launch watchdog
    //
    // `LaunchProgress` is normally bounded — the orchestrator advances
    // phase to `.done` within seconds even on cold start. A small class
    // of pathological cases (locked JSONL, broken snapshot decode loop,
    // truly enormous histories) can leave the user staring at a frozen
    // overlay indefinitely. The watchdog declares the launch "stalled"
    // after `launchWatchdogSeconds` and replaces the spinner with an
    // actionable empty state pointing at Diagnostics. The state is
    // automatically reset if `hasTurns` later becomes true (the parse
    // eventually completed) or `launchInProgress` becomes false.
    private var launchWatchdogTask: Task<Void, Never>?
    private var isLaunchStalled: Bool = false

    /// Test seam — production uses 90 s; unit tests inject a sub-second
    /// value so the watchdog fires within the test timeout.
    nonisolated(unsafe) static var launchWatchdogSeconds: TimeInterval = 90

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Turn start-time column — "M/d HH:mm". Seconds are dropped to
    /// save column width and reduce visual noise when scanning rows.
    private static let startTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    // MARK: - Columns

    private enum Col: String {
        case prompt, time, model, contextWindow, tokens, cacheRead, cacheWrite, cacheTTL, reasoning, cost
        var id: NSUserInterfaceItemIdentifier { .init(rawValue) }
    }

    /// Turn sort key — used as the `sortDescriptor.key`.
    private enum SortKey: String {
        case prompt, time, model, contextWindow, tokens, cacheRead, cacheWrite, reasoning, cost
    }

    /// Current sort. Default: start time descending (newest first).
    private var currentSortKey: SortKey = .time
    private var currentSortAscending: Bool = false
    private var configuredProvider: ProviderKind?
    private var defaultColumnWidthsByIdentifier: [String: CGFloat] = [:]

    /// UserDefaults keys for column-state persistence. AppKit's
    /// `autosaveTableColumns` path is unreliable for `NSOutlineView`
    /// when an `outlineTableColumn` is set, so we save/restore widths
    /// and order manually under our own keys (same pattern as the
    /// sidebar-width restore in `DashboardSplitViewController`).
    private static let columnWidthsDefaultsKey = "Lupen.TurnOutlineColumnWidths"
    private static let columnOrderDefaultsKey  = "Lupen.TurnOutlineColumnOrder"
    private static let sortKeyDefaultsKey      = "Lupen.TurnOutlineSortKey"
    private static let sortAscendingDefaultsKey = "Lupen.TurnOutlineSortAscending"

    /// Breathing room after the last column (6.9) — applied as a
    /// clip-view content inset and subtracted from the prompt
    /// auto-fit budget so the columns don't overflow into it.
    private static let tableTrailingGutter: CGFloat = 8

    /// Breathing room BEFORE the first column (6.9 follow-up — the
    /// real source of the "turn header feels cramped" feedback): rows
    /// started flush against the sidebar split divider, disclosure
    /// triangles touching the panel edge, while the sidebar itself
    /// insets its content 12pt. A clip-view inset is the only lever
    /// that moves the disclosure triangle too — cell padding starts
    /// after it.
    private static let tableLeadingGutter: CGFloat = 10

    /// Session-relative cost-outlier bar (6.9). The old fixed $10 line
    /// painted nearly every row of an expensive session orange —
    /// all-emphasis is no emphasis, and the cost column out-shouted the
    /// conversation itself. A turn now reads as "unusually expensive"
    /// only against its own session: 2× the mean of the session's
    /// positive turn costs, floored at $1. A flat distribution clears
    /// nobody (2× mean exceeds every value), so uniform sessions stay
    /// calm and genuine spikes still pop.
    private var costOutlierThresholdUSD: Double = .infinity

    private func recomputeCostOutlierThreshold() {
        let costs = turns.map { displayCost(for: $0).totalCostUSD }.filter { $0 > 0 }
        guard !costs.isEmpty else {
            costOutlierThresholdUSD = .infinity
            return
        }
        let mean = costs.reduce(0, +) / Double(costs.count)
        costOutlierThresholdUSD = max(mean * 2, 1.0)
    }

    private static func columnWidthsDefaultsKey(for provider: ProviderKind) -> String {
        "\(columnWidthsDefaultsKey).\(provider.rawValue)"
    }

    private static func columnOrderDefaultsKey(for provider: ProviderKind) -> String {
        "\(columnOrderDefaultsKey).\(provider.rawValue)"
    }

    private static func sortKeyDefaultsKey(for provider: ProviderKind) -> String {
        "\(sortKeyDefaultsKey).\(provider.rawValue)"
    }

    private static func sortAscendingDefaultsKey(for provider: ProviderKind) -> String {
        "\(sortAscendingDefaultsKey).\(provider.rawValue)"
    }

    /// Set to `true` once `applyPersistedColumnState()` has applied the
    /// saved widths / order. Notifications fired during the apply phase
    /// itself (AppKit re-emits `columnDidResize` as `column.width = ...`
    /// runs) would otherwise overwrite the saved value with the
    /// freshly-applied one — harmless when widths match, but masks bugs
    /// if they don't, so we gate writes behind this flag.
    private var didRestoreColumnState = false
    private var isApplyingColumnState = false

    /// Re-entrancy guard for `applyPromptAutoFit()` — setting
    /// `promptCol.width` fires `NSTableView.columnDidResizeNotification`
    /// which lands in `persistColumnWidths(_:)`. The prompt column is
    /// auto-computed from the viewport (not user-persisted), so the
    /// notification is uninteresting; this flag lets the persistence
    /// path no-op while we're driving our own width change.
    private var isAutoFittingPrompt = false

    // MARK: - Init

    init(store: AppStateStore, columnStateDefaults: UserDefaults = .standard) {
        self.store = store
        self.columnStateDefaults = columnStateDefaults
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        self.view = root
        setupOutlineView()
        setupScrollView(in: root)
        setupEmptyState(in: root)
        setupLaunchProgressOverlay(in: root)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
        observeWindowClose()
    }

    // MARK: - Setup

    private func setupOutlineView() {
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .plain
        outlineView.headerView = NSTableHeaderView()
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 16
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.gridStyleMask = []
        outlineView.intercellSpacing = NSSize(width: 8, height: 0)

        let promptCol = NSTableColumn(identifier: Col.prompt.id)
        promptCol.title = "Conversation"
        promptCol.minWidth = 320
        promptCol.width = 520
        // Both `userResizingMask` and `autoresizingMask` are required —
        // without them the user can't drag the column edge.
        promptCol.resizingMask = [.userResizingMask, .autoresizingMask]
        promptCol.headerCell.alignment = .center
        promptCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.prompt.rawValue, ascending: true)

        // "Started" default width ≈ the "M/d HH:mm" string's rendered
        // width + padding. Floor = default so a stray drag can't crush
        // the column below the point where "10/31 23:59" still fits.
        let timeCol = NSTableColumn(identifier: Col.time.id)
        timeCol.title = "Started"
        timeCol.width = 100
        timeCol.minWidth = 100
        timeCol.resizingMask = .userResizingMask
        timeCol.headerCell.alignment = .center
        timeCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.time.rawValue, ascending: false)

        // Model column — lives between "Started" and "Tokens" so the
        // row reads "time → model → size → cost" (when-who-how-much).
        // Per-family text tint (Opus purple / Sonnet blue / Haiku teal)
        // carries the signal without a pill / badge; Xcode Issue
        // Navigator's severity-tinted filename pattern. `sortDescriptor`
        // uses the model raw string only for `NSTableColumn` plumbing —
        // `sortedTurns` translates that into a tier-ordered comparison
        // (Opus → Sonnet → Haiku) because alphabetical ordering would
        // stick Sonnet between Haiku and Opus and bury the premium
        // tier.
        let modelCol = NSTableColumn(identifier: Col.model.id)
        modelCol.title = "Model"
        modelCol.headerToolTip =
            "Model used for the request. Opus (premium), Sonnet (standard), Haiku (fast)."
        // Wider min/default — short names like `opus-4-7` did not fit
        // at 62pt and rendered as `opus-...`.
        modelCol.minWidth = 60
        modelCol.width = 78
        modelCol.maxWidth = 120
        modelCol.resizingMask = .userResizingMask
        modelCol.headerCell.alignment = .center
        modelCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.model.rawValue, ascending: true)

        let contextWindowCol = NSTableColumn(identifier: Col.contextWindow.id)
        contextWindowCol.title = "Ctx"
        contextWindowCol.headerToolTip = "Model context window tokens reported by Codex when present."
        contextWindowCol.minWidth = 52
        contextWindowCol.width = 66
        contextWindowCol.maxWidth = 90
        contextWindowCol.resizingMask = .userResizingMask
        contextWindowCol.headerCell.alignment = .center
        contextWindowCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.contextWindow.rawValue, ascending: false)

        let tokensCol = NSTableColumn(identifier: Col.tokens.id)
        tokensCol.title = "Tokens"
        tokensCol.minWidth = 60
        tokensCol.width = 80
        tokensCol.resizingMask = .userResizingMask
        tokensCol.headerCell.alignment = .center
        tokensCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.tokens.rawValue, ascending: false)

        // Cache is split into CR (read) and CW (write) — separate
        // columns sort independently. They mean different things
        // (read = cost savings, write = new cache creation cost), so
        // merging them under one header would force an awkward sort
        // key choice.
        let crCol = NSTableColumn(identifier: Col.cacheRead.id)
        crCol.title = "CR"
        crCol.headerToolTip = "Cache Read"
        crCol.minWidth = 48
        crCol.width = 60
        crCol.resizingMask = .userResizingMask
        crCol.headerCell.alignment = .center
        crCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.cacheRead.rawValue, ascending: false)

        let cwCol = NSTableColumn(identifier: Col.cacheWrite.id)
        cwCol.title = "CW"
        cwCol.headerToolTip = "Cache Write"
        cwCol.minWidth = 48
        cwCol.width = 60
        cwCol.resizingMask = .userResizingMask
        cwCol.headerCell.alignment = .center
        cwCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.cacheWrite.rawValue, ascending: false)

        // TTL — which ephemeral cache bucket the CW bytes landed in.
        // Anthropic offers two TTLs: 5-minute (default) and 1-hour
        // (opt-in, 2× write cost but better hit rate on long-running
        // sessions). Showing this column surfaces *why* CW values
        // sometimes seem expensive — a 1h write on a 5m workload is
        // wasted spend. Non-sortable for now (no SortKey entry).
        let ttlCol = NSTableColumn(identifier: Col.cacheTTL.id)
        ttlCol.title = "TTL"
        ttlCol.headerToolTip =
            "Cache creation TTL — 5m (default, cheaper write) or 1h (premium, 2× write cost)."
        ttlCol.minWidth = 40
        ttlCol.width = 48
        ttlCol.maxWidth = 80
        ttlCol.resizingMask = .userResizingMask
        ttlCol.headerCell.alignment = .center

        let reasoningCol = NSTableColumn(identifier: Col.reasoning.id)
        reasoningCol.title = "Reasoning"
        reasoningCol.headerToolTip = "Reasoning output tokens."
        reasoningCol.minWidth = 70
        reasoningCol.width = 86
        reasoningCol.resizingMask = .userResizingMask
        reasoningCol.headerCell.alignment = .center
        reasoningCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.reasoning.rawValue, ascending: false)

        let costCol = NSTableColumn(identifier: Col.cost.id)
        costCol.title = "Cost"
        costCol.minWidth = 60
        costCol.width = 80
        costCol.resizingMask = .userResizingMask
        costCol.headerCell.alignment = .center
        costCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.cost.rawValue, ascending: false)

        outlineView.addTableColumn(promptCol)
        outlineView.addTableColumn(timeCol)
        outlineView.addTableColumn(modelCol)
        outlineView.addTableColumn(contextWindowCol)
        outlineView.addTableColumn(tokensCol)
        outlineView.addTableColumn(crCol)
        outlineView.addTableColumn(cwCol)
        outlineView.addTableColumn(ttlCol)
        outlineView.addTableColumn(reasoningCol)
        outlineView.addTableColumn(costCol)

        outlineView.outlineTableColumn = promptCol
        defaultColumnWidthsByIdentifier = Dictionary(
            uniqueKeysWithValues: outlineView.tableColumns.map { ($0.identifier.rawValue, $0.width) }
        )

        applyProviderColumnConfiguration(force: true)
        observeColumnChanges()
    }

    private func applyProviderColumnConfiguration(force: Bool = false) {
        let provider = store.activeProvider
        let previousProvider = configuredProvider
        guard force || previousProvider != provider else { return }

        if let previousProvider, previousProvider != provider {
            flushColumnState(for: previousProvider)
        }

        isApplyingColumnState = true
        didRestoreColumnState = false
        defer { isApplyingColumnState = false }

        resetColumnWidthsToDefaults()
        applyColumnOrder(Self.defaultColumnOrder(for: provider))
        configuredProvider = provider

        for column in outlineView.tableColumns {
            guard let descriptor = TurnOutlineColumnConfiguration.descriptor(
                for: column.identifier.rawValue,
                provider: provider
            ) else { continue }
            column.title = descriptor.title
            column.headerToolTip = descriptor.headerToolTip
            column.isHidden = !descriptor.isVisible
            column.headerCell.alignment = .center
            if let key = descriptor.sortKey {
                column.sortDescriptorPrototype = NSSortDescriptor(
                    key: key,
                    ascending: key == SortKey.prompt.rawValue || key == SortKey.model.rawValue
                )
            } else {
                column.sortDescriptorPrototype = nil
            }
        }

        applyPersistedColumnState(for: provider)
        applyPersistedOrDefaultSort(for: provider)
        updateContextWindowColumnVisibility()
        applyPromptAutoFit()
    }

    private func updateContextWindowColumnVisibility() {
        guard let column = outlineView.tableColumn(withIdentifier: Col.contextWindow.id) else { return }
        let descriptorVisible = TurnOutlineColumnConfiguration
            .descriptor(for: Col.contextWindow.rawValue, provider: store.activeProvider)?
            .isVisible == true
        let shouldShow = descriptorVisible
        column.isHidden = !shouldShow
        if !shouldShow && currentSortKey == .contextWindow {
            currentSortKey = .time
            currentSortAscending = false
            outlineView.sortDescriptors = [
                NSSortDescriptor(key: SortKey.time.rawValue, ascending: false)
            ]
        }
    }

    /// Restore saved column widths + order from UserDefaults. Falls
    /// back silently for unknown / missing keys so first launch (or a
    /// future column addition) just uses the defaults baked into
    /// `setupOutlineView()`.
    private func applyPersistedColumnState(for provider: ProviderKind) {
        resetColumnWidthsToDefaults()
        if let widths = columnStateDefaults.dictionary(
            forKey: Self.columnWidthsDefaultsKey(for: provider)
        ) as? [String: Double] {
            for column in outlineView.tableColumns {
                if column.isHidden { continue }
                // Prompt column is auto-fit to the viewport — its
                // width is derived in `applyPromptAutoFit()` from
                // (viewport − non-prompt total). Skipping the
                // persisted value here prevents a wide saved width
                // (from a previous session on a wider window) from
                // pushing the right-side columns off-screen until
                // the next layout pass. `applyPromptAutoFit` runs
                // in viewDidLayout, which fires after the scroll
                // view has its real frame.
                if column.identifier == Col.prompt.id { continue }
                if let width = widths[column.identifier.rawValue], width > 0 {
                    column.width = CGFloat(width)
                }
            }
        }
        if let savedOrder = columnStateDefaults.array(
            forKey: Self.columnOrderDefaultsKey(for: provider)
        ) as? [String], !savedOrder.isEmpty {
            applyColumnOrder(Self.columnOrder(for: provider, savedVisibleOrder: savedOrder))
        }
        didRestoreColumnState = true
    }

    private func resetColumnWidthsToDefaults() {
        for column in outlineView.tableColumns {
            if let width = defaultColumnWidthsByIdentifier[column.identifier.rawValue] {
                column.width = width
            }
        }
    }

    private func applyColumnOrder(_ identifiers: [String]) {
        for (targetIndex, ident) in identifiers.enumerated() {
            guard targetIndex < outlineView.tableColumns.count else { break }
            if let currentIndex = outlineView.tableColumns.firstIndex(where: { $0.identifier.rawValue == ident }),
               currentIndex != targetIndex {
                outlineView.moveColumn(currentIndex, toColumn: targetIndex)
            }
        }
    }

    private static func defaultColumnOrder(for provider: ProviderKind) -> [String] {
        TurnOutlineColumnConfiguration.descriptors(for: provider).map(\.id)
    }

    private static func columnOrder(
        for provider: ProviderKind,
        savedVisibleOrder: [String]
    ) -> [String] {
        let descriptors = TurnOutlineColumnConfiguration.descriptors(for: provider)
        let allIDs = descriptors.map(\.id)
        let visibleIDs = descriptors.filter(\.isVisible).map(\.id)
        let savedVisible = savedVisibleOrder.filter { visibleIDs.contains($0) }
        let visibleOrder = savedVisible + visibleIDs.filter { !savedVisible.contains($0) }
        let hiddenOrder = allIDs.filter { !visibleOrder.contains($0) }
        return visibleOrder + hiddenOrder
    }

    /// Wire NSTableView column-change notifications so user drags get
    /// persisted on the same run-loop tick. We listen on `outlineView`
    /// only (the notification's `object`), so other table views in the
    /// window are unaffected.
    private func observeColumnChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(persistColumnWidths(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: outlineView
        )
        center.addObserver(
            self,
            selector: #selector(persistColumnOrder(_:)),
            name: NSTableView.columnDidMoveNotification,
            object: outlineView
        )
    }

    @objc private func persistColumnWidths(_ note: Notification) {
        // Auto-fit on the prompt column re-emits this notification;
        // ignore those rounds — prompt is intentionally never
        // persisted (its width is always derived from the viewport).
        // Real user drags still land here for non-prompt columns and
        // get persisted as before.
        if isAutoFittingPrompt || isApplyingColumnState { return }
        flushColumnState()
    }

    @objc private func persistColumnOrder(_ note: Notification) {
        if isApplyingColumnState { return }
        flushColumnState()
    }

    /// Subscribes to lifecycle events that should trigger a column-state
    /// snapshot. NSOutlineView's `columnDidMoveNotification` does not
    /// fire reliably on user drags in some macOS versions (verified
    /// empirically — `Lupen.TurnOutlineColumnOrder` stayed unwritten
    /// even after drag-reorder). The window-close + app-terminate +
    /// view-disappear hooks below cover those gaps; each save is
    /// idempotent so the redundancy is harmless when the notification
    /// path *does* fire.
    private func observeWindowClose() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppOrWindowWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        // Window reference isn't available until the view is in a
        // window; subscribe on first viewDidAppear.
    }

    @objc private func handleAppOrWindowWillTerminate(_ note: Notification) {
        flushColumnState()
    }

    @objc private func handleWindowWillClose(_ note: Notification) {
        flushColumnState()
    }

    /// Snapshot the live column widths + order to UserDefaults. Safe to
    /// call repeatedly — same input produces the same output, so the
    /// redundant calls from multiple lifecycle hooks don't churn disk.
    private func flushColumnState() {
        flushColumnState(for: store.activeProvider)
    }

    private func flushColumnState(for provider: ProviderKind) {
        guard didRestoreColumnState, !isApplyingColumnState else { return }
        // Exclude the prompt column — its width is always derived
        // from the viewport in `applyPromptAutoFit`. Persisting a
        // viewport-derived width would lock the next launch to that
        // viewport's value even if the new launch's window is wider
        // or narrower.
        let widths = Dictionary(uniqueKeysWithValues: outlineView.tableColumns
            .filter { !$0.isHidden && $0.identifier != Col.prompt.id }
            .map { ($0.identifier.rawValue, Double($0.width)) })
        let order = outlineView.tableColumns
            .filter { !$0.isHidden }
            .map { $0.identifier.rawValue }
        columnStateDefaults.set(widths, forKey: Self.columnWidthsDefaultsKey(for: provider))
        columnStateDefaults.set(order, forKey: Self.columnOrderDefaultsKey(for: provider))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Subscribe to window close once the window relationship exists.
        if let window = view.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Re-derive the prompt column's width every time the view's
        // bounds change — covers window resize, sidebar/divider drag,
        // detail-pane toggle, and the post-restore first layout pass.
        applyPromptAutoFit()
    }

    /// Resize the prompt (Conversation) column to fill whatever
    /// horizontal space is left after the other columns + intercell
    /// spacing, clamped to its `minWidth`. The intent (per user
    /// request 2026-05-03) is "Started…Cost stays visible whenever
    /// possible — when the window narrows, prompt shrinks first
    /// instead of pushing the right-side columns off-screen".
    ///
    /// Why this is explicit code rather than relying on
    /// `NSTableColumn.autoresizingMask`: AppKit's built-in
    /// `.uniformColumnAutoresizingStyle` distributes only the
    /// *delta* between successive table-frame sizes among
    /// `.autoresizingMask`-eligible columns. Once the prompt column
    /// hits `minWidth`, subsequent shrinks are silently lost — the
    /// outline view's intrinsic content width stays equal to the
    /// sum of all column widths, and the right-side columns clip
    /// against the scroll view's clipView. Persisted widths from a
    /// previous larger-window session compound the issue: restoring
    /// a 600-pt prompt width on a 700-pt viewport leaves no room
    /// for anyone else.
    ///
    /// The fix is to re-derive prompt width as `viewport
    /// − non_prompt_widths − intercell_spacing` on every layout,
    /// which is what this method does. The prompt column is
    /// intentionally NOT persisted (see `flushColumnState` /
    /// `applyPersistedColumnState`) — its width is always a
    /// function of the current viewport.
    ///
    /// `hasHorizontalScroller = true` on the scroll view is the
    /// graceful fallback for the rare case where even
    /// `prompt.minWidth + Σ non_prompt.width + spacing` exceeds the
    /// viewport (e.g. user dragged a non-prompt column wider than
    /// fits). Without it the right-side columns would simply clip
    /// against the clipView edge.
    private func applyPromptAutoFit() {
        guard didRestoreColumnState,
              let promptCol = outlineView.tableColumns.first(where: { $0.identifier == Col.prompt.id })
        else { return }
        let viewportWidth = scrollView.contentView.bounds.width
        guard viewportWidth > 0 else { return }

        let intercell = outlineView.intercellSpacing.width
        let visibleColumns = outlineView.tableColumns.filter { !$0.isHidden }
        let columnCount = visibleColumns.count
        // n columns means n − 1 inter-column gaps. Outline view's
        // disclosure-triangle indentation lives inside the prompt
        // column itself, so it's already accounted for via prompt's
        // own width budget.
        let totalSpacing = intercell * CGFloat(max(columnCount - 1, 0))
        let nonPromptTotal = visibleColumns
            .filter { $0.identifier != Col.prompt.id }
            .reduce(CGFloat(0)) { $0 + $1.width }

        // The clip-view bounds don't shrink for contentInsets — budget
        // both edge gutters explicitly or the column sum overflows
        // into them and re-grows a horizontal scroller (6.9).
        let available = viewportWidth - nonPromptTotal - totalSpacing
            - Self.tableLeadingGutter - Self.tableTrailingGutter
        let target = max(promptCol.minWidth, available)
        // 0.5pt tolerance avoids ping-pong on sub-pixel residue —
        // viewDidLayout fires several times in a row during window
        // resize and we don't want each pass to set a fractionally-
        // different width and re-invoke layout.
        guard abs(promptCol.width - target) > 0.5 else { return }

        isAutoFittingPrompt = true
        promptCol.width = target
        isAutoFittingPrompt = false
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        flushColumnState()
        // Defensive — `[weak self]` in the Task body already no-ops on
        // deallocation, but cancelling here releases the Task's main
        // executor slot a few seconds earlier in the closed-window
        // case.
        cancelLaunchWatchdog()
    }

    /// Restore the user's last sort key/direction from UserDefaults, or
    /// fall back to the default (`time` descending — most recent first).
    /// Unknown saved keys (e.g. removed in a future enum migration) also
    /// fall back, so a torn or stale value never wedges the outline.
    private func applyPersistedOrDefaultSort(for provider: ProviderKind) {
        let savedKey = columnStateDefaults.string(
            forKey: Self.sortKeyDefaultsKey(for: provider)
        ).flatMap(SortKey.init(rawValue:))
        let visibleSavedKey = savedKey.flatMap { key in
            TurnOutlineColumnConfiguration.isSortKeyVisible(key.rawValue, provider: provider)
                ? key
                : nil
        }
        let resolvedKey = visibleSavedKey ?? .time
        let resolvedAscending: Bool = {
            // Only honour the saved direction when the saved key was
            // valid; otherwise the default key dictates the default
            // direction so the outline always opens with the freshest
            // turn at top.
            guard visibleSavedKey != nil,
                  columnStateDefaults.object(forKey: Self.sortAscendingDefaultsKey(for: provider)) != nil
            else { return false }
            return columnStateDefaults.bool(forKey: Self.sortAscendingDefaultsKey(for: provider))
        }()
        currentSortKey = resolvedKey
        currentSortAscending = resolvedAscending
        outlineView.sortDescriptors = [
            NSSortDescriptor(key: resolvedKey.rawValue, ascending: resolvedAscending)
        ]
    }

    private func setupScrollView(in container: NSView) {
        scrollView.documentView = outlineView
        // Edge gutters (6.9): without them the disclosure triangles sat
        // flush against the sidebar split divider and the last numeric
        // column (CW) against the window edge. A clip-view inset —
        // header scrolls with it — survives column reordering, unlike
        // padding inside whichever cell happens to be first/last, and
        // it's the only lever that moves the disclosure triangle. This
        // scroll view lives inside the split, never under the title
        // bar, so disabling automatic insets forfeits nothing.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 0,
            left: Self.tableLeadingGutter,
            bottom: 0,
            right: Self.tableTrailingGutter
        )
        scrollView.hasVerticalScroller = true
        // Horizontal scroller is the graceful fallback for very narrow
        // windows where even prompt-at-minWidth + every other column at
        // its own minWidth still exceeds viewport. `applyPromptAutoFit`
        // (called from viewDidLayout) keeps the common case
        // (viewport ≥ ~660pt) scrollerless; this flag only matters at
        // the extreme.
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func setupEmptyState(in container: NSView) {
        if let img = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .thin)
            emptyImageView.image = img.withSymbolConfiguration(config)
            emptyImageView.contentTintColor = .tertiaryLabelColor
        }

        emptyTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyTitleLabel.textColor = .secondaryLabelColor
        emptyTitleLabel.alignment = .center

        emptySubtitleLabel.font = .systemFont(ofSize: 11)
        emptySubtitleLabel.textColor = .tertiaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.maximumNumberOfLines = 2

        showSelectSessionEmptyState()

        let stack = NSStackView(views: [emptyImageView, emptyTitleLabel, emptySubtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(stack)
        container.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: container.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: emptyStateView.widthAnchor, constant: -32),
        ])

        scrollView.isHidden = true
    }

    private func showEmptyState(title: String, subtitle: String) {
        emptyTitleLabel.stringValue = title
        emptySubtitleLabel.stringValue = subtitle
    }

    private func showSelectSessionEmptyState() {
        let descriptor = store.activeProvider.descriptor
        showEmptyState(
            title: "Select a \(descriptor.displayName) Session",
            subtitle: "Choose a \(descriptor.displayName) session from the sidebar\nto view its conversation."
        )
    }

    private func showNoConversationEmptyState() {
        let descriptor = store.activeProvider.descriptor
        showEmptyState(
            title: "No \(descriptor.displayName) Conversation",
            subtitle: "This \(descriptor.displayName) session has no turns yet."
        )
    }

    private func showIndexingSessionEmptyState() {
        showEmptyState(
            title: "Indexing This Session…",
            subtitle: "Its conversation imports next and appears automatically.\nOther sessions keep indexing in the background."
        )
    }

    /// Host the SwiftUI `LaunchProgressView` inside the Turn outline pane so
    /// the user can see exactly where a long cold-start parse is along its
    /// way (Plan 13 Phase 5 overlay that was built but never wired).
    ///
    /// SwiftUI justification: the overlay combines a linear
    /// `ProgressView`, `.ultraThinMaterial` rounded-rect card,
    /// `RelativeDateTimeFormatter` ETA, and a 1 Hz tick timer for the ETA
    /// countdown. Re-building that in AppKit (NSProgressIndicator +
    /// NSVisualEffectView + Timer + NSLayoutConstraint) runs 4–5× more
    /// boilerplate for the same result, and the existing
    /// `LaunchProgressHostingView` wraps it in an NSHostingView so drop-in
    /// is a single add-subview + pinned-edge call.
    ///
    /// `launchProgressContainer` stays pinned to the outline pane's full
    /// bounds so the material card can center itself via SwiftUI. Visibility
    /// is owned by `updateStateVisibility()` which flips between outline,
    /// empty state, and this overlay based on `store.launchProgress.phase`.
    private func setupLaunchProgressOverlay(in container: NSView) {
        let hosting = LaunchProgressHostingView(store: store)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        launchProgressContainer.translatesAutoresizingMaskIntoConstraints = false
        launchProgressContainer.addSubview(hosting)
        container.addSubview(launchProgressContainer)

        NSLayoutConstraint.activate([
            launchProgressContainer.topAnchor.constraint(equalTo: container.topAnchor),
            launchProgressContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            launchProgressContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            launchProgressContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Center the material card. NSHostingView sizes to its SwiftUI
            // content's intrinsic width (max 520 per LaunchProgressView),
            // so pin both axes to center and let SwiftUI drive the size.
            hosting.centerXAnchor.constraint(equalTo: launchProgressContainer.centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: launchProgressContainer.centerYAnchor),
            hosting.leadingAnchor.constraint(greaterThanOrEqualTo: launchProgressContainer.leadingAnchor, constant: 16),
            hosting.trailingAnchor.constraint(lessThanOrEqualTo: launchProgressContainer.trailingAnchor, constant: -16),
        ])

        launchProgressContainer.isHidden = true
    }

    /// Single source of truth for which of the three surfaces (outline / empty /
    /// launch-progress overlay) is visible. Called whenever turns, session
    /// selection, or `store.launchProgress` changes.
    private func updateStateVisibility() {
        let hasSession = currentSessionId != nil
        let hasTurns = !turns.isEmpty
        let phase = store.launchProgress.phase
        // `phase == .idle` is the pre-orchestrator state; `phase == .done`
        // is the terminal state. In both cases we treat launch as "not in
        // progress" and let the normal outline/empty/Select-a-Session
        // rhythm take over — the overlay is only for the active launch.
        let launchInProgress = (phase != .idle && phase != .done)

        // Stalled override — only kicks in while launch is still in
        // progress. If `launchInProgress` flipped to false on its own
        // (parse completed slowly but completed), the natural empty /
        // outline branches below run and the next non-stalled state
        // implicitly clears the flag.
        if isLaunchStalled && launchInProgress {
            scrollView.isHidden = true
            emptyStateView.isHidden = false
            setLaunchProgressOverlayHidden(true)
            showEmptyState(
                title: "Parse Stalled",
                subtitle: "Loading didn't complete after \(Int(Self.launchWatchdogSeconds)) seconds.\nWindow ▸ Diagnostics… for details."
            )
            return
        }

        // Priority:
        //   1) Turns present → outline view (show live data immediately
        //      even if launch is still in progress).
        //   2) Session selected + launch in progress → per-scope
        //      "Indexing this session…" state. Selecting jumped the
        //      session's unit to the queue head, so this resolves into
        //      the outline on the next refresh tick — a global
        //      "N of M" card here would hide a working surface behind
        //      whole-corpus progress the sidebar already shows.
        //   3) Launch in progress (nothing selected) → LaunchProgress
        //      overlay.
        //   4) Session selected + launch done + no turns → "No Conversation".
        //   5) No session selected → "Select a Session".
        if hasTurns {
            scrollView.isHidden = false
            emptyStateView.isHidden = true
            setLaunchProgressOverlayHidden(true)
            cancelLaunchWatchdog()
            isLaunchStalled = false
        } else if launchInProgress, hasSession {
            scrollView.isHidden = true
            emptyStateView.isHidden = false
            setLaunchProgressOverlayHidden(true)
            showIndexingSessionEmptyState()
            armLaunchWatchdogIfNeeded()
        } else if launchInProgress {
            scrollView.isHidden = true
            emptyStateView.isHidden = true
            setLaunchProgressOverlayHidden(false)
            armLaunchWatchdogIfNeeded()
        } else if hasSession {
            scrollView.isHidden = true
            emptyStateView.isHidden = false
            setLaunchProgressOverlayHidden(true)
            showNoConversationEmptyState()
            cancelLaunchWatchdog()
            isLaunchStalled = false
        } else {
            scrollView.isHidden = true
            emptyStateView.isHidden = false
            setLaunchProgressOverlayHidden(true)
            showSelectSessionEmptyState()
            cancelLaunchWatchdog()
            isLaunchStalled = false
        }
    }

    /// Arm the launch watchdog if not already running and not in a
    /// stalled state. Re-arms are no-ops — a single in-flight timer
    /// covers a contiguous "showing the overlay" window. Cancellation
    /// happens via `cancelLaunchWatchdog()` in every non-overlay branch
    /// of `updateStateVisibility`.
    private func armLaunchWatchdogIfNeeded() {
        guard launchWatchdogTask == nil, !isLaunchStalled else { return }
        let seconds = Self.launchWatchdogSeconds
        launchWatchdogTask = Task { @MainActor [weak self] in
            let nanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let self else { return }
            if Task.isCancelled { return }
            // Re-check the state we cared about at the time the timer
            // armed. Anything could have happened during the sleep
            // (turns arrived, phase reached .done, the controller was
            // dismissed); only declare stalled if the overlay is
            // *still* the visible surface and the parse hasn't
            // finished.
            let phase = self.store.launchProgress.phase
            let overlayStillShown = !self.launchProgressContainer.isHidden
            if phase != .done && overlayStillShown {
                LoggerService.shared.error(
                    "Launch progress stalled — no completion in \(Int(seconds))s, forcing overlay dismiss",
                    context: "TurnOutline"
                )
                self.isLaunchStalled = true
                self.updateStateVisibility()
            }
            self.launchWatchdogTask = nil
        }
    }

    private func cancelLaunchWatchdog() {
        launchWatchdogTask?.cancel()
        launchWatchdogTask = nil
    }

    /// Hide/show the Plan 13 launch overlay. Separated from
    /// `updateStateVisibility` so callers read as "which surface wins" at
    /// a glance. Visibility flips propagate to the SwiftUI hosting view
    /// automatically — the `@Observable` subscription inside
    /// `LaunchProgressView` drives the inner redraw.
    private func setLaunchProgressOverlayHidden(_ hidden: Bool) {
        if launchProgressContainer.isHidden != hidden {
            launchProgressContainer.isHidden = hidden
        }
    }

    // MARK: - Observation

    private func startObserving() {
        // Track 1 — turns / isLoading: drive the full outline reload path
        // (reloadTurns pulls Turn graphs out of the assembler).
        withObservationTracking {
            _ = store.isLoading
            _ = store.activeProvider
            // SQLite-first conversation refresh signal (plan 4.1) —
            // the driver bumps this on its throttled import cadence.
            _ = store.sqliteConversationGeneration
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.handleStoreUpdate()
                self?.startObserving()
            }
        }

        // Track 2 — launchProgress: overlay visibility only. Kept on a
        // **separate** Observation track on purpose. Phase A publishes
        // `launchProgress` ~50 times per second via its throttled
        // progress updates; if we pulled launchProgress into the main
        // tracking block above, every one of those would fan out
        // through `handleStoreUpdate → reloadTurns →
        // assembler.turns(in:)` on the main queue while the
        // background parse thread is still mutating the assembler's
        // internal dictionaries. That's exactly the race that
        // produced the `-[__NSCFNumber objectForKey:]` crash during
        // cold-start testing. Keeping launchProgress on its own
        // track lets the overlay update at full cadence without
        // ever dragging the assembler into a concurrent-read
        // position.
        observeLaunchProgress()
    }

    private func observeLaunchProgress() {
        withObservationTracking {
            _ = store.launchProgress
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateStateVisibility()
                self?.observeLaunchProgress()
            }
        }
    }

    private func handleStoreUpdate() {
        applyProviderColumnConfiguration()
        guard let sessionId = currentSessionId else {
            // Even with no session selected we still refresh the overlay —
            // `isLoading` alone can flip while a user is idle on the dashboard.
            updateStateVisibility()
            return
        }
        reloadTurns(for: sessionId, preserveSelection: true)
    }

    // MARK: - Public API

    func showSession(sessionId: String) {
        let isNewSession = currentSessionId != sessionId
        currentSessionId = sessionId
        let selectionKeyToRestore = isNewSession ? selectedIdentityKeyBySessionId[sessionId] : nil
        // Publish to the store's diagnostic hint so live-append logs
        // can flag mismatches between the session the user is viewing
        // and the session Claude Code is appending to. See
        // `AppStateStore.uiViewedSessionId` for the rationale.
        store.uiViewedSessionId = sessionId
        if isNewSession {
            expandedTurnIds.removeAll()
            expandedSkillGroupIds.removeAll()
            expandedSubAgentKeys.removeAll()
            // Cold-start the appearance coordinator: without this,
            // the engine sees session B's IDs as "new relative to
            // session A's IDs" and emits up to 12 appear triggers,
            // making the entire conversation flash on every session
            // switch. `reset()` empties the previous snapshot so the
            // first `prepare()` for the new session is treated as a
            // genuine cold start (suppression policy returns 0
            // triggers — same code path used at app launch).
            appearanceCoordinator.reset()
        }
        reloadTurns(
            for: sessionId,
            preserveSelection: !isNewSession || selectionKeyToRestore != nil,
            preferredSelectionKey: selectionKeyToRestore
        )
    }

    /// Resolve the SubAgent sibling rows that should follow `step`
    /// in the flat child list and append them in link order.
    /// Centralised so the Turn-level walker and the SkillGroup
    /// interior walker share the exact same insertion semantics.
    private func appendSubAgentSiblings(
        for step: Step,
        parentTurnId: String,
        sessionId: String,
        nodes: [String: TurnOutlineNode],
        links: [String: [SubAgentLinker.Link]],
        into children: inout [TurnOutlineNode]
    ) {
        guard let stepLinks = links[step.uuid] else { return }
        for link in stepLinks {
            let key = "subAgent:\(sessionId):\(parentTurnId):\(step.uuid):\(link.agentId)"
            if let cached = nodes[key] {
                children.append(cached)
            }
        }
    }

    func clear() {
        currentSessionId = nil
        store.uiViewedSessionId = nil
        turns = []
        costOutlierThresholdUSD = .infinity
        lastTurnsSnapshot = []
        turnNodes.removeAll()
        stepNodes.removeAll()
        skillGroupNodes.removeAll()
        groupedRowsByTurn.removeAll()
        expandedTurnIds.removeAll()
        expandedSkillGroupIds.removeAll()
        expandedSubAgentKeys.removeAll()
        // Reset the appearance coordinator so the next session select
        // is treated as a cold start — every row would otherwise look
        // "new" relative to the previous session's snapshot and we'd
        // get a flash storm.
        appearanceCoordinator.reset()
        isProgrammaticSelectionChange = true
        outlineView.reloadData()
        isProgrammaticSelectionChange = false
        updateStateVisibility()
    }

    // MARK: - SQLite-first conversation (plan 4.1)

    /// Header aggregates per turn id — under SQLite-first the cells and
    /// sort comparators read these instead of summing steps.
    private var sqliteAggregates: [String: SQLiteConversationSource.HeaderAggregate] = [:]
    private var sqliteTurnIdByParentStepUuid: [String: String] = [:]
    private var materializedTurnIds: Set<String> = []
    /// Sub-agent children materialized on their own expand, keyed by
    /// the subAgent node identity key. The outline retains the node
    /// object it was first handed (stub payload), so the data source
    /// consults this map before the node's own turn.
    private var subAgentMaterializedSteps: [String: [Step]] = [:]

    private var isSQLiteConversation: Bool { store.sqliteConversationSource != nil }

    private func resetSQLiteConversationState() {
        sqliteAggregates = [:]
        sqliteTurnIdByParentStepUuid = [:]
        materializedTurnIds = []
        subAgentMaterializedSteps = [:]
    }

    private func reloadTurnsFromSQLite(
        source: SQLiteConversationSource,
        sessionId: String,
        preserveSelection: Bool,
        selectedKey: String?,
        preferredSelectionKey: String?
    ) {
        let snapshot = (try? source.snapshot(sessionId: sessionId))
            ?? SQLiteConversationSource.Snapshot.empty

        var newLinksByStepUuid: [String: [SubAgentLinker.Link]] = [:]
        for link in snapshot.links {
            newLinksByStepUuid[link.parentAssistantUuid, default: []].append(link)
        }
        var newSubTurnsByAgentId: [String: Turn] = [:]
        for stub in snapshot.turns where stub.isSidechainOnly {
            if let agentId = snapshot.agentIdByTurnId[stub.id] ?? stub.steps.first?.agentId {
                newSubTurnsByAgentId[agentId] = stub
            }
        }

        // Sort comparators read the sidecar — install it before sorting.
        let aggregatesUnchanged = sqliteAggregates == snapshot.aggregates
        sqliteAggregates = snapshot.aggregates
        let newTurns = sortedTurns(snapshot.turns.filter { !$0.isSidechainOnly })

        // Mirror the legacy skip: avoid flicker / scroll jumps when a
        // refresh tick changed nothing the outline renders.
        let turnsUnchanged = newTurns == lastTurnsSnapshot
        let linksUnchanged = subAgentLinksByStepUuid == newLinksByStepUuid
        let subTurnsUnchanged = subAgentTurnsByAgentId == newSubTurnsByAgentId
        if preserveSelection && turnsUnchanged && linksUnchanged
            && subTurnsUnchanged && aggregatesUnchanged {
            return
        }

        lastTurnsSnapshot = newTurns
        turns = newTurns
        // Aggregates were assigned above, so displayCost reads the
        // sidecar — recompute the session-relative outlier bar (6.9).
        recomputeCostOutlierThreshold()
        updateContextWindowColumnVisibility()
        compactedAwayTurnIds = snapshot.compactedAwayTurnIds
        // Turn-level cold-cache marks from the sidecar times; each
        // turn's steps classify incrementally when they materialize.
        cacheClassification = Self.sqliteTurnCacheClassification(
            aggregates: snapshot.aggregates
        )

        // Stub nodes only — children (grouped rows, step nodes, graft
        // splices) build per turn in `ensureTurnChildrenMaterialized`.
        var newTurnNodes: [String: TurnOutlineNode] = [:]
        for turn in turns {
            newTurnNodes["\(turn.sessionId):\(turn.id)"] = TurnOutlineNode(turn: turn)
        }
        turnNodes = newTurnNodes
        stepNodes = [:]
        skillGroupNodes = [:]
        groupedRowsByTurn = [:]
        flatChildrenByTurnId = [:]
        flatChildrenBySkillGroupId = [:]
        subAgentTurnsByAgentId = newSubTurnsByAgentId
        subAgentLinksByStepUuid = newLinksByStepUuid
        sqliteTurnIdByParentStepUuid = snapshot.turnIdByParentStepUuid
        materializedTurnIds = []
        subAgentMaterializedSteps = [:]

        // SubAgent nodes: the link row names the parent step uuid and
        // the snapshot maps it to its turn — no toolCalls scan needed.
        var newSubAgentNodes: [String: TurnOutlineNode] = [:]
        for (parentStepUuid, links) in newLinksByStepUuid {
            guard let parentTurnId = snapshot.turnIdByParentStepUuid[parentStepUuid] else { continue }
            for link in links {
                guard let subTurn = newSubTurnsByAgentId[link.agentId] else { continue }
                let key = "subAgent:\(sessionId):\(parentTurnId):\(parentStepUuid):\(link.agentId)"
                newSubAgentNodes[key] = TurnOutlineNode(
                    subAgentLink: link,
                    turn: subTurn,
                    parentTurnId: parentTurnId,
                    parentStepUuid: parentStepUuid
                )
            }
        }
        subAgentNodes = newSubAgentNodes

        finishReload(
            sessionId: sessionId,
            newTurns: newTurns,
            newFlatByTurn: [:],
            preserveSelection: preserveSelection,
            selectedKey: selectedKey,
            preferredSelectionKey: preferredSelectionKey
        )
    }

    /// Materializes one turn's children on first expand: scoped step
    /// decode → real `Turn` swapped into `turns` → grouped rows, node
    /// caches and graft splices for exactly this turn.
    @discardableResult
    private func ensureTurnChildrenMaterialized(_ turnId: String) -> Bool {
        guard isSQLiteConversation else { return true }
        guard !materializedTurnIds.contains(turnId) else { return true }
        guard let source = store.sqliteConversationSource,
              let sessionId = currentSessionId,
              let stubIndex = turns.firstIndex(where: { $0.id == turnId })
        else { return false }
        materializedTurnIds.insert(turnId)

        let stub = turns[stubIndex]
        let steps = (try? source.materializeSteps(sessionId: sessionId, turnId: turnId)) ?? []
        guard !steps.isEmpty else { return false }
        let real = Turn(
            id: stub.id,
            sessionId: stub.sessionId,
            steps: steps,
            isInterrupted: stub.isInterrupted
        )
        turns[stubIndex] = real
        turnNodes["\(real.sessionId):\(real.id)"] = TurnOutlineNode(turn: real)
        buildSQLiteChildren(for: real)
        classifyMaterializedSteps(of: real)
        return true
    }

    /// Per-turn equivalent of the legacy reload's node-building loops.
    private func buildSQLiteChildren(for turn: Turn) {
        let sessionId = turn.sessionId
        let rows = SkillGroupBuilder.group(turn.steps)
        groupedRowsByTurn[turn.id] = rows
        for row in rows {
            switch row {
            case .step(let step):
                stepNodes["\(sessionId):\(turn.id):\(step.uuid)"] =
                    TurnOutlineNode(step: step, parentTurnId: turn.id)
            case .skillGroup(let group):
                skillGroupNodes[group.id] = TurnOutlineNode(
                    skillGroup: group, sessionId: sessionId, parentTurnId: turn.id
                )
                for step in group.steps {
                    stepNodes["\(sessionId):\(turn.id):\(step.uuid)"] =
                        TurnOutlineNode(step: step, parentTurnId: turn.id)
                }
            }
        }
        var children: [TurnOutlineNode] = []
        children.reserveCapacity(rows.count)
        for row in rows {
            switch row {
            case .step(let step):
                if let stepNode = stepNodes["\(sessionId):\(turn.id):\(step.uuid)"] {
                    children.append(stepNode)
                }
                appendSubAgentSiblings(
                    for: step, parentTurnId: turn.id, sessionId: sessionId,
                    nodes: subAgentNodes, links: subAgentLinksByStepUuid,
                    into: &children
                )
            case .skillGroup(let group):
                if let groupNode = skillGroupNodes[group.id] {
                    children.append(groupNode)
                }
                var groupChildren: [TurnOutlineNode] = []
                for step in group.steps {
                    if let stepNode = stepNodes["\(sessionId):\(turn.id):\(step.uuid)"] {
                        groupChildren.append(stepNode)
                    }
                    appendSubAgentSiblings(
                        for: step, parentTurnId: turn.id, sessionId: sessionId,
                        nodes: subAgentNodes, links: subAgentLinksByStepUuid,
                        into: &groupChildren
                    )
                }
                flatChildrenBySkillGroupId[group.id] = groupChildren
            }
        }
        flatChildrenByTurnId[turn.id] = children
    }

    /// Sub-agent children on their own expand: scoped decode of the
    /// sidechain turn, cached by node identity key (the outline keeps
    /// handing us the stub-payload node object).
    private func materializedSubAgentSteps(for node: TurnOutlineNode) -> [Step]? {
        guard case .subAgent(_, let subTurn, _, _) = node.kind else { return nil }
        guard isSQLiteConversation else { return subTurn.steps }
        let key = node.identityKey
        if let cached = subAgentMaterializedSteps[key] { return cached }
        guard let source = store.sqliteConversationSource,
              let sessionId = currentSessionId else { return subTurn.steps }
        let steps = (try? source.materializeSteps(sessionId: sessionId, turnId: subTurn.id)) ?? []
        guard !steps.isEmpty else { return subTurn.steps }
        subAgentMaterializedSteps[key] = steps
        for step in steps {
            stepNodes["\(subTurn.sessionId):\(subTurn.id):\(step.uuid)"] =
                TurnOutlineNode(step: step, parentTurnId: subTurn.id)
        }
        classifySteps(steps, turnColdOk: cacheClassification.coldOkTurnIds.contains(subTurn.id))
        return steps
    }

    /// The materialized `Turn` for detail-pane callbacks — header
    /// selection materializes on demand so the pane never sees a stub.
    private func materializedTurn(for turn: Turn) -> Turn {
        guard isSQLiteConversation else { return turn }
        ensureTurnChildrenMaterialized(turn.id)
        return turns.first { $0.id == turn.id } ?? turn
    }

    /// Turn-level cold-cache classification from sidecar times (same
    /// gap rule as `computeCacheClassification`, no steps needed).
    private static func sqliteTurnCacheClassification(
        aggregates: [String: SQLiteConversationSource.HeaderAggregate]
    ) -> CacheClassification {
        var result = CacheClassification()
        let chrono = aggregates
            .map { (id: $0.key, start: $0.value.startTime, end: $0.value.endTime) }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        var prevTurnEnd: Date?
        for entry in chrono {
            if let prev = prevTurnEnd, let start = entry.start {
                if start.timeIntervalSince(prev) > coldCacheGapSeconds {
                    result.coldOkTurnIds.insert(entry.id)
                }
            } else {
                result.coldOkTurnIds.insert(entry.id)
            }
            if let end = entry.end { prevTurnEnd = end }
        }
        return result
    }

    /// Incremental step-level cold-cache marks for one materialized
    /// turn: the first step inherits the turn's mark (the inter-turn
    /// gap), in-turn gaps classify exactly.
    private func classifyMaterializedSteps(of turn: Turn) {
        classifySteps(
            turn.steps,
            turnColdOk: cacheClassification.coldOkTurnIds.contains(turn.id)
        )
    }

    private func classifySteps(_ steps: [Step], turnColdOk: Bool) {
        let chrono = steps.sorted { $0.timestamp < $1.timestamp }
        var prevStepTime: Date?
        for step in chrono {
            if let prev = prevStepTime {
                if step.timestamp.timeIntervalSince(prev) > Self.coldCacheGapSeconds {
                    cacheClassification.coldOkStepIds.insert(step.uuid)
                }
            } else if turnColdOk {
                cacheClassification.coldOkStepIds.insert(step.uuid)
            }
            prevStepTime = step.timestamp
        }
    }

    // MARK: - Reload

    private func reloadTurns(
        for sessionId: String,
        preserveSelection: Bool,
        preferredSelectionKey: String? = nil
    ) {
        // Save selection identity (programmatic selection isn't fired
        // when the same row stays selected).
        let selectedNode = outlineView.selectedRow >= 0
            ? outlineView.item(atRow: outlineView.selectedRow) as? TurnOutlineNode
            : nil
        let selectedKey = preferredSelectionKey ?? selectedNode?.identityKey

        // SQLite-first (plan 4.1): top level renders from the turns
        // table's aggregate columns; steps materialize per turn on
        // expand via scoped raw-line decode. The legacy graph path was
        // deleted in 5.3 — without an installed source there is nothing
        // to render.
        guard let source = store.sqliteConversationSource else {
            resetSQLiteConversationState()
            flatChildrenByTurnId = [:]
            flatChildrenBySkillGroupId = [:]
            finishReload(
                sessionId: sessionId,
                newTurns: [],
                newFlatByTurn: [:],
                preserveSelection: preserveSelection,
                selectedKey: selectedKey,
                preferredSelectionKey: preferredSelectionKey
            )
            return
        }
        reloadTurnsFromSQLite(
            source: source,
            sessionId: sessionId,
            preserveSelection: preserveSelection,
            selectedKey: selectedKey,
            preferredSelectionKey: preferredSelectionKey
        )
    }

    /// Shared reload tail (legacy + SQLite paths): match indices,
    /// appearance triggers, reloadData, expansion + selection restore.
    private func finishReload(
        sessionId: String,
        newTurns: [Turn],
        newFlatByTurn: [String: [TurnOutlineNode]],
        preserveSelection: Bool,
        selectedKey: String?,
        preferredSelectionKey: String?
    ) {
        rebuildMatchIndices()

        // Phase 8.3 — compute appearance triggers for the new row set
        // BEFORE `reloadData()` so the row-view factory has them ready
        // when AppKit synchronously re-installs every visible row.
        // Snapshot includes Turn rows at top level + **all** Step rows
        // (regardless of expansion). Steps under collapsed Turns are
        // marked via `collapsedAnimParents` so the engine translates
        // their triggers to the Turn header (deduplicated). Without
        // this, a step arriving under a collapsed Turn would silently
        // fail to fire any animation — the user would have no signal
        // that something updated below the closed disclosure.
        // Skill-group / sub-agent rows are deliberately excluded per
        // UX spec (their cyan container styling is the existing visual cue).
        var orderedAnimIDs: [String] = []
        var animParentByID: [String: String] = [:]
        var collapsedAnimParents: Set<String> = []
        orderedAnimIDs.reserveCapacity(newTurns.count + newFlatByTurn.values.reduce(0) { $0 + $1.count })
        for turn in newTurns {
            let turnNodeKey = "turn:\(sessionId):\(turn.id)"
            orderedAnimIDs.append(turnNodeKey)
            if !expandedTurnIds.contains(turn.id) {
                collapsedAnimParents.insert(turnNodeKey)
            }
            for child in newFlatByTurn[turn.id] ?? [] {
                if case .step = child.kind {
                    orderedAnimIDs.append(child.identityKey)
                    animParentByID[child.identityKey] = turnNodeKey
                }
                // skillGroup / subAgent children intentionally
                // skipped — their visual identity already
                // distinguishes them and the spec excludes them.
            }
        }
        appearanceCoordinator.prepare(
            orderedIDs: orderedAnimIDs,
            parentByID: animParentByID,
            collapsedParents: collapsedAnimParents
        )

        // Guard against delegate selection-change callbacks fired
        // during `reloadData`.
        isProgrammaticSelectionChange = true
        outlineView.reloadData()

        // Restore expansion state — auto-expand the Turn that contains
        // the currently selected row.
        var idsToExpand = expandedTurnIds
        if let key = selectedKey,
           let parts = identityFields(in: key, kind: "step", sessionId: sessionId, fieldCount: 2) {
            let selectedTurnId = parts[0]
            if turnNodes["\(sessionId):\(selectedTurnId)"] != nil {
                idsToExpand.insert(selectedTurnId)
            } else if let container = subAgentContainer(forSubTurnId: selectedTurnId) {
                idsToExpand.insert(container.parentTurnId)
                expandedSubAgentKeys.insert(container.subAgentKey)
                if let groupId = skillGroupId(containingStepUuid: container.parentStepUuid) {
                    expandedSkillGroupIds.insert(groupId)
                }
            }
        } else if let key = selectedKey,
                  let parts = identityFields(in: key, kind: "skillGroup", sessionId: sessionId, fieldCount: 2) {
            // The skillGroup itself must also be expanded so its
            // child steps remain visible.
            idsToExpand.insert(parts[0])
            expandedSkillGroupIds.insert(parts[1])
        } else if let key = selectedKey,
                  let parts = identityFields(in: key, kind: "subAgent", sessionId: sessionId, fieldCount: 3) {
            idsToExpand.insert(parts[0])
            expandedSubAgentKeys.insert(key)
            if let groupId = skillGroupId(containingStepUuid: parts[1]) {
                expandedSkillGroupIds.insert(groupId)
            }
        }
        for turnId in idsToExpand {
            if let node = turnNodes["\(sessionId):\(turnId)"] {
                outlineView.expandItem(node)
            }
        }
        // Re-apply skillGroup expansion *after* the parent Turn expansion so
        // the group rows exist in the outline view's item cache.
        for groupId in expandedSkillGroupIds {
            if let node = skillGroupNodes[groupId] {
                outlineView.expandItem(node)
            }
        }
        for subAgentKey in expandedSubAgentKeys {
            if let node = subAgentNodes[subAgentKey] {
                outlineView.expandItem(node)
            }
        }
        isProgrammaticSelectionChange = false

        // State overlay: outline, loading, or empty (see updateStateVisibility).
        updateStateVisibility()

        // Restore selection (programmatic — delegate callback skipped).
        if preserveSelection, let key = selectedKey {
            if let row = rowForIdentityKey(key) {
                isProgrammaticSelectionChange = true
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isProgrammaticSelectionChange = false
                if let node = outlineView.item(atRow: row) as? TurnOutlineNode {
                    selectedIdentityKeyBySessionId[sessionId] = node.identityKey
                    if preferredSelectionKey != nil {
                        notifySelection(for: node)
                    }
                }
            } else {
                onSelectionCleared?()
            }
        } else if !preserveSelection {
            isProgrammaticSelectionChange = true
            outlineView.deselectAll(nil)
            isProgrammaticSelectionChange = false
            onSelectionCleared?()
        }

        // NOTE: do NOT clear pending appearance triggers here.
        // `outlineView.reloadData()` does not synchronously create
        // row views — AppKit defers row-view realisation to the next
        // display pass on the runloop. Wiping the trigger dict at
        // this point (still inside the same runloop iteration as
        // `reloadData()`) drains every trigger before AppKit ever
        // asks for the matching row view, and `consume(id:)` returns
        // nil for everything. The next `prepare()` cycle's
        // `removeAll` handles drainage of any leftover entries.
    }

    private func rowForIdentityKey(_ key: String) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? TurnOutlineNode,
               node.identityKey == key {
                return row
            }
        }
        return nil
    }

    private func identityFields(
        in key: String,
        kind: String,
        sessionId: String,
        fieldCount: Int
    ) -> [String]? {
        let prefix = "\(kind):\(sessionId):"
        guard key.hasPrefix(prefix), fieldCount > 0 else { return nil }
        let remainder = key.dropFirst(prefix.count)
        let parts = remainder.split(
            separator: ":",
            maxSplits: fieldCount - 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == fieldCount else { return nil }
        return parts.map(String.init)
    }

    private func subAgentContainer(forSubTurnId subTurnId: String) -> (
        subAgentKey: String,
        parentTurnId: String,
        parentStepUuid: String
    )? {
        for node in subAgentNodes.values {
            if case .subAgent(_, let turn, let parentTurnId, let parentStepUuid) = node.kind,
               turn.id == subTurnId {
                return (node.identityKey, parentTurnId, parentStepUuid)
            }
        }
        return nil
    }

    private func skillGroupId(containingStepUuid stepUuid: String) -> String? {
        for rows in groupedRowsByTurn.values {
            for row in rows {
                guard case .skillGroup(let group) = row,
                      group.steps.contains(where: { $0.uuid == stepUuid }) else {
                    continue
                }
                return group.id
            }
        }
        return nil
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return turns.count }
        guard let node = item as? TurnOutlineNode else { return 0 }
        switch node.kind {
        case .turn(let turn):
            // SQLite-first: AppKit asks for the count only when the
            // item expands (or restores expanded) — the lazy hook.
            ensureTurnChildrenMaterialized(turn.id)
            // Pre-built flat list = base SkillGroupBuilder rows +
            // SubAgent siblings spliced in after their parent step.
            return flatChildrenByTurnId[turn.id]?.count
                ?? groupedRowsByTurn[turn.id]?.count
                ?? turn.steps.count
        case .skillGroup(let g, _, _):
            return flatChildrenBySkillGroupId[g.id]?.count ?? g.steps.count
        case .step:
            // Option B layout — sub-agents are siblings, not children.
            // Step nodes never expand.
            return 0
        case .subAgent(_, let turn, _, _):
            return (materializedSubAgentSteps(for: node) ?? turn.steps).count
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            let turn = turns[index]
            return turnNodes["\(turn.sessionId):\(turn.id)"] ?? TurnOutlineNode(turn: turn)
        }
        guard let node = item as? TurnOutlineNode else {
            return TurnOutlineNode(turn: turns[index])  // should not happen
        }
        switch node.kind {
        case .turn(let turn):
            // Top-level child = pre-built flat list mixing .step /
            // .skillGroup / .subAgent (siblings).
            if let flat = flatChildrenByTurnId[turn.id], index < flat.count {
                return flat[index]
            }
            // Defensive fallback — should be unreachable since
            // `reloadTurns` always populates `flatChildrenByTurnId`.
            let step = turn.steps[index]
            let key = "\(turn.sessionId):\(turn.id):\(step.uuid)"
            return stepNodes[key] ?? TurnOutlineNode(step: step, parentTurnId: turn.id)
        case .skillGroup(let group, let sid, let tid):
            if let flat = flatChildrenBySkillGroupId[group.id], index < flat.count {
                return flat[index]
            }
            let step = group.steps[index]
            let key = "\(sid):\(tid):\(step.uuid)"
            return stepNodes[key] ?? TurnOutlineNode(step: step, parentTurnId: tid)
        case .step:
            // Should not be reached: isItemExpandable returns false
            // for .step (Option B — sub-agents are siblings, not
            // children). Defend against the impossible.
            assertionFailure("child:ofItem called on .step — Step nodes have no children in Option B layout")
            if let first = turns.first {
                return turnNodes["\(first.sessionId):\(first.id)"] ?? TurnOutlineNode(turn: first)
            }
            return node
        case .subAgent(_, let turn, _, _):
            // Children = sub-agent's own Steps in timestamp order
            // (materialized map first — the node payload is a stub
            // under SQLite-first).
            let steps = materializedSubAgentSteps(for: node) ?? turn.steps
            let step = steps[index]
            let key = "\(turn.sessionId):\(turn.id):\(step.uuid)"
            return stepNodes[key] ?? TurnOutlineNode(step: step, parentTurnId: turn.id)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TurnOutlineNode else { return false }
        switch node.kind {
        case .turn(let turn):
            if let flat = flatChildrenByTurnId[turn.id] { return !flat.isEmpty }
            // Unmaterialized SQLite stub: answer from the aggregate
            // columns without triggering the scoped decode.
            if let aggregate = sqliteAggregates[turn.id] {
                return aggregate.stepCount > 0
            }
            return !turn.steps.isEmpty
        case .skillGroup(let g, _, _):
            return !(flatChildrenBySkillGroupId[g.id]?.isEmpty ?? g.steps.isEmpty)
        case .step:
            // Option B layout — sub-agents are siblings, not children.
            return false
        case .subAgent(_, let turn, _, _):
            if let aggregate = sqliteAggregates[turn.id],
               subAgentMaterializedSteps[node.identityKey] == nil {
                return aggregate.stepCount > 0
            }
            return !(materializedSubAgentSteps(for: node) ?? turn.steps).isEmpty
        }
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TurnOutlineNode, let colId = tableColumn?.identifier else { return nil }
        switch node.kind {
        case .turn(let turn):
            return configureTurnCell(turn: turn, column: colId)
        case .skillGroup(let group, _, _):
            return configureSkillGroupCell(group: group, column: colId)
        case .step(let step, _):
            return configureStepCell(step: step, column: colId)
        case .subAgent(let link, let turn, _, _):
            // Diagnostic: confirm cell renderer reaches the SubAgent
            // path. A miss here means the node was created but the
            // delegate switch falls through somewhere upstream.
            if colId.rawValue == "prompt" {
                LoggerService.shared.debug(
                    "renderSubAgent agentId=\(link.agentId) "
                    + "type=\(link.subagentType ?? "nil") "
                    + "desc=\(link.description ?? "nil") "
                    + "subTurnSteps=\(turn.steps.count)",
                    context: "OutlineGraft"
                )
            }
            return configureSubAgentCell(link: link, turn: turn, column: colId)
        }
    }

    private func configureTurnCell(turn: Turn, column colId: NSUserInterfaceItemIdentifier) -> NSView {
        switch Col(rawValue: colId.rawValue) {
        case .prompt:
            // Turn header design follows Mail / Xcode Issue Navigator:
            // Turns rely on the disclosure triangle and 13pt semibold
            // text alone to convey "this is a group container" (Apple
            // HIG: container rows use disclosure + typography, not
            // icons). Status (interrupted / API error / compacted)
            // rides as a trailing text badge so all headers share one
            // leading edge (6.9).
            let preview = TurnPreview.make(for: turn)
            let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let sourceLabel = codexSourceLabel(for: turn)
            // Build the Turn header attributed string:
            //  - "/skill ..." slash command → cyan highlight (slashHighlightedHeader)
            //  - otherwise → photo placeholder swapped for SF Symbol (attributedPreview)
            //  - interrupted Turn → dim tone
            let attributed: NSAttributedString = {
                let base: NSAttributedString
                if let slash = Self.slashHighlightedHeader(preview, font: headerFont) {
                    base = slash
                } else {
                    base = Self.attributedPreview(
                        preview,
                        font: headerFont,
                        color: .labelColor,
                        attachmentColor: .systemBlue
                    )
                }
                return Self.prependingCodexSourceLabel(sourceLabel, to: base, font: headerFont)
            }()
            if turn.isInterrupted {
                // Status rides as a TRAILING badge (6.9) — the old
                // leading icon cell started its text 28pt in while
                // ordinary headers started at the cell edge, so sibling
                // Turn headers zig-zagged by 24pt. Same pattern as the
                // `✂ compacted` badge below.
                let cell = makeOrReuseTurnHeaderCell(id: NSUserInterfaceItemIdentifier("TurnCell_prompt_interrupted"))
                let dimAttributed: NSAttributedString = {
                    let base: NSAttributedString
                    if let slash = Self.slashHighlightedHeader(preview, font: headerFont) {
                        base = slash
                    } else {
                        base = Self.attributedPreview(
                            preview,
                            font: headerFont,
                            color: .secondaryLabelColor,
                            attachmentColor: .tertiaryLabelColor
                        )
                    }
                    return Self.prependingCodexSourceLabel(
                        sourceLabel,
                        to: base,
                        font: headerFont,
                        color: .tertiaryLabelColor
                    )
                }()
                let withBadge = Self.appendingStatusBadge("⊘ interrupted", to: dimAttributed)
                let hintedDim = appendShortPromptHint(to: withBadge, for: turn)
                cell.textField?.attributedStringValue = QueryHighlighter.applied(to: hintedDim, query: highlightQuery)
                cell.textField?.alignment = .left
                cell.textField?.lineBreakMode = .byTruncatingTail
                cell.toolTip = sourceLabel.map { "Interrupted · Codex source: \($0)" } ?? "Interrupted"
                cell.setAccessibilityLabel("\(preview), interrupted turn")
                return cell
            } else if turn.endedWithApiError {
                // Trailing badge like `interrupted`/`compacted` (6.9) so
                // every Turn header shares one leading edge. Badge keeps
                // .systemOrange — matches the `.stop` Step row styling
                // and the menu-bar diagnostics warning palette — and the
                // preview text stays at full opacity (unlike
                // `interrupted`) because the user's prompt itself is
                // still valid; only Claude's reply failed to
                // materialise.
                let cell = makeOrReuseTurnHeaderCell(id: NSUserInterfaceItemIdentifier("TurnCell_prompt_apiError"))
                let withBadge = Self.appendingStatusBadge("⚠ API error", color: .systemOrange, to: attributed)
                let hinted = appendShortPromptHint(to: withBadge, for: turn)
                cell.textField?.attributedStringValue = QueryHighlighter.applied(to: hinted, query: highlightQuery)
                cell.textField?.alignment = .left
                cell.textField?.lineBreakMode = .byTruncatingTail
                // Tooltip surfaces the actual error body when available
                // (the same text the Step row + Detail pane now show)
                // so a hover gives the user the failure reason without
                // opening the Detail pane.
                if let body = turn.lastStep?.text, !body.isEmpty {
                    let source = sourceLabel.map { "Codex source: \($0) · " } ?? ""
                    cell.toolTip = "Ended with API error · \(source)\(body)"
                } else {
                    cell.toolTip = sourceLabel.map { "Ended with API error · Codex source: \($0)" }
                        ?? "Ended with API error"
                }
                cell.setAccessibilityLabel("\(preview), turn ended with API error")
                return cell
            } else if compactedAwayTurnIds.contains(turn.id) {
                // `/compact` (auto or manual) wiped this Turn's
                // assistant follow-up from the JSONL — only the user
                // prompt remains, and the next Turn is the
                // `↻ Compact resume` summary. Surface a trailing
                // `✂ compacted` badge so the user understands why
                // tokens read 0 and no replies are visible. Prompt
                // text itself stays at full opacity (the prompt was
                // valid and the user's reply did exist; it's just
                // been summarised away).
                let cell = makeOrReuseTurnHeaderCell(id: NSUserInterfaceItemIdentifier("TurnCell_prompt_compacted"))
                let withBadge = Self.appendingStatusBadge("✂ compacted", to: attributed)
                let hinted = appendShortPromptHint(to: withBadge, for: turn)
                cell.textField?.attributedStringValue = QueryHighlighter.applied(to: hinted, query: highlightQuery)
                cell.textField?.alignment = .left
                cell.textField?.lineBreakMode = .byTruncatingTail
                let source = sourceLabel.map { " Codex source: \($0)." } ?? ""
                cell.toolTip = "Reply was summarized by /compact into the next turn — original assistant entries are no longer in the JSONL.\(source)"
                cell.setAccessibilityLabel(
                    "\(preview), reply summarized by compact into the next turn"
                )
                return cell
            } else {
                let cell = makeOrReuseTurnHeaderCell(id: NSUserInterfaceItemIdentifier("TurnCell_prompt_header"))
                let hinted = appendShortPromptHint(to: attributed, for: turn)
                cell.textField?.attributedStringValue = QueryHighlighter.applied(to: hinted, query: highlightQuery)
                cell.textField?.alignment = .left
                cell.textField?.lineBreakMode = .byTruncatingTail
                cell.toolTip = sourceLabel.map { "Codex source: \($0)" }
                return cell
            }
        case .time:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_time"))
            if let start = turn.startTime {
                cell.textField?.stringValue = Self.startTimeFormatter.string(from: start)
            } else {
                cell.textField?.stringValue = CostFormatter.emDash
            }
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .center
            return cell
        case .model:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_model"))
            let summary = displayModelSummary(for: turn)
            cell.textField?.attributedStringValue = Self.turnModelAttr(summary: summary)
            cell.textField?.alignment = .center
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.toolTip = Self.turnModelTooltip(summary: summary)
            cell.setAccessibilityLabel(Self.turnModelAccessibility(summary: summary))
            return cell
        case .contextWindow:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_contextWindow"))
            let contextWindow = displayTokens(for: turn).contextWindow
            cell.textField?.stringValue = contextWindow.map(CompactNumber.compact) ?? CostFormatter.emDash
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.textColor = contextWindow == nil ? .quaternaryLabelColor : .secondaryLabelColor
            cell.textField?.alignment = .right
            cell.toolTip = contextWindow.map { "Context window: \(NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal)) tokens" }
            return cell
        case .tokens:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_tokens"))
            // Turn header rolls in sub-agent tokens to stay symmetric
            // with the Cost column (otherwise sub-agent-heavy turns
            // would surface implausible price/token ratios). Reporting
            // continues to use bare `aggregateTokens`.
            let agg = displayTokens(for: turn)
            cell.textField?.stringValue = CompactNumber.compact(agg.inputTokens + agg.outputTokens)
            // Regular, not semibold (6.9): with Tokens AND Cost both
            // semibold the numeric block read as one flat slab of
            // emphasis. Cost keeps the weight — it's the column the
            // user scans for.
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.textColor = .labelColor
            cell.textField?.alignment = .right
            return cell
        case .cacheRead:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_cacheRead"))
            cell.textField?.attributedStringValue = Self.cacheReadAttr(
                displayTokens(for: turn).cacheReadInputTokens,
                fontSize: 12,
                weight: .regular
            )
            cell.textField?.alignment = .right
            return cell
        case .cacheWrite:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_cacheWrite"))
            let agg = displayTokens(for: turn)
            cell.textField?.attributedStringValue = Self.cacheWriteAttr(
                agg.cacheCreationInputTokens,
                cr: agg.cacheReadInputTokens,
                coldOk: cacheClassification.coldOkTurnIds.contains(turn.id),
                fontSize: 12,
                weight: .regular
            )
            cell.textField?.alignment = .right
            return cell
        case .cacheTTL:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_cacheTTL"))
            let agg = displayTokens(for: turn)
            cell.textField?.attributedStringValue = Self.cacheTTLAttr(
                eph1h: agg.cacheCreationEphemeral1h,
                eph5m: agg.cacheCreationEphemeral5m,
                fontSize: 11,
                weight: .regular
            )
            cell.textField?.alignment = .center
            return cell
        case .reasoning:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_reasoning"))
            let reasoning = displayTokens(for: turn).reasoningOutputTokens
            cell.textField?.stringValue = reasoning > 0 ? CompactNumber.compact(reasoning) : CostFormatter.emDash
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.textColor = reasoning > 0 ? .labelColor : .quaternaryLabelColor
            cell.textField?.alignment = .right
            return cell
        case .cost:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_cost"))
            // Turn header shows the user-perceived total — own steps
            // PLUS any sub-agents this turn spawned. Reporting code
            // continues to use bare `aggregateCost` (sub-agent Turns
            // are summed separately) to avoid double-counting.
            cell.textField?.attributedStringValue = Self.costAttr(
                displayCost(for: turn).totalCostUSD,
                confidence: costConfidence(for: turn),
                fontSize: 12,
                weight: .semibold,
                warningThreshold: costOutlierThresholdUSD
            )
            cell.textField?.alignment = .right
            cell.toolTip = costTooltip(confidence: costConfidence(for: turn))
            return cell
        case nil:
            return makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("TurnCell_empty"))
        }
    }

    /// Append a `· ↪ "..."` reply-to hint to a Turn header when the prompt
    /// is a short acknowledgment (`y`, `네`, `ok` …). Returns the input
    /// unchanged when no hint applies so every caller can use the result
    /// blindly.
    ///
    /// The hint is pulled from the preceding Turn's closing text via
    /// `ShortPromptContextResolver`, then styled in tertiary-label color
    /// so it reads as secondary context without competing with the
    /// primary prompt text.
    /// Append a trailing `· <badge>` status badge to a Turn header
    /// attributed string (`✂ compacted`, `⊘ interrupted`,
    /// `⚠ API error`). Trailing text — never a leading icon — so every
    /// Turn header keeps one shared leading edge (6.9). Rendered at
    /// 11pt regular so it reads as metadata, not content; color
    /// defaults to dim tertiary, callers escalate (orange) when the
    /// status is a failure worth spotting in a scan.
    static func appendingStatusBadge(
        _ badge: String,
        color: NSColor = .tertiaryLabelColor,
        to attributed: NSAttributedString
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        result.append(NSAttributedString(
            string: "  ·  \(badge)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color
            ]
        ))
        return result
    }

    private static func prependingCodexSourceLabel(
        _ label: String?,
        to attributed: NSAttributedString,
        font: NSFont,
        color: NSColor = .systemTeal
    ) -> NSAttributedString {
        guard let label, !label.isEmpty else { return attributed }
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "\(label) · ",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(11, font.pointSize - 1), weight: .semibold),
                .foregroundColor: color
            ]
        ))
        result.append(attributed)
        return result
    }

    private func codexSourceLabel(for turn: Turn) -> String? {
        guard store.activeProvider == .codex,
              let identityKey = Self.codexSourceIdentityKey(for: turn),
              identityKey != currentSessionId else {
            return nil
        }
        return Self.fallbackCodexSourceLabel(forIdentityKey: identityKey)
    }

    static func codexSourceIdentityKey(for turn: Turn) -> String? {
        for requestId in turn.steps.compactMap(\.requestId) {
            if let key = CodexSourceDiscriminator.requestSourceIdentityKey(from: requestId) {
                return key
            }
        }
        return codexSourceIdentityKey(fromTurnId: turn.id)
    }

    private static func codexSourceIdentityKey(fromTurnId turnId: String) -> String? {
        guard turnId.hasPrefix("codex:") else { return nil }
        if let sourceRange = turnId.range(of: ":source:") {
            let sourceSuffix = turnId[sourceRange.upperBound...]
            guard let nextColon = sourceSuffix.firstIndex(of: ":") else { return nil }
            return CodexSourceDiscriminator.sourceIdentityKey(
                scopedSessionId: String(turnId[..<sourceRange.lowerBound]),
                sourceKey: String(sourceSuffix[..<nextColon])
            )
        }

        let rawStart = turnId.index(turnId.startIndex, offsetBy: "codex:".count)
        let rawAndRest = turnId[rawStart...]
        guard let nextColon = rawAndRest.firstIndex(of: ":") else { return nil }
        return "codex:\(rawAndRest[..<nextColon])"
    }

    private static func fallbackCodexSourceLabel(forIdentityKey identityKey: String) -> String? {
        let components = CodexSourceDiscriminator.sourceIdentityComponents(from: identityKey)
        let rawID = ProviderScopedID.rawID(from: components.scopedSessionId)
        let shortRaw = String(rawID.prefix(8))
        if let sourceKey = components.sourceKey {
            return "source \(shortRaw)#\(sourceKey.prefix(6))"
        }
        return "subagent \(shortRaw)"
    }

    private func appendShortPromptHint(
        to attributed: NSAttributedString,
        for turn: Turn
    ) -> NSAttributedString {
        // Resolver finds the chronologically-previous Turn by startTime,
        // so it doesn't matter that `turns` here is DESC-sorted (newest
        // first) for display.
        guard let hint = ShortPromptContextResolver.hint(
            for: turns, currentTurnId: turn.id
        ) else {
            return attributed
        }
        let result = NSMutableAttributedString(attributedString: attributed)
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        result.append(NSAttributedString(
            string: "  ·  ↪ \u{201C}\(hint)\u{201D}",
            attributes: hintAttrs
        ))
        return result
    }

    private func configureStepCell(step: Step, column colId: NSUserInterfaceItemIdentifier) -> NSView {
        switch Col(rawValue: colId.rawValue) {
        case .prompt:
            // The user-prompt emphasis is handled by the row-level
            // accent bar (`TurnAccentRowView` `.promptDescendant`).
            // Here we keep the standard icon cell but preserve the
            // nested indent on `toolResult` so toolCall → toolResult
            // pairs read as Xcode Issue Navigator style.
            let isNested = step.kind == .toolResult
            let cellId = NSUserInterfaceItemIdentifier(
                isNested ? "StepCell_prompt_nested" : "StepCell_prompt"
            )
            let cell = makeOrReuseIconCell(id: cellId, iconLeading: isNested ? 20 : 4)
            let attr = attributedStepSummary(for: step)
            cell.textField?.attributedStringValue = step.kind == .prompt
                ? QueryHighlighter.applied(to: attr, query: highlightQuery)
                : attr
            cell.textField?.alignment = .left
            cell.textField?.lineBreakMode = .byTruncatingTail

            cell.imageView?.image = NSImage(
                systemSymbolName: StepKindStyle.roleSymbol(for: step.kind),
                accessibilityDescription: StepKindStyle.label(for: step.kind)
            )
            cell.imageView?.contentTintColor = StepKindStyle.roleTint(for: step.kind)
            cell.toolTip = StepKindStyle.label(for: step.kind)
            return cell
        case .model:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_model"))
            if let model = step.model, !model.isEmpty,
               !PricingTable.isSyntheticModel(model) {
                let short = ModelNameFormatter.short(model)
                cell.textField?.stringValue = short
                cell.textField?.textColor = ModelDisplay.color(for: model)
                // Semibold matches the Turn header — 11pt colored text
                // needs the extra weight to clear "large text" WCAG
                // threshold (3:1) against both light and dark
                // backgrounds.
                cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
                cell.toolTip = model
                cell.setAccessibilityLabel(
                    "Model: \(ModelDisplay.voiceOverLabel(short: short))"
                )
            } else {
                // Non-assistant steps (prompt / toolResult) — blank cell
                // keeps the column scannable vertically. em-dash here
                // would add visual noise the Conversation column
                // already doesn't have.
                cell.textField?.stringValue = ""
                cell.textField?.textColor = .labelColor
                cell.toolTip = nil
                cell.setAccessibilityElement(false)
            }
            cell.textField?.alignment = .center
            cell.textField?.lineBreakMode = .byTruncatingTail
            return cell
        case .contextWindow:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_contextWindow"))
            let contextWindow = step.tokens?.contextWindow
            cell.textField?.stringValue = contextWindow.map(CompactNumber.compact) ?? CostFormatter.emDash
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = contextWindow == nil ? .quaternaryLabelColor : .secondaryLabelColor
            cell.textField?.alignment = .right
            cell.toolTip = contextWindow.map { "Context window: \(NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal)) tokens" }
            return cell
        case .tokens:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_tokens"))
            if let t = step.tokens {
                cell.textField?.stringValue = CompactNumber.compact(t.inputTokens + t.outputTokens)
                cell.textField?.textColor = .secondaryLabelColor
            } else {
                cell.textField?.stringValue = CostFormatter.emDash
                cell.textField?.textColor = .quaternaryLabelColor
            }
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.alignment = .right
            return cell
        case .cacheRead:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_cacheRead"))
            cell.textField?.attributedStringValue = Self.cacheReadAttr(
                step.tokens?.cacheReadInputTokens ?? 0,
                fontSize: 11,
                weight: .regular
            )
            cell.textField?.alignment = .right
            return cell
        case .cacheWrite:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_cacheWrite"))
            let cw = step.tokens?.cacheCreationInputTokens ?? 0
            let cr = step.tokens?.cacheReadInputTokens ?? 0
            cell.textField?.attributedStringValue = Self.cacheWriteAttr(
                cw, cr: cr,
                coldOk: cacheClassification.coldOkStepIds.contains(step.uuid),
                fontSize: 11,
                weight: .regular
            )
            cell.textField?.alignment = .right
            return cell
        case .cacheTTL:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_cacheTTL"))
            cell.textField?.attributedStringValue = Self.cacheTTLAttr(
                eph1h: step.tokens?.cacheCreationEphemeral1h ?? 0,
                eph5m: step.tokens?.cacheCreationEphemeral5m ?? 0,
                fontSize: 10,
                weight: .regular
            )
            cell.textField?.alignment = .center
            return cell
        case .reasoning:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_reasoning"))
            let reasoning = step.tokens?.reasoningOutputTokens ?? 0
            cell.textField?.stringValue = reasoning > 0 ? CompactNumber.compact(reasoning) : CostFormatter.emDash
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = reasoning > 0 ? .secondaryLabelColor : .quaternaryLabelColor
            cell.textField?.alignment = .right
            return cell
        case .cost:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_cost"))
            let confidence = CostConfidence.evaluate(provider: store.activeProvider, steps: [step])
            cell.textField?.attributedStringValue = Self.costAttr(
                step.cost?.totalCostUSD ?? 0,
                confidence: confidence,
                fontSize: 11,
                weight: .regular,
                warningThreshold: costOutlierThresholdUSD
            )
            cell.textField?.alignment = .right
            if store.activeProvider == .codex, step.cost == nil {
                cell.toolTip = "Codex local data reports usage per request, not for this individual step. The Turn row shows the estimated request total."
            } else {
                cell.toolTip = costTooltip(confidence: confidence)
            }
            return cell
        case .time:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_time"))
            cell.textField?.stringValue = Self.timeFormatter.string(from: step.timestamp)
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            cell.textField?.textColor = .tertiaryLabelColor
            cell.textField?.alignment = .center
            return cell
        case nil:
            return makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("StepCell_empty"))
        }
    }

    // MARK: - SkillGroup cell

    /// Cell for a `skillGroup` header row.
    ///
    /// Conversation column: folder icon + `/skill-name` label in cyan
    /// monospace. The header is a SYNTHETIC section marker, separate from
    /// the trigger Skill-call step which appears as the group's first
    /// child. That separation lets users spot phase boundaries at a
    /// glance (the `/sync-anthropic-pricing` label reads as "a skill
    /// divided this section") without sacrificing the raw step history,
    /// which stays browsable when the group is expanded.
    private func configureSkillGroupCell(
        group: SkillGroupBuilder.SkillGroup,
        column colId: NSUserInterfaceItemIdentifier
    ) -> NSView {
        switch Col(rawValue: colId.rawValue) {
        case .prompt:
            let cell = makeOrReuseIconCell(
                id: NSUserInterfaceItemIdentifier("SkillGroupCell_prompt"),
                iconLeading: 4
            )
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.systemCyan
            ]
            cell.textField?.attributedStringValue = NSAttributedString(
                string: group.label,
                attributes: attrs
            )
            cell.textField?.alignment = .left
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.imageView?.image = NSImage(
                systemSymbolName: "folder",
                accessibilityDescription: "Skill group"
            )
            cell.imageView?.contentTintColor = .systemCyan
            cell.toolTip = skillGroupTooltip(for: group)
            return cell
        case .time:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_time"))
            if let start = group.steps.first?.timestamp {
                cell.textField?.stringValue = Self.startTimeFormatter.string(from: start)
            } else {
                cell.textField?.stringValue = CostFormatter.emDash
            }
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .center
            return cell
        case .model:
            // SkillGroup rows aggregate child Steps that can span
            // multiple models; showing one would be misleading. The
            // whole row is cyan-themed so adding the Haiku teal next to
            // it would read as a single over-saturated column. Leave
            // blank — per-child Steps still show their individual model.
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_model"))
            cell.textField?.stringValue = ""
            cell.setAccessibilityElement(false)
            return cell
        case .contextWindow:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_contextWindow"))
            let contextWindow = displayTokens(for: group).contextWindow
            cell.textField?.stringValue = contextWindow.map { "Σ \(CompactNumber.compact($0))" } ?? CostFormatter.emDash
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = contextWindow == nil ? .quaternaryLabelColor : .systemCyan
            return cell
        case .tokens:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_tokens"))
            // Mirrors the Cost cell rollup — `/wiki-ingest` 6× sub-agent
            // dispatch should surface its tokens on the skill header.
            let agg = displayTokens(for: group)
            cell.textField?.stringValue = "Σ \(CompactNumber.compact(agg.inputTokens + agg.outputTokens))"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            cell.textField?.textColor = .systemCyan
            return cell
        case .cacheRead:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_cacheRead"))
            let n = displayTokens(for: group).cacheReadInputTokens
            cell.textField?.stringValue = n > 0 ? "Σ \(CompactNumber.compact(n))" : "—"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .systemCyan
            return cell
        case .cacheWrite:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_cacheWrite"))
            let n = displayTokens(for: group).cacheCreationInputTokens
            cell.textField?.stringValue = n > 0 ? "Σ \(CompactNumber.compact(n))" : "—"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .systemCyan
            return cell
        case .cacheTTL:
            // Surface the rolled-up TTL bucket — same `cacheTTLAttr`
            // rendering as Turn header / Step rows, fed from
            // `displayTokens(for: group)` so any sub-agents this skill
            // dispatched contribute their TTL too. Earlier this cell
            // was intentionally blank to keep the cyan palette uniform;
            // surfacing the orange "1h"/"5m+1h" tint is the deliberate
            // trade — flagging premium cache spend at the skill-group
            // level (where `/wiki-ingest`-style 6× sub-agent fan-outs
            // can rack up expensive 1h writes) is more valuable than
            // visual calm.
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_cacheTTL"))
            let agg = displayTokens(for: group)
            cell.textField?.attributedStringValue = Self.cacheTTLAttr(
                eph1h: agg.cacheCreationEphemeral1h,
                eph5m: agg.cacheCreationEphemeral5m,
                fontSize: 11,
                weight: .regular
            )
            cell.textField?.alignment = .center
            return cell
        case .reasoning:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_reasoning"))
            let reasoning = displayTokens(for: group).reasoningOutputTokens
            cell.textField?.stringValue = reasoning > 0 ? "Σ \(CompactNumber.compact(reasoning))" : "—"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .systemCyan
            return cell
        case .cost:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_cost"))
            // Skill group header rolls in any sub-agents spawned by
            // its interior Steps (e.g. `/wiki-ingest` dispatching 6
            // parallel sub-agents — those costs belong on the skill
            // header, not just on each sub-agent row).
            let cost = displayCost(for: group).totalCostUSD
            let confidence = costConfidence(for: group)
            cell.textField?.attributedStringValue = Self.prefixedCostAttr(
                prefix: "Σ ",
                cost: cost,
                confidence: confidence,
                fontSize: 11,
                weight: .bold,
                exactColor: .systemCyan,
                warningThreshold: costOutlierThresholdUSD
            )
            cell.toolTip = costTooltip(confidence: confidence)
            return cell
        case nil:
            return makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("SkillGroupCell_empty"))
        }
    }

    /// Render a `.subAgent` row — Phase B Option B sibling of the
    /// parent `Agent` Step. Visual weight matches `configureSkillGroupCell`
    /// (cyan tint + bold/semibold) so the user perceives the row as a
    /// peer-level group header, not a faded metadata note. The user
    /// asked for this parity explicitly after the previous muted
    /// secondary/tertiary palette read as low-importance.
    private func configureSubAgentCell(
        link: SubAgentLinker.Link,
        turn: Turn,
        column colId: NSUserInterfaceItemIdentifier
    ) -> NSView {
        switch Col(rawValue: colId.rawValue) {
        case .prompt:
            let cell = makeOrReuseIconCell(
                id: NSUserInterfaceItemIdentifier("SubAgentCell_prompt"),
                iconLeading: 4
            )
            let labelText: String = {
                if link.linkKind == .workflow {
                    let phase = Self.nonEmptyTrimmed(link.workflowPhaseTitle)
                    let label = Self.nonEmptyTrimmed(link.workflowLabel)
                        ?? Self.nonEmptyTrimmed(link.description)
                    switch (phase, label) {
                    case (let phase?, let label?) where phase != label:
                        return "\(phase) · \(label)"
                    case (let phase?, _):
                        return phase
                    case (_, let label?):
                        return label
                    default:
                        return Self.nonEmptyTrimmed(link.workflowName) ?? "Workflow agent"
                    }
                }
                let type = link.subagentType ?? "agent"
                if let desc = link.description, !desc.isEmpty {
                    return "\(type) — \(desc)"
                }
                return type
            }()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.systemCyan
            ]
            cell.textField?.attributedStringValue = NSAttributedString(
                string: labelText, attributes: attrs
            )
            cell.textField?.alignment = .left
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.imageView?.image = NSImage(
                systemSymbolName: link.linkKind == .workflow ? "gearshape.2.fill" : "person.2.fill",
                accessibilityDescription: link.linkKind == .workflow ? "Workflow agent" : "Sub-agent"
            )
            cell.imageView?.contentTintColor = .systemCyan
            cell.toolTip = tooltip(forSubAgentLink: link)
            return cell
        case .time:
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_time"))
            if let start = turn.startTime {
                cell.textField?.stringValue = Self.startTimeFormatter.string(from: start)
            } else {
                cell.textField?.stringValue = CostFormatter.emDash
            }
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .center
            return cell
        case .model:
            // Surface the child run's model like the TTL/cost columns
            // do (user request, 6.9 follow-up) — the sidecar's
            // agg_models makes this free. A single-model child shows
            // that model in its tier tint; mixed runs reuse the
            // Turn-header summary shape ("primary +N"). Earlier this
            // cell was intentionally blank to keep the cyan row
            // uniform; knowing which model a delegated run burned
            // tokens on beats the visual calm.
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_model"))
            let summary = displayModelSummary(for: turn)
            cell.textField?.attributedStringValue = Self.turnModelAttr(summary: summary)
            cell.textField?.alignment = .center
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.toolTip = Self.turnModelTooltip(summary: summary)
            if summary.primary == nil {
                cell.setAccessibilityElement(false)
            } else {
                cell.setAccessibilityLabel(Self.turnModelAccessibility(summary: summary))
            }
            return cell
        case .contextWindow:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_contextWindow"))
            let contextWindow = displayTokens(for: turn).contextWindow
            cell.textField?.stringValue = contextWindow.map { "Σ \(CompactNumber.compact($0))" } ?? CostFormatter.emDash
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = contextWindow == nil ? .quaternaryLabelColor : .systemCyan
            return cell
        case .tokens:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_tokens"))
            // Sidecar-aware (6.7): the node's Turn payload is a header
            // STUB under SQLite-first — reading it directly rendered
            // every sub-agent container as "Σ 0".
            let agg = displayTokens(for: turn)
            cell.textField?.stringValue = "Σ \(CompactNumber.compact(agg.inputTokens + agg.outputTokens))"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            cell.textField?.textColor = .systemCyan
            return cell
        case .cacheRead:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_cacheRead"))
            let n = displayTokens(for: turn).cacheReadInputTokens
            cell.textField?.stringValue = n > 0 ? "Σ \(CompactNumber.compact(n))" : "—"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .systemCyan
            return cell
        case .cacheWrite:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_cacheWrite"))
            let n = displayTokens(for: turn).cacheCreationInputTokens
            cell.textField?.stringValue = n > 0 ? "Σ \(CompactNumber.compact(n))" : "—"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .systemCyan
            return cell
        case .cacheTTL:
            // Surface the TTL bucket aggregated across the sub-agent's
            // own steps — same `cacheTTLAttr` rendering as Turn header
            // and per-step rows. Sub-agent is a leaf in the 1-level
            // rollup contract, so bare `aggregateTokens` is correct
            // (no further sub-sub-agents to fold in).
            //
            // Earlier this cell was intentionally blank to keep the
            // row's cyan palette uniform; surfacing the orange "5m"
            // tint is the deliberate trade — flagging premium cache
            // spend on a child run is more valuable than the visual
            // calm, since premium-1h writes inside an unattended
            // sub-agent are exactly the kind of spend that goes
            // unnoticed otherwise.
            let cell = makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_cacheTTL"))
            let agg = displayTokens(for: turn)
            cell.textField?.attributedStringValue = Self.cacheTTLAttr(
                eph1h: agg.cacheCreationEphemeral1h,
                eph5m: agg.cacheCreationEphemeral5m,
                fontSize: 11,
                weight: .regular
            )
            cell.textField?.alignment = .center
            return cell
        case .reasoning:
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_reasoning"))
            let reasoning = displayTokens(for: turn).reasoningOutputTokens
            cell.textField?.stringValue = reasoning > 0 ? "Σ \(CompactNumber.compact(reasoning))" : "—"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .systemCyan
            return cell
        case .cost:
            // Σ = full sub-agent cost rolls up here so the user sees
            // "this child cost me $X" without expanding.
            let cell = makeOrReusePillCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_cost"))
            let confidence = costConfidence(for: turn)
            cell.textField?.attributedStringValue = Self.prefixedCostAttr(
                prefix: "Σ ",
                cost: displayCost(for: turn).totalCostUSD,
                confidence: confidence,
                fontSize: 11,
                weight: .bold,
                exactColor: .systemCyan,
                warningThreshold: costOutlierThresholdUSD
            )
            cell.toolTip = costTooltip(confidence: confidence)
            return cell
        case nil:
            return makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier("SubAgentCell_empty"))
        }
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func tooltip(forSubAgentLink link: SubAgentLinker.Link) -> String {
        if link.linkKind == .workflow {
            var lines = ["Workflow agent"]
            if let workflowName = Self.nonEmptyTrimmed(link.workflowName) {
                lines.append("workflow: \(workflowName)")
            }
            if let phase = Self.nonEmptyTrimmed(link.workflowPhaseTitle) {
                lines.append("phase: \(phase)")
            }
            if let label = Self.nonEmptyTrimmed(link.workflowLabel) {
                lines.append("label: \(label)")
            }
            if let state = Self.nonEmptyTrimmed(link.workflowAgentState) {
                lines.append("state: \(state)")
            }
            if let model = Self.nonEmptyTrimmed(link.workflowModel) {
                lines.append("model: \(model)")
            }
            if let runId = Self.nonEmptyTrimmed(link.workflowRunId) {
                lines.append("runId: \(runId)")
            }
            lines.append("agentId: \(link.agentId)")
            return lines.joined(separator: "\n")
        }
        return "Sub-agent (\(link.subagentType ?? "unknown"))"
            + (link.description.map { "\n\($0)" } ?? "")
            + "\nagentId: \(link.agentId)"
    }

    /// Produce the hover tooltip for a skillGroup row. Names the skill and
    /// calls out boundary diagnostics — `.reply` is always excluded, so no
    /// heuristic disclaimer is needed.
    private func skillGroupTooltip(for group: SkillGroupBuilder.SkillGroup) -> String {
        var lines = ["Skill: \(group.label)"]
        if !group.hasToolResult {
            lines.append("Interrupted — no matching tool_result found.")
        } else if !group.hasIsMetaAnchor {
            lines.append("Skill preamble not detected.")
        }
        lines.append("Σ = sum of every step in this section "
            + "(through the next skill or `.reply`). "
            + "Interleaved main-thread tool calls are absorbed; "
            + "`.reply` stays outside.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Attributed preview with inline photo symbol

    /// Returns an attributed string built from a `TurnPreview` where
    /// the `🖼` emoji placeholder is replaced by an inline SF Symbol
    /// `photo` attachment so the icon renders in the system text tone
    /// instead of the off-tone color emoji glyph.
    static func attributedPreview(
        _ preview: String,
        font: NSFont,
        color: NSColor,
        attachmentColor: NSColor? = nil
    ) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        guard preview.contains("🖼") else {
            return NSAttributedString(string: preview, attributes: baseAttrs)
        }

        let attachTint = attachmentColor ?? color
        let result = NSMutableAttributedString()
        let parts = preview.components(separatedBy: "🖼")
        for (index, part) in parts.enumerated() {
            if !part.isEmpty {
                result.append(NSAttributedString(string: part, attributes: baseAttrs))
            }
            if index < parts.count - 1 {
                result.append(photoSymbolAttachment(font: font, color: attachTint))
            }
        }
        return result
    }

    /// Inline SF Symbol `photo` attachment scaled/tinted to match the
    /// surrounding text's font size and color.
    private static func photoSymbolAttachment(font: NSFont, color: NSColor) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: "photo", accessibilityDescription: "image")?
            .withSymbolConfiguration(config) else {
            // fallback — plain emoji
            return NSAttributedString(string: "🖼", attributes: [
                .font: font, .foregroundColor: color
            ])
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Baseline tweak — the `photo` symbol's natural anchor is the
        // top, so nudge it down slightly so it sits on the text baseline.
        let baselineDescender = font.descender
        attachment.bounds = CGRect(
            x: 0,
            y: baselineDescender + 1,
            width: image.size.width,
            height: image.size.height
        )
        let str = NSMutableAttributedString(attachment: attachment)
        // Trailing space so the symbol doesn't crowd the next glyph.
        let leading = NSAttributedString(string: " ", attributes: [
            .font: font, .foregroundColor: color
        ])
        let wrap = NSMutableAttributedString()
        wrap.append(str)
        wrap.append(leading)
        return wrap
    }

    // MARK: - Attributed step summary

    /// Build a per-Step one-line attributed summary, styled per kind:
    /// - `.toolCall` / `.thought`: bold toolName, secondary input
    /// - `.toolResult`: toolName + short content
    /// - `.reply` / `.prompt`: plain
    private func attributedStepSummary(for step: Step) -> NSAttributedString {
        let regular = NSFont.systemFont(ofSize: 11)
        let semibold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let primary = StepKindStyle.textColor(for: step.kind)
        let dim = NSColor.tertiaryLabelColor

        func plain(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: regular, .foregroundColor: primary])
        }
        func emphatic(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: semibold, .foregroundColor: NSColor.labelColor])
        }
        func muted(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: regular, .foregroundColor: dim])
        }

        switch step.kind {
        case .prompt:
            // Compact-away placeholder — when a Turn lost its assistant
            // follow-up to `/compact`, the lone prompt step row would
            // otherwise duplicate the Turn header text. Replace it with
            // a single "summarised away" line so the empty expand area
            // tells the user *why* there are no replies. The original
            // prompt content stays accessible in the Detail panel
            // (Step.text retains the full body).
            if compactedAwayTurnIds.contains(step.uuid) {
                let italicFont = NSFontManager.shared.font(
                    withFamily: NSFont.systemFont(ofSize: 12).familyName ?? ".AppleSystemUIFont",
                    traits: .italicFontMask,
                    weight: 5,
                    size: 12
                ) ?? NSFont.systemFont(ofSize: 12, weight: .regular)
                return NSAttributedString(
                    string: "✂ Reply was summarized by /compact into the next turn",
                    attributes: [
                        .font: italicFont,
                        .foregroundColor: NSColor.tertiaryLabelColor
                    ]
                )
            }
            // The Prompt is the Turn's entry point — 12pt semibold +
            // `.labelColor` puts it two hierarchy steps above the
            // remaining steps (11pt regular + `.secondaryLabelColor`),
            // mirroring Apple Mail's "subject bold + meta dim" pattern.
            // The leading row-level accent bar (`TurnAccentRowView`
            // `.promptDescendant`) reinforces it.
            let promptFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let promptMutedAttrs: [NSAttributedString.Key: Any] = [
                .font: promptFont,
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let promptPlain: (String) -> NSAttributedString = { s in
                NSAttributedString(string: s, attributes: [
                    .font: promptFont,
                    .foregroundColor: NSColor.labelColor
                ])
            }
            let promptMuted: (String) -> NSAttributedString = { s in
                NSAttributedString(string: s, attributes: promptMutedAttrs)
            }
            // `TurnPreview.clean`: `[Image #N]` → 🖼, drop `[Image source: ...]`.
            // Apply the same cleanup pipeline the Turn header uses so
            // the prompt step row never leaks raw `[Image #N]` tokens.
            let raw = step.oneLineSummary()
            let cleaned = TurnPreview.clean(raw)
            // Slash commands and image attachments are mutually
            // exclusive — `/cmd args` takes the slash-highlight path,
            // everything else takes the inline-attachment path.
            if cleaned.hasPrefix("/") {
                return Self.slashHighlighted(
                    cleaned,
                    plain: promptPlain,
                    muted: promptMuted
                )
            }
            return Self.attributedPreview(
                cleaned,
                font: promptFont,
                color: .labelColor,
                attachmentColor: .controlAccentColor
            )

        case .reply:
            // The final reply is the Turn's exit point — symmetrical
            // with the prompt at 12pt medium so the "ask → answer"
            // pair surfaces as the two visual anchors of the Turn.
            // Prompt uses semibold (entry emphasis), reply uses medium
            // (close emphasis, one tier lighter).
            let replyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            return NSAttributedString(
                string: step.oneLineSummary(),
                attributes: [
                    .font: replyFont,
                    .foregroundColor: NSColor.labelColor
                ]
            )

        case .stop:
            return plain(step.oneLineSummary())

        case .interruption:
            return NSAttributedString(
                string: "User cancelled this request",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.systemRed
                ]
            )

        case .thought:
            let text = (step.text ?? "").replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let result = NSMutableAttributedString()
            if !text.isEmpty {
                result.append(plain(text))
            }
            if let first = step.toolCalls.first {
                if !text.isEmpty { result.append(muted("  →  ")) }
                result.append(emphatic(StepKindStyle.displayName(forToolName: first.name)))
                let input = ToolInputFormatter.format(call: first, limit: 60)
                if !input.isEmpty && input != "(no input)" {
                    result.append(muted("  \(input)"))
                }
                if step.toolCalls.count > 1 {
                    // "· 4 tools" bold accent badge — signals that the
                    // following toolResult rows are parallel calls
                    // dispatched from this thought.
                    let badge = NSAttributedString(
                        string: "  · \(step.toolCalls.count) tools",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                            .foregroundColor: NSColor.controlAccentColor
                        ]
                    )
                    result.append(badge)
                }
            } else if text.isEmpty {
                return muted("(thinking)")
            }
            return result

        case .toolCall:
            let result = NSMutableAttributedString()
            if let first = step.toolCalls.first {
                result.append(emphatic(StepKindStyle.displayName(forToolName: first.name)))
                let input = ToolInputFormatter.format(call: first, limit: 80)
                if !input.isEmpty && input != "(no input)" {
                    result.append(muted("  \(input)"))
                }
                if step.toolCalls.count > 1 {
                    // Parallel-batch count — same badge style as the
                    // thought row.
                    let badge = NSAttributedString(
                        string: "  · \(step.toolCalls.count) tools",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                            .foregroundColor: NSColor.controlAccentColor
                        ]
                    )
                    result.append(badge)
                }
            } else {
                return muted("(empty tool call)")
            }
            return result

        case .toolResult:
            let result = NSMutableAttributedString()
            guard let tr = step.toolResult else { return muted("(empty result)") }
            // The legacy session-wide tool-name index died with the
            // graphs (5.3); the synthetic fallback covers the rest.
            let rawToolName = tr.toolUseId.contains(":patch:") ? "patch_apply_end" : "tool"
            let toolName = StepKindStyle.displayName(forToolName: rawToolName)
            if tr.isError {
                result.append(NSAttributedString(string: "✗ ", attributes: [.font: semibold, .foregroundColor: NSColor.systemRed]))
            }
            result.append(emphatic(toolName))
            let content = tr.abbreviatedContent(limit: 120)
            if !content.isEmpty {
                result.append(muted("  \(content)"))
            }
            return result
        }
    }

    // MARK: - Cache cell formatting

    // MARK: - Cache-miss classification (rules 1–3 of cell styling)

    /// 1-hour gap matches Anthropic's 1h-ephemeral cache expiry.
    /// Turns/Steps with a larger gap "naturally" miss cache and inflate
    /// CW, so the warning is softened one tone (orange instead of red).
    private static let coldCacheGapSeconds: TimeInterval = 3600

    /// Computed once per session. Sorts by timestamp (independent of
    /// display order, which is usually DESC) to find the chronologically
    /// first Turn/Step and any neighbour with a > 1h gap, packed into id
    /// sets for O(1) lookup at cell-render time.
    private struct CacheClassification {
        /// Turn.id — session chrono-first OR > 1h after previous Turn end.
        var coldOkTurnIds: Set<String> = []
        /// Step.uuid — session chrono-first OR > 1h after previous Step timestamp.
        var coldOkStepIds: Set<String> = []
    }

    private static func computeCacheClassification(for turns: [Turn]) -> CacheClassification {
        var result = CacheClassification()
        // Sort ascending by timestamp (independent of display order,
        // which is usually DESC) to identify the session's
        // chronologically-first row.
        let chronoTurns = turns.sorted { a, b in
            (a.startTime ?? .distantPast) < (b.startTime ?? .distantPast)
        }
        var prevTurnEnd: Date?
        for turn in chronoTurns {
            if let prev = prevTurnEnd, let start = turn.startTime {
                if start.timeIntervalSince(prev) > coldCacheGapSeconds {
                    result.coldOkTurnIds.insert(turn.id)
                }
            } else {
                // First Turn in the session.
                result.coldOkTurnIds.insert(turn.id)
            }
            if let end = turn.endTime { prevTurnEnd = end }
        }
        // Same logic on the Step.timestamp axis.
        let chronoSteps = chronoTurns.flatMap { $0.steps }
            .sorted { $0.timestamp < $1.timestamp }
        var prevStepTime: Date?
        for step in chronoSteps {
            if let prev = prevStepTime {
                if step.timestamp.timeIntervalSince(prev) > coldCacheGapSeconds {
                    result.coldOkStepIds.insert(step.uuid)
                }
            } else {
                // First Step in the session.
                result.coldOkStepIds.insert(step.uuid)
            }
            prevStepTime = step.timestamp
        }
        return result
    }

    // MARK: - CR / CW / Cost cell rendering

    /// Shared right-aligned paragraph style for numeric columns
    /// (CR / CW / Cost).
    ///
    /// `cell.textField?.alignment = .right` only takes effect on the
    /// `stringValue` path. Once `attributedStringValue` is set, the
    /// `NSAttributedString`'s own `.paragraphStyle` wins, and missing
    /// it falls back to `NSParagraphStyle.default`'s `.natural`
    /// alignment (= `.left` in LTR) — which is why CR/CW/Cost values
    /// previously rendered flush-left despite the column setting.
    /// Every attributed helper includes this style in its attribute
    /// dict so right-alignment is locked into the value itself.
    private static let rightAlignedParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        return p
    }()

    /// Center-aligned paragraph style for attributed-string cells whose
    /// column uses center alignment (Model, TTL). Same rationale as
    /// `rightAlignedParagraph`: `textField.alignment` is ignored once
    /// `attributedStringValue` is set, so the alignment has to live in
    /// the attribute dict.
    private static let centerAlignedParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }()

    /// Cache-TTL attributed value. Picks between "5m" / "1h" based on
    /// which ephemeral bucket the Turn/Step wrote to.
    ///
    /// - both zero  → em-dash (quaternary).
    /// - 5m only    → "5m" in systemOrange (the premium-priced choice
    ///   to call out).
    /// - 1h only    → "1h" in labelColor (normal text).
    /// - both > 0   → "5m+1h" in systemOrange — the Turn mixed, so the
    ///   warning tint wins.
    private static func cacheTTLAttr(
        eph1h: Int,
        eph5m: Int,
        fontSize: CGFloat,
        weight: NSFont.Weight
    ) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        guard eph1h > 0 || eph5m > 0 else {
            return NSAttributedString(
                string: CostFormatter.emDash,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.quaternaryLabelColor,
                    .paragraphStyle: centerAlignedParagraph,
                ]
            )
        }
        let text: String
        let color: NSColor
        if eph5m > 0 && eph1h > 0 {
            text = "5m+1h"
            color = .systemOrange
        } else if eph5m > 0 {
            text = "5m"
            color = .systemOrange
        } else {
            text = "1h"
            color = .labelColor
        }
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: centerAlignedParagraph,
            ]
        )
    }

    /// Cache-Read attributed value.
    ///
    /// Rule 1 — outside the CW orange/red warning cases, CR and CW
    /// both use the same `labelColor` as the Tokens column. CR has no
    /// extra exceptions: em-dash if 0, otherwise plain white.
    private static func cacheReadAttr(_ cr: Int, fontSize: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        guard cr > 0 else {
            return NSAttributedString(
                string: CostFormatter.emDash,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.quaternaryLabelColor,
                    .paragraphStyle: rightAlignedParagraph,
                ]
            )
        }
        return NSAttributedString(
            string: CompactNumber.compact(cr),
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: rightAlignedParagraph,
            ]
        )
    }

    /// Cache-Write attributed value — three emphasis levels:
    ///   • `cw == 0`             → em-dash (quaternary).
    ///   • `cw ≤ 1_000`          → dim (rule 2).
    ///   • `cw ≥ 10_000 && cw·2 > cr` → cache-miss warning (rule 3):
    ///       - `coldOk == true`  → bright-orange bold (session first or > 1h gap).
    ///       - `coldOk == false` → bright-red bold (hot miss).
    ///   • otherwise              → `labelColor`.
    ///
    /// Priority: warning (rule 3) > dim (rule 2) > normal. The warning
    /// is checked first so a value ≥ 10k can't be hidden by the dim case.
    private static func cacheWriteAttr(
        _ cw: Int, cr: Int, coldOk: Bool,
        fontSize: CGFloat,
        weight: NSFont.Weight
    ) -> NSAttributedString {
        guard cw > 0 else {
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
            return NSAttributedString(
                string: CostFormatter.emDash,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.quaternaryLabelColor,
                    .paragraphStyle: rightAlignedParagraph,
                ]
            )
        }
        let tint: NSColor
        let finalWeight: NSFont.Weight
        // Integer-safe form of `cw > cr/2` is `cw*2 > cr`. Both cw and
        // cr stay well within Int64 range, so no overflow risk.
        if cw >= 10_000 && cw * 2 > cr {
            tint = coldOk ? .systemOrange : .systemRed
            finalWeight = .bold
        } else if cw <= 1_000 {
            tint = .tertiaryLabelColor
            finalWeight = weight
        } else {
            tint = .labelColor
            finalWeight = weight
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: finalWeight)
        return NSAttributedString(
            string: CompactNumber.compact(cw),
            attributes: [
                .font: font,
                .foregroundColor: tint,
                .paragraphStyle: rightAlignedParagraph,
            ]
        )
    }

    /// Cost attributed value — visual priority by amount (6.9 rework):
    ///   • `cost == 0`               → em-dash (quaternary, "no value").
    ///   • `cost ≤ 0.1`              → dim, easy to skip when scanning.
    ///   • `cost ≥ warningThreshold` → warning orange — the session's
    ///     outliers only (`costOutlierThresholdUSD`), so emphasis means
    ///     "unusual", not "expensive session".
    ///   • otherwise                  → `labelColor`. The old $1+ gold
    ///     step is gone: yellow read as a second warning tier and
    ///     painted most rows of any real session.
    private static func costAttr(
        _ cost: Double,
        confidence: CostConfidence = .exact,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        warningThreshold: Double = .infinity
    ) -> NSAttributedString {
        prefixedCostAttr(
            prefix: "",
            cost: cost,
            confidence: confidence,
            fontSize: fontSize,
            weight: weight,
            exactColor: nil,
            warningThreshold: warningThreshold
        )
    }

    private static func prefixedCostAttr(
        prefix: String,
        cost: Double,
        confidence: CostConfidence,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        exactColor: NSColor?,
        warningThreshold: Double = .infinity
    ) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        let display = CostColor.display(
            cost: cost,
            confidence: confidence,
            prefix: prefix,
            exactColor: exactColor,
            warningThreshold: warningThreshold
        )
        return NSAttributedString(
            string: display.text,
            attributes: [
                .font: font,
                .foregroundColor: display.color,
                .paragraphStyle: rightAlignedParagraph,
            ]
        )
    }

    // MARK: - Turn Model column helpers

    /// Attributed string for the Turn row's Model column.
    ///
    /// `TurnModelSummary.resolve` distills the Turn's mixed model usage
    /// into (primary, extras). We tint the **primary** portion in its
    /// family colour (Opus purple / Sonnet blue / Haiku teal) and add
    /// a subdued suffix when the Turn mixed models:
    ///   * 1 model:   `opus-4-7`
    ///   * 2 models:  `opus-4-7 · haiku-4-5`  (both tinted by family)
    ///   * 3+ models: `opus-4-7 +2` (+N in tertiary tint)
    ///
    /// Empty string for Turns without a resolvable model (e.g. a Turn
    /// made entirely of interrupted prompt rows before any assistant
    /// reply landed — edge case).
    /// Mode-aware model summary: under SQLite-first the resolve order
    /// is precomputed into the turns table (`agg_models`); legacy
    /// resolves from steps.
    private func displayModelSummary(for turn: Turn) -> TurnModelSummary.Resolved {
        if let aggregate = sqliteAggregates[turn.id] {
            return TurnModelSummary.Resolved(
                primary: aggregate.models.first,
                extras: Array(aggregate.models.dropFirst())
            )
        }
        return TurnModelSummary.resolve(for: turn)
    }

    private static func turnModelAttr(summary: TurnModelSummary.Resolved) -> NSAttributedString {
        guard let primary = summary.primary else {
            return NSAttributedString(string: "")
        }
        // Semibold (not medium): per HIG, 11pt "small text" requires
        // 4.5:1 contrast; 11pt semibold falls under the "large text"
        // 3:1 threshold, which is where systemPurple / systemBlue /
        // systemTeal comfortably land against sidebar / window
        // backgrounds in both light and dark mode. Xcode's Source
        // Editor syntax colour uses the same weight for the same
        // reason (macos-ux-designer WCAG review 2026-04-22).
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let primaryShort = ModelNameFormatter.short(primary)
        let primaryColor = ModelDisplay.color(for: primary)
        let result = NSMutableAttributedString(string: primaryShort, attributes: [
            .font: font,
            .foregroundColor: primaryColor,
            .paragraphStyle: centerAlignedParagraph,
        ])
        if !summary.extras.isEmpty {
            // Mixed-model Turn — render primary in family tint, everything
            // after it in `tertiaryLabelColor`. Tinting both primary and
            // the second extra (earlier design) collapsed into a single
            // colored run when both belonged to the same family (e.g.
            // Opus + Opus-preview), losing the "mixed" signal. Mail's
            // "From: A, B, C" convention — only the first name is bold —
            // is the model we mirror.
            let neutral: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: centerAlignedParagraph,
            ]
            if summary.extras.count == 1, let second = summary.extras.first {
                result.append(NSAttributedString(string: " · ", attributes: neutral))
                result.append(NSAttributedString(
                    string: ModelNameFormatter.short(second),
                    attributes: neutral
                ))
            } else {
                result.append(NSAttributedString(
                    string: " +\(summary.extras.count)",
                    attributes: neutral
                ))
            }
        }
        return result
    }

    /// Hover tooltip for the Turn Model column — surfaces the full list
    /// of models the Turn touched so power users can audit the mix
    /// without expanding the Turn.
    private static func turnModelTooltip(summary: TurnModelSummary.Resolved) -> String? {
        guard let primary = summary.primary else { return nil }
        if summary.extras.isEmpty {
            return primary
        }
        return "Primary: \(primary)\nAlso: \(summary.extras.joined(separator: ", "))"
    }

    /// VoiceOver label for the Turn Model column. Expands the short
    /// form so hyphens aren't read letter-by-letter.
    private static func turnModelAccessibility(summary: TurnModelSummary.Resolved) -> String {
        guard let primary = summary.primary else { return "No model" }
        let spoken = ModelDisplay.voiceOverLabel(short: ModelNameFormatter.short(primary))
        if summary.extras.isEmpty {
            return "Model: \(spoken)"
        }
        let others = summary.extras
            .map { ModelDisplay.voiceOverLabel(short: ModelNameFormatter.short($0)) }
            .joined(separator: ", ")
        return "Models: \(spoken), \(others)"
    }

    // MARK: - Sorting

    /// Sort turns by the current sort key / direction.
    ///
    /// `model` sorts by **tier order** (Opus → Sonnet → Haiku →
    /// Unknown), not alphabetically. Alphabetical would yield
    /// `haiku < opus < sonnet` — putting Sonnet between Haiku and Opus
    /// and burying the premium tier. Within a tier, the short name is
    /// compared alphabetically so versions of the same family stay
    /// adjacent.
    private func sortedTurns(_ turns: [Turn]) -> [Turn] {
        let asc = currentSortAscending
        switch currentSortKey {
        case .time:
            return turns.sorted { a, b in
                let ta = a.startTime ?? .distantPast
                let tb = b.startTime ?? .distantPast
                return asc ? ta < tb : ta > tb
            }
        case .model:
            return turns.sorted { a, b in
                let pa = displayModelSummary(for: a).primary
                let pb = displayModelSummary(for: b).primary
                let ta = ModelDisplay.tier(for: pa)
                let tb = ModelDisplay.tier(for: pb)
                if ta != tb {
                    return asc ? ta < tb : ta > tb
                }
                let sa = (pa.map(ModelNameFormatter.short) ?? "")
                let sb = (pb.map(ModelNameFormatter.short) ?? "")
                return asc ? sa.localizedCaseInsensitiveCompare(sb) == .orderedAscending
                           : sa.localizedCaseInsensitiveCompare(sb) == .orderedDescending
            }
        case .prompt:
            return turns.sorted { a, b in
                let pa = TurnPreview.make(for: a)
                let pb = TurnPreview.make(for: b)
                return asc ? pa.localizedCaseInsensitiveCompare(pb) == .orderedAscending
                           : pa.localizedCaseInsensitiveCompare(pb) == .orderedDescending
            }
        case .contextWindow:
            let displayed = Dictionary(
                turns.map { ($0.id, displayTokens(for: $0).contextWindow ?? 0) },
                uniquingKeysWith: { first, _ in first }
            )
            return turns.sorted { a, b in
                let ca = displayed[a.id] ?? 0
                let cb = displayed[b.id] ?? 0
                return asc ? ca < cb : ca > cb
            }
        case .tokens:
            // Memoize the rollup once per Turn — same anti-drift
            // motivation as the Cost comparator below: bare
            // `aggregateTokens` here while the cell shows the rollup
            // would silently break "click the column to sort by what
            // I see". `uniquingKeysWith:` keeps the first sighting on
            // a hypothetical `turn.id` collision instead of trapping.
            let displayed = Dictionary(
                turns.map { ($0.id, displayTokens(for: $0).effectiveTokens) },
                uniquingKeysWith: { first, _ in first }
            )
            return turns.sorted { a, b in
                let ta = displayed[a.id] ?? 0
                let tb = displayed[b.id] ?? 0
                return asc ? ta < tb : ta > tb
            }
        case .cacheRead:
            let displayed = Dictionary(
                turns.map { ($0.id, displayTokens(for: $0).cacheReadInputTokens) },
                uniquingKeysWith: { first, _ in first }
            )
            return turns.sorted { a, b in
                let ca = displayed[a.id] ?? 0
                let cb = displayed[b.id] ?? 0
                return asc ? ca < cb : ca > cb
            }
        case .cacheWrite:
            let displayed = Dictionary(
                turns.map { ($0.id, displayTokens(for: $0).cacheCreationInputTokens) },
                uniquingKeysWith: { first, _ in first }
            )
            return turns.sorted { a, b in
                let ca = displayed[a.id] ?? 0
                let cb = displayed[b.id] ?? 0
                return asc ? ca < cb : ca > cb
            }
        case .reasoning:
            let displayed = Dictionary(
                turns.map { ($0.id, displayTokens(for: $0).reasoningOutputTokens) },
                uniquingKeysWith: { first, _ in first }
            )
            return turns.sorted { a, b in
                let ra = displayed[a.id] ?? 0
                let rb = displayed[b.id] ?? 0
                return asc ? ra < rb : ra > rb
            }
        case .cost:
            // Memoize the rollup once per Turn so the comparator is
            // O(1) instead of O(steps × links_per_step) inside an
            // O(n log n) sort. The displayed cell value uses the
            // same `aggregateCostIncludingSubAgents(...)` path —
            // sorting on bare `aggregateCost` here while the cell
            // shows the rollup would silently break the user's
            // mental model of "click the column to sort by what I
            // see".
            // Use `uniquingKeysWith:` rather than `uniqueKeysWithValues:`
            // — `turn.id` should be unique per session per
            // ConversationAssembler invariants, but trapping inside a
            // sort comparator on a hypothetical drift would crash the
            // UI. Defensive: keep the first sighting on collision.
            let displayed = Dictionary(
                turns.map { ($0.id, displayCost(for: $0).totalCostUSD) },
                uniquingKeysWith: { first, _ in first }
            )
            return turns.sorted { a, b in
                let ca = displayed[a.id] ?? 0
                let cb = displayed[b.id] ?? 0
                return asc ? ca < cb : ca > cb
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if isApplyingColumnState { return }
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key,
              let sortKey = SortKey(rawValue: key) else { return }
        currentSortKey = sortKey
        currentSortAscending = descriptor.ascending
        let provider = store.activeProvider
        columnStateDefaults.set(sortKey.rawValue, forKey: Self.sortKeyDefaultsKey(for: provider))
        columnStateDefaults.set(descriptor.ascending, forKey: Self.sortAscendingDefaultsKey(for: provider))
        if let sessionId = currentSessionId {
            // A sort change is not a data change, but it still needs a
            // forced reload — invalidate the snapshot.
            lastTurnsSnapshot = []
            reloadTurns(for: sessionId, preserveSelection: true)
        }
    }

    // MARK: - Slash command highlighting

    /// Slash-command highlight for Step rows. In "/skill args" only the
    /// command portion gets monospace cyan; non-slash text falls back
    /// to plain.
    private static func slashHighlighted(
        _ text: String,
        plain: (String) -> NSAttributedString,
        muted: (String) -> NSAttributedString
    ) -> NSAttributedString {
        guard text.hasPrefix("/") else { return plain(text) }
        let cmdAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.systemCyan
        ]
        if let spaceIdx = text.firstIndex(of: " ") {
            let cmd = String(text[..<spaceIdx])
            let args = String(text[spaceIdx...])
            let result = NSMutableAttributedString()
            result.append(NSAttributedString(string: cmd, attributes: cmdAttrs))
            result.append(muted(args))
            return result
        }
        return NSAttributedString(string: text, attributes: cmdAttrs)
    }

    /// Slash-command highlight for Turn headers. 13pt semibold plus a
    /// monospace cyan command portion. Returns `nil` when the text is
    /// not a slash command so the caller can fall back to another
    /// attributed builder.
    private static func slashHighlightedHeader(_ text: String, font: NSFont) -> NSAttributedString? {
        guard text.hasPrefix("/") else { return nil }
        let cmdAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold),
            .foregroundColor: NSColor.systemCyan
        ]
        if let spaceIdx = text.firstIndex(of: " ") {
            let cmd = String(text[..<spaceIdx])
            let args = String(text[spaceIdx...])
            let result = NSMutableAttributedString()
            result.append(NSAttributedString(string: cmd, attributes: cmdAttrs))
            result.append(NSAttributedString(string: args, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            return result
        }
        return NSAttributedString(string: text, attributes: cmdAttrs)
    }

    /// Turn header cell — text only, left-aligned, 4pt leading. Text
    /// sits right next to the disclosure triangle to mimic the Mail /
    /// Xcode style.
    private func makeOrReuseTurnHeaderCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            reused.textField.map(TurnOutlineCellTextLayout.applySingleLineBehavior)
            return reused
        }
        let tf = NSTextField(labelWithString: "")
        // `NSTextField(labelWithString:)` defaults to `usesSingleLineMode =
        // false` — a multi-line label. On fixed-height outline rows that
        // means a long prompt wraps and the intrinsic content height grows
        // past the row, bleeding the next row's area (observed: Korean
        // step prompts spanning 2–3 rows, overlapping the following
        // toolCall rows). `maximumNumberOfLines = 1` + `byTruncatingTail`
        // alone are not enough; `usesSingleLineMode = true` is the
        // authoritative switch that also flips `cell.wraps = false`.
        TurnOutlineCellTextLayout.applySingleLineBehavior(to: tf)
        tf.translatesAutoresizingMaskIntoConstraints = false

        let cv = NSTableCellView()
        cv.identifier = id
        cv.textField = tf
        cv.addSubview(tf)
        NSLayoutConstraint.activate([
            // 4pt — matches the icon cells. The "header feels cramped"
            // feedback (6.9) turned out to be the missing table-level
            // LEADING gutter (rows started flush against the split
            // divider), not the disclosure-to-text gap; see
            // `tableLeadingGutter`. A first attempt widened this to
            // 10pt and was rolled back.
            tf.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
        ] + TurnOutlineCellTextLayout.verticalBoundsConstraints(for: tf, in: cv))
        return cv
    }

    /// Text-only cell used by the numeric columns.
    private func makeOrReuseTextCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            reused.textField.map(TurnOutlineCellTextLayout.applySingleLineBehavior)
            return reused
        }
        let tf = NSTextField(labelWithString: "")
        // See `makeOrReuseTurnHeaderCell` for why this is needed — numeric
        // cells rarely break, but Time column em-dash fallback and similar
        // edge cases still benefit from guaranteed single-line rendering.
        TurnOutlineCellTextLayout.applySingleLineBehavior(to: tf)
        tf.translatesAutoresizingMaskIntoConstraints = false

        let cv = NSTableCellView()
        cv.identifier = id
        cv.textField = tf
        cv.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
            tf.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
        ] + TurnOutlineCellTextLayout.verticalBoundsConstraints(for: tf, in: cv))
        return cv
    }

    /// Icon + text cell used by the Prompt column.
    /// - Parameter iconLeading: leading inset for the icon. Nested cells
    ///   (`toolResult`) use a deeper indent so toolCall → toolResult
    ///   pairs read as a visual group.
    private func makeOrReuseIconCell(
        id: NSUserInterfaceItemIdentifier,
        iconLeading: CGFloat = 4
    ) -> NSTableCellView {
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            reused.textField.map(TurnOutlineCellTextLayout.applySingleLineBehavior)
            return reused
        }
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown

        let tf = NSTextField(labelWithString: "")
        // See `makeOrReuseTurnHeaderCell` — this is the primary site where
        // wrapping used to occur (long Step `.prompt` rows with Korean +
        // CJK content). `usesSingleLineMode = true` guarantees
        // `byTruncatingTail` wins over the default multi-line behaviour.
        TurnOutlineCellTextLayout.applySingleLineBehavior(to: tf)
        tf.translatesAutoresizingMaskIntoConstraints = false

        let cv = NSTableCellView()
        cv.identifier = id
        cv.imageView = iv
        cv.textField = tf
        cv.addSubview(iv)
        cv.addSubview(tf)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: iconLeading),
            iv.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),

            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
            tf.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
        ] + TurnOutlineCellTextLayout.verticalBoundsConstraints(for: tf, in: cv))
        return cv
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TurnOutlineNode else { return }
        if let turn = node.turn {
            expandedTurnIds.insert(turn.id)
        } else if let group = node.skillGroup {
            expandedSkillGroupIds.insert(group.id)
        } else if case .subAgent = node.kind {
            expandedSubAgentKeys.insert(node.identityKey)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TurnOutlineNode else { return }
        if let turn = node.turn {
            expandedTurnIds.remove(turn.id)
        } else if let group = node.skillGroup {
            expandedSkillGroupIds.remove(group.id)
        } else if case .subAgent = node.kind {
            expandedSubAgentKeys.remove(node.identityKey)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if isProgrammaticSelectionChange { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TurnOutlineNode else {
            if let currentSessionId {
                selectedIdentityKeyBySessionId.removeValue(forKey: currentSessionId)
            }
            onSelectionCleared?()
            return
        }
        if let currentSessionId {
            selectedIdentityKeyBySessionId[currentSessionId] = node.identityKey
        }
        notifySelection(for: node)
    }

    private func notifySelection(for node: TurnOutlineNode) {
        switch node.kind {
        case .step(let step, let parentTurnId):
            // Q1: on Step click, pass the whole owning Turn to the detail (the
            // builder highlights that Step). In a SQLite-first setup the Turn
            // may be a stub, so materialize it; if not found, fall back to a
            // single-Step Turn of just that Step.
            let parent = turns.first { $0.id == parentTurnId }
            let resolved = parent.map { materializedTurn(for: $0) }
                ?? Turn(id: parentTurnId, sessionId: step.sessionId, steps: [step], isInterrupted: false)
            onStepSelected?(step, resolved)
        case .turn(let turn):
            // Turn header row clicked — show Turn-level summary in the
            // detail pane. SQLite-first materializes on demand so the
            // pane never receives a header stub.
            let resolved = materializedTurn(for: turn)
            onTurnSelected?(resolved, displayCost(for: resolved), displayTokens(for: resolved))
        case .skillGroup(let group, _, _):
            onSkillGroupSelected?(group, displayCost(for: group), displayTokens(for: group))
        case .subAgent(_, let turn, _, _):
            // Sub-agent header click → route to the sub-agent's own
            // Turn summary (aggregated tokens/cost). Distinct from the
            // parent Turn so the detail pane shows the child's metrics.
            // Sub-agent rows are leaves in the 1-level rollup contract,
            // so bare `aggregateCost` / `aggregateTokens` are correct here.
            if isSQLiteConversation {
                let steps = materializedSubAgentSteps(for: node) ?? turn.steps
                let resolved = Turn(
                    id: turn.id, sessionId: turn.sessionId,
                    steps: steps, isInterrupted: turn.isInterrupted
                )
                let aggregate = sqliteAggregates[turn.id]
                onTurnSelected?(
                    resolved,
                    aggregate?.cost ?? resolved.aggregateCost,
                    aggregate?.tokens ?? resolved.aggregateTokens
                )
            } else {
                onTurnSelected?(turn, turn.aggregateCost, turn.aggregateTokens)
            }
        }
    }

    /// Same value the outline header cell renders for this Turn —
    /// `aggregateCost` plus any sub-agent Turns this Turn spawned.
    /// Used at click time (passed to the detail pane), by the sort
    /// comparator on the Cost column, AND by the cell renderer —
    /// single source of "what we display" so a future tweak doesn't
    /// drift the three sites apart.
    private func displayCost(for turn: Turn) -> CostBreakdown {
        // SQLite-first: the aggregate columns already include subagent
        // contributions (TurnAggregateColumns) — never sum stub steps.
        if let aggregate = sqliteAggregates[turn.id] { return aggregate.cost }
        return turn.aggregateCostIncludingSubAgents(
            linksByStepUuid: subAgentLinksByStepUuid,
            subAgentTurnsByAgentId: subAgentTurnsByAgentId
        )
    }

    /// Same as `displayCost(for:)` but for a SkillGroup row — rolls
    /// in any sub-agents the group's interior steps spawned (the
    /// `/wiki-ingest` 6-parallel-dispatch screenshot scenario).
    private func displayCost(for group: SkillGroupBuilder.SkillGroup) -> CostBreakdown {
        // SQLite-first: the in-memory sub-agent Turns are stubs whose
        // `aggregateCost` is 0, so roll up their SQL header aggregates by
        // agentId instead — the same source the sub-agent rows render, so
        // the skill header and its children no longer disagree.
        if isSQLiteConversation {
            return group.aggregateCostIncludingSubAgents(
                linksByStepUuid: subAgentLinksByStepUuid,
                subAgentCostByAgentId: sqliteSubAgentCostByAgentId
            )
        }
        return group.aggregateCostIncludingSubAgents(
            linksByStepUuid: subAgentLinksByStepUuid,
            subAgentTurnsByAgentId: subAgentTurnsByAgentId
        )
    }

    /// Sub-agent cost keyed by agentId, sourced from the SQL header
    /// aggregates (non-stub) — what the skill-group rollup needs under
    /// SQLite-first. Falls back to the Turn's own cost when no aggregate
    /// exists (fully-materialized / legacy).
    private var sqliteSubAgentCostByAgentId: [String: CostBreakdown] {
        var map: [String: CostBreakdown] = [:]
        for (agentId, subTurn) in subAgentTurnsByAgentId {
            map[agentId] = sqliteAggregates[subTurn.id]?.cost ?? subTurn.aggregateCost
        }
        return map
    }

    /// Token twin of `sqliteSubAgentCostByAgentId`.
    private var sqliteSubAgentTokensByAgentId: [String: TokenBreakdown] {
        var map: [String: TokenBreakdown] = [:]
        for (agentId, subTurn) in subAgentTurnsByAgentId {
            map[agentId] = sqliteAggregates[subTurn.id]?.tokens ?? subTurn.aggregateTokens
        }
        return map
    }

    private func costConfidence(for turn: Turn) -> CostConfidence {
        // Unmaterialized SQLite stub: steps aren't loaded, so the
        // per-step confidence walk has nothing to read. Default to
        // exact (non-codex is always exact; codex refines on expand —
        // recorded 4.1 degradation).
        if isSQLiteConversation, !materializedTurnIds.contains(turn.id) {
            return .exact
        }
        let resolved = isSQLiteConversation
            ? (turns.first { $0.id == turn.id } ?? turn)
            : turn
        return CostConfidence.evaluate(
            provider: store.activeProvider,
            steps: displayedSteps(for: resolved)
        )
    }

    private func costConfidence(for group: SkillGroupBuilder.SkillGroup) -> CostConfidence {
        CostConfidence.evaluate(
            provider: store.activeProvider,
            steps: displayedSteps(for: group)
        )
    }

    private func displayedSteps(for turn: Turn) -> [Step] {
        stepsIncludingSpawnedSubAgents(from: turn.steps)
    }

    private func displayedSteps(for group: SkillGroupBuilder.SkillGroup) -> [Step] {
        stepsIncludingSpawnedSubAgents(from: group.steps)
    }

    private func stepsIncludingSpawnedSubAgents(from base: [Step]) -> [Step] {
        var result = base
        for step in base {
            for link in subAgentLinksByStepUuid[step.uuid] ?? [] {
                if let subTurn = subAgentTurnsByAgentId[link.agentId] {
                    result.append(contentsOf: subTurn.steps)
                }
            }
        }
        return result
    }

    private func costTooltip(confidence: CostConfidence) -> String? {
        CostConfidencePresentation.outlineTooltip(provider: store.activeProvider, confidence: confidence)
    }

    /// Token-twin of `displayCost(for: Turn)` — same value the outline
    /// header cells render for tokens / cacheRead / cacheWrite /
    /// cacheTTL on this Turn (`aggregateTokens` plus any sub-agent
    /// Turns this Turn spawned). Used at click time, by the sort
    /// comparators on those columns, AND by the cell renderers — single
    /// source of "what we display" so a future tweak doesn't drift the
    /// sites apart.
    private func displayTokens(for turn: Turn) -> TokenBreakdown {
        // SQLite-first: see displayCost(for:) — sidecar wins.
        if let aggregate = sqliteAggregates[turn.id] { return aggregate.tokens }
        return turn.aggregateTokensIncludingSubAgents(
            linksByStepUuid: subAgentLinksByStepUuid,
            subAgentTurnsByAgentId: subAgentTurnsByAgentId
        )
    }

    /// Same as `displayTokens(for: Turn)` but for a SkillGroup row.
    private func displayTokens(for group: SkillGroupBuilder.SkillGroup) -> TokenBreakdown {
        // SQLite-first: roll up sub-agent SQL aggregates by agentId (stub
        // Turns carry zero) — keeps tokens / CR / CW / TTL on the skill
        // header consistent with the sub-agent rows. See displayCost(for:).
        if isSQLiteConversation {
            return group.aggregateTokensIncludingSubAgents(
                linksByStepUuid: subAgentLinksByStepUuid,
                subAgentTokensByAgentId: sqliteSubAgentTokensByAgentId
            )
        }
        return group.aggregateTokensIncludingSubAgents(
            linksByStepUuid: subAgentLinksByStepUuid,
            subAgentTurnsByAgentId: subAgentTurnsByAgentId
        )
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? TurnOutlineNode else { return 28 }
        switch node.kind {
        case .turn: return 34        // Turn header — more prominent
        case .skillGroup: return 26  // Between Turn and Step — visibly a subheader
        case .step: return 22        // Step row — denser
        case .subAgent: return 26    // Same weight as a skillGroup header
        }
    }

    /// Pick the row view variant per node kind.
    ///
    /// **No indent guides (final decision 2026-04-24)**: After many
    /// iterations on leading accent bars and indent guides, the cleanest
    /// result is to not draw any group-membership indicator at all —
    /// disclosure triangles + 16pt per-level indentation + the typography
    /// hierarchy (prompt semibold + others secondary) already carry the
    /// "belongs to the Turn" signal. This matches Mail / Finder / Xcode
    /// Project Navigator (all of which omit tree indent guides).
    ///
    /// - `.turn` / `.step` → `nil` (default NSTableRowView)
    /// - `.skillGroup` / `.subAgent` → `SkillGroupRowView` — cyan container
    ///   tint is a semantically distinct signal (skill/subagent grouping,
    ///   not Turn boundary) so it stays.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? TurnOutlineNode else { return nil }
        switch node.kind {
        case .turn, .step:
            // Always return a `LupenAnimatedRowView` so the appearance
            // animation has a layer-backed canvas to draw on. The
            // overlay sublayer is created lazily on the first
            // animation request, so non-animating rows still pay only
            // a single empty NSTableRowView's cost.
            let row = LupenAnimatedRowView()
            if let trigger = appearanceCoordinator.consume(id: node.identityKey) {
                // Step rows get the weaker `streamingAppear` tint
                // because they arrive at high frequency during live
                // assistant output; Turn rows get the stronger
                // `appear` tint because they're rarer and signal a
                // larger event (a new user prompt landed).
                let isStreamingChild: Bool = {
                    if case .step = node.kind { return true }
                    return false
                }()
                let style = LupenAnimatedRowView.Style.from(
                    trigger: trigger,
                    isStreamingChild: isStreamingChild
                )
                row.scheduleAppearanceAnimation(style: style, syncStart: trigger.syncStart)
            }
            return row
        case .skillGroup, .subAgent:
            return SkillGroupRowView()
        }
    }

    // MARK: - Query highlight

    /// Apply a new highlight query. Called by the split VC's bridge
    /// closure whenever the sidebar's search field commits a debounced
    /// value. Empty string = clear all highlights.
    func setHighlightQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != highlightQuery else { return }
        highlightQuery = trimmed
        rebuildMatchIndices()
        refreshHighlightedCells()
    }

    /// Rebuild `matchedTurnIndices` from the current `turns` array
    /// and `highlightQuery`. Called on query change and after
    /// `reloadTurns` rebuilds the Turn list.
    private func rebuildMatchIndices() {
        currentMatchIndex = nil
        guard !highlightQuery.isEmpty else {
            matchedTurnIndices = []
            return
        }
        matchedTurnIndices = turns.indices.filter {
            TurnQueryMatcher.turnMatches(turns[$0], query: highlightQuery)
        }
    }

    // MARK: - ⌘G / ⇧⌘G match navigation

    /// Jump to the next matching Turn (⌘G). Wraps around from the
    /// last match to the first. Beeps if there are no matches.
    @objc func navigateToNextMatch(_ sender: Any?) {
        guard !matchedTurnIndices.isEmpty else { NSSound.beep(); return }
        if let cur = currentMatchIndex {
            currentMatchIndex = (cur + 1) % matchedTurnIndices.count
        } else {
            currentMatchIndex = 0
        }
        scrollToCurrentMatch()
    }

    /// Jump to the previous matching Turn (⇧⌘G). Wraps around from
    /// the first match to the last.
    @objc func navigateToPreviousMatch(_ sender: Any?) {
        guard !matchedTurnIndices.isEmpty else { NSSound.beep(); return }
        if let cur = currentMatchIndex {
            currentMatchIndex = (cur - 1 + matchedTurnIndices.count) % matchedTurnIndices.count
        } else {
            currentMatchIndex = matchedTurnIndices.count - 1
        }
        scrollToCurrentMatch()
    }

    private func scrollToCurrentMatch() {
        guard let idx = currentMatchIndex,
              idx < matchedTurnIndices.count else { return }
        let turnIndex = matchedTurnIndices[idx]
        guard turnIndex < turns.count else { return }
        let turn = turns[turnIndex]
        let key = "\(turn.sessionId):\(turn.id)"
        guard let node = turnNodes[key] else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        isProgrammaticSelectionChange = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isProgrammaticSelectionChange = false
        outlineView.scrollRowToVisible(row)
        onTurnSelected?(turn, displayCost(for: turn), displayTokens(for: turn))
    }

    /// Re-render the Conversation (prompt) column for all visible
    /// rows so `QueryHighlighter.applied(to:query:)` picks up the
    /// latest `highlightQuery`. Off-screen rows get a fresh
    /// `viewFor:tableColumn:item:` when they scroll into view, which
    /// reads `highlightQuery` at that time.
    ///
    /// Only the prompt column is reloaded — cost/token/time cells
    /// don't carry text highlights and don't need a redraw.
    private func refreshHighlightedCells() {
        let promptColIndex = outlineView.column(withIdentifier: Col.prompt.id)
        guard promptColIndex >= 0 else { return }
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.length > 0 else { return }
        outlineView.reloadData(
            forRowIndexes: IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)),
            columnIndexes: IndexSet(integer: promptColIndex)
        )
    }

    // MARK: - Pill cell (skillGroup numeric columns)

    /// Pill-style badge cell used by skillGroup Tokens / CR / CW / Cost
    /// columns. A rounded cyan fill around the value + bold cyan text
    /// communicates "this is an aggregate estimate, not a single step's
    /// metric." The caller sets `textField.stringValue` with the `≈`
    /// prefix already applied.
    ///
    /// The pill hugs the trailing edge of the cell (like the plain text
    /// cell) so skillGroup numeric columns line up with step/Turn rows.
    private func makeOrReusePillCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            reused.textField.map(TurnOutlineCellTextLayout.applySingleLineBehavior)
            return reused
        }
        // PillBackgroundView overrides `updateLayer()` so its backing CGColor
        // is re-resolved whenever effective appearance changes — avoids the
        // classic "dark-mode cyan frozen on a light-mode window" pitfall
        // that bites anyone setting layer.backgroundColor once from a
        // dynamic NSColor.
        let pill = PillBackgroundView()
        pill.translatesAutoresizingMaskIntoConstraints = false

        let tf = NSTextField(labelWithString: "")
        // Pill cells are always short (≈$1.23 etc.), so wrapping is
        // unlikely — but keep behaviour consistent with the other
        // cell factories so a future wider pill variant doesn't
        // regress silently.
        TurnOutlineCellTextLayout.applySingleLineBehavior(to: tf)
        tf.alignment = .right
        tf.drawsBackground = false
        tf.translatesAutoresizingMaskIntoConstraints = false

        let cv = NSTableCellView()
        cv.identifier = id
        cv.textField = tf
        pill.addSubview(tf)
        cv.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -4),
            pill.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 16),
            // Let the pill size to its content via the text field.
            pill.leadingAnchor.constraint(
                lessThanOrEqualTo: tf.leadingAnchor, constant: -7
            ),
            tf.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            tf.leadingAnchor.constraint(greaterThanOrEqualTo: pill.leadingAnchor, constant: 7),
            tf.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return cv
    }
}

#if DEBUG
extension TurnOutlineViewController {
    @discardableResult
    func selectIdentityForTesting(_ key: String) -> Bool {
        guard let currentSessionId,
              let row = rowForIdentityKey(key),
              let node = outlineView.item(atRow: row) as? TurnOutlineNode else {
            return false
        }
        isProgrammaticSelectionChange = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isProgrammaticSelectionChange = false
        selectedIdentityKeyBySessionId[currentSessionId] = node.identityKey
        notifySelection(for: node)
        return true
    }

    func selectedIdentityKeyForTesting(sessionId: String) -> String? {
        selectedIdentityKeyBySessionId[sessionId]
    }

    func setSelectedIdentityKeyForTesting(_ key: String, sessionId: String) {
        selectedIdentityKeyBySessionId[sessionId] = key
    }

    func currentlySelectedIdentityKeyForTesting() -> String? {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? TurnOutlineNode else {
            return nil
        }
        return node.identityKey
    }

    /// Whether a row with this identity key is currently realized in
    /// the outline (6.3 — lets the refresh-tick test prove a re-render
    /// actually happened before asserting selection survival).
    func hasRowForIdentityForTesting(_ key: String) -> Bool {
        rowForIdentityKey(key) != nil
    }

    /// Which of the three mutually-exclusive surfaces is showing (6.5
    /// overlay-policy pins).
    func stateSurfacesForTesting() -> (outline: Bool, empty: Bool, overlay: Bool) {
        (!scrollView.isHidden, !emptyStateView.isHidden, !launchProgressContainer.isHidden)
    }

    /// Rendered tokens/cost cell text for a sub-agent container row —
    /// pins that the cells read the sidecar aggregates, not the stub
    /// Turn payload (6.7: every container rendered "Σ 0" / "Σ —").
    func subAgentMetricCellTextsForTesting(identityKey: String) -> (tokens: String, cost: String, model: String)? {
        guard let row = rowForIdentityKey(identityKey) else { return nil }
        func cellText(_ col: Col) -> String? {
            guard let index = outlineView.tableColumns.firstIndex(where: { $0.identifier == col.id }),
                  let cell = outlineView.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField
            else { return nil }
            return field.stringValue.isEmpty ? field.attributedStringValue.string : field.stringValue
        }
        guard let tokens = cellText(.tokens), let cost = cellText(.cost),
              let model = cellText(.model)
        else { return nil }
        return (tokens, cost, model)
    }

    func emptyStateTitleForTesting() -> String {
        emptyTitleLabel.stringValue
    }

    func emptyStateSubtitleForTesting() -> String {
        emptySubtitleLabel.stringValue
    }

    static func costColorForTesting(
        cost: Double,
        confidence: CostConfidence = .exact,
        exactColor: NSColor? = nil,
        warningThreshold: Double = .infinity
    ) -> NSColor? {
        prefixedCostAttr(
            prefix: "",
            cost: cost,
            confidence: confidence,
            fontSize: 12,
            weight: .regular,
            exactColor: exactColor,
            warningThreshold: warningThreshold
        ).attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    /// 6.9: session-relative outlier bar, exposed for pinning the
    /// 2×mean / $1-floor / empty-∞ rule without a full reload cycle.
    func costOutlierThresholdForTesting() -> Double {
        costOutlierThresholdUSD
    }

    func refreshProviderColumnsForTesting() {
        applyProviderColumnConfiguration()
    }

    func visibleColumnIdentifiersForTesting() -> [String] {
        outlineView.tableColumns
            .filter { !$0.isHidden }
            .map { $0.identifier.rawValue }
    }

    func columnWidthForTesting(_ identifier: String) -> CGFloat? {
        outlineView.tableColumn(withIdentifier: .init(identifier))?.width
    }

    func currentSortForTesting() -> (key: String, ascending: Bool) {
        (currentSortKey.rawValue, currentSortAscending)
    }

    @discardableResult
    func setSortForTesting(_ identifier: String, ascending: Bool) -> Bool {
        guard let sortKey = SortKey(rawValue: identifier) else {
            return false
        }
        outlineView.sortDescriptors = [
            NSSortDescriptor(key: sortKey.rawValue, ascending: ascending)
        ]
        outlineView(outlineView, sortDescriptorsDidChange: [])
        return true
    }

    @discardableResult
    func moveVisibleColumnForTesting(_ identifier: String, toVisibleIndex targetVisibleIndex: Int) -> Bool {
        let visibleColumns = outlineView.tableColumns.filter { !$0.isHidden }
        guard targetVisibleIndex >= 0,
              targetVisibleIndex < visibleColumns.count,
              let currentIndex = outlineView.tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }) else {
            return false
        }
        let targetIdentifier = visibleColumns[targetVisibleIndex].identifier
        guard let targetIndex = outlineView.tableColumns.firstIndex(where: { $0.identifier == targetIdentifier }) else {
            return false
        }
        if currentIndex != targetIndex {
            outlineView.moveColumn(currentIndex, toColumn: targetIndex)
        }
        flushColumnState()
        return true
    }

    @discardableResult
    func setColumnWidthForTesting(_ identifier: String, width: CGFloat) -> Bool {
        guard let column = outlineView.tableColumn(withIdentifier: .init(identifier)) else {
            return false
        }
        column.width = width
        flushColumnState()
        return true
    }
}
#endif

// MARK: - TurnAccentRowView

/// Base row view that paints a 2pt vertical accent bar at the leading edge
/// of every row inside the outline, signalling "this row belongs to a
/// Turn's conversation group."
///
/// Two styles exist:
/// - `.turn` — the Turn row itself, rendered with a stronger accent so the
///   Turn header is the scan anchor.
/// - `.descendant` — every Step / SkillGroup / SubAgent row *inside* that
///   Turn, rendered with a subtler accent so they read as members of the
///   same group without shouting over the Turn header.
///
/// The bar is redrawn in `drawSelection` too, so it remains visible when
/// the row is selected or highlighted.
///
/// Leading offset (`barX = 12`) places the bar inside the first column's
/// disclosure-triangle gutter — it doesn't overlap prompt / icon content.
// MARK: - SkillGroupRowView

/// Row view for SkillGroup / SubAgent rows — paints a subtle `systemCyan`
/// tint across the full row so these "container headers" are distinct
/// from ordinary steps. This is a semantically distinct signal from
/// ordinary hierarchy (skill/subagent grouping, not Turn boundary) so
/// the cyan tint stays even after the Turn-descendant indent guide
/// experiments were removed.
private final class SkillGroupRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        NSColor.systemCyan.withAlphaComponent(0.10).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
        NSColor.systemCyan.withAlphaComponent(0.10).setFill()
        bounds.fill()
    }
}

// MARK: - PillBackgroundView

/// Rounded cyan pill used behind aggregate values on skillGroup rows.
///
/// Unlike a plain NSView with `layer.backgroundColor = dynamicColor.cgColor`,
/// this view overrides `updateLayer()` so the backing CGColor is resolved
/// from `NSColor.systemCyan` every time the effective appearance changes —
/// dark ↔ light mode swaps keep the pill visually consistent with
/// `SkillGroupRowView`'s `drawBackground`, which re-resolves its color on
/// every draw pass.
///
/// AppKit auto-invalidates layer-backed views and calls `updateLayer()`
/// when `viewDidChangeEffectiveAppearance()` fires, so no explicit
/// observation is needed as long as `wantsLayer` and `wantsUpdateLayer`
/// are both true.
private final class PillBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `wantsLayer = true` makes AppKit back the view with a CALayer.
        // Layer mutations happen in `updateLayer()` — setting properties
        // directly in init is unreliable because the layer may not exist
        // until first display.
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Re-applied on every appearance change, so systemCyan resolves
        // against the current effectiveAppearance each time.
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.systemCyan
            .withAlphaComponent(0.18)
            .cgColor
    }
}
