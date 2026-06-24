import AppKit

/// Verify Costs window controller. Opened via Window menu →
/// "Verify Costs…" (⌘⇧V). Same lifecycle as the Diagnostics / Reports
/// windows — `AppDelegate` caches the instance.
@MainActor
final class VerifyCostsWindowController: NSWindowController {

    private let store: AppStateStore

    init(store: AppStateStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ProviderKind.claudeCode.verificationWindowTitle
        window.minSize = NSSize(width: 720, height: 420)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let vc = VerifyCostsViewController(store: store)
        window.contentViewController = vc
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — code-only window")
    }

    func show() {
        window?.title = store.activeProvider.verificationWindowTitle
        showWindow(nil)
        window?.bringToFront()
    }
}
