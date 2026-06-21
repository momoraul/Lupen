//
//  ManageModels.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Top-level tabs (scopes) of the "Manage Sessions & Storage" window.
///
/// `sessions`/`projects`/`cache` are primary views (inside the session area)
/// where cleanup (Trash) is allowed; `allDisk` is a read-only secondary view
/// covering the whole provider home
/// (research-ccmgr.md §1.6 — two-tier display decision).
enum ManageScope: String, CaseIterable, Sendable, Identifiable {
    case sessions
    case cache
    case allDisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .cache:    return "Lupen Cache"
        case .allDisk:  return "All Disk"
        }
    }
}

/// The kind of item a row represents.
enum ManageItemKind: String, Sendable, Equatable {
    /// A session known to the index (tracked).
    case session
    /// A `.jsonl` inside the session area but unknown to the index (untracked).
    case orphanFile
    /// A large allocated-size item at the provider home root (read-only secondary view).
    case diskItem
    /// An index remnant present in the index but whose original file is gone on disk (prune candidate).
    case indexRemnant
}

/// Deletion-safety classification — a visual language (color/icon) that builds
/// user trust.
/// (research §B-5: never rely on color alone; pair with badge/tooltip text)
enum StorageClassification: String, Sendable, Equatable {
    case safe          // 🟢 Regenerable / completed session
    case caution       // 🟡 Recent / untracked / large file
    case danger        // 🔴 Dangerous (whether the action is allowed is decided by protection)
    case unclassified  // ⚪ Outside the classification rules
}

/// The actions allowed inside the app. An allowlist model — only `deletable`
/// can be trashed.
enum StorageProtection: String, Sendable, Equatable {
    /// Can be moved to Trash (confirmation friction is calibrated separately).
    case deletable
    /// In-app deletion blocked — Reveal in Finder only (auth/config, app-state DB, outside the session area, or indexing in progress).
    case blocked
    /// Unclassified — deletion locked (unclassified = not deletable principle).
    case locked

    /// The only state that allows a move to Trash.
    var canTrash: Bool { self == .deletable }
}

/// Row status — shown in an emoji column (per user request). Independent of
/// classification (whether deletable), it shows "why you should be careful" at a glance.
enum ManageStatus: String, Sendable, Equatable {
    case normal
    case recentlyActive
    case untracked
    case indexing
    case blocked
    case error

    var emoji: String {
        switch self {
        case .normal:         return ""
        case .recentlyActive: return "🕐"
        case .untracked:      return "❓"
        case .indexing:       return "⏳"
        case .blocked:        return "🔒"
        case .error:          return "⚠️"
        }
    }
    var label: String {
        switch self {
        case .normal:         return "Normal"
        case .recentlyActive: return "Recently active"
        case .untracked:      return "Untracked"
        case .indexing:       return "Indexing"
        case .blocked:        return "Blocked"
        case .error:          return "Error"
        }
    }
    /// Status description shown in the detail panel (empty string when normal).
    var detailDescription: String {
        switch self {
        case .normal:         return ""
        case .recentlyActive: return "Active within the last ~10 minutes. It may be in use — confirm before deleting."
        case .untracked:      return "Not tracked by the Lupen index. Only path and size are known; delete with extra care."
        case .indexing:       return "Indexing is in progress. The status updates automatically when it finishes."
        case .blocked:        return "auth/config, app-state DB, or outside the session area — can't be deleted in-app. Use Reveal in Finder."
        case .error:          return "The original file is missing on disk (index remnant) or failed to parse."
        }
    }
    /// Sort order for the status column (higher-priority statuses on top).
    var sortOrder: Int {
        switch self {
        case .blocked:        return 0
        case .error:          return 1
        case .indexing:       return 2
        case .untracked:      return 3
        case .recentlyActive: return 4
        case .normal:         return 5
        }
    }
}

/// One row in the management list. The result of reconciling the index (instant)
/// with the FS measurement (correction). A pure value type — no UI/concurrency
/// dependencies (P1 foundation, test target).
struct ManageRowModel: Sendable, Equatable, Identifiable {
    /// Provider-scoped session id, or the representative path of an untracked/disk item.
    let id: String
    let provider: ProviderKind
    let kind: ManageItemKind

    var displayTitle: String
    /// Original session id (for Resume). nil for orphan/disk items.
    var rawSessionId: String? = nil
    /// The decoded actual project path (for display/Reveal).
    var projectPath: String? = nil
    /// The encoded directory name under `~/.claude/projects` (original).
    var encodedProject: String? = nil
    var branch: String? = nil
    var firstPrompt: String? = nil
    /// Session start (creation) time — the Created column.
    var createdAt: Date? = nil
    /// Last activity (update) time — the Updated column.
    var lastActivity: Date? = nil

    /// Allocated size in bytes. Displayed via `ByteCountFormatter`, **sorted on this Int64**.
    var sizeBytes: Int64 = 0
    /// When true, an index approximation (before measurement) — shown dimmed / with `~` in the UI.
    var isEstimatedSize: Bool = false
    var fileCount: Int = 0

    /// File paths targeted for deletion (all source files of the session).
    var filePaths: [String] = []
    /// The session companion directory `<sessionId>/` (trashed alongside if present).
    var companionDirectory: String? = nil

    var parseState: StoreParseState? = nil
    var status: ManageStatus = .normal
    var classification: StorageClassification = .unclassified
    var protection: StorageProtection = .locked
    var isIndexed: Bool = false
    var existsOnDisk: Bool = true

    /// Short project name for column display (the last path component).
    var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return "—" }
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    /// The paths actually moved on a Trash operation (files + companion directory).
    var trashTargets: [String] {
        var targets = filePaths
        if let companionDirectory { targets.append(companionDirectory) }
        return targets
    }
}
