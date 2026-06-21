//
//  ManageSessionsWindowController.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import AppKit

/// Hosts the "Manage Sessions & Storage" window. AppDelegate creates and reuses
/// it as a lazy singleton — same pattern as Reports/Verify Costs.
@MainActor
final class ManageSessionsWindowController: NSWindowController, NSWindowDelegate {

    init(
        provider: ProviderKind,
        isIndexingProvider: @escaping @MainActor () -> Bool,
        storeProvider: @escaping @MainActor (ProviderKind) -> ProviderStore?,
        contextProvider: @escaping @MainActor (ProviderKind) -> ManageProviderContext?,
        requestRescan: @escaping @MainActor (ProviderKind) -> Void,
        rebuildIndex: @escaping @MainActor (ProviderKind) -> Void
    ) {
        let store = ManageStore(
            provider: provider,
            isIndexingProvider: isIndexingProvider,
            storeProvider: storeProvider,
            contextProvider: contextProvider,
            requestRescan: requestRescan,
            rebuildIndex: rebuildIndex
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manage Sessions & Storage"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 520)
        window.center()
        window.setFrameAutosaveName("ManageSessionsWindow")
        window.contentViewController = ManageViewController(store: store)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
