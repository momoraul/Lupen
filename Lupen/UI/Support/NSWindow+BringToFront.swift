//
//  NSWindow+BringToFront.swift
//  Lupen
//
//  Created by jaden on 2026/06/24.
//

import AppKit

extension NSWindow {
    /// Reliably surfaces this window to the front from *any* context —
    /// including an `NSStatusItem` (menu-bar) click, where the app is NOT the
    /// active application.
    ///
    /// A status-item click does not activate the app, and under macOS 14+
    /// "cooperative activation" a self-`NSApp.activate(...)` from that context
    /// is frequently ignored: the app stays inactive, so a plain
    /// `makeKeyAndOrderFront(_:)` leaves the window *behind* the frontmost
    /// app's windows — the "click logs but nothing appears; a Dock click is
    /// needed" symptom. (Dock clicks work because the Dock activates the app
    /// first, then calls `applicationShouldHandleReopen`.)
    ///
    /// `orderFrontRegardless()` is the fix: it brings the window to the front
    /// of its level *even while the app is inactive*, so the window is always
    /// visible regardless of whether activation succeeded. `activate` is still
    /// requested first so key-focus follows when the system does grant it.
    @MainActor
    func bringToFront() {
        if isMiniaturized { deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}
