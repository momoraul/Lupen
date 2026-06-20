//
//  ManageSessionsWindowController.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import AppKit

/// "Manage Sessions & Storage" 윈도우를 호스팅한다. AppDelegate가 lazy
/// 싱글톤으로 생성·재사용 — Reports/Verify Costs와 동일 패턴.
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
