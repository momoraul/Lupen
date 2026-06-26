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

    private let store: ManageStore

    init(
        source: SessionSource,
        sources: [SessionSource],
        isIndexingProvider: @escaping @MainActor () -> Bool,
        storeProvider: @escaping @MainActor (SessionSource) -> ProviderStore?,
        contextProvider: @escaping @MainActor (SessionSource) -> ManageProviderContext?,
        requestRescan: @escaping @MainActor (SessionSource) -> Void,
        rebuildIndex: @escaping @MainActor (SessionSource) -> Void,
        hasLiveDriver: @escaping @MainActor (SessionSource) -> Bool
    ) {
        let store = ManageStore(
            source: source,
            sources: sources,
            isIndexingProvider: isIndexingProvider,
            storeProvider: storeProvider,
            contextProvider: contextProvider,
            requestRescan: requestRescan,
            rebuildIndex: rebuildIndex,
            hasLiveDriver: hasLiveDriver
        )
        self.store = store
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

    /// Re-push the latest enabled sources + active selection before showing —
    /// the controller is a reused singleton, so changes since the last open
    /// must be applied or the switcher would show a stale list.
    func update(sources: [SessionSource], active: SessionSource) {
        store.updateSources(sources, active: active)
    }

    func show() {
        window?.bringToFront()
    }
}
