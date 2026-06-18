import AppKit

/// Main dashboard window — standard macOS window with toolbar.
final class DashboardWindow: NSWindow, NSToolbarDelegate {

    static let logButtonId = NSToolbarItem.Identifier("openLogs")

    var onOpenLogs: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )

        title = "Lupen"
        minSize = NSSize(width: 800, height: 500)
        setFrameAutosaveName("DashboardWindow")
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        backgroundColor = .windowBackgroundColor
        titlebarAppearsTransparent = false
        center()

        // The log window is a maintainer-only diagnostic; its toolbar button
        // (the toolbar's only item) ships in DEBUG builds only. In RELEASE the
        // window keeps a plain title bar rather than an empty toolbar strip.
        #if DEBUG
        let toolbar = NSToolbar(identifier: "DashboardToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        #endif
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.logButtonId]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.logButtonId]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.logButtonId else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Logs"
        item.toolTip = "Open Log Window"
        item.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Logs")
        item.target = self
        item.action = #selector(openLogsClicked)
        return item
    }

    @objc private func openLogsClicked() {
        onOpenLogs?()
    }
}
