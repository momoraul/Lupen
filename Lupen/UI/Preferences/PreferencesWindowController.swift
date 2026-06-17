import AppKit
import SwiftUI

/// Hosts `PreferencesForm` inside a titled NSWindow.
///
/// ## Why SwiftUI `Form` instead of hand-rolled AppKit
///
/// Same rationale as `FilterPopoverViewController` — the macOS 26 System
/// Settings chrome (grouped section cards, automatic label alignment,
/// liquid-glass backgrounds) is expensive to mimic with `NSStackView` and
/// trivial with `SwiftUI.Form.formStyle(.grouped)` inside an
/// `NSHostingController`. This is the approved exception to the
/// AppKit-first convention for settings-style UIs.
///
/// Construction pattern mirrors `ReportsWindowController`:
/// - `AppDelegate` holds a single optional instance, constructed lazily on
///   first open and reused thereafter (brings the window forward rather
///   than rebuilding SwiftUI state).
/// - `show()` is idempotent — subsequent calls just key-and-front.
/// - `NSHostingController.sizingOptions = [.preferredContentSize]` auto-
///   sizes the window to the form's fitting size.
@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    private let settings: AppSettings

    init(
        settings: AppSettings,
        onRevealLogFile: @escaping () -> Void,
        onClearCacheAndReparse: @escaping () -> Void,
        statuslineService: StatuslineConnectionService? = nil
    ) {
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = false
        // `isReleasedWhenClosed = false` so the window can be re-shown after
        // a close without rebuilding the hosting controller. Matches every
        // other secondary window in the app.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PreferencesWindow")

        super.init(window: window)
        window.delegate = self

        let root = PreferencesForm(
            settings: settings,
            onRevealLogFile: onRevealLogFile,
            onClearCacheAndReparse: onClearCacheAndReparse,
            statuslineService: statuslineService
        )
        let hosting = NSHostingController(rootView: root)
        // Auto-size to SwiftUI content. Form.grouped drives the window height
        // via preferredContentSize, so the Pinned section appearing/
        // disappearing auto-resizes the window cleanly.
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    /// Flush any pending debounced settings write when the user closes the
    /// Preferences window. A rapid "open → toggle → close within 250ms"
    /// sequence would otherwise lose the toggle if the app were killed
    /// before the debounce timer fires.
    func windowWillClose(_ notification: Notification) {
        settings.persistNow()
    }
}
