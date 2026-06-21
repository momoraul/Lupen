//
//  ManageDeletionPlanner.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Deletion-confirmation friction tiers (GitLab Pajamas 3-tier, research §B-5).
enum DeletionFriction: Sendable, Equatable {
    case low     // Single, reversible, safe → trash without a modal + Undo snackbar
    case medium  // Several or caution → confirmation modal
    case high    // Bulk or untracked → modal + typing confirmation
}

/// Pure decision logic for the deletion flow (test target). The actual
/// Trash/index manipulation is handled by `ManageTrashService`/`ManageStore`.
enum ManageDeletionPlanner {
    static let bulkCountThreshold = 20
    static let bulkByteThreshold: Int64 = 1_000_000_000   // 1 GB

    /// Whether all candidates are deletable. false if even one blocked/locked is mixed in
    /// (allowlist — unclassified/blocked are not deletable).
    static func allDeletable(_ rows: [ManageRowModel]) -> Bool {
        !rows.isEmpty && rows.allSatisfy { $0.protection == .deletable }
    }

    static func totalBytes(_ rows: [ManageRowModel]) -> Int64 {
        rows.reduce(0) { $0 + $1.sizeBytes }
    }

    static func friction(rows: [ManageRowModel]) -> DeletionFriction {
        let count = rows.count
        let hasUntracked = rows.contains { !$0.isIndexed }
        if hasUntracked || count >= bulkCountThreshold || totalBytes(rows) >= bulkByteThreshold {
            return .high
        }
        if count > 1 || rows.contains(where: { $0.classification == .caution }) {
            return .medium
        }
        return .low
    }

    struct ConfirmCopy: Equatable {
        let title: String
        let body: String
        let confirmButton: String
        let requiresTyping: Bool
        let typingToken: String
    }

    static func confirmCopy(rows: [ManageRowModel]) -> ConfirmCopy {
        let count = rows.count
        let size = ByteCountFormatter.string(fromByteCount: totalBytes(rows), countStyle: .file)
        let hasUntracked = rows.contains { !$0.isIndexed }
        let noun = "\(count) \(hasUntracked ? "item" : "session")\(count == 1 ? "" : "s")"
        let lead = hasUntracked
            ? "These files are not tracked by Lupen."
            : "Conversation history and attached logs will be removed."
        return ConfirmCopy(
            title: "Move \(noun) to Trash?",
            body: "\(lead) Reclaims \(size).\nYou can restore from Trash for 30 days.",
            confirmButton: "Delete \(noun)",
            requiresTyping: friction(rows: rows) == .high,
            typingToken: "DELETE"
        )
    }
}
