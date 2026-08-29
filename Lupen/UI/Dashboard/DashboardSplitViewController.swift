import AppKit

/// 3-pane split view: left sidebar (sessions) | right top (requests) / right bottom (detail).
/// Uses NSSplitViewController with autosave for proportions.
@MainActor
final class DashboardSplitViewController: NSSplitViewController {

    private let store: AppStateStore
    private let settings: AppSettings
    private let defaults: UserDefaults
    private let sessionListVC: SessionListViewController
    private let turnOutlineVC: TurnOutlineViewController
    private let detailVC: DetailViewController

    /// Right-pane container and its view controller. Stored rather than
    /// `viewDidLoad` locals because reattaching the detail pane after it
    /// has lived in its own window needs an `addChild` target and a
    /// superview to put the view back into.
    private let rightContainerVC = NSViewController()
    private let rightContainer = NSView()

    /// 1pt hairline between the turn outline and whatever sits below it —
    /// the detail pane while attached, the "in a separate window" strip
    /// while detached. Keeping the separator anchored in BOTH states is
    /// what stops the turn outline from silently collapsing to zero
    /// height when the detail view leaves the hierarchy.
    private let innerSeparator = NSBox()

    /// Shown in the detail pane's place while it lives in its own window.
    /// Sized to `detailMinimizedHeight` so the geometry matches the
    /// already-tuned minimized state, and carries a Put Back button so
    /// there is always a visible way home even when the detached window
    /// is behind another app (HIG: provide a clear path back).
    private lazy var detachedStrip = DetachedDetailPlaceholderView { [weak self] in
        self?.detachCoordinator.reattach()
    }

    /// Detach/reattach state machine. Owns the separate window; calls
    /// back into this controller for the actual view surgery.
    private(set) lazy var detachCoordinator = DetailPaneDetachCoordinator(
        host: self,
        defaults: defaults,
        frameAutosaveName: detailWindowFrameAutosaveName
    )

    /// nil disables the detached window's frame autosave (tests only —
    /// autosave writes to `UserDefaults.standard` regardless of `defaults`).
    private let detailWindowFrameAutosaveName: String?

    /// Constraints binding the detail pane into the right container, and
    /// the strip that replaces it. Held as objects and flipped via
    /// `isActive` rather than rebuilt — AppKit does not revive the
    /// cross-view constraints it drops on `removeFromSuperview()`, and
    /// rebuilding them on every round trip accumulates duplicates.
    private var attachedDetailConstraints: [NSLayoutConstraint] = []
    private var detachedStripConstraints: [NSLayoutConstraint] = []

    /// Auto-Layout height constraint on the detail pane. Toggle
    /// minimize/expand is implemented as
    /// `constraint.animator().constant = ...` which gives a smooth
    /// 0.25s slide. The turn-outline pane's top edge is anchored to
    /// the right container's top, so it remains absolutely stable
    /// during the animation — only its bottom edge follows the
    /// detail pane's top.
    ///
    /// We dropped the inner `NSSplitViewController` (and the
    /// `setPosition`/`animator()` path that came with it) because
    /// `NSSplitViewController` is Auto-Layout-driven internally and
    /// applies divider moves in two passes (an immediate layout
    /// followed by the animator), which surfaced as a transient
    /// jump in the turn-outline pane's frame on every toggle.
    private var detailHeightConstraint: NSLayoutConstraint?

    /// Height the detail pane shrinks to when "minimized" — enough
    /// for the tab bar + toggle button row, nothing more.
    static let detailMinimizedHeight: CGFloat = 38

    /// Minimum height when expanded. Stops the user from manually
    /// dragging the divider below a useful size — 38pt is the
    /// explicit "minimized" state, reached only via the toggle
    /// button. Between 38 and this the pane would be neither usable
    /// nor clearly "minimized", so we disallow that range.
    ///
    /// 240pt is sized against the empty-state composition: tab bar
    /// (~38pt header strip) + the vertically-centred
    /// icon+title+subtitle stack (~90pt content) + a breathing
    /// margin. Below ~200pt the empty-state stack starts touching
    /// the header strip; 150pt was the previous value and produced
    /// the "cramped No Selection" appearance users reported.
    static let detailExpandedMinHeight: CGFloat = 240

