import AppKit

/// Right bottom pane: detail view with 3 tabs (Tokens, Conversation, Raw).
/// Uses NSSegmentedControl for tab switching.
@MainActor
/// Stable identity of the detail pane's current selection (plan 4.2).
/// Keys the skip-rerender check and guards the lazily-loaded Raw/Usage
/// tabs against configuring a stale selection.
enum DetailSelectionID: Equatable {
    case request(id: String)
    case step(sessionId: String, uuid: String)
    case turn(sessionId: String, turnId: String)
    case skillGroup(sessionId: String, groupId: String)
}

final class DetailViewController: NSViewController {

    private let store: AppStateStore
    private let segmentedControl = NSSegmentedControl()
    private let containerView = NSView()
    /// Thin hairline separator drawn between the segmented control row
    /// and the tab content. Without it the floating tab bar blurred
    /// into the content area; the separator gives the detail pane a
    /// proper "titled" chrome like Mail's inspector.
    private let headerSeparator = NSBox()

    // Empty state
    private let emptyStateView = NSView()
    private let emptyImageView = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "")
    private let emptySubtitleLabel = NSTextField(labelWithString: "")

    private let tokensView: TokensDetailView
    private let conversationView: ConversationDetailView
    private let attachmentsView: AttachmentsDetailView
    private let rawView: RawDetailView
    private let usageView: UsageDetailView
    private let finderButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    /// Xcode-style "toggle bottom pane" button. Visually indicates
    /// the detail pane's collapse state (filled glyph = visible,
    /// outline = hidden). Action delegated to the split-view owner
    /// via `onTogglePaneRequested`; the VC doesn't know its own
    /// split-item since collapse state lives on the container.
    private let togglePaneButton = NSButton()
    /// Vertical hairline that visually groups the toggle button with
    /// the reveal-in-Finder button — Xcode's status-bar pattern of a
    /// `|` between adjacent header controls. Without it the toggle
    /// floats alone in the corner; with it the trailing two controls
    /// read as a single "actions" cluster.
    private let togglePaneSeparator = NSBox()

    /// Transparent strip in the header row's empty background area
    /// between the segmented control and the trailing control cluster
    /// (Reveal-in-Finder + separator + toggle). Hover shows the
    /// resize-up-down cursor; drag adjusts the detail pane's height.
    ///
    /// **Why a frame-bounded strip instead of a whole-header overlay
    /// with hit-test tricks** — `addCursorRect` is frame-based, and
    /// AppKit's cursor manager doesn't reliably defer to z-order
    /// when a sibling view at lower z-order has a cursor rect that
    /// overlaps an upper sibling's frame. Constraining this view's
    /// frame to the empty strip means the resize cursor is only
    /// applied where it should be — outside the strip there's no
    /// cursor rect at all, so AppKit falls back to the system arrow
    /// over the buttons. This is the same pattern NSSplitView uses
    /// for its dividers.
    private let headerResizeHandle = DetailHeaderResizeHandleView()

    /// Right-aligned cluster that holds the trailing header controls
    /// (Reveal-in-Finder + vertical separator + toggle) as a single
    /// `NSStackView`. Two reasons:
    ///   1. Lets the resize handle anchor its trailing edge to a
    ///      single, stable view (`trailingClusterStack.leadingAnchor`)
    ///      rather than juggling priorities for the leftmost visible
    ///      control across `finderButton.isHidden` flips. NSStackView
    ///      collapses hidden arranged subviews to zero width
    ///      automatically, so the cluster's leading edge tracks the
    ///      effective leftmost visible control with no extra wiring.
    ///   2. Centralizes the trailing-actions group's spacing so the
    ///      8pt gaps between Reveal / separator / toggle live in one
    ///      place.
    private let trailingClusterStack = NSStackView()

    /// Split view owner sets this closure to collapse/expand the
    /// detail pane when the user clicks the toggle button. Keeps
    /// `DetailViewController` agnostic of its parent hierarchy.
    var onTogglePaneRequested: (() -> Void)?

    /// Drag-to-resize callbacks — fired as the user drags on the
    /// header background. Owner (`DashboardSplitViewController`)
    /// translates the delta into a height-constraint change.
    var onHeaderResizeBegan: (() -> Void)?
    var onHeaderResizeDragged: ((CGFloat) -> Void)?
    var onHeaderResizeEnded: (() -> Void)?

    /// Whether the detail pane content is currently minimized
    /// (header-only mode). Feeds `updateVisibility()` so every
    /// isHidden flip funnels through a single decision point.
    private var isMinimizedState: Bool = false

    /// True when a Turn/Step/Request is currently being displayed.
    /// Drives the mutually-exclusive `containerView` vs
    /// `emptyStateView` visibility in `updateVisibility()`.
    private var hasSelection: Bool {
        currentRequest != nil || currentSelection != nil
    }

    private var currentRequest: ParsedRequest?
    /// Order here MUST match the segmented control's segment labels
    /// (`setupSegmentedControl()`) — the label-to-view mapping is
    /// purely positional via `showTab(index:)`.
    private var currentTabViews: [NSView] {
        [conversationView, attachmentsView, tokensView, usageView, rawView]
    }

    init(store: AppStateStore) {
        self.store = store
        self.tokensView = TokensDetailView()
        self.conversationView = ConversationDetailView()
        self.attachmentsView = AttachmentsDetailView()
        self.rawView = RawDetailView()
        self.usageView = UsageDetailView()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        self.view = root

        setupSegmentedControl()
        setupContainer()
        setupEmptyState()
        layoutViews()
        showTab(0)
        // Start in empty state
        clearSelection()
    }


    // MARK: - Setup

    private func setupSegmentedControl() {
        segmentedControl.segmentCount = 5
        // Tab order — most-used first. `Conversation` is the primary
        // landing tab; `Raw` is a developer escape hatch and lives
        // last. Order must match `currentTabViews`.
        segmentedControl.setLabel("Conversation", forSegment: 0)
        segmentedControl.setLabel("Attachments", forSegment: 1)
        segmentedControl.setLabel("Tokens", forSegment: 2)
        segmentedControl.setLabel("Usage", forSegment: 3)
        segmentedControl.setLabel("Raw", forSegment: 4)
        segmentedControl.segmentStyle = .texturedRounded
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(tabChanged(_:))
        segmentedControl.controlSize = .small

        finderButton.bezelStyle = .accessoryBarAction
        finderButton.controlSize = .small
        finderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Reveal in Finder")
        finderButton.imagePosition = .imageLeading
        finderButton.target = self
        finderButton.action = #selector(revealInFinder)

        // Xcode-style "hide bottom pane" glyph. Two design choices
        // that distinguish this from a generic flat icon:
        //  1. **Bordered + accessory-bar bezel** — gives the button a
        //     hover/press background like the toolbar controls in
        //     Finder/Mail. Without `isBordered = true` the button
        //     has no clickable affordance until hovered.
        //  2. **Monochrome tint with explicit point size** (set in
        //     `applyTogglePaneSymbol()`) — Xcode tints the whole
        //     glyph in a single colour, not split halves. Palette
        //     rendering felt under-saturated next to the segmented
        //     control. We also pin `pointSize` so the symbol scales
        //     proportionally to the larger button frame instead of
        //     staying at SF Symbols' default ~14pt.
        togglePaneButton.bezelStyle = .accessoryBarAction
        togglePaneButton.controlSize = .regular
        togglePaneButton.isBordered = true
        togglePaneButton.imagePosition = .imageOnly
        togglePaneButton.toolTip = "Hide Detail Pane (⇧⌘Y)"
        togglePaneButton.target = self
        togglePaneButton.action = #selector(togglePaneClicked)
        applyTogglePaneSymbol()

        // Vertical hairline between the reveal-in-Finder button and
        // the toggle pane button — visually clusters the two trailing
        // controls (Xcode's status-bar `|` pattern).
        togglePaneSeparator.boxType = .separator

        headerSeparator.boxType = .separator

        // Wire the header background drag-to-resize handle.
        headerResizeHandle.onDragBegan = { [weak self] in
            self?.onHeaderResizeBegan?()
        }
        headerResizeHandle.onDragDelta = { [weak self] delta in
            self?.onHeaderResizeDragged?(delta)
        }
        headerResizeHandle.onDragEnded = { [weak self] in
            self?.onHeaderResizeEnded?()
        }
    }

    /// Render `togglePaneButton`'s glyph at an explicit point size with
    /// a hue-flipping tint that mirrors Xcode's debug-area toggle.
    ///
    /// **Symbol choice** — `inset.filled.bottomthird.square`. Verified
    /// reference points:
    ///   - Xcode's IDEKit binary references this exact name (extracted
    ///     via `strings $XCODE/.../IDEKit | grep`).
    ///   - The macOS public SF Symbols catalogue
    ///     (`/System/Library/CoreServices/CoreGlyphs.bundle`) lists
    ///     this symbol — so it's not a private Xcode asset and is
    ///     covered by the standard SF Symbols license for Apple-
    ///     platform apps.
    ///   - Runtime probe (`NSImage(systemSymbolName:)`) returns a
    ///     valid 15×14pt image on macOS 26.
    /// Falls back to `square.bottomhalf.filled` if a future toolchain
    /// drops the inset variant.
    ///
    /// **Sizing** — SF Symbols default to ~14pt; that looked tiny
    /// inside the 28pt button frame. `pointSize: 16, weight: .medium`
    /// brings the glyph weight in line with the segmented control's
    /// text.
    ///
    /// **Tint policy** — derived from inspecting two Xcode screenshots
    /// the user shared (active state = blue accent, inactive state =
    /// faint grey-white):
    ///
    ///   Expanded  (pane visible) → `.controlAccentColor`
    ///   Minimized (pane hidden)  → `.tertiaryLabelColor`
    ///
    /// Earlier iterations of this method tried two other policies:
    ///   - `[.controlAccentColor, .tertiaryLabelColor]` palette (only
    ///     the inset half tinted) — read as under-saturated next to
    ///     the segmented control.
    ///   - `.labelColor` ↔ `.tertiaryLabelColor` monochrome — same hue
    ///     in both states, mistakenly assumed Xcode kept hue constant.
    ///     User screenshots showed Xcode does flip hue.
    /// `.tertiaryLabelColor` (≈ 30% opacity) is chosen over
    /// `.secondaryLabelColor` (≈ 50% opacity) for the inactive state
    /// because secondaryLabel-grey vs accent-blue read as too similar
    /// in luminance on dark backgrounds.
    private func applyTogglePaneSymbol() {
        let preferredName = "inset.filled.bottomthird.square"
        let fallbackName  = "square.bottomhalf.filled"
        let resolvedName = NSImage(systemSymbolName: preferredName, accessibilityDescription: nil) != nil
            ? preferredName
            : fallbackName

        // Bake the colour into the image itself via `paletteColors`
        // (single-colour palette = monochrome). This bypasses the
        // `contentTintColor` path entirely — `bezelStyle =
        // .accessoryBarAction` + `isBordered = true` was observed to
        // ignore `contentTintColor` and apply AppKit's own system
        // tint, which made active/inactive look identical.
        // `paletteColors` is enforced at draw time inside the image
        // and overrides whatever the bezel would apply.
        let tint: NSColor = isMinimizedState ? .secondaryLabelColor : .controlAccentColor
        let sizeConfig    = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        let mergedConfig  = sizeConfig.applying(paletteConfig)
        togglePaneButton.image = NSImage(
            systemSymbolName: resolvedName,
            accessibilityDescription: isMinimizedState ? "Show Detail Pane" : "Hide Detail Pane"
        )?.withSymbolConfiguration(mergedConfig)

        // Belt-and-suspenders — keep `contentTintColor` aligned with the
        // palette so any future AppKit bezel that *does* honour it
        // doesn't drift away from the baked colour.
        togglePaneButton.contentTintColor = tint
    }

    /// Minimize/expand the detail pane content while keeping the
    /// header (tab segmented control + toggle button) always visible.
    /// Xcode's "debug area" toggle behaves the same way — the console
    /// collapses to a thin header bar so the toggle stays clickable.
    ///
    /// Split-view owner (`DashboardSplitViewController`) drives the
    /// divider animation; this method just stores the flag and hands
    /// off to `updateVisibility()` so every isHidden change flows
    /// through a single decision point.
    func setMinimized(_ minimized: Bool) {
        isMinimizedState = minimized
        updateVisibility()
    }

    /// Single source of truth for every child view's `isHidden`.
    ///
    /// Visibility rules (valid across all (selection × minimized) combos):
    ///
    ///   | selection? | minimized? | segmented | toggle | separator | finder | container | emptyState |
    ///   |------------|------------|-----------|--------|-----------|--------|-----------|------------|
    ///   | no         | no         | ✓         | ✓      | ✓         | ✗      | ✗         | ✓          |
    ///   | yes        | no         | ✓         | ✓      | ✓         | ✓      | ✓         | ✗          |
    ///   | no         | yes        | ✓         | ✓      | ✗         | ✗      | ✗         | ✗          |
    ///   | yes        | yes        | ✓         | ✓      | ✗         | ✓      | ✗         | ✗          |
    ///
    /// (`segmented` and `toggle` are ALWAYS visible — that's the
    /// "header row" the user must always see.)
    ///
    /// Previously `clearSelection()`, `showTurn()`, and `setMinimized()`
    /// each set isHidden fields independently, which produced every
    /// possible inconsistent combination (empty state + tokens
    /// content stacked, header hidden while content shown, etc).
    /// Routing all flips through this table guarantees the pane is
    /// only ever in one of the four legal states above.
    private func updateVisibility() {
        // Header row — always on-screen, regardless of selection /
        // minimize state. These are the only affordances the user
        // can reach to *change* the other state dimensions.
        segmentedControl.isHidden = false
        togglePaneButton.isHidden = false

        // Reveal in Finder needs something selected to reveal. The
        // grouping separator follows the same visibility rule — when
        // finder is hidden the lone separator would float between
        // empty space and the toggle.
        finderButton.isHidden = !hasSelection
        togglePaneSeparator.isHidden = !hasSelection

        // Below-header content.
        if isMinimizedState {
            headerSeparator.isHidden = true
            containerView.isHidden = true
            emptyStateView.isHidden = true
        } else {
            headerSeparator.isHidden = false
            containerView.isHidden = !hasSelection
            emptyStateView.isHidden = hasSelection
        }

        // Toggle button visual state — palette swap (glyph + colours)
        // routes through `applyTogglePaneSymbol()` so the icon morphs
        // alongside the tooltip change. The tooltip alone wasn't a
        // strong enough state cue.
        applyTogglePaneSymbol()
        togglePaneButton.toolTip = isMinimizedState ? "Show Detail Pane (⇧⌘Y)" : "Hide Detail Pane (⇧⌘Y)"
    }

    private func setupContainer() {
        containerView.wantsLayer = true

        for tabView in currentTabViews {
            tabView.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(tabView)
            NSLayoutConstraint.activate([
                tabView.topAnchor.constraint(equalTo: containerView.topAnchor),
                tabView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                tabView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                tabView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])
        }
    }

    private func setupEmptyState() {
        if let img = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .thin)
            emptyImageView.image = img.withSymbolConfiguration(config)
            emptyImageView.contentTintColor = .tertiaryLabelColor
        }

        emptyTitleLabel.stringValue = "No Selection"
        emptyTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        emptyTitleLabel.textColor = .secondaryLabelColor
        emptyTitleLabel.alignment = .center

        emptySubtitleLabel.stringValue = "Select a Turn or Step from the list above\nto view its details."
        emptySubtitleLabel.font = .systemFont(ofSize: 11)
        emptySubtitleLabel.textColor = .tertiaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [emptyImageView, emptyTitleLabel, emptySubtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        // A tiny custom gap between the icon and the title makes the
        // composition feel less cramped — matches Xcode's "No Editor"
        // Zero-State.
        stack.setCustomSpacing(12, after: emptyImageView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: emptyStateView.widthAnchor, constant: -32),
        ])
    }

    private func layoutViews() {
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        containerView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        finderButton.translatesAutoresizingMaskIntoConstraints = false
        togglePaneButton.translatesAutoresizingMaskIntoConstraints = false
        togglePaneSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        trailingClusterStack.translatesAutoresizingMaskIntoConstraints = false

        // Configure the trailing-cluster NSStackView. Holds the three
        // trailing controls (Reveal / separator / toggle) so the
        // resize handle can anchor against a single moving leading
        // edge — when the Reveal button is hidden, NSStackView
        // collapses it to zero width automatically and the cluster's
        // leading edge tracks the separator/toggle without manual
        // priority juggling.
        trailingClusterStack.orientation = .horizontal
        trailingClusterStack.alignment = .centerY
        trailingClusterStack.spacing = 8
        trailingClusterStack.addArrangedSubview(finderButton)
        trailingClusterStack.addArrangedSubview(togglePaneSeparator)
        trailingClusterStack.addArrangedSubview(togglePaneButton)

        view.addSubview(headerResizeHandle)
        view.addSubview(segmentedControl)
        view.addSubview(trailingClusterStack)
        view.addSubview(headerSeparator)
        view.addSubview(containerView)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            // Segmented control — leading-aligned (macOS convention for
            // tab-bar-style segmented controls inside a pane).
            segmentedControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DetailStyles.horizontalInset),

            // Trailing cluster — flush right at Apple's 16pt header
            // trailing token. Centred against the segmented control.
            trailingClusterStack.centerYAnchor.constraint(equalTo: segmentedControl.centerYAnchor),
            trailingClusterStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // Keep the cluster from colliding with the segmented control
            // when the pane is narrow — preserved from the original
            // layout where the same minimum gap protected `finderButton`.
            trailingClusterStack.leadingAnchor.constraint(greaterThanOrEqualTo: segmentedControl.trailingAnchor, constant: 12),

            // Toggle pane button — 28×28 hit target meets HIG's
            // non-touch control minimum.
            togglePaneButton.widthAnchor.constraint(equalToConstant: 28),
            togglePaneButton.heightAnchor.constraint(equalToConstant: 28),

            // Vertical separator — 1×14pt hairline clustering Reveal
            // and toggle (Xcode status-bar `|` pattern).
            togglePaneSeparator.widthAnchor.constraint(equalToConstant: 1),
            togglePaneSeparator.heightAnchor.constraint(equalToConstant: 14),

            // Hairline separator directly beneath the segmented row —
            // gives the pane a titled-chrome feel and cleanly divides
            // tab bar from tab content.
            headerSeparator.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            headerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Resize handle — frame restricted to the empty strip
            // between the segmented control and the trailing cluster.
            // Because the cursor-rect is frame-based, this geometry
            // alone guarantees the resize cursor only ever shows on
            // the empty background; the controls' frames are entirely
            // outside this view, so the system arrow falls back over
            // them. Same approach NSSplitView's divider uses.
            headerResizeHandle.topAnchor.constraint(equalTo: view.topAnchor),
            headerResizeHandle.bottomAnchor.constraint(equalTo: headerSeparator.topAnchor),
            headerResizeHandle.leadingAnchor.constraint(equalTo: segmentedControl.trailingAnchor),
            headerResizeHandle.trailingAnchor.constraint(equalTo: trailingClusterStack.leadingAnchor),

            // Content container sits flush against the separator — each
            // tab view adds its own internal insets (DetailStyles.horizontalInset).
            containerView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Empty state covers the *content* area only (below the
            // header separator) — never the header row. Otherwise it
            // would intercept hit-tests on the resize handle when no
            // selection is active and break header-drag mid-gesture.
            emptyStateView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Public

    func showRequest(_ request: ParsedRequest) {
        currentRequest = request
        currentSessionId = request.sessionId
        currentSelection = .request(id: request.id)
        updateVisibility()

        // Legacy request selection (pre-Turn model): the per-request
        // cost/prompt graphs died with 5.3 — render what the request
        // itself carries.
        tokensView.configure(
            tokens: request.tokens,
            cost: CostCalculator.calculateCost(
                tokens: request.tokens, model: request.model, speed: request.speed
            ),
            model: request.model,
            provider: request.provider
        )
        conversationView.configure(blocks: [])
        // Legacy request path (`ParsedRequest`) has no Step-scoped
        // attachment manifest — it predates the Turn/Step model. Leave
        // the tab empty; any user viewing this path is on an old code
        // path that doesn't surface attachments.
        attachmentsView.configure(attachments: [], context: .step)
        setRawUsageContent(for: currentSelection) { [weak self] in
            guard let self else { return }
            let rawData: Data? = nil
            self.rawView.configure(rawPayload: rawData)
            if request.provider == .codex {
                self.usageView.configure(rawPayloadSections: [
                    CodexUsagePayloadSection(requestId: request.id, rawPayload: rawData),
                ])
            } else {
                self.usageView.configure(rawPayload: rawData)
            }
        }
    }

    /// Skips the re-render when the same Step is bound consecutively
    /// so streaming updates don't yank the user's scroll position
    /// or cause a flicker.
    func showStep(_ step: Step, in turn: Turn) {
        let identity = DetailSelectionID.step(sessionId: step.sessionId, uuid: step.uuid)
        if currentSelection == identity {
            // Same Step re-bound. Skip the full re-render so that
            // streaming updates don't yank the user's scroll position
            // back to the top. Partial token/cost updates are deferred
            // until we need them — current UX cost is negligible.
            return
        }
        currentSelection = identity
        currentRequest = nil
        currentSessionId = step.sessionId
        updateVisibility()

        let tokens = step.tokens ?? TokenBreakdown(
            inputTokens: 0, outputTokens: 0,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            cacheCreationEphemeral1h: 0, cacheCreationEphemeral5m: 0
        )
        tokensView.configure(
            tokens: tokens,
            cost: step.cost,
            model: step.model,
            provider: ProviderScopedID(value: step.sessionId)?.provider ?? .claudeCode
        )

        // Q1: even on Step selection, draw the whole Turn flow and highlight only that Step.
        conversationView.configure(
            blocks: ConversationStoryBuilder.build(turn: turn, highlight: step.uuid)
        )

        // Attachments tab — read the unified manifest produced by
        // `AttachmentResolver`. `step.attachments` covers every channel
        // (inline images, `[Image source:]` meta, prompt mentions,
        // tool input / output paths & URLs, reply mentions) so the
        // tab finally sees what every Step *actually* touched.
        //
        // Inline image rows need a provider closure that can reach
        // the JSONL raw bytes (inline images carry no file path —
        // bytes live only in `message.content[].source.data`). The
        // provider is captured for the lifetime of this Step display;
        // `store.rawJSON(for: step)` is lazy and cached, so clicking
        // the same preview repeatedly doesn't re-scan the file.
        attachmentsView.configure(
            attachments: step.attachments,
            context: .step,
            inlineImageProvider: { [weak self] ref in
                self?.loadInlineImage(for: ref, fromStep: step)
            }
        )

        // `Step.rawJSON` is stripped from the snapshot (Plan 13 Phase 8), so
        // post-launch Steps load nil for this field until their JSONL is
        // scanned. `store.rawJSON(for:)` returns the inline bytes if the
        // Step was built live, reads `step.rawJSONLocator` (SQLite-first
        // materialization attaches it), or lazy-scans the file.
        setRawUsageContent(for: identity) { [weak self] in
            guard let self else { return }
            let payloads = self.rawAndUsagePayload(for: step)
            self.rawView.configure(rawPayload: payloads.raw)
            self.usageView.configure(rawPayloadSections: payloads.usage)
        }
    }

    private var currentSessionId: String?
    private var currentSelection: DetailSelectionID?

    // MARK: - Lazy Raw/Usage (plan 4.2)

    /// Raw/Usage payloads come from disk (locator reads) — deferred
    /// until the user actually fronts one of those tabs. Hidden tabs
    /// no longer fetch anything (memory-audit P1).
    private var pendingRawUsageLoad: (() -> Void)?
    private var pendingRawUsageSelection: DetailSelectionID?
    private static let lazyTabIndexes: Set<Int> = [3, 4]   // Usage, Raw

    /// Installs the Raw/Usage content for the current selection: runs
    /// immediately when one of those tabs is frontmost, otherwise parks
    /// the loader for the first matching `showTab`.
    private func setRawUsageContent(
        for selection: DetailSelectionID?,
        load: @escaping () -> Void
    ) {
        if Self.lazyTabIndexes.contains(segmentedControl.selectedSegment) {
            pendingRawUsageLoad = nil
            pendingRawUsageSelection = nil
            load()
        } else {
            pendingRawUsageLoad = load
            pendingRawUsageSelection = selection
            // The previous selection's bytes must not flash when the
            // user fronts the tab before the loader runs.
            rawView.configure(rawPayload: nil)
            usageView.configure(rawPayloadSections: nil)
        }
    }

    /// Renders a whole-Turn summary (as opposed to a single Step).
    /// Tokens/Cost come from the Turn aggregate; Conversation /
    /// Attachments / Raw / Usage tabs are sourced from the Turn's
    /// prompt Step. An orphan Turn with no prompt Step falls back to
    /// an empty state.
    ///
    /// `displayCost` / `displayTokens` are required (no default) so
    /// the outline header and the detail Tokens tab stay in sync
    /// within a single selection — own + sub-agent rollups are
    /// computed by the caller (see `aggregateCostIncludingSubAgents`)
    /// and must be passed through. Adding a default would let a
    /// future caller invoke `showTurn(turn)` and silently desync the
    /// two surfaces.
    func showTurn(_ turn: Turn, displayCost: CostBreakdown, displayTokens: TokenBreakdown) {
        currentSelection = .turn(sessionId: turn.sessionId, turnId: turn.id)
        currentRequest = nil
        currentSessionId = turn.sessionId
        updateVisibility()

        // Model can vary across Steps within a Turn, so fall back to
        // the prompt Step's model (or nil) for the header label.
        let promptStep = turn.promptStep
        tokensView.configure(
            tokens: displayTokens,
            cost: displayCost,
            model: promptStep?.model,
            provider: ProviderScopedID(value: turn.sessionId)?.provider ?? .claudeCode
        )

        conversationView.configure(blocks: ConversationStoryBuilder.build(turn: turn))

        // Step selection uses `Step.attachments`; Turn selection
        // aggregates via `Turn.allAttachments` so the tab shows every
        // attachment touched by every Step in the Turn (prompt
        // images + tool I/O paths/URLs + reply mentions). Both
        // paths share the `AttachmentRef` type produced by the
        // 2-phase resolver.
        //
        // Inline image preview: at Turn scope, the owning Step of an
        // `.inlineImage` ref isn't immediately known — search the
        // Turn's Steps for the one whose `attachments` carries the
        // same locator. O(steps) at click time, fine for typical
        // Turn sizes.
        attachmentsView.configure(
            attachments: turn.allAttachments,
            context: .turn,
            inlineImageProvider: { [weak self] ref in
                self?.loadInlineImage(for: ref, fromTurn: turn)
            }
        )

        // Raw/Usage uses the prompt Step's rawJSON as the Turn's
        // entry point. Lazy-loaded through the store because rawJSON
        // is stripped from the snapshot (see the Step branch above).
        setRawUsageContent(for: currentSelection) { [weak self] in
            guard let self else { return }
            let rawPayload = promptStep.flatMap { self.store.rawJSON(for: $0) }
            self.rawView.configure(rawPayload: rawPayload)
            self.usageView.configure(
                rawPayloadSections: self.usagePayloads(for: turn.steps, fallbackRaw: rawPayload)
            )
        }
    }

    func showSkillGroup(
        _ group: SkillGroupBuilder.SkillGroup,
        displayCost: CostBreakdown,
        displayTokens: TokenBreakdown
    ) {
        let sessionId = group.steps.first?.sessionId
        currentSelection = .skillGroup(sessionId: sessionId ?? "unknown", groupId: group.id)
        currentRequest = nil
        currentSessionId = sessionId
        updateVisibility()

        let firstStep = group.steps.first
        tokensView.configure(
            tokens: displayTokens,
            cost: displayCost,
            model: firstStep?.model,
            provider: sessionId.flatMap { ProviderScopedID(value: $0)?.provider } ?? .claudeCode
        )

        conversationView.configure(
            blocks: ConversationStoryBuilder.build(
                turn: Turn(
                    id: group.id,
                    sessionId: sessionId ?? group.id,
                    steps: group.steps,
                    isInterrupted: false
                )
            )
        )

        attachmentsView.configure(
            attachments: Self.attachments(from: group.steps),
            context: .turn,
            inlineImageProvider: { [weak self] ref in
                self?.loadInlineImage(for: ref, fromSteps: group.steps)
            }
        )

        setRawUsageContent(for: currentSelection) { [weak self] in
            guard let self else { return }
            let rawPayload = firstStep.flatMap { self.store.rawJSON(for: $0) }
            self.rawView.configure(rawPayload: rawPayload)
            self.usageView.configure(
                rawPayloadSections: self.usagePayloads(for: group.steps, fallbackRaw: rawPayload)
            )
        }
    }

    private func rawAndUsagePayload(for step: Step) -> (raw: Data?, usage: [CodexUsagePayloadSection]?) {
        let raw = store.rawJSON(for: step)
        guard ProviderScopedID(value: step.sessionId)?.provider == .codex,
              !codexRequestIds(from: [step]).isEmpty else {
            return (raw, raw.map { [CodexUsagePayloadSection(requestId: nil, rawPayload: $0)] })
        }
        // Request-line locators are a recorded 4.2 follow-up gap — the
        // per-request token_count payload is unavailable from the index;
        // the section header still names the request id.
        let payloads = codexRequestIds(from: [step]).map {
            CodexUsagePayloadSection(requestId: $0, rawPayload: nil)
        }
        return (raw, payloads)
    }

    private func usagePayloads(for steps: [Step], fallbackRaw: Data?) -> [CodexUsagePayloadSection]? {
        guard steps.first.flatMap({ ProviderScopedID(value: $0.sessionId)?.provider }) == .codex else {
            return fallbackRaw.map { [CodexUsagePayloadSection(requestId: nil, rawPayload: $0)] }
        }
        let requestIds = codexRequestIds(from: steps)
        guard !requestIds.isEmpty else {
            return fallbackRaw.map { [CodexUsagePayloadSection(requestId: nil, rawPayload: $0)] }
        }
        return requestIds.map {
            CodexUsagePayloadSection(requestId: $0, rawPayload: nil)
        }
    }

    private func codexRequestIds(from steps: [Step]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for step in steps {
            let candidates = step.requestIds.isEmpty
                ? step.requestId.map { [$0] } ?? []
                : step.requestIds
            for id in candidates where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    func clearSelection() {
        currentRequest = nil
        currentSelection = nil
        pendingRawUsageLoad = nil
        pendingRawUsageSelection = nil
        emptyTitleLabel.stringValue = "No Selection"
        emptySubtitleLabel.stringValue = "Select a Turn or Step from the list above\nto view its details."
        updateVisibility()
    }

    // MARK: - Tab Switching

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        showTab(sender.selectedSegment)
    }

    // MARK: - Test seams (plan 4.2)

    var isRawUsageLoadPendingForTesting: Bool { pendingRawUsageLoad != nil }

    func frontTabForTesting(_ index: Int) {
        segmentedControl.selectedSegment = index
        showTab(index)
    }

    private func showTab(_ index: Int) {
        // First visit to Raw/Usage for this selection: run the parked
        // loader (plan 4.2 — hidden tabs never fetch).
        if Self.lazyTabIndexes.contains(index),
           let load = pendingRawUsageLoad,
           pendingRawUsageSelection == currentSelection {
            pendingRawUsageLoad = nil
            pendingRawUsageSelection = nil
            load()
        }
        for (i, tabView) in currentTabViews.enumerated() {
            tabView.isHidden = (i != index)
        }
    }

    // MARK: - Toggle Pane

    @objc private func togglePaneClicked() {
        onTogglePaneRequested?()
    }

    // MARK: - Finder

    @objc private func revealInFinder() {
        let sessionId = currentRequest?.sessionId ?? currentSessionId
        guard let sid = sessionId, let url = store.jsonlFileURL(for: sid) else { return }
        // `NSWorkspace.activateFileViewerSelecting` can fail under
        // sandbox restrictions, so spawn `open -R <path>` instead —
        // same effect, sandbox-friendly.
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-R", url.path]
        try? process.run()
    }

    // MARK: - Inline image preview

    /// Resolves an `.inlineImage` ref to an image payload (rendered
    /// `NSImage` + original bytes + media type) by pulling the raw
    /// JSONL line for `step` and decoding the base64 payload of the
    /// image block at the locator's index. Returns nil for non-inline
    /// refs or any decoding failure — the Attachments tab then
    /// silently skips the preview.
    ///
    /// Raw bytes are returned alongside the rendered `NSImage` so the
    /// preview's Save button can write the *original* PNG / JPEG
    /// verbatim (no re-encode round-trip that would strip metadata
    /// or shift colours).
    fileprivate func loadInlineImage(
        for ref: AttachmentRef,
        fromStep step: Step
    ) -> AttachmentsDetailView.InlineImagePayload? {
        guard ref.kind == .inlineImage else { return nil }
        guard let raw = store.rawJSON(for: step) else { return nil }
        guard let idx = InlineImageLoader.imageIndex(fromLocator: ref.locator) else { return nil }
        guard let decoded = InlineImageLoader.decodeImage(fromRawJSON: raw, imageIndex: idx) else {
            return nil
        }
        guard let image = NSImage(data: decoded.data) else { return nil }
        return AttachmentsDetailView.InlineImagePayload(
            image: image,
            rawBytes: decoded.data,
            mediaType: decoded.mediaType
        )
    }

    /// Turn-scoped variant — search the Turn for the Step owning the
    /// inline image and delegate to the Step path. Matches on
    /// `locator` since that's what `Turn.allAttachments` uses as its
    /// dedup key.
    fileprivate func loadInlineImage(
        for ref: AttachmentRef,
        fromTurn turn: Turn
    ) -> AttachmentsDetailView.InlineImagePayload? {
        guard ref.kind == .inlineImage else { return nil }
        for step in turn.steps
        where step.attachments.contains(where: { $0.locator == ref.locator }) {
            return loadInlineImage(for: ref, fromStep: step)
        }
        return nil
    }

    fileprivate func loadInlineImage(
        for ref: AttachmentRef,
        fromSteps steps: [Step]
    ) -> AttachmentsDetailView.InlineImagePayload? {
        guard ref.kind == .inlineImage else { return nil }
        for step in steps
        where step.attachments.contains(where: { $0.locator == ref.locator }) {
            return loadInlineImage(for: ref, fromStep: step)
        }
        return nil
    }

    private static func attachments(from steps: [Step]) -> [AttachmentRef] {
        var order: [String] = []
        var byLocator: [String: AttachmentRef] = [:]

        for step in steps {
            for ref in step.attachments {
                if let existing = byLocator[ref.locator] {
                    if ref.origin.dedupPriority > existing.origin.dedupPriority {
                        byLocator[ref.locator] = ref
                    }
                } else {
                    byLocator[ref.locator] = ref
                    order.append(ref.locator)
                }
            }
        }

        return order.compactMap { byLocator[$0] }
    }

}

// MARK: - Tokens Detail View

/// Document view that reports `isFlipped = true`, so `scroll(NSPoint.zero)`
/// scrolls to the TOP instead of the bottom. NSStackView's default
/// un-flipped coordinate system put `(0,0)` at the document's bottom,
/// which is why every rebind left the Tokens tab staring at the last
/// row. Wrapping the content in a flipped host is the idiomatic AppKit
/// fix (the same pattern `NSTextView` uses internally).
private final class TokensFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Xcode Build Settings-style token/cost breakdown. Flat list of rows,
/// no grouped boxes, label column at a fixed offset, value starts at
/// the same offset column across every section — so you get clean
/// vertical alignment for scanning.
///
/// Layout (20pt leading / 20pt trailing, full pane width):
/// ```
/// ──────────────────────────────────  ← separator above section
/// Tokens                              ← header 13pt semibold
///
///   Input Tokens        25
///   Output Tokens       19,881
///   Cache Creation      38,295
///     Ephemeral 1h      38,295       ← sub-row indent
///     Ephemeral 5m      0
///   Cache Read          5,233,375
///
///   Total Context       5,291,576    ← semibold emphasis
///   Effective           19,906
///   Cache Efficiency    99.3%
///
/// ──────────────────────────────────
/// Cost
///   …
/// ```
///
/// Row = `[label, fixed 200pt column][gap][value, left-aligned]`. Fixed
/// column means values align vertically: on a 1200pt pane, both "25"
/// and "5,291,576" start at x=200 regardless of label length.
final class TokensDetailView: NSView {

    private let scrollView = NSScrollView()
    private let documentView = TokensFlippedDocumentView()
    private let outerStack = NSStackView()

    /// Fixed leading offset for the value column (from pane leading +
    /// horizontal inset). Label sits in the 200pt column, value starts
    /// right after.
    private static let labelColumnWidth: CGFloat = 200
    private static let horizontalInset: CGFloat = 20
    private static let rowVerticalGap: CGFloat = 2
    private static let sectionVerticalGap: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 0                        // custom per-element
        outerStack.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 20, right: 0)
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(outerStack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Document view tracks scroll viewport width so content is
            // pane-wide. Its height follows its subviews (outerStack).
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            outerStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    func configure(
        tokens: TokenBreakdown,
        cost: CostBreakdown?,
        model: String?,
        provider: ProviderKind = .claudeCode
    ) {
        // Clear previous content.
        for v in outerStack.arrangedSubviews {
            outerStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        // --- Section: Tokens ---
        var tokenRows: [RowSpec] = [
            .row("Input Tokens", formatNumber(tokens.inputTokens)),
            .row("Output Tokens", formatNumber(tokens.outputTokens)),
        ]
        if provider == .codex || tokens.reasoningOutputTokens > 0 {
            tokenRows.append(.row("Reasoning Output", formatNumber(tokens.reasoningOutputTokens)))
        }
        let hasCacheCreationTokens = tokens.cacheCreationInputTokens > 0
            || tokens.cacheCreationEphemeral1h > 0
            || tokens.cacheCreationEphemeral5m > 0
        if provider == .claudeCode || hasCacheCreationTokens {
            tokenRows.append(.row("Cache Creation", formatNumber(tokens.cacheCreationInputTokens)))
        }
        if provider == .claudeCode || tokens.cacheCreationEphemeral1h > 0 {
            tokenRows.append(.subRow("Ephemeral 1h", formatNumber(tokens.cacheCreationEphemeral1h)))
        }
        if provider == .claudeCode || tokens.cacheCreationEphemeral5m > 0 {
            tokenRows.append(.subRow("Ephemeral 5m", formatNumber(tokens.cacheCreationEphemeral5m)))
        }
        if provider == .claudeCode || tokens.cacheReadInputTokens > 0 {
            let cacheReadLabel = provider == .codex ? "Cached Input" : "Cache Read"
            tokenRows.append(.row(cacheReadLabel, formatNumber(tokens.cacheReadInputTokens)))
        }
        if provider == .codex, let contextWindow = tokens.contextWindow {
            tokenRows.append(.row("Context Window", formatNumber(contextWindow)))
        }
        tokenRows.append(contentsOf: [
            .separator,
            .total(
                provider == .codex ? "Total Tokens" : "Total Context",
                formatNumber(tokens.totalContextTokens)
            ),
            .row(
                "Effective",
                formatNumber(tokens.effectiveTokens),
                tooltip: provider == .codex
                    ? "Billed input + output + reasoning tokens; cached input is shown separately"
                    : "Actual billed tokens - cache reads excluded"
            ),
        ])
        if let ratio = tokens.cacheEfficiencyRatio {
            tokenRows.append(.row("Cache Efficiency", String(format: "%.1f%%", ratio * 100)))
        }
        addSection(title: "Tokens", rows: tokenRows, isFirst: true)

        // --- Section: Cost ---
        if let cost {
            let cacheCreationTotal = cost.cacheCreate1hCostUSD + cost.cacheCreate5mCostUSD
            var costRows: [RowSpec] = [
                .row("Input", DetailCostFormatter.format(cost.inputCostUSD)),
                .row("Output", DetailCostFormatter.format(cost.outputCostUSD)),
            ]
            if provider == .claudeCode || cacheCreationTotal > 0 {
                costRows.append(.row("Cache Creation", DetailCostFormatter.format(cacheCreationTotal)))
            }
            if provider == .claudeCode || cost.cacheCreate1hCostUSD > 0 {
                costRows.append(.subRow("Ephemeral 1h", DetailCostFormatter.format(cost.cacheCreate1hCostUSD)))
            }
            if provider == .claudeCode || cost.cacheCreate5mCostUSD > 0 {
                costRows.append(.subRow("Ephemeral 5m", DetailCostFormatter.format(cost.cacheCreate5mCostUSD)))
            }
            if provider == .claudeCode || cost.cacheReadCostUSD > 0 {
                let cacheReadLabel = provider == .codex ? "Cached Input" : "Cache Read"
                costRows.append(.row(cacheReadLabel, DetailCostFormatter.format(cost.cacheReadCostUSD)))
            }
            costRows.append(contentsOf: [
                .separator,
                .total("Total Cost", DetailCostFormatter.format(cost.totalCostUSD)),
            ])
            addSection(title: "Cost", rows: costRows)
        } else {
            addSection(title: "Cost", rows: [
                .row("Status", model == nil ? "Unknown model" : "Cost unavailable"),
            ])
        }

        // --- Section: Model ---
        addSection(title: "Model", rows: [
            .row("Name", model ?? "Unknown"),
        ])

        // Force layout so scroll offset math uses up-to-date document
        // height. `isFlipped = true` on TokensFlippedDocumentView makes
        // (0, 0) the top-left — `scroll(.zero)` now does what it says.
        layoutSubtreeIfNeeded()
        documentView.scroll(.zero)
    }

    // MARK: - Row specs

    private enum RowSpec {
        case row(String, String, tooltip: String? = nil)
        case subRow(String, String)
        case total(String, String)
        case separator
    }

    // MARK: - Section builder

    /// Builds a section directly into `outerStack`:
    ///   horizontal rule (skipped for first section)
    ///   section header
    ///   row
    ///   row
    ///   ...
    /// All items share the same leading inset (`horizontalInset`).
    /// Values sit at the fixed `labelColumnWidth` offset so columns
    /// align across the whole view.
    private func addSection(title: String, rows: [RowSpec], isFirst: Bool = false) {
        if !isFirst {
            let rule = makeSectionTopRule()
            outerStack.addArrangedSubview(rule)
            rule.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor).isActive = true
            rule.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor).isActive = true
            outerStack.setCustomSpacing(Self.sectionVerticalGap, after: rule)
        }

        let header = makeSectionHeader(title: title)
        outerStack.addArrangedSubview(header)
        header.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor, constant: Self.horizontalInset).isActive = true
        header.trailingAnchor.constraint(lessThanOrEqualTo: outerStack.trailingAnchor, constant: -Self.horizontalInset).isActive = true
        outerStack.setCustomSpacing(10, after: header)

        for (i, spec) in rows.enumerated() {
            let view: NSView
            switch spec {
            case let .row(name, value, tooltip):
                view = makeRow(name: name, value: value, style: .regular, tooltip: tooltip)
            case let .subRow(name, value):
                view = makeRow(name: name, value: value, style: .sub, tooltip: nil)
            case let .total(name, value):
                view = makeRow(name: name, value: value, style: .total, tooltip: nil)
            case .separator:
                view = makeInlineSeparator()
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            outerStack.addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor).isActive = true

            // Row-to-row spacing stays tight (2pt), except extra air
            // around an inline separator (visual break before totals).
            if i < rows.count - 1 {
                let next = rows[i + 1]
                switch (spec, next) {
                case (.separator, _), (_, .separator):
                    outerStack.setCustomSpacing(6, after: view)
                default:
                    outerStack.setCustomSpacing(Self.rowVerticalGap, after: view)
                }
            }
        }

        // Gap before the next section's top rule.
        if let last = outerStack.arrangedSubviews.last {
            outerStack.setCustomSpacing(Self.sectionVerticalGap, after: last)
        }
    }

    private func makeSectionTopRule() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeSectionHeader(title: String) -> NSView {
        // Selectable — so the user can copy "Tokens" / "Cost" / "Model"
        // if they're quoting a section name in notes, same as Xcode
        // Build Settings headers which are selectable.
        let label = DetailStyles.makeSelectableValueLabel(
            title,
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor,
            alignment: .left
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeInlineSeparator() -> NSView {
        // Small air gap — not a visible line. The visual "section ends
        // with a total" cue comes from typography (.total row is
        // semibold + slightly larger) rather than a rule.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return spacer
    }

    // MARK: - Row builder

    private enum RowStyle { case regular, sub, total }

    private func makeRow(
        name: String,
        value: String,
        style: RowStyle,
        tooltip: String?
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let nameFont: NSFont
        let valueFont: NSFont
        let nameColor: NSColor
        let valueColor: NSColor
        let rowHeight: CGFloat
        let labelIndent: CGFloat
        switch style {
        case .regular:
            nameFont = .systemFont(ofSize: 13, weight: .regular)
            valueFont = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            nameColor = .labelColor
            valueColor = .labelColor
            rowHeight = 22
            labelIndent = 0
        case .sub:
            nameFont = .systemFont(ofSize: 12, weight: .regular)
            valueFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            nameColor = .secondaryLabelColor
            valueColor = .secondaryLabelColor
            rowHeight = 20
            labelIndent = 16
        case .total:
            nameFont = .systemFont(ofSize: 13, weight: .semibold)
            valueFont = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            nameColor = .labelColor
            valueColor = .labelColor
            rowHeight = 24
            labelIndent = 0
        }

        // Name AND value labels are both selectable — users want to copy
        // category names ("Cache Creation"), model names, and values
        // freely. The detail pane is a data surface, not decorative
        // chrome, so every text field responds to click-drag selection
        // + ⌘C. Previously only the value was selectable; the label
        // read-only — an oversight relative to the explicit user
        // requirement to copy any displayed text.
        let nameLabel = DetailStyles.makeSelectableValueLabel(
            name,
            font: nameFont,
            color: nameColor,
            alignment: .left
        )
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        if let tooltip { nameLabel.toolTip = tooltip }

        // Value: selectable so the user can copy the number / cost /
        // model name (the detail view's whole point is exposing data).
        // Left-aligned starting at the fixed column — values line up
        // vertically across every row in the section.
        let valueLabel = DetailStyles.makeSelectableValueLabel(
            value,
            font: valueFont,
            color: valueColor,
            alignment: .left
        )
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1

        row.addSubview(nameLabel)
        row.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: rowHeight),

            // Label: 20pt pane inset + optional sub-row indent.
            //        Bounded to (labelColumnWidth - gap) so it can't
            //        collide with the value column.
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.horizontalInset + labelIndent),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: row.leadingAnchor,
                constant: Self.horizontalInset + Self.labelColumnWidth - 8
            ),

            // Value: starts at the fixed column boundary, left-aligned.
            //        On a 1200pt pane both "25" and "5,291,576" start
            //        at x = 20 + 200 = 220pt from pane leading — so
            //        the numbers form a visible vertical column.
            valueLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.horizontalInset + Self.labelColumnWidth),
            valueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -Self.horizontalInset),
        ])

        // Accessibility: VoiceOver reads "Input Tokens, 25" as one row.
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)
        row.setAccessibilityLabel("\(name), \(value)")
        nameLabel.setAccessibilityElement(false)
        valueLabel.setAccessibilityElement(false)

        return row
    }

    // MARK: - Number formatting

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Raw Detail View

