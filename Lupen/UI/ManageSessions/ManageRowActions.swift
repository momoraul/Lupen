//
//  ManageRowActions.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Bundle of inspector/context-menu actions. `ManageViewController` builds it
/// and injects it into the SwiftUI inspector (the view doesn't know the behavior
/// implementation — separation).
struct ManageRowActions {
    var resume: (ManageRowModel) -> Void
    var reveal: (ManageRowModel) -> Void
    var openFolder: (ManageRowModel) -> Void
    var openTerminal: (ManageRowModel) -> Void
    var copyCommand: (ManageRowModel) -> Void
    var export: (ManageRowModel) -> Void
    /// Single-row Trash (friction/Undo wired in P4).
    var trashRow: (ManageRowModel) -> Void
    /// Trash the selected batch (collector — P4).
    var trashSelected: () -> Void
}
