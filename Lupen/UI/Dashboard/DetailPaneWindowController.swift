import AppKit

/// Window the detail pane moves into when detached.
///
/// **A standard window, not a panel.** HIG points inspectors at utility
/// panels, and this window does follow the dashboard's selection. But a
/// panel is required to hide itself whenever the app deactivates — and
/// this feature exists precisely so the user can keep a conversation open
/// while working in the terminal. A panel would vanish every time they
/// switched away, which defeats the point. The pane is also primary
/// reading material (transcripts, raw JSON, token tables), not a small
/// property palette, so it takes a normal window like a Notes note.
///
/// The window object outlives its closing (`isReleasedWhenClosed = false`)
/// and is reused for later detaches, matching how every other auxiliary
/// window in the app is managed.
@MainActor
final class DetailPaneWindowController: NSWindowController, NSWindowDelegate {

    private let hostVC: DetachedDetailHostViewController
    private let onWindowWillClose: () -> Void

    /// Also held here, not just on the host view controller. A window's
    /// action chain starts at its first responder — when that is the
    /// window itself (an empty pane has no focusable view), the chain runs
    /// window → window controller → app and never walks the view
    /// hierarchy, so the host's `supplementalTarget` is never consulted.
    /// A window controller is always on that chain.
    private weak var actionResponder: NSResponder?

    /// Reattaching happens inside `windowWillClose`, and AppKit is happy
    /// to re-enter that delegate. The coordinator guards its own state
    /// too; this is the second lock.
    private var isClosing = false

    static let defaultFrameAutosaveName = "LupenDetailWindow"

    /// Injectable because `NSWindow` frame autosave always writes to
    /// `UserDefaults.standard`, whatever suite the rest of the feature was
    /// handed — tests pass nil so a run cannot rearrange the developer's
    /// own windows.
    init(
        actionResponder: NSResponder?,
        frameAutosaveName: String? = defaultFrameAutosaveName,
        onWindowWillClose: @escaping () -> Void
    ) {
        self.hostVC = DetachedDetailHostViewController(actionResponder: actionResponder)
        self.onWindowWillClose = onWindowWillClose
        self.actionResponder = actionResponder

        // 900×700 is a real promotion over the ~260pt the pane gets in the
        // dashboard, and clears the 6-tab segmented control (455pt) plus
        // the trailing button cluster without crowding.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = DetailPaneDetachStrings.windowTitle
        window.isReleasedWhenClosed = false
        // Without this, a user whose system prefers tabs "Always" gets the
        // detached window merged in as a tab of the dashboard — which is
        // exactly the arrangement they were trying to escape.
        window.tabbingMode = .disallowed
        // The pane's root view is transparent; without an explicit
        // background the window renders black in Light Mode.
        window.backgroundColor = .windowBackgroundColor
        // The pane already draws its own hairline under the tab bar.
        window.titlebarSeparatorStyle = .none
        // Header (45pt) + the pane's own expanded floor (240pt).
        window.contentMinSize = NSSize(width: 720, height: 300)
        // Auxiliary, not primary. `.fullScreenPrimary` would let this
        // window go full screen on its own, but it also stops it appearing
        // in the same space as a full-screen dashboard — detaching while
        // the dashboard is full screen would fling the user to another
        // space. Seeing both at once is the entire point of the feature,
        // so the window trades its own full-screen button for the ability
        // to sit alongside one.
        window.collectionBehavior.insert(.fullScreenAuxiliary)

        super.init(window: window)
        window.delegate = self
        window.contentViewController = hostVC

        if let frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
            // `setFrameUsingName` reports whether a saved frame existed, so
            // a first-ever detach gets placed beside the dashboard instead
            // of landing on top of it.
            if !window.setFrameUsingName(frameAutosaveName) {
                positionBesideMainWindow(window)
            }
        } else {
            positionBesideMainWindow(window)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func embed(_ detailVC: DetailViewController) {
        hostVC.embed(detailVC)
        // Set before the window is shown: AppKit reads
        // `initialFirstResponder` at the moment the window becomes key, so
        // assigning it afterwards has no effect on the first activation.
        window?.initialFirstResponder = detailVC.tabBarControl
        applySubtitle(detailVC.contextSubtitle)
        detailVC.onContextSubtitleChanged = { [weak self] subtitle in
            self?.applySubtitle(subtitle)
        }
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let actionResponder, actionResponder.responds(to: action) {
            return actionResponder
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func releaseDetail() {
        hostVC.embeddedDetail?.onContextSubtitleChanged = nil
        hostVC.releaseDetail()
    }

    /// Start keyboard focus on the tab bar so Tab order and VoiceOver both
    /// begin somewhere predictable. `initialFirstResponder` is assigned in
    /// `embed`; this only nudges focus for a window that is already up.
    func focusInitialResponder() {
        hostVC.embeddedDetail?.focusTabBar()
    }

    /// Live context goes in the subtitle, never the title — see
    /// `DetailPaneDetachStrings.windowTitle`.
    private func applySubtitle(_ subtitle: String) {
        window?.subtitle = subtitle
    }

    /// Place the window to the right of the dashboard when there is room
    /// on that screen, since the whole point is seeing the outline and
    /// the detail at the same time. Falls back to a cascade.
    private func positionBesideMainWindow(_ window: NSWindow) {
        // Target the dashboard specifically — `NSApp.windows` also holds
        // the status-item window and any other auxiliary panel.
        let dashboard = NSApp.windows.first {
            $0 !== window && $0.contentViewController is DashboardSplitViewController
        }
        guard let main = dashboard ?? NSApp.mainWindow,
              let screen = main.screen ?? NSScreen.main
        else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        var frame = window.frame
        let gap: CGFloat = 12
        let proposedX = main.frame.maxX + gap
        if proposedX + frame.width <= visible.maxX {
            frame.origin.x = proposedX
            // Clamp both ends: a dashboard sitting low on the screen would
            // otherwise push this window's bottom under the Dock.
            frame.origin.y = max(
                visible.minY,
                min(main.frame.maxY - frame.height, visible.maxY - frame.height)
            )
            window.setFrame(frame, display: false)
        } else {
            // No room alongside — offset instead of stacking exactly.
            // `cascadeTopLeft(from:)` places the window *at* the point it is
            // given, so passing the dashboard's own top-left would hide it
            // completely behind this window, which is the opposite of what
            // detaching is for.
            let offset: CGFloat = 22
            window.cascadeTopLeft(
                from: NSPoint(x: main.frame.minX + offset, y: main.frame.maxY - offset)
            )
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Every close path lands here — the red button, ⌘W, and any
        // programmatic `close()`. `windowShouldClose` would miss the last
        // one, which is why reattaching hangs off this instead.
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        onWindowWillClose()
    }
}