    /// Height to restore when un-minimizing (updated each time the
    /// user expands manually via the divider, so the toggle remembers
    /// their last preferred height).
    private var savedDetailExpandedHeight: CGFloat = 260
    private var isDetailMinimized = false

    /// User-defaults key for the persisted sidebar width.
    /// `splitView.autosaveName` is unreliable when a sidebar
    /// `NSSplitViewItem` carries `minimumThickness` / `maximumThickness`
    /// constraints — Apple's own apps work around it the same way. We
    /// snapshot the width on every resize and restore it on first
    /// appearance.
    private static let sidebarWidthDefaultsKey = "Lupen.DashboardSidebarWidth"

    /// Guard against the initial-layout `splitViewDidResizeSubviews`
    /// clobbering the just-read saved width. AppKit fires that
    /// delegate callback during the first layout pass *before*
    /// `viewDidAppear` runs, so without this gate we'd persist the
    /// default width, then try to restore from the newly-wiped value.
    private var didRestoreSidebarWidth = false

    init(
        store: AppStateStore,
        settings: AppSettings,
        automaticSessionSelectionEnabled: Bool = true,
        defaults: UserDefaults = .standard,
        detailWindowFrameAutosaveName: String? = DetailPaneWindowController.defaultFrameAutosaveName
    ) {
        self.store = store
        self.settings = settings
        self.defaults = defaults
        self.detailWindowFrameAutosaveName = detailWindowFrameAutosaveName
        self.sessionListVC = SessionListViewController(
            store: store,
            settings: settings,
            automaticSessionSelectionEnabled: automaticSessionSelectionEnabled
        )
        self.turnOutlineVC = TurnOutlineViewController(store: store)
        self.detailVC = DetailViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Right pane: a plain Auto-Layout container that hosts the
        // turn outline (top, top-anchored to the container's top) and
        // the detail pane (bottom-anchored, with a variable height
        // constraint). A separator hairline sits between them. This
        // replaces the previous inner `NSSplitViewController` so that
        // toggle animation is driven by a single height-constraint
        // change — no `setPosition` two-pass layout, no transient
        // turn-outline frame jumps.
        rightContainerVC.view = rightContainer

        rightContainerVC.addChild(turnOutlineVC)
        rightContainerVC.addChild(detailVC)

        let turnView = turnOutlineVC.view
        let detailView = detailVC.view
        innerSeparator.boxType = .separator

        turnView.translatesAutoresizingMaskIntoConstraints = false
        detailView.translatesAutoresizingMaskIntoConstraints = false
        innerSeparator.translatesAutoresizingMaskIntoConstraints = false
        detachedStrip.translatesAutoresizingMaskIntoConstraints = false

        rightContainer.addSubview(turnView)
        rightContainer.addSubview(innerSeparator)
        rightContainer.addSubview(detailView)

        // Detail pane's variable height — the only thing that animates
        // on toggle. Initial value mirrors the previous default
        // expanded height (≥ `detailExpandedMinHeight`).
        //
        // This one is self-referencing (a constant on `detailView`
        // itself), so unlike the sibling constraints below AppKit does
        // NOT drop it when the view leaves the container — detaching
        // must deactivate it explicitly or the pane stays pinned to this
        // height inside its own window.
        let detailHeight = detailView.heightAnchor.constraint(equalToConstant: savedDetailExpandedHeight)
        detailHeight.isActive = true
        self.detailHeightConstraint = detailHeight

        // Always-on geometry: the turn outline and the hairline. The
        // outline's bottom stops at the separator in BOTH attach states,
        // so its anchor chain never breaks — only what sits *below* the
        // separator is swapped.
        NSLayoutConstraint.activate([
            // Turn outline — top pinned to container top (this is the
            // edge that must stay stable during the toggle animation).
            // Bottom pinned to the inner separator's top, which in turn
            // sits just above the detail pane.
            turnView.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            turnView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            turnView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            turnView.bottomAnchor.constraint(equalTo: innerSeparator.topAnchor),

            // Inner separator — 1pt hairline between the two panes.
            innerSeparator.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            innerSeparator.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            innerSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Attached-state geometry — everything that mentions `detailView`.
        // Built once and toggled, never rebuilt (see the property docs).
        attachedDetailConstraints = [
            innerSeparator.bottomAnchor.constraint(equalTo: detailView.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(attachedDetailConstraints)

        // Detached-state geometry — the strip takes the detail pane's
        // place under the separator. Created eagerly so detaching is a
        // pure activation flip; the strip is only added as a subview
        // while detached.
        detachedStripConstraints = [
            innerSeparator.bottomAnchor.constraint(equalTo: detachedStrip.topAnchor),
            detachedStrip.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            detachedStrip.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            detachedStrip.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
            detachedStrip.heightAnchor.constraint(equalToConstant: Self.detailMinimizedHeight),
        ]

        // Outer split: sidebar | right container.
        splitView.isVertical = true
        // Deliberately no `autosaveName` on the outer split — AppKit's
        // built-in path fights the manual sidebar-width restore (see
        // `didRestoreSidebarWidth` and `splitViewDidResizeSubviews`).

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sessionListVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = false

        let rightItem = NSSplitViewItem(viewController: rightContainerVC)
        rightItem.minimumThickness = 400

        // Wire selection: session list -> turn outline -> detail
        sessionListVC.onSessionSelected = { [weak self] session in
            guard let self = self else { return }
            // Selected session jumps the import queue (plan §1
            // priority ②) — no-op once its unit is imported.
            self.store.prioritizeSessionImport?(session.rawSessionId)
            self.turnOutlineVC.showSession(sessionId: session.id)
            self.turnOutlineVC.setHighlightQuery(
                self.sessionListVC.currentQuery,
                scope: self.sessionListVC.currentSearchTextScope
            )
        }

        sessionListVC.onHighlightQueryChanged = { [weak self] query, scope in
            self?.turnOutlineVC.setHighlightQuery(query, scope: scope)
        }

        sessionListVC.onSelectionCleared = { [weak self] in
            self?.turnOutlineVC.clear()
            self?.detailVC.clearSelection()
        }

        turnOutlineVC.onStepSelected = { [weak self] step, turn in
            self?.detailVC.showStep(step, in: turn)
        }

        turnOutlineVC.onTurnSelected = { [weak self] turn, displayCost, displayTokens in
            self?.detailVC.showTurn(turn, displayCost: displayCost, displayTokens: displayTokens)
        }

        turnOutlineVC.onSkillGroupSelected = { [weak self] group, displayCost, displayTokens in
            self?.detailVC.showSkillGroup(group, displayCost: displayCost, displayTokens: displayTokens)
        }

        turnOutlineVC.onSelectionCleared = { [weak self] in
            self?.detailVC.clearSelection()
        }

        detailVC.onTogglePaneRequested = { [weak self] in
            self?.toggleDetailPane(nil)
        }

        // Drag-to-resize on the detail header background. Owner
        // captures the height at drag-start and updates the
        // constraint live during drag.
        detailVC.onHeaderResizeBegan = { [weak self] in
            self?.handleResizeBegan()
        }
        detailVC.onHeaderResizeDragged = { [weak self] delta in
            self?.handleResizeDragged(delta: delta)
        }
        detailVC.onHeaderResizeEnded = { [weak self] in
            self?.handleResizeEnded()
        }

        detailVC.onDetachRequested = { [weak self] in
            self?.detachCoordinator.toggle()
        }

        // Add split items LAST. `addSplitViewItem(sidebarItem)` loads
        // sessionListVC.view, which triggers its first `reloadData` — and that
        // reload can auto-select a session and invoke `onSessionSelected`.
        // Wiring the callbacks above FIRST ensures that early auto-select
        // actually drives the turn outline; otherwise `onSessionSelected` is
        // still nil at that point, so the row gets selected but the turn list
        // never renders until the user clicks a *different* session.
        addSplitViewItem(sidebarItem)
        addSplitViewItem(rightItem)
    }

    // MARK: - Drag-to-resize handlers

    /// Detail-pane height captured at the moment the user pressed on
    /// the header resize handle. Live drag adds the cumulative
    /// `delta` to this value to compute the new height — using a
    /// snapshot avoids drift from fractional rounding across many
    /// `mouseDragged` events.
    private var resizeStartHeight: CGFloat?

    private func handleResizeBegan() {
        guard let constraint = detailHeightConstraint else { return }
        resizeStartHeight = constraint.constant
        // Reveal the content for the duration of the drag, regardless
        // of whether the pane started in minimized or expanded state.
        // The end handler reconciles the final state.
        if isDetailMinimized {
            detailVC.setMinimized(false)
        }
    }

    private func handleResizeDragged(delta: CGFloat) {
        guard let constraint = detailHeightConstraint,
              let start = resizeStartHeight else { return }

        // Compute clamp window from the current right-pane container
        // so the user can never push the turn outline below 140pt or
        // the detail pane below the minimized floor.
        let containerHeight = view.bounds.height  // outer split's right pane
        let turnOutlineMin: CGFloat = 140
        let separator: CGFloat = 1
        let maxHeight = max(Self.detailMinimizedHeight, containerHeight - turnOutlineMin - separator)
        let proposed = start + delta
        constraint.constant = min(maxHeight, max(Self.detailMinimizedHeight, proposed))
    }

    private func handleResizeEnded() {
        defer { resizeStartHeight = nil }
        guard let constraint = detailHeightConstraint else { return }
        let final = constraint.constant
        // Snap zone — anything in the gap between minimized (38pt)
        // and the expanded floor (240pt) snaps to the nearer endpoint
        // so a manual drag never leaves the pane in the awkward
        // "neither minimized nor usable" range.
        let snapMidpoint = (Self.detailMinimizedHeight + Self.detailExpandedMinHeight) / 2
        let snapTarget: CGFloat
        if final < Self.detailExpandedMinHeight {
            snapTarget = final < snapMidpoint
                ? Self.detailMinimizedHeight
                : Self.detailExpandedMinHeight
        } else {
            snapTarget = final
        }

        let willMinimize = snapTarget == Self.detailMinimizedHeight
        isDetailMinimized = willMinimize
        if !willMinimize {
            savedDetailExpandedHeight = snapTarget
        }

        if abs(snapTarget - final) > 0.5 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                constraint.animator().constant = snapTarget
                view.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.detailVC.setMinimized(willMinimize)
                }
            })
        } else {
            detailVC.setMinimized(willMinimize)
        }
    }

