//
//  ManageTrashService.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Handles moving items to Trash and restoring them (Undo). It does not offer
/// permanent deletion (`removeItem`) — safety first (plan §13). If the user
/// wants permanent deletion, they empty the Finder Trash. Runs in the background
/// (detached) for zero main-thread blocking.
struct ManageTrashService: Sendable {

    /// The result of a single Trash operation.
    struct Outcome: Sendable, Equatable {
        var trashedPaths: [String] = []
        var failedPaths: [String] = []
        /// For Undo (original path → URL inside Trash).
        var restore: [RestoreEntry] = []
    }

    struct RestoreEntry: Sendable, Equatable {
        let originalPath: String
        let trashedURL: URL
    }

    /// Moves `paths` to Trash. Paths that no longer exist are silently skipped
    /// (not treated as success — not added to trashed). Processes one item at a
    /// time to preserve Put Back in bulk operations.
    func trash(_ paths: [String]) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            var outcome = Outcome()
            let fm = FileManager.default
            for path in paths {
                guard fm.fileExists(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path)
                var resulting: NSURL?
                do {
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    outcome.trashedPaths.append(path)
                    if let resultingURL = resulting as URL? {
                        outcome.restore.append(RestoreEntry(originalPath: path, trashedURL: resultingURL))
                    }
                } catch {
                    outcome.failedPaths.append(path)
                }
            }
            return outcome
        }.value
    }

    /// Undo — restores items from Trash to their original paths. Skips when
    /// something already exists at the original path (recreated).
    func restore(_ entries: [RestoreEntry]) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for entry in entries {
                let original = URL(fileURLWithPath: entry.originalPath)
                guard !fm.fileExists(atPath: entry.originalPath) else { continue }
                try? fm.moveItem(at: entry.trashedURL, to: original)
            }
        }.value
    }
}