final class RawDetailView: NSView {

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: DetailStyles.horizontalInset, height: 12)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.isAutomaticLinkDetectionEnabled = false

        // Ensure textView tracks scrollView width (critical for hidden-then-shown tabs)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(rawPayload: Data?) {
        guard let data = rawPayload else {
            textView.string = "(no raw data available)"
            textView.textColor = .tertiaryLabelColor
            return
        }

        let formatted = JSONPrettyFormatter.format(data)
        textView.textColor = .labelColor
        textView.string = formatted
        textView.scrollToBeginningOfDocument(nil)
    }
}

// MARK: - Usage Detail View

struct CodexUsagePayloadSection: Equatable {
    let requestId: String?
    let rawPayload: Data?
}

enum CodexUsageDetailFormatter {
    private static let tokenKeyOrder = [
        "input_tokens",
        "cached_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "total_tokens"
    ]

    static func text(from rawPayload: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: rawPayload) as? [String: Any],
              json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else {
            return nil
        }

        var lines = ["Codex Usage", ""]
        if let model = payload["model"] ?? info["model"] ?? info["model_name"] {
            lines.append("model: \(formatVal(model))")
        }
        if let contextWindow = info["model_context_window"] {
            lines.append("model_context_window: \(formatVal(contextWindow))")
        }

