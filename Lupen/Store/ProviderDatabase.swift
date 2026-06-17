//
//  ProviderDatabase.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation
import GRDB

/// Per-provider SQLite index database for the SQLite-first refactor
/// (docs/Research/2026-06-10-sqlite-first-refactor/plan.md).
///
/// Owns the `DatabasePool` lifecycle: WAL mode (single serialized writer,
/// concurrent snapshot readers), busy timeout, schema bootstrap, and the
/// rebuild-on-version-bump policy. The database is a derived cache — the
/// JSONL logs are the source of truth — so a `schema_version` mismatch
/// never migrates: the files are deleted and the schema is bootstrapped
/// fresh, and importers re-index in the background.
///
/// Module guardrail (plan.md Confirmed Decisions): GRDB types must not
/// leak outside `Lupen/Store/` — repositories expose domain DTOs only.
final class ProviderDatabase: @unchecked Sendable {

    /// Bump to force a wipe-and-reindex on next launch. Never write
    /// migration code against this — see the rebuild policy above.
    /// v2: subagent_links PK gained agent_id (N workflow links per tool_use).
    /// v3: idx_sessions_page_order expression index (sidebar keyset page).
    /// v4: turns carry full token/cost breakdown columns (4.1 headers).
    /// v5: skills extracted at import (4.4 Reports) — rebuild populates.
    /// v6: sessions.last_git_branch (6.1 sidebar branch row).
    /// v7: subagent_links.parent_assistant_uuid stores the MERGED step
    ///     uuid, not the raw tool_use line's (6.6 graft-join fix —
    ///     streamed thinking+tool_use splits left links pointing at no
    ///     step row, hiding every sub-agent graft in the outline).
    /// v8: prompt_preview/cached_title cap 50 → 300 chars (6.12 — wide
    ///     Conversation columns showed "…" mid-line). Value-only change;
    ///     the bump exists so existing rows re-index with the longer
    ///     preview instead of leaving a 50/300 mix per import age.
    /// v9: search_fts gains source_file_id + an AFTER DELETE trigger on
    ///     source_files (B3 — FTS5 takes no foreign key, so re-imports
    ///     orphaned old FTS rows and double-counted prompt hits). Rebuild
    ///     recreates the virtual table with the new column.
    /// v10: requests INSERT became `ON CONFLICT(id) DO NOTHING`. Behavior-
    ///     only change; the bump forces a rebuild so sessions previously
    ///     parked `failed` by the cross-session `requests.id` collision
    ///     (compact-continuation replays sharing requestIds) re-import and
    ///     recover their conversation + cost.
    /// v11: sessions gain `logical_parent_uuid` + `superseded_by` for
    ///     compact-continuation lineage merging — redundant earlier
    ///     snapshots collapse into the canonical leaf so the sidebar shows
    ///     one session and Verify Costs stops flagging the replay overlap.
    /// v12: new `request_membership` table records the full per-file
    ///     billable requestId list (pre-dedup). The lineage resolver now
    ///     detects replays by requestId SHARING — not `logical_parent_uuid`,
    ///     which `--resume` (a session fork) never writes — so resume/fork
    ///     overlaps collapse to the canonical owner and Verify Costs clears.
    /// v13: `request_membership` excludes sidechains (subagent requestIds no
    ///     longer inflate a parent's owner rank) and carries each file's
    ///     token values, so the re-home rewrites the deduped row to the
    ///     OWNER's tokens + re-finalizes — fixing the residual per-session
    ///     token/cost drift when a replay caught a different usage snapshot.
    /// v14: a transcript that carries its OWN sessionId on some lines is
    ///     attributed to its filename even when the first (replayed) line
    ///     carries the parent's id — so a `--resume` that keeps the parent
    ///     id no longer orphans the resumed session's shell as perpetually
    ///     `partial`. The replayed turns/steps/links such a file re-imports
    ///     for the parent now `ON CONFLICT DO NOTHING` like requests.
    /// v15: requests INSERT on `ON CONFLICT(id)` now RE-BINDS source_file_id
    ///     to the importing file instead of `DO NOTHING`. A replayed
    ///     requestId's single row was pinned (CASCADE) to whichever file
    ///     imported it first; re-indexing that file deleted the row while
    ///     other carriers only DO-NOTHING'd, so it vanished and `requests`
    ///     drifted behind `request_membership` (Verify Costs flagged the
    ///     billable requestIds as missing). The bump forces a clean rebuild
    ///     so existing drifted rows recover.
    static let schemaVersion: Int32 = 15

