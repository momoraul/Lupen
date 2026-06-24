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
    private var isSetUp = false

    init(
        store: AppStateStore,
        settings: AppSettings,
        autoSelectFirstSessionOnShow: Bool = true,
        openLogsAction: @escaping () -> Void,
        autoSelectAction: @escaping (DashboardSplitViewController) -> Void = { splitVC in
            splitVC.selectFirstSessionIfNeeded()
        }
    ) {
        self.store = store
        self.settings = settings
        self.autoSelectFirstSessionOnShow = autoSelectFirstSessionOnShow
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
                automaticSessionSelectionEnabled: autoSelectFirstSessionOnShow
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
