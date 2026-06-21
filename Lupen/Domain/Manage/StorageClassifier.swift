//
//  StorageClassifier.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Maps a path to a deletion-safety classification. **Allowlist-based** —
/// only paths explicitly judged safe become `deletable`; anything outside
/// the rules is `locked`.
///
/// Absolute constraints (plan §5.1):
/// - auth / config / app-state DBs (`*.sqlite`) are **hard-blocked** (`blocked`).
/// - Blocked while indexing or outside the session area.
/// - Deletion allowed only inside the session area (`~/.claude/projects`·`~/.codex/sessions`).
struct StorageClassifier: Sendable {

    /// Per-provider area definition. Only files inside `sessionAreaRoots` are deletion candidates.
    struct Scope: Sendable, Equatable {
        /// Provider home (`~/.claude` or `~/.codex`).
        let providerHome: URL
        /// Cleanable session-area roots (`projects/` or `sessions/`).
        let sessionAreaRoots: [URL]
    }

    let scope: Scope
    /// Recent-modification threshold to treat as "active". Items modified within this window are caution.
    var activeWindow: TimeInterval = 600  // 10 minutes

    /// Classify a single path.
    /// - Parameters:
    ///   - isIndexed: Whether the index is tracking this item (untracked raises caution).
    ///   - isIndexing: Whether this provider is currently indexing (if so, block).
    ///   - lastModified: Last-modified time (for active protection).
    func classify(
        path: String,
        isIndexed: Bool,
        isIndexing: Bool,
        lastModified: Date?,
        now: Date = Date()
    ) -> (classification: StorageClassification, protection: StorageProtection) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent.lowercased()

        // 1) Hard-block: auth/config/app-state DB/lock — blocked wherever they are.
        if Self.isHardBlocked(name: name) {
            return (.danger, .blocked)
        }

        // 2) While indexing — block everything for safety.
        if isIndexing {
            return (.danger, .blocked)
        }

        // 3) Not cleanable if outside the session area.
        guard isInsideSessionArea(url) else {
            // If inside the provider home (all-disk item), read-only block;
            // if entirely outside, unclassified and locked.
            return isInsideProviderHome(url) ? (.danger, .blocked) : (.unclassified, .locked)
        }

        // 4) Inside the session area — deletable. Classify only the risk level.
        if let lastModified, now.timeIntervalSince(lastModified) < activeWindow {
            return (.caution, .deletable)   // recent activity — caution, but deletable
        }
        if !isIndexed {
            return (.caution, .deletable)   // untracked — caution
        }
        return (.safe, .deletable)
    }

    // MARK: - Hard-block rules

    /// Whether this is an auth/config/app-state DB/lock file. Lowercased filename.
    static func isHardBlocked(name: String) -> Bool {
        // SQLite/DB/lock family (app state — never delete).
        let blockedSuffixes = [
            ".sqlite", ".sqlite3", ".db",
            ".sqlite-wal", ".sqlite-shm", ".sqlite3-wal", ".sqlite3-shm",
            ".db-wal", ".db-shm", ".lock"
        ]
        if blockedSuffixes.contains(where: { name.hasSuffix($0) }) { return true }

        // auth / credentials / config family — block exact filenames only.
        // Prefix matching (`hasPrefix`) would lock legitimate session logs
        // like `configuration-notes.jsonl`, so it isn't used. Real sensitive
        // files (auth.json/.credentials.json, etc.) live at the provider home
        // root and are already blocked by isInsideSessionArea=false; this exact
        // list is a defense-in-depth layer on top of that.
        let blockedExact = [
            "config.toml", "config.json", "auth.json", ".env",
            "credentials.json", ".credentials.json",
        ]
        return blockedExact.contains(name)
    }

    // MARK: - Containment

    func isInsideSessionArea(_ url: URL) -> Bool {
        scope.sessionAreaRoots.contains { Self.isDescendant(url, of: $0) }
    }

    func isInsideProviderHome(_ url: URL) -> Bool {
        Self.isDescendant(url, of: scope.providerHome)
    }

    /// Whether `url` is a (strict) descendant of `root`. Path-component prefix
    /// comparison, normalized via `standardizedFileURL` first so `..`/symlinks
    /// in the mix are handled.
    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let u = url.standardizedFileURL.pathComponents
        let r = root.standardizedFileURL.pathComponents
        guard u.count > r.count else { return false }
        return Array(u.prefix(r.count)) == r
    }
}