        appendUsageSection("last_token_usage", info["last_token_usage"], to: &lines)
        appendUsageSection("total_token_usage", info["total_token_usage"], to: &lines)

        return lines.joined(separator: "\n")
    }

    private static func appendUsageSection(_ title: String, _ value: Any?, to lines: inout [String]) {
        guard let usage = value as? [String: Any], !usage.isEmpty else { return }
        if lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(title)

        let orderedKeys = tokenKeyOrder.filter { usage[$0] != nil }
        let remainingKeys = usage.keys.filter { !tokenKeyOrder.contains($0) }.sorted()
        for key in orderedKeys + remainingKeys {
            lines.append("    \(key): \(formatVal(usage[key]))")
        }
    }

    private static func formatVal(_ val: Any?) -> String {
        guard let val else { return "null" }
        if let n = val as? Int {
            return NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        }
        if let n = val as? NSNumber {
            return NumberFormatter.localizedString(from: n, number: .decimal)
        }
        if let s = val as? String { return s }
        return "\(val)"
    }
}

enum CodexUsagePayloadFormatter {
    static func text(from sections: [CodexUsagePayloadSection]) -> String? {
        guard !sections.isEmpty else { return nil }
        guard sections.contains(where: { $0.requestId != nil }) else { return nil }
        if sections.count == 1,
           let data = sections[0].rawPayload,
           let text = CodexUsageDetailFormatter.text(from: data) {
            return text
        }

        let rendered = sections.enumerated().map { index, section in
            var lines = [sectionTitle(index: index, section: section), ""]
            if let data = section.rawPayload,
               let text = CodexUsageDetailFormatter.text(from: data) {
                lines.append(text)
            } else {
                lines.append("(raw usage payload unavailable)")
            }
            return lines.joined(separator: "\n")
        }
        return rendered.joined(separator: "\n\n---\n\n")
    }

