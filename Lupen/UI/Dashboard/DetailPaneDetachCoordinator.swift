import AppKit

/// The dashboard side of detach/reattach. Implemented by
/// `DashboardSplitViewController`, which owns the constraints the pane is
/// bound with — the view surgery has to live where that geometry lives.
@MainActor
protocol DetailPaneDetachHost: AnyObject {
    var detachableDetailViewController: DetailViewController { get }
    /// Responder that owns the detail pane's button and menu actions.
    /// The detached window inserts this into its own responder chain so
    /// Export / Find / tab-switch keep reaching their real target instead
    /// of dying at the window boundary.
    var detachActionResponder: NSResponder? { get }
    func detachDetailFromDashboard()
    func reattachDetailToDashboard()
}

/// Strings and glyphs shared by the detach button, the placeholder strip
/// and the menu item, so the three surfaces can never drift apart.
///
/// **Wording** follows Apple's own vocabulary rather than invented terms:
/// Finder ships `Open in New Window` and `Put Back`, Music has
/// `Open Now Playing in New Window`. "Detach" is a developer word.
enum DetailPaneDetachStrings {

    static let detachMenuTitle = "Open Detail in New Window"
    static let reattachMenuTitle = "Put Detail Back in Main Window"

    static let detachTooltip = "Open Detail in New Window (⌃⌘Y)"
    /// Shown on the button inside the detached window, where closing the
    /// window is the reattach gesture.
    static let putBackTooltip = "Put Detail Back in Main Window (⌘W)"
    /// Shown on the dashboard's placeholder strip. Deliberately *not* the
    /// ⌘W variant: in the dashboard that chord closes the dashboard
    /// itself, so advertising it there would strand the user with only the
    /// detached window. ⌃⌘Y works from either window.
    static let putBackFromDashboardTooltip = "Put Detail Back in Main Window (⌃⌘Y)"

    static let detachAccessibilityLabel = detachMenuTitle
    static let putBackAccessibilityLabel = reattachMenuTitle

    static let detachedAnnouncement = "Detail opened in a new window"
    static let reattachedAnnouncement = "Detail returned to the main window"

    /// Window that the pane moves into. Fixed title with the live context
    /// in the subtitle — a title that changes on every click would make
    /// the Window menu entry jump around, and HIG asks for short, stable
    /// window titles that omit the app name.
    static let windowTitle = "Detail"
    static let noSelectionSubtitle = "No Selection"

    /// Cap for the subtitle. `TurnPreview` defaults to 300 characters,
    /// which is far past what a title bar can show.
    static let subtitleMaxLength = 80

    /// "This content becomes its own window" — a macOS window (traffic
    /// lights and all) lifting off a plain rectangle. Deliberately not an
    /// expand/collapse arrow pair: Apple tags those symbols with
    /// `fullscreen` / `maximize` keywords, and users read them that way.
    static func detachSymbol(tint: NSColor) -> NSImage? {
        symbol(
            preferred: "macwindow.on.rectangle",
            fallback: "macwindow",
            tint: tint,
            accessibilityDescription: detachAccessibilityLabel
        )
    }

    /// Inverse action, shown only inside the detached window and on the
    /// placeholder strip. The "fullscreen exit" reading these inward
    /// arrows can carry is closed off by context: neither surface is ever
    /// full screen.
    static func reattachSymbol(tint: NSColor) -> NSImage? {
        symbol(
            preferred: "arrow.down.right.and.arrow.up.left.rectangle",
            fallback: "pip.exit",
            tint: tint,
            accessibilityDescription: putBackAccessibilityLabel
        )
    }

    /// Colour is baked in through `paletteColors` for the same reason as
    /// `DetailViewController.applyTogglePaneSymbol()`:
    /// `.accessoryBarAction` + `isBordered` ignores `contentTintColor` and
    /// substitutes AppKit's own tint.
    ///
    /// **Point size is 13, not the toggle's 16.** Matching point sizes does
    /// not match rendered sizes — these glyphs are wider than
    /// `inset.filled.bottomthird.square`, and at 16pt they render 24×20
    /// against the toggle's 19×18, leaving 2pt of breathing room inside the
    /// shared 28pt button instead of 4.5pt. 13pt brings the rendered width
    /// back in line so the two neighbouring controls read as a pair.
    private static func symbol(
        preferred: String,
        fallback: String,
        tint: NSColor,
        accessibilityDescription: String
    ) -> NSImage? {
        let name = NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil
            ? preferred
            : fallback
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        return NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(sizeConfig.applying(paletteConfig))
    }
}