    /// Minimize / expand the detail pane, Xcode debug-console style.
    ///
    /// The pane doesn't fully collapse — it shrinks to the header row
    /// height (`detailMinimizedHeight`) so the toggle button remains
    /// visible and clickable. Re-pressing the button restores the
    /// previously remembered expanded height.
    ///
    /// Wired via:
    ///   - `DetailViewController.togglePaneButton`
    ///     (`inset.filled.bottomthird.square` SF Symbol in the pane
    ///     header)
    ///   - Window menu "Toggle Detail Pane" (⇧⌘Y) — fallback entry
    ///     point; `target = nil` routes through the responder chain
    ///     and lands here.
    ///
    /// **Animation** — animates the detail pane's height constraint
    /// over 0.25s (Xcode debug-area cadence) with an `easeInEaseOut`
    /// curve. Because the turn outline is anchored to the right
    /// container's top and the inner separator's top (which in turn
    /// sits above the detail pane), the turn outline's top edge is
    /// absolutely stable across the entire animation — only its
    /// bottom edge tracks the detail pane's top as it slides.
    ///
    /// `view.layoutSubtreeIfNeeded()` inside the animation block is
    /// what gives Auto Layout a chance to drive the constraint
    /// change as a smooth animation; without it the constant change
    /// would apply on the next layout pass, snapping instantly.
    @objc func toggleDetailPane(_ sender: Any?) {
        // Minimize/expand is meaningless while the pane lives in its own
        // window — and the height constraint it drives is deactivated,
        // so without this guard the call would silently do nothing while
        // still flipping `isDetailMinimized` out of sync.
        guard detachCoordinator.state == .attached else { return }
        guard let constraint = detailHeightConstraint else { return }

        let willMinimize = !isDetailMinimized
        let targetHeight: CGFloat
        if willMinimize {
            // Capture the current height so the next expand restores
            // to where the user left it.
            savedDetailExpandedHeight = max(
                Self.detailExpandedMinHeight,
                constraint.constant
            )
            targetHeight = Self.detailMinimizedHeight
        } else {
            targetHeight = max(Self.detailExpandedMinHeight, savedDetailExpandedHeight)
        }

        // Update state + content visibility in lock-step with the
        // animation start. Header-row visibility (segmented control,
        // toggle button, separator) flows through `setMinimized`.
        isDetailMinimized = willMinimize
        detailVC.setMinimized(willMinimize)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            constraint.animator().constant = targetHeight
            view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Detach / reattach view surgery

    /// Minimized flag captured at detach time. A window has no
    /// "collapsed to a header strip" state, so the pane is normalized to
    /// expanded while detached and this restores what the user had.
    private var wasMinimizedBeforeDetach = false

    /// Select the first session if nothing is selected yet.
    func selectFirstSessionIfNeeded() {
        sessionListVC.selectFirstSessionIfNeeded()
    }

    /// Edit menu → Find (⌘F) entry point when focus is anywhere
    /// *outside* the sidebar.
    ///
    /// The sidebar's search field lives inside `sessionListVC`, but
    /// when the user has focus on the Turn outline or the detail pane,
    /// the responder chain goes detail/turn VC → right inner split VC
    /// → this outer split VC → window — **never** through
    /// `sessionListVC`. If only `SessionListViewController` implemented
    /// `focusSearchField(_:)`, the ⌘F menu item would be disabled
    /// whenever focus wasn't already in the sidebar, which is the
    /// opposite of useful.
    ///
    /// So we also implement the selector here and forward to the
    /// sidebar. `NSSplitViewController` is always in the responder
    /// chain of any pane it owns, so this becomes the reliable
    /// landing point for Find no matter where focus is.
    @objc func focusSearchField(_ sender: Any?) {
        sessionListVC.focusSearchField(sender)
    }

    @objc func navigateToNextMatch(_ sender: Any?) {
        turnOutlineVC.navigateToNextMatch(sender)
    }

    @objc func navigateToPreviousMatch(_ sender: Any?) {
        turnOutlineVC.navigateToPreviousMatch(sender)
    }

    // MARK: - File menu (turn analysis export, forwarded to the outline)

    /// ⇧⌘E / File → "Export Turn Analysis…". Same reasoning as
    /// `resumeSelectedSession(_:)`: the outline VC is only in the responder
    /// chain while focus sits inside it, but the split view controller always
    /// is, so this is the reliable landing point. With no turn selected the
    /// outline's own guard makes it a no-op; `validateMenuItem` below greys the
    /// item out first so the user sees that up front.
    @objc func exportTurnAnalysis(_ sender: Any?) {
        turnOutlineVC.exportTurnAnalysis(sender)
    }

    @objc func copyTurnAnalysis(_ sender: Any?) {
        turnOutlineVC.copyTurnAnalysis(sender)
    }

    // MARK: - Session menu (forwarded to sidebar)

    /// ⌘R / Session → "Resume in Claude Code". The real work lives on
    /// `SessionListViewController`; we only need to be here because when
    /// focus is in the Turn outline or the detail pane, the responder
    /// chain doesn't pass through the sidebar VC. The split view
    /// controller *is* always in the chain for any pane it owns, so
    /// this becomes the reliable landing point for the shortcut.
    @objc func resumeSelectedSession(_ sender: Any?) {
        sessionListVC.resumeSelectedSession(sender)
    }

    /// ⇧⌘C / Session → "Copy Resume Command". Mirrors the reasoning on
    /// `resumeSelectedSession(_:)`.
    @objc func copyResumeCommandForSelectedSession(_ sender: Any?) {
        sessionListVC.copyResumeCommandForSelectedSession(sender)
    }

    // MARK: - View menu (sidebar layout)

    /// Wired from View → "Group Sessions by Project" (⌘1) through the
    /// responder chain. Setting the layout fires `AppSettings` observation,
    /// which the sidebar VC catches and rebuilds against.
    @objc func setSessionListLayoutGrouped(_ sender: Any?) {
        settings.sessionListLayout = .grouped
    }

    /// Wired from View → "Flat Session List" (⌘2).
    @objc func setSessionListLayoutFlat(_ sender: Any?) {
        settings.sessionListLayout = .flat
    }

    /// Wired from View → "Open Detail in New Window" (⌃⌘Y), and from the
    /// detach button in the pane header.
    @objc func toggleDetailPaneDetachment(_ sender: Any?) {
        detachCoordinator.toggle()
    }

    /// View → "Show Only Matching Turns" (⌥⌘F). Narrows the turn outline
    /// to the turns the current search matched.
    @objc func toggleMatchingTurnsOnly(_ sender: Any?) {
        turnOutlineVC.setShowsMatchesOnly(!turnOutlineVC.showsMatchesOnly)
    }

    /// NSMenuItem validation — check the active layout's menu item and
    /// leave the other one unchecked. Returning `true` keeps both items
    /// enabled so the user can always flip back. NSResponder already
    /// provides a default `validateMenuItem` via its NSMenuItemValidation
    /// conformance, so this is a regular declaration (not `override`).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setSessionListLayoutGrouped(_:)):
            menuItem.state = (settings.sessionListLayout == .grouped) ? .on : .off
            return true
        case #selector(setSessionListLayoutFlat(_:)):
            menuItem.state = (settings.sessionListLayout == .flat) ? .on : .off
            return true
        case #selector(toggleDetailPaneDetachment(_:)):
            // One item, two directions — Finder pairs "Open in New
            // Window" with "Put Back" the same way.
            menuItem.title = detachCoordinator.state == .detached
                ? DetailPaneDetachStrings.reattachMenuTitle
                : DetailPaneDetachStrings.detachMenuTitle
            return true
        case #selector(toggleDetailPane(_:)):
            // Minimize/expand has no meaning while the pane is a window.
            return detachCoordinator.state == .attached
        case #selector(toggleMatchingTurnsOnly(_:)):
            menuItem.state = turnOutlineVC.showsMatchesOnly ? .on : .off
            // Nothing to narrow to without a query.
            return !sessionListVC.currentQuery.isEmpty
        case #selector(resumeSelectedSession(_:)),
             #selector(copyResumeCommandForSelectedSession(_:)):
            // Mirror the sidebar's enablement so the main-menu item
            // greys out when there's no session selection — stops the
            // system bell on ⌘R.
            return sessionListVC.validateMenuItem(menuItem)
        case #selector(exportTurnAnalysis(_:)),
             #selector(copyTurnAnalysis(_:)):
            // Grey out rather than ringing the system bell on ⇧⌘E when no row
            // is selected. `nil` sender means "use the selection", which is
            // exactly what the menu path does.
            return turnOutlineVC.canExportTurnAnalysis(nil)
        default:
            return true
        }
    }

    // MARK: - Test seams (detach/reattach layout regressions)

    var rightPaneContainerForTesting: NSView { rightContainer }
    var rightPaneViewControllerForTesting: NSViewController { rightContainerVC }
    var turnOutlineViewForTesting: NSView { turnOutlineVC.view }
    var detailHeightConstraintForTesting: NSLayoutConstraint? { detailHeightConstraint }

    // MARK: - Sidebar width persistence

    override func viewDidAppear() {
        super.viewDidAppear()
        // Restore once on first appearance. Re-open / key-window cycles
        // shouldn't re-apply the saved width — the user may have
        // dragged the divider and we'd snap back on every reopen.
        guard !didRestoreSidebarWidth else { return }
        defer { didRestoreSidebarWidth = true }
        guard let saved = defaults.object(forKey: Self.sidebarWidthDefaultsKey) as? Double,
              saved.isFinite, saved > 0
        else { return }
        // setPosition is clamped against splitViewItem min/max thickness, so
        // a stale value larger/smaller than the current bounds is harmless.
        splitView.setPosition(CGFloat(saved), ofDividerAt: 0)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // Ignore AppKit's initial layout pass — it fires this delegate
        // before `viewDidAppear` has had a chance to restore the saved
        // width, so persisting here would overwrite the stored value
        // with whatever the default layout produced.
        guard didRestoreSidebarWidth else { return }
        guard splitView.subviews.indices.contains(0) else { return }
        let width = splitView.subviews[0].bounds.width
        guard width > 0 else { return }
        defaults.set(Double(width), forKey: Self.sidebarWidthDefaultsKey)
    }
}