    private static func sectionTitle(index: Int, section: CodexUsagePayloadSection) -> String {
        let prefix = "Request \(index + 1)"
        guard let requestId = section.requestId, !requestId.isEmpty else {
            return prefix
        }
        return "\(prefix) — \(requestId)"
    }
}

/// Shows the API response's usage structure in a readable tree format.
/// Extracts message.usage from the raw JSONL payload and displays each field
/// with proper indentation and formatting.
final class UsageDetailView: NSView {

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: DetailStyles.horizontalInset, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(rawPayload: Data?) {
        guard let data = rawPayload else {
            setEmpty()
            return
        }

        if let codexUsage = CodexUsageDetailFormatter.text(from: data) {
            textView.textStorage?.setAttributedString(NSAttributedString(string: codexUsage, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
            textView.scrollToBeginningOfDocument(nil)
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            setEmpty()
            return
        }

        let result = NSMutableAttributedString()

        // Header
        appendHeader(to: result, "API Response — usage")
        appendLine(to: result, "")

        // Top-level fields
        let topFields: [(String, String)] = [
            ("input_tokens", formatVal(usage["input_tokens"])),
            ("output_tokens", formatVal(usage["output_tokens"])),
            ("cache_creation_input_tokens", formatVal(usage["cache_creation_input_tokens"])),
            ("cache_read_input_tokens", formatVal(usage["cache_read_input_tokens"])),
            ("service_tier", formatVal(usage["service_tier"])),
        ]

        for (key, val) in topFields {
            appendKeyValue(to: result, key: key, value: val, indent: 0)
        }

        // cache_creation sub-object
        if let cacheCreation = usage["cache_creation"] as? [String: Any] {
            appendLine(to: result, "")
            appendHeader(to: result, "cache_creation")
            for (key, val) in cacheCreation.sorted(by: { $0.key < $1.key }) {
                appendKeyValue(to: result, key: key, value: formatVal(val), indent: 1)
            }
        }

        // server_tool_use sub-object
        if let toolUse = usage["server_tool_use"] as? [String: Any] {
            appendLine(to: result, "")
            appendHeader(to: result, "server_tool_use")
            for (key, val) in toolUse.sorted(by: { $0.key < $1.key }) {
                appendKeyValue(to: result, key: key, value: formatVal(val), indent: 1)
            }
        }

        // Other fields not shown above
        let knownKeys: Set<String> = [
            "input_tokens", "output_tokens",
            "cache_creation_input_tokens", "cache_read_input_tokens",
            "service_tier", "cache_creation", "server_tool_use"
        ]
        let otherKeys = usage.keys.filter { !knownKeys.contains($0) }.sorted()
        if !otherKeys.isEmpty {
            appendLine(to: result, "")
            appendHeader(to: result, "Other Fields")
            for key in otherKeys {
                appendKeyValue(to: result, key: key, value: formatVal(usage[key]), indent: 0)
            }
        }

        // Model info from message level
        if let model = message["model"] as? String {
            appendLine(to: result, "")
            appendHeader(to: result, "Request Info")
            appendKeyValue(to: result, key: "model", value: model, indent: 0)
            if let stopReason = message["stop_reason"] as? String {
                appendKeyValue(to: result, key: "stop_reason", value: stopReason, indent: 0)
            }
            if let msgId = message["id"] as? String {
                appendKeyValue(to: result, key: "id", value: msgId, indent: 0)
            }
        }

        textView.textStorage?.setAttributedString(result)
        textView.scrollToBeginningOfDocument(nil)
    }

    func configure(rawPayloadSections: [CodexUsagePayloadSection]?) {
        guard let payloads = rawPayloadSections, !payloads.isEmpty else {
            setEmpty()
            return
        }
        guard let text = CodexUsagePayloadFormatter.text(from: payloads) else {
            configure(rawPayload: payloads.first?.rawPayload)
            return
        }

        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        textView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - Formatting helpers

    private func setEmpty() {
        let empty = NSAttributedString(string: "(no usage data available)", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        textView.textStorage?.setAttributedString(empty)
        textView.scrollToBeginningOfDocument(nil)
    }

    private func appendHeader(to str: NSMutableAttributedString, _ text: String) {
        // Match `DetailStyles.sectionHeaderFont` so USER/ASSISTANT in
        // Conversation, "Tokens"/"Cost"/"Model" in Tokens, and these
        // Usage sub-object headers all read at the same tone.
        str.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: DetailStyles.sectionHeaderFont,
            .foregroundColor: DetailStyles.sectionHeaderColor,
        ]))
    }

    private func appendLine(to str: NSMutableAttributedString, _ text: String) {
        str.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]))
    }

    private func appendKeyValue(to str: NSMutableAttributedString, key: String, value: String, indent: Int) {
        let prefix = String(repeating: "    ", count: indent)
        // Key tinted in secondary label colour (down from `systemTeal`)
        // — the colourful teal popped against dark-mode sidebars but
        // clashed with the rest of the detail pane's monochrome tone.
        // Bold-ish (.medium) weight still distinguishes key from value
        // without resorting to hue.
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        str.append(NSAttributedString(string: "\(prefix)\(key): ", attributes: keyAttrs))
        str.append(NSAttributedString(string: "\(value)\n", attributes: valueAttrs))
    }

    private func formatVal(_ val: Any?) -> String {
        guard let val else { return "null" }
        if let n = val as? Int { return NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
        if let n = val as? Double { return String(format: "%.2f", n) }
        if let s = val as? String { return s }
        return "\(val)"
    }
}

