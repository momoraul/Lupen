import AppKit
import SwiftUI

/// Hosts `DiagnosticsView` inside a regular titled NSWindow. Created lazily
/// by `AppDelegate` the first time the user opens Diagnostics, then reused
/// (brought forward) for subsequent openings so the user sees the same
/// scroll/selection state.
@MainActor
final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {

    private let diagnostics: ParseDiagnostics

    init(diagnostics: ParseDiagnostics) {
        self.diagnostics = diagnostics

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Parse Diagnostics"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ParseDiagnosticsWindow")

        super.init(window: window)
        window.delegate = self

        let root = DiagnosticsView(diagnostics: diagnostics) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: root)
        window.contentViewController = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
