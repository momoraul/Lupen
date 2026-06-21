//
//  ManageTableView.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import AppKit

/// NSTableView subclass for a keyboard shortcut (⌫ = Trash selected items).
/// ↑↓ row navigation/selection is NSTableView's default behavior.
final class ManageTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:       // delete, forward delete
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }
}