// MARK: - DetailPaneDetachHost

extension DashboardSplitViewController: DetailPaneDetachHost {

    var detachableDetailViewController: DetailViewController { detailVC }

    /// The detached window splices this back into its responder chain so
    /// Export Turn Analysis, Find, and the layout menu items keep
    /// resolving to their real target instead of dying at the window edge.
    var detachActionResponder: NSResponder? { self }

    /// Take the detail pane out of the dashboard so it can be installed
    /// in its own window.
    ///
    /// Order matters. The height constraint goes first because it is
    /// self-referencing and would otherwise survive the move and pin the
    /// pane to its dashboard height inside the window. The strip is
    /// installed *before* the view leaves, so the inner separator never
    /// spends a layout pass without a bottom anchor — losing it collapses
    /// the turn outline to zero height, and AppKit reports no ambiguity
    /// for it, so the failure is completely silent.
    func detachDetailFromDashboard() {
        if let constraint = detailHeightConstraint, !isDetailMinimized {
            savedDetailExpandedHeight = max(Self.detailExpandedMinHeight, constraint.constant)
        }
        wasMinimizedBeforeDetach = isDetailMinimized
        if isDetailMinimized {
            isDetailMinimized = false
            detailVC.setMinimized(false)
        }

        detailHeightConstraint?.isActive = false
        NSLayoutConstraint.deactivate(attachedDetailConstraints)

        if detachedStrip.superview == nil {
            rightContainer.addSubview(detachedStrip)
        }
        NSLayoutConstraint.activate(detachedStripConstraints)

        detailVC.removeFromParent()
        detailVC.view.removeFromSuperview()
    }

    /// Put the detail pane back under the turn outline, restoring the
    /// height and minimized state it had when it left.
    ///
    /// Reactivates the *same* constraint objects rather than building new
    /// ones — AppKit does not revive the ones it dropped, and rebuilding
    /// per round trip accumulates duplicates.
    func reattachDetailToDashboard() {
        NSLayoutConstraint.deactivate(detachedStripConstraints)
        detachedStrip.removeFromSuperview()

        rightContainerVC.addChild(detailVC)
        let detailView = detailVC.view
        // Insurance: any window hosting path can flip this back on.
        detailView.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(detailView)

        NSLayoutConstraint.activate(attachedDetailConstraints)
        detailHeightConstraint?.constant = wasMinimizedBeforeDetach
            ? Self.detailMinimizedHeight
            : max(Self.detailExpandedMinHeight, savedDetailExpandedHeight)
        detailHeightConstraint?.isActive = true

        isDetailMinimized = wasMinimizedBeforeDetach
        detailVC.setMinimized(wasMinimizedBeforeDetach)
        rightContainer.layoutSubtreeIfNeeded()
    }
}
