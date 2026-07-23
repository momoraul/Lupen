//
//  TurnOutlineView.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import AppKit

/// `NSOutlineView` subclass that adds right-click menu support to the turn
/// outline.
///
/// The view does hit-testing only; the view controller builds the menu through
/// an injected `menuProvider`. That split is the one
/// `SessionListViewController` already uses for the sidebar, and it keeps menu
/// construction — which needs the controller's state — out of the view.
///
/// Right-clicking deliberately does **not** change the selection, so the menu
/// must carry its subject explicitly (`NSMenuItem.representedObject`) rather
/// than letting the action read `selectedRow`. Reading the selection would act
/// on whatever was highlighted before the right-click, which is the wrong row
/// exactly when it matters.
final class TurnOutlineView: NSOutlineView {

    /// Returns the menu for the row that was clicked, or `nil` for no menu.
    var menuProvider: ((TurnOutlineNode) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0,
              let node = item(atRow: clickedRow) as? TurnOutlineNode else { return nil }
        return menuProvider?(node)
    }
}