// MARK: - Detail header resize handle

/// Transparent NSView that covers the empty background of the detail
/// pane's header row. Behaves like the Xcode debug-area divider:
///
///   - **Hover** → shows the resize-up-down cursor.
///   - **Mouse-down + drag** → reports a vertical delta in window
///     coordinates so the owning split-view controller can adjust the
///     detail pane's height constraint.
///
/// Buttons (segmented control, reveal-in-Finder, toggle, separator)
/// are added to the parent *after* this view, so their hit-tests win
/// on the controls themselves — this view only intercepts events on
/// the empty background between them.
@MainActor
final class DetailHeaderResizeHandleView: NSView {

    /// Called when the user presses down on the handle. Owner should
    /// snapshot the current detail height for delta math.
    var onDragBegan: (() -> Void)?
    /// Vertical delta in window coordinates relative to the press
    /// point. Positive = mouse moved up = detail pane should grow.
    var onDragDelta: ((CGFloat) -> Void)?
    /// Called on mouse-up. Owner should snap / commit the final state.
    var onDragEnded: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragOriginY: CGFloat?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Cursor handling uses the standard cursor-rect mechanism (which
    /// is frame-based and reapplied by AppKit on every mouse move)
    /// rather than `cursorUpdate(with:)` (which only fires on tracking
    /// area boundary crossings). The owner — `DetailViewController` —
    /// also installs an arrow cursor-rect on each sibling control in
    /// `viewWillLayout()` so that whenever the mouse is over a
    /// segmented control / button / separator, that view's own
    /// cursor-rect (arrow) wins over the handle's resize-up-down.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        // Hit-test on the *parent* — if there's a button under the
        // press point we let it handle the event (this should be
        // unreachable because z-order puts buttons above us, but it's
        // a safety net for transparent regions of the buttons).
        dragOriginY = event.locationInWindow.y
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOriginY else { return }
        // macOS window coords are bottom-left origin: dragging the
        // mouse UP increases y. Detail pane is bottom-anchored with
        // a variable height, so dragging up should increase the
        // height. Pass through the raw signed delta.
        let delta = event.locationInWindow.y - origin
        onDragDelta?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragOriginY = nil
        onDragEnded?()
    }
}