/// Drives the detail pane between the dashboard and its own window.
///
/// Owns the window controller and the persisted flag; delegates the view
/// surgery to the host. Every path in and out of the detached state goes
/// through `detach()` / `reattach()` so the window-close route and the
/// button route can never diverge.
@MainActor
final class DetailPaneDetachCoordinator {

    enum State {
        case attached
        case detached
    }

    private(set) var state: State = .attached

    /// Reattaching runs from inside `windowWillClose`, which AppKit can
    /// re-enter. The guard makes both entry points idempotent.
    private var isTransitioning = false

    /// Weak: the host owns this coordinator.
    private weak var host: DetailPaneDetachHost?
    private var windowController: DetailPaneWindowController?
    private let defaults: UserDefaults
    private let frameAutosaveName: String?

    /// Window placement is left to `setFrameAutosaveName`; this only
    /// records *whether* the pane was detached, so reopening the
    /// dashboard can restore the arrangement the user left behind.
    static let detachedDefaultsKey = "Lupen.DetailWindowDetached"

    /// - Parameter frameAutosaveName: nil disables window-frame autosave.
    ///   Tests pass nil — frame autosave bypasses the injected `defaults`
    ///   and always writes to `UserDefaults.standard`.
    init(
        host: DetailPaneDetachHost,
        defaults: UserDefaults = .standard,
        frameAutosaveName: String? = DetailPaneWindowController.defaultFrameAutosaveName
    ) {
        self.host = host
        self.defaults = defaults
        self.frameAutosaveName = frameAutosaveName
    }

    /// Whether the pane was detached when the dashboard last closed.
    /// Read by the dashboard on show — deliberately not applied at app
    /// launch, since Lupen usually launches without opening the
    /// dashboard at all and a lone child window would be baffling.
    var shouldRestoreDetached: Bool {
        defaults.bool(forKey: Self.detachedDefaultsKey)
    }

    func toggle() {
        switch state {
        case .attached: detach()
        case .detached: reattach()
        }
    }

    /// - Parameter activating: whether the new window should take key
    ///   focus. True when the user asked for it. False when restoring a
    ///   remembered arrangement — the user clicked to open the *dashboard*,
    ///   and having this window jump in front of it and steal the keyboard
    ///   would send their next keystrokes somewhere they never looked.
    func detach(activating: Bool = true) {
        guard state == .attached, !isTransitioning, let host else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        host.detachDetailFromDashboard()

        let detailVC = host.detachableDetailViewController
        let controller = windowController ?? makeWindowController()
        windowController = controller
        controller.embed(detailVC)
        detailVC.setDetached(true)

        if activating {
            controller.showWindow(nil)
            controller.window?.bringToFront()
            controller.focusInitialResponder()
        } else {
            controller.window?.orderFront(nil)
        }

        state = .detached
        defaults.set(true, forKey: Self.detachedDefaultsKey)
        announce(DetailPaneDetachStrings.detachedAnnouncement)
    }

    /// - Parameter fromWindowClose: true when called from the window's
    ///   own `windowWillClose`, where asking the window to close again
    ///   would re-enter the delegate.
    func reattach(fromWindowClose: Bool = false) {
        guard state == .detached, !isTransitioning, let host else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        let detailVC = host.detachableDetailViewController
        windowController?.releaseDetail()
        detailVC.setDetached(false)
        host.reattachDetailToDashboard()

        if !fromWindowClose {
            windowController?.window?.close()
        }

        state = .attached
        defaults.set(false, forKey: Self.detachedDefaultsKey)
        announce(DetailPaneDetachStrings.reattachedAnnouncement)

        // Focus follows the content home. The user's attention was on the
        // detail content, so handing focus back to its tab bar keeps the
        // context; dumping it on the turn outline would not.
        // `isVisible` matters: closing a window does not tear down its view
        // hierarchy, so `view.window` still points at a dashboard the user
        // closed. Without the check, putting the pane back would resurrect
        // a window they deliberately put away.
        if let window = detailVC.view.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            detailVC.focusTabBar()
        }
    }

    /// Restore the arrangement the user left, called when the dashboard
    /// is shown rather than at launch.
    func restoreIfNeeded() {
        guard shouldRestoreDetached, state == .attached else { return }
        detach(activating: false)
    }

    private func makeWindowController() -> DetailPaneWindowController {
        DetailPaneWindowController(
            actionResponder: host?.detachActionResponder,
            frameAutosaveName: frameAutosaveName,
            onWindowWillClose: { [weak self] in
                self?.reattach(fromWindowClose: true)
            }
        )
    }

    /// VoiceOver users get no visual cue that content moved to another
    /// window, so state changes are announced explicitly.
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
