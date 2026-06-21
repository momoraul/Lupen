import AppKit

/// 3-pane split view: left sidebar (sessions) | right top (requests) / right bottom (detail).
/// Uses NSSplitViewController with autosave for proportions.
@MainActor
final class DashboardSplitViewController: NSSplitViewController {

    private let store: AppStateStore
    private let settings: AppSettings
    private let sessionListVC: SessionListViewController
    private let turnOutlineVC: TurnOutlineViewController
    private let detailVC: DetailViewController

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
        automaticSessionSelectionEnabled: Bool = true
    ) {
        self.store = store
        self.settings = settings
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
        let rightContainer = NSView()
        let rightVC = NSViewController()
        rightVC.view = rightContainer

        rightVC.addChild(turnOutlineVC)
        rightVC.addChild(detailVC)

        let turnView = turnOutlineVC.view
        let detailView = detailVC.view
        let innerSeparator = NSBox()
        innerSeparator.boxType = .separator

        turnView.translatesAutoresizingMaskIntoConstraints = false
        detailView.translatesAutoresizingMaskIntoConstraints = false
        innerSeparator.translatesAutoresizingMaskIntoConstraints = false

        rightContainer.addSubview(turnView)
        rightContainer.addSubview(innerSeparator)
        rightContainer.addSubview(detailView)

        // Detail pane's variable height — the only thing that animates
        // on toggle. Initial value mirrors the previous default
        // expanded height (≥ `detailExpandedMinHeight`).
        let detailHeight = detailView.heightAnchor.constraint(equalToConstant: savedDetailExpandedHeight)
        detailHeight.isActive = true
        self.detailHeightConstraint = detailHeight

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
            innerSeparator.bottomAnchor.constraint(equalTo: detailView.topAnchor),
            innerSeparator.heightAnchor.constraint(equalToConstant: 1),

            // Detail pane — bottom pinned, height variable.
            detailView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
        ])

        // Outer split: sidebar | right container.
        splitView.isVertical = true
        // Deliberately no `autosaveName` on the outer split — AppKit's
        // built-in path fights the manual sidebar-width restore (see
        // `didRestoreSidebarWidth` and `splitViewDidResizeSubviews`).

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sessionListVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let rightItem = NSSplitViewItem(viewController: rightVC)
        rightItem.minimumThickness = 400
        addSplitViewItem(rightItem)

        // Wire selection: session list -> turn outline -> detail
        sessionListVC.onSessionSelected = { [weak self] session in
            guard let self = self else { return }
            // Selected session jumps the import queue (plan §1
            // priority ②) — no-op once its unit is imported.
            self.store.prioritizeSessionImport?(session.rawSessionId)
            self.turnOutlineVC.showSession(sessionId: session.id)
            self.turnOutlineVC.setHighlightQuery(self.sessionListVC.currentQuery)
        }

        sessionListVC.onHighlightQueryChanged = { [weak self] query in
            self?.turnOutlineVC.setHighlightQuery(query)
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
        case #selector(resumeSelectedSession(_:)),
             #selector(copyResumeCommandForSelectedSession(_:)):
            // Mirror the sidebar's enablement so the main-menu item
            // greys out when there's no session selection — stops the
            // system bell on ⌘R.
            return sessionListVC.validateMenuItem(menuItem)
        default:
            return true
        }
    }

    // MARK: - Sidebar width persistence

    override func viewDidAppear() {
        super.viewDidAppear()
        // Restore once on first appearance. Re-open / key-window cycles
        // shouldn't re-apply the saved width — the user may have
        // dragged the divider and we'd snap back on every reopen.
        guard !didRestoreSidebarWidth else { return }
        defer { didRestoreSidebarWidth = true }
        guard let saved = UserDefaults.standard.object(forKey: Self.sidebarWidthDefaultsKey) as? Double,
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
        UserDefaults.standard.set(Double(width), forKey: Self.sidebarWidthDefaultsKey)
    }
}