    enum BootstrapOutcome: Equatable, Sendable {
        /// No database file existed; schema created from scratch.
        case createdFresh
        /// File existed with the current schema version.
        case opened
        /// File existed with a different version; wiped and recreated.
        case rebuilt(fromVersion: Int32)
    }

    /// The live pool. Swapped only by `rebuildStorage()` (5.2b
    /// disk-I/O recovery) — reads go through the lock so concurrent
    /// users always see a coherent instance. `@unchecked Sendable`
    /// rests on this lock plus the immutable remainder.
    var pool: DatabasePool {
        poolLock.lock()
        defer { poolLock.unlock() }
        return _pool
    }
    private var _pool: DatabasePool
    private let poolLock = NSLock()
    let fileURL: URL
    let outcome: BootstrapOutcome

    private init(pool: DatabasePool, fileURL: URL, outcome: BootstrapOutcome) {
        self._pool = pool
        self.fileURL = fileURL
        self.outcome = outcome
    }

    // MARK: - Opening

    static func open(
        provider: ProviderKind,
        appSupportRoot: URL = LupenPaths.applicationSupportRoot()
    ) throws -> ProviderDatabase {
        try open(at: LupenPaths.indexDatabaseURL(for: provider, appSupportRoot: appSupportRoot))
    }

    static func open(at fileURL: URL) throws -> ProviderDatabase {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existedBefore = FileManager.default.fileExists(atPath: fileURL.path)
        let pool = try makePool(at: fileURL)

        guard existedBefore else {
            try bootstrapSchema(in: pool)
            return ProviderDatabase(pool: pool, fileURL: fileURL, outcome: .createdFresh)
        }

        let foundVersion = try pool.read { db in
            try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        if foundVersion == schemaVersion {
            return ProviderDatabase(pool: pool, fileURL: fileURL, outcome: .opened)
        }

        // Version mismatch → rebuild policy: wipe and bootstrap fresh.
        try pool.close()
        try deleteDatabaseFiles(at: fileURL)
        let freshPool = try makePool(at: fileURL)
        try bootstrapSchema(in: freshPool)
        LoggerService.shared.logFromAnyThread(
            .info,
            "Provider index rebuilt: schema v\(foundVersion) → v\(schemaVersion) at \(fileURL.lastPathComponent)",
            context: "Store"
        )
        return ProviderDatabase(
            pool: freshPool,
            fileURL: fileURL,
            outcome: .rebuilt(fromVersion: foundVersion)
        )
    }

    /// Closes the underlying pool. Safe to call once before discarding
    /// the instance (tests and explicit teardown paths).
    func close() throws {
        try pool.close()
    }

    // MARK: - Storage failure recovery (plan 5.2b)

    /// True when `error` means the storage underneath an open pool can
    /// no longer serve work — the DB file vanished or was rebuilt by a
    /// foreign instance (3.8 run-3: `SQLite error 10: disk I/O error`
    /// on every unit), the file is corrupt, or the pool was closed.
    /// Retrying queued imports against such a pool spins forever; the
    /// only fix is `rebuildStorage()` + rescan.
    static func isStorageFailure(_ error: Error) -> Bool {
        guard let databaseError = error as? DatabaseError else { return false }
        switch databaseError.resultCode.primaryResultCode {
        case .SQLITE_IOERR, .SQLITE_CORRUPT, .SQLITE_NOTADB,
             .SQLITE_CANTOPEN, .SQLITE_FULL, .SQLITE_PERM,
             .SQLITE_READONLY, .SQLITE_MISUSE:
            return true
        default:
            return false
        }
    }

    /// Last-resort recovery for a persistently failing pool: close it
    /// (best effort — it may already be unusable), delete the database
    /// files, and bootstrap a fresh schema at the same path. The
    /// instance — and every `ProviderStore` holding it — stays valid;
    /// only the underlying pool is swapped. Callers re-index from the
    /// source logs afterwards (the derived data is rebuildable by
    /// definition).
    func rebuildStorage() throws {
        poolLock.lock()
        defer { poolLock.unlock() }
        try? _pool.close()
        try Self.deleteDatabaseFiles(at: fileURL)
        let fresh = try Self.makePool(at: fileURL)
        try Self.bootstrapSchema(in: fresh)
        _pool = fresh
    }

    // MARK: - Internals

    private static func makePool(at fileURL: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5.0)
        // DatabasePool activates WAL journaling itself; nothing to add.
        return try DatabasePool(path: fileURL.path, configuration: configuration)
    }

    private static func bootstrapSchema(in pool: DatabasePool) throws {
        try pool.write { db in
            try ProviderDatabaseSchema.createV1(db)
            try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
        }
    }

    private static func deleteDatabaseFiles(at fileURL: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fileURL.path + suffix)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
    }
}
