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

        // 6.14 hardening — the menu-bar click intermittently failed to
        // surface this window (user had to click the Dock icon). Three
        // ordered fixes, each targeting a known failure mode:
        //
        // 1) De-miniaturize first. `makeKeyAndOrderFront` never pulls a
        //    window out of the Dock, so a minimized dashboard made the
        //    status-item click a silent no-op — the exact "Dock click
        //    needed" symptom.
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }

        // 2) Activate BEFORE ordering. A status-item click does not
        //    activate the app, and under macOS 14+ cooperative
        //    activation an order-then-activate sequence can lose the
        //    race: the window order-fronts on its own Space while the
        //    app stays inactive, so nothing visibly happens. Activating
        //    first also lets the system's "switch to a Space with open
        //    windows for the application" behavior kick in when the
        //    dashboard lives on another Space.
        //    NSApp.activate() (macOS 14+ cooperative) does not reliably
        //    activate from status bar button clicks.
        //    activate(ignoringOtherApps:) is deprecated but has no
        //    working replacement for this use case. Used by NetNewsWire,
        //    Rectangle, and other production apps.
        NSApp.activate(ignoringOtherApps: true)

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)

        // 3) Re-front on the next runloop tick, after the cooperative
        //    activation request has settled. When the first order
        //    already won this is a harmless no-op; when it lost the
        //    activation race this is what actually brings the window
        //    forward.
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }

        if autoSelectFirstSessionOnShow,
           let splitVC = window?.contentViewController as? DashboardSplitViewController {
            autoSelectAction(splitVC)
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
