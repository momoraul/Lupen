import AppKit
import SwiftUI

/// Hosts `ReportsView` in a titled NSWindow. Created lazily by
/// `AppDelegate` and reused on subsequent openings — same pattern as
/// `DiagnosticsWindowController`.
@MainActor
final class ReportsWindowController: NSWindowController, NSWindowDelegate {

    private let store: AppStateStore
    private let sampleStore: RateLimitSampleStore?

    init(store: AppStateStore, sampleStore: RateLimitSampleStore? = nil) {
        self.store = store
        self.sampleStore = sampleStore

        // 920×600 keeps Overview's 6 cards in a single row (single-row
        // threshold ~882pt: LazyVGrid `adaptive(minimum: 132)` × 6 +
        // 5×10 spacing + 40 horizontal padding) with the hero chart
        // (280pt) plus header/footer fitting without clipping.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Reports"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.center()
        // V2 autosave key so existing users' saved smaller frames
        // (740×520) don't override the new default. After one resize
        // the V2 key takes over and restores that size next launch.
        window.setFrameAutosaveName("ReportsWindowV2")

        super.init(window: window)
        window.delegate = self

        let root = ReportsView(
            store: store,
            sampleStore: sampleStore
        ) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: root)
        window.contentViewController = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.bringToFront()
    }
}
