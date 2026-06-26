import Foundation

/// Single point of store access for the CLI. Opens the per-provider
/// SQLite index the GUI app maintains, optionally refreshes it from the
/// source logs, and exposes its `ProviderStore` (which conforms to
/// `ReportsRepository`) to the subcommands.
///
/// `ProviderDatabase`/`ProviderStore` are `Sendable` and carry no
/// `@MainActor` constraint, so they run fine in a CLI process with no run
/// loop (GRDB is synchronous). The index is just a cache of the raw
/// `~/.claude` / `~/.codex` logs, so the CLI is self-sufficient: it never
/// requires the app to have run — a cold first run builds the index from
/// the logs itself (see `CLIRefresher`).
///
/// Opening the index is itself a write: `ProviderDatabase.open` creates the
/// provider directory and bootstraps (or, on a schema bump, rebuilds) the
/// schema. The refresh that follows populates it; the report queries are
/// read-only. A cross-process lock (`CLIProcessLock`) keeps two concurrent
/// `lupen` refreshes from doing duplicate work.
struct CLIEngine {
    let provider: ProviderKind
    let store: ProviderStore
    let bootstrapOutcome: ProviderDatabase.BootstrapOutcome
    /// Whether a refresh was requested (false under `--no-refresh`).
    let didRefresh: Bool
    /// Result of the refresh, or nil when none was requested.
    let refreshOutcome: CLIRefresher.Outcome?

    static func open(
        provider: ProviderKind,
        refresh: Bool,
        appSupportRoot: URL = LupenPaths.applicationSupportRoot(),
        progress: (String) -> Void = { CLIOutput.note($0) }
    ) throws -> CLIEngine {
        // A built-in provider is just its built-in source; delegate so the
        // index path / refresh source are identical to the per-source path.
        try open(
            source: SessionSourceRegistry.builtinSource(
                for: provider,
                claudeRoot: FileDiscovery().projectsDirectory,
                codexRoot: CodexSessionDiscovery().codexHome
            ),
            refresh: refresh,
            appSupportRoot: appSupportRoot,
            progress: progress
        )
    }

    /// Open the index for an explicit session source — the per-source DB under
    /// `providers/<source.id>/`, refreshed from `source.root` via the source's
    /// parser. The built-in convenience above routes through here.
    static func open(
        source: SessionSource,
        refresh: Bool,
        appSupportRoot: URL = LupenPaths.applicationSupportRoot(),
        progress: (String) -> Void = { CLIOutput.note($0) }
    ) throws -> CLIEngine {
        let database = try ProviderDatabase.open(
            at: LupenPaths.indexDatabaseURL(forSourceId: source.id, appSupportRoot: appSupportRoot)
        )
        let store = ProviderStore(database: database)

        var outcome: CLIRefresher.Outcome?
        if refresh {
            let lockURL = LupenPaths.refreshLockURL(forSourceId: source.id, appSupportRoot: appSupportRoot)
            if let lock = CLIProcessLock.acquire(at: lockURL, timeout: 30) {
                defer { lock.release() }
                outcome = CLIRefresher.run(
                    source: ProviderIndexSource(source),
                    store: store,
                    progress: progress
                )
            } else {
                outcome = .skippedLockHeld
            }
        }

        return CLIEngine(
            provider: source.kind,
            store: store,
            bootstrapOutcome: database.outcome,
            didRefresh: refresh,
            refreshOutcome: outcome
        )
    }

    /// Optional one-line freshness hint for stderr (keeps stdout clean for
    /// piped consumers). Stays quiet when nothing notable happened.
    func freshnessNote() -> String? {
        Self.freshnessNote(
            bootstrap: bootstrapOutcome,
            didRefresh: didRefresh,
            outcome: refreshOutcome
        )
    }

    /// Pure freshness-message logic (no store access), so the branch
    /// matrix is unit-testable.
    static func freshnessNote(
        bootstrap: ProviderDatabase.BootstrapOutcome,
        didRefresh: Bool,
        outcome: CLIRefresher.Outcome?
    ) -> String? {
        if case .rebuilt = bootstrap {
            // A schema bump wipes the index on open. Only a refresh repopulates
            // it — under --no-refresh the index is empty and the report is zeros,
            // so don't claim a reindex that didn't happen.
            return didRefresh
                ? "Index rebuilt for a new version — reindexed from your logs."
                : "Index reset for a new version — run without --no-refresh to reindex."
        }
        guard didRefresh else {
            return "Showing the on-disk index (--no-refresh)."
        }
        guard let outcome else { return nil }
        if outcome.skipped {
            return "Another Lupen process is indexing; showing the current index."
        }
        if outcome.imported > 0 {
            let plural = outcome.imported == 1 ? "" : "s"
            return "↻ Indexed \(outcome.imported) updated session\(plural)."
        }
        return nil
    }
}
