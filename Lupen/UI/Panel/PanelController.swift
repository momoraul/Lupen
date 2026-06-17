import AppKit

/// Manages the dropdown popover shown when the statusbar icon is clicked.
/// Uses NSPopover with .transient behavior — the standard Apple pattern for
/// menubar popups (Control Center, Wi-Fi, Bluetooth all use this).
///
/// NSPopover.transient handles:
/// - Click-outside dismissal (automatic)
/// - ESC key dismissal (automatic)
/// - Positioning relative to the anchor view (automatic)
/// - No activation policy changes needed
/// - No global event monitors needed
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {

    private let store: AppStateStore
    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.contentSize = NSSize(width: 340, height: 420)
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        return p
    }()

    private var contentController: DropdownViewController?

    init(store: AppStateStore) {
        self.store = store
        super.init()
    }

    var isOpen: Bool { popover.isShown }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show(relativeTo: button)
        }
    }

    func close() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func show(relativeTo button: NSStatusBarButton) {
        if contentController == nil {
            contentController = DropdownViewController(store: store)
        }
        popover.contentViewController = contentController
        contentController?.refreshContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
}
