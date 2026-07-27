import AppKit
import Observation

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {

    private let store: AppStateStore
    private let settings: AppSettings
    private let autoSelectFirstSessionOnShow: Bool
    private let autoSelectAction: (DashboardSplitViewController) -> Void
    /// Opens the Logs window. Owned by AppDelegate so the main-menu
    /// `Window ▸ Logs…` item and the Dashboard toolbar button route
    /// through the same controller instead of constructing two
    /// separate windows.
    private let openLogsAction: () -> Void
    /// Passed through to the split controller, which reads the persisted
    /// pane arrangement from it. Injectable so a test run neither reads nor
    /// writes the developer's real window state.
    private let defaults: UserDefaults
    private let detailWindowFrameAutosaveName: String?
    private var isSetUp = false

    init(
        store: AppStateStore,
        settings: AppSettings,
        autoSelectFirstSessionOnShow: Bool = true,
        defaults: UserDefaults = .standard,
        detailWindowFrameAutosaveName: String? = DetailPaneWindowController.defaultFrameAutosaveName,
        openLogsAction: @escaping () -> Void,
        autoSelectAction: @escaping (DashboardSplitViewController) -> Void = { splitVC in
            splitVC.selectFirstSessionIfNeeded()
        }
    ) {
        self.store = store
        self.settings = settings
        self.autoSelectFirstSessionOnShow = autoSelectFirstSessionOnShow
        self.defaults = defaults
        self.detailWindowFrameAutosaveName = detailWindowFrameAutosaveName
        self.openLogsAction = openLogsAction
        self.autoSelectAction = autoSelectAction
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showDashboard() {
        if !isSetUp {
            let splitVC = DashboardSplitViewController(
                store: store,
                settings: settings,
                automaticSessionSelectionEnabled: autoSelectFirstSessionOnShow,
                defaults: defaults,
                detailWindowFrameAutosaveName: detailWindowFrameAutosaveName
            )
            let window = DashboardWindow()
            window.contentViewController = splitVC
            window.delegate = self
            window.onOpenLogs = { [openLogsAction] in
                openLogsAction()
            }
            self.window = window
            updateWindowTitle()
            startObservingModeTitle()
            isSetUp = true
        }

        // Surface reliably from the status-item click context. The click
        // leaves the app inactive, so `bringToFront()`'s `orderFrontRegardless`
        // is what actually pulls the window forward instead of leaving it
        // hidden behind the frontmost app. See `NSWindow.bringToFront`.
        showWindow(nil)
        window?.bringToFront()

        // Defer auto-selection to the next runloop tick. Running it inline
        // mutates the outline during the window's first layout pass (right
        // after makeKeyAndOrderFront) and trips `_NSDetectedLayoutRecursion`;
        // deferring lets the first layout settle, then claims selection/focus.
        if autoSelectFirstSessionOnShow {
            DispatchQueue.main.async { [weak self] in
                guard let splitVC = self?.window?.contentViewController
                    as? DashboardSplitViewController else { return }
                self?.autoSelectAction(splitVC)
            }
        }

        // Put the detail pane back in its own window if that is where the
        // user left it. Deferred for the same reason as auto-selection —
        // moving views during the window's first layout pass trips
        // `_NSDetectedLayoutRecursion`. Restoring here rather than at
        // launch matters too: Lupen usually launches straight to the menu
        // bar, and a detail window with no dashboard behind it would be
        // baffling.
        DispatchQueue.main.async { [weak self] in
            guard let splitVC = self?.window?.contentViewController
                as? DashboardSplitViewController else { return }
            splitVC.detachCoordinator.restoreIfNeeded()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // App stays .regular — Dock icon persists for easy re-access
    }

    private func startObservingModeTitle() {
        withObservationTracking {
            _ = settings.activeProvider
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateWindowTitle()
                self?.startObservingModeTitle()
            }
        }
    }

    private func updateWindowTitle() {
        window?.title = "Lupen - \(settings.activeProvider.descriptor.displayName)"
    }
}
