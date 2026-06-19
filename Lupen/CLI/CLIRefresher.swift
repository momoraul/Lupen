import Foundation

/// Incrementally refreshes a provider's SQLite index from its source logs
/// before the CLI queries it — the headless equivalent of what the GUI app
/// does on launch. Drives the very same `ProviderIndexCoordinator`
/// (fingerprint-based incremental scan → priority-ordered detail imports)
/// so the CLI and the app stay byte-for-byte consistent; there is no
/// second, divergent import path.
///
/// Blocking by design: a one-shot `lupen` run wants the freshest numbers,
/// so it waits for the import queue to drain. The first run on a cold index
/// can take a while (full backfill); subsequent runs are cheap because
/// unchanged files are skipped by fingerprint.
enum CLIRefresher {
    struct Outcome: Sendable, Equatable {
        /// Units (sessions) imported or re-imported this run.
        let imported: Int
        /// Units that failed (kept their prior state; retried next run).
        let failed: Int
        /// True when the refresh was skipped (another process held the
        /// lock) and the caller is reading the current on-disk index.
        let skipped: Bool

        static let skippedLockHeld = Outcome(imported: 0, failed: 0, skipped: true)
    }

    /// Production source directory for a provider (honours the same
    /// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` overrides as the GUI app).
    static func source(for provider: ProviderKind) -> ProviderIndexSource {
        switch provider {
        case .claudeCode: return .claude(projectsDirectory: FileDiscovery().projectsDirectory)
        case .codex:      return .codex(codexHome: CodexSessionDiscovery().codexHome)
        }
    }

    /// Run one refresh generation to completion and report the tally.
    /// `progress` is invoked (on the calling thread) at most every
    /// `progressInterval` while a long cold index drains.
    static func run(
        source: ProviderIndexSource,
        store: ProviderStore,
        progressInterval: TimeInterval = 3,
        progress: (String) -> Void = { _ in }
    ) -> Outcome {
        let coordinator = ProviderIndexCoordinator(source: source, store: store)
        let tally = Tally()
        coordinator.start(eventSink: { event in tally.record(event) })
        // `waitUntilIdle` returns as soon as the queue drains, or after the
        // interval if still working — so a fast/incremental refresh returns
        // immediately and only a slow cold index emits progress.
        while !coordinator.waitUntilIdle(timeout: progressInterval) {
            let snapshot = tally.snapshot()
            progress("indexing… \(snapshot.imported) session(s) so far")
        }
        // Match the GUI's on-idle reconciliation: collapse compact-continuation
        // replays onto their canonical session and re-finalize per-session costs,
        // so resume/replay sessions report the same numbers Verify Costs computes.
        // Idempotent — a no-op once the lineage map has settled.
        _ = try? ClaudeContinuationResolver.run(store: store)
        let snapshot = tally.snapshot()
        return Outcome(imported: snapshot.imported, failed: snapshot.failed, skipped: false)
    }

    /// Thread-safe event accumulator: the coordinator delivers events on
    /// its own queue while the caller blocks in `waitUntilIdle`.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var imported = 0
        private var failed = 0

        func record(_ event: ProviderIndexEvent) {
            lock.lock()
            defer { lock.unlock() }
            switch event {
            case .unitImported: imported += 1
            case .unitFailed: failed += 1
            case .metadataScanCompleted, .idle: break
            }
        }

        func snapshot() -> (imported: Int, failed: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (imported, failed)
        }
    }
}
