//
//  ProviderIndexCoordinator.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Where one provider's source logs live on disk.
enum ProviderIndexSource: Sendable, Equatable {
    case claude(projectsDirectory: URL)
    case codex(codexHome: URL)

    var provider: ProviderKind {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codex
        }
    }

    /// Build the index source a session source feeds the pipeline: the
    /// scanner reads `source.root` keyed by `source.kind` — Claude scans the
    /// projects directory directly, Codex uses the codexHome (parent of
    /// `sessions/`, also holding `session_index.jsonl`). `SessionSource.root`
    /// already carries the right base directory per kind, so no derivation.
    init(_ source: SessionSource) {
        switch source.kind {
        case .claudeCode: self = .claude(projectsDirectory: source.root)
        case .codex: self = .codex(codexHome: source.root)
        }
    }
}

/// Events a coordinator delivers to the main actor (plan §5: progress /
/// coverage snapshots into `AppStateStore`; UI refreshes by re-querying
/// the store after a change notification — never by receiving graphs).
enum ProviderIndexEvent: Sendable {
    /// Metadata scan finished — session shells are queryable, the
    /// sidebar can render, and `pendingUnits` detail imports were queued.
    case metadataScanCompleted(provider: ProviderKind, pendingUnits: Int, coverage: StoreCoverage)
    /// One atomic unit landed; affected scoped session id + fresh
    /// coverage for invalidation-by-event (sidebar row, open
    /// conversation, today cost).
    case unitImported(provider: ProviderKind, scopedSessionId: String, coverage: StoreCoverage)
    /// A unit failed to import; its sources keep their non-imported
    /// state and will be retried on the next scan.
    case unitFailed(provider: ProviderKind, sessionRawId: String, message: String)
    /// The import queue drained for the current generation.
    case idle(provider: ProviderKind, coverage: StoreCoverage)
}

/// Phase 3.1: per-provider SQLite-first index coordinator, generalized
/// from the `CodexProviderRuntime` shape (serial worker queue, lifecycle
/// generations, main-actor event delivery) — but feeding the Phase 2
/// scoped importers instead of a provider-wide load.
///
/// Import priority after a metadata scan (plan Target Architecture §1):
/// ① sources touched today (menu-bar today cost becomes correct within
/// seconds), ② the selected/visible session (`prioritize`), ③ background
/// backfill, newest first / oldest last. Units are deduplicated by
/// session, cancellation is generation-based and lands at the batch
/// boundaries 2.8 built, and every write goes through the store's
/// repositories — no `AppStateStore`, no in-memory graphs (Rule 2).
final class ProviderIndexCoordinator: @unchecked Sendable {

    typealias EventSink = @Sendable (ProviderIndexEvent) -> Void

    struct Configuration: Sendable {
        /// "Today" boundary for the priority split.
        var calendar: Calendar = .current
        /// Forwarded to the detail importers.
        var writeBatchRowLimit: Int = 2_000
        /// Units whose sources total more than this are demoted to the
        /// END of their queue. The worker is serial and units are
        /// non-preemptive, so a giant identity group at the head
        /// blocks every later unit — including user-selected ones —
        /// for its whole import (the 109 GB jumbo group measured in
        /// the wild held "7 of 383" for tens of minutes).
        var largeUnitDemoteBytes: Int64 = 1 << 30   // 1 GiB
        /// Forwarded to the Codex detail importer: a non-duplicated piece
        /// at least this large imports via the memory-bounded projection
        /// (user prompts kept, non-user body clipped). Overridable so the
        /// safety floor can be tuned per environment rather than baked in.
        var oversizedPieceByteThreshold: Int64 = CodexDetailImporter.defaultOversizedPieceByteThreshold
        init() {}
    }

    let source: ProviderIndexSource
    let store: ProviderStore
    var configuration = Configuration()

    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var eventSink: EventSink?
    private var lifecycleGeneration: UInt64 = 0
    private var isRunning = false
    private var isWorking = false
    private var isPumpSuspended = false
    private var isScanSuspended = false
    private var parkedScanGenerations: [UInt64] = []
    /// Priority buckets, drained in order; FIFO within a bucket.
    private var selectedQueue: [String] = []
    private var todayQueue: [String] = []
    private var backfillQueue: [String] = []
    private var pendingIds: Set<String> = []
    private let idleGroup = DispatchGroup()
    /// 5.2b: consecutive scan/unit failures classified as storage
    /// failures (vanished/corrupt DB file, foreign rebuild of the same
    /// path, closed pool). At the threshold the queue would spin
    /// forever (3.8 run-3), so the coordinator rebuilds the storage
    /// underneath the pool and rescans.
    private var consecutiveStorageFailures = 0
    private let storageFailureRecoveryThreshold = 3

    init(source: ProviderIndexSource, store: ProviderStore) {
        self.source = source
        self.store = store
        self.queue = DispatchQueue(
            label: "io.lupen.provider-index.\(source.provider.rawValue)",
            qos: .utility
        )
    }

    // MARK: - Lifecycle

    /// Starts a fresh generation: metadata scan, then priority-ordered
    /// detail imports. Safe to call again (rescan); stale work from the
    /// previous generation stops at its next cancellation boundary.
    func start(eventSink: @escaping EventSink) {
        let generation: UInt64 = withState {
            lifecycleGeneration += 1
            isRunning = true
            self.eventSink = eventSink
            selectedQueue.removeAll()
            todayQueue.removeAll()
            backfillQueue.removeAll()
            pendingIds.removeAll()
            return lifecycleGeneration
        }
        idleGroup.enter()
        queue.async { [weak self] in
            defer { self?.idleGroup.leave() }
            self?.scanAndEnqueue(generation: generation)
        }
    }

    /// Re-runs the metadata scan and queues whatever it left
    /// non-imported (changed sources were demoted by the scanner).
    /// Same generation — in-flight units keep running.
    func requestRescan() {
        let generation: UInt64? = withState { isRunning ? lifecycleGeneration : nil }
        guard let generation else { return }
        idleGroup.enter()
        queue.async { [weak self] in
            defer { self?.idleGroup.leave() }
            self?.scanAndEnqueue(generation: generation)
        }
    }

    /// Jump a session to the front of the import queue (user selected
    /// it). No-op when its sources are already imported or in flight.
    func prioritize(sessionRawId: String) {
        let shouldPump: Bool = withState {
            guard isRunning else { return false }
            if let index = todayQueue.firstIndex(of: sessionRawId) {
                todayQueue.remove(at: index)
            } else if let index = backfillQueue.firstIndex(of: sessionRawId) {
                backfillQueue.remove(at: index)
            } else if pendingIds.contains(sessionRawId) {
                return false   // already selected-queued or in flight
            } else {
                pendingIds.insert(sessionRawId)
            }
            selectedQueue.append(sessionRawId)
            return true
        }
        if shouldPump { pump() }
    }

    /// Stops the worker: queued units are dropped, the in-flight unit
    /// cancels at its next batch boundary (its source stays
    /// `incomplete`; restart is idempotent — 2.8).
    func stop() {
        withState {
            lifecycleGeneration += 1
            isRunning = false
            eventSink = nil
            selectedQueue.removeAll()
            todayQueue.removeAll()
            backfillQueue.removeAll()
            pendingIds.removeAll()
        }
    }

    /// Blocks until queued work for the current generation drains.
    /// Test seam — production callers consume events instead.
    @discardableResult
    func waitUntilIdle(timeout: TimeInterval = 30) -> Bool {
        idleGroup.wait(timeout: .now() + timeout) == .success
    }

    /// Test seam: hold the pump so queue order can be arranged
    /// deterministically before any unit starts.
    func suspendPumpingForTesting() {
        withState { isPumpSuspended = true }
    }

    func resumePumpingForTesting() {
        withState { isPumpSuspended = false }
        pump()
    }

    /// Test seam: hold metadata scans (initial and rescans) so pre-scan
    /// behavior — e.g. the warm-index projection at driver start — is
    /// observable deterministically.
    func suspendScanningForTesting() {
        withState { isScanSuspended = true }
    }

    func resumeScanningForTesting() {
        let parked: [UInt64] = withState {
            isScanSuspended = false
            let generations = parkedScanGenerations
            parkedScanGenerations.removeAll()
            return generations
        }
        for generation in parked {
            idleGroup.enter()
            queue.async { [weak self] in
                defer { self?.idleGroup.leave() }
                self?.scanAndEnqueue(generation: generation)
            }
        }
    }

    // MARK: - Scan + enqueue

    private func scanAndEnqueue(generation: UInt64) {
        let parked: Bool = withState {
            guard isScanSuspended else { return false }
            parkedScanGenerations.append(generation)
            return true
        }
        if parked { return }
        guard isCurrent(generation) else { return }
        do {
            switch source {
            case .claude(let projectsDirectory):
                try ClaudeMetadataScanner(writer: store)
                    .scan(projectsDirectory: projectsDirectory)
            case .codex(let codexHome):
                try CodexMetadataScanner(writer: store).scan(codexHome: codexHome)
            }

            let sources = try store.allSourceFiles()
            let pendingUnits = enqueueUnits(from: sources, generation: generation)
            guard isCurrent(generation) else { return }
            emit(.metadataScanCompleted(
                provider: source.provider,
                pendingUnits: pendingUnits,
                coverage: try store.coverage()
            ))
        } catch {
            emit(.unitFailed(
                provider: source.provider,
                sessionRawId: "(metadata-scan)",
                message: String(describing: error)
            ))
            noteFailureAndRecoverIfPersistent(error, generation: generation)
        }
        pump()
    }

    /// Splits non-imported sources into today/backfill unit queues,
    /// newest first within each. Returns the number of queued units.
    private func enqueueUnits(from sources: [StoreSourceFile], generation: UInt64) -> Int {
        let startOfToday = configuration.calendar.startOfDay(for: Date())

        struct Candidate {
            var latestModified: Date = .distantPast
            var totalBytes: Int64 = 0
            var needsImport = false
        }
        var candidates: [String: Candidate] = [:]
        for sourceFile in sources {
            guard let sessionRawId = sourceFile.sessionRawId else { continue }
            var candidate = candidates[sessionRawId] ?? Candidate()
            if let modified = sourceFile.modifiedAt, modified > candidate.latestModified {
                candidate.latestModified = modified
            }
            candidate.totalBytes += sourceFile.byteSize
            switch sourceFile.parseState {
            case .pending, .metadata, .incomplete:
                candidate.needsImport = true
            case .imported, .failed:
                break   // failed = unreadable meta; rescan owns retries
            }
            candidates[sessionRawId] = candidate
        }

        // Newest-first, but demoted large units sort behind everything
        // small — a giant group at the head would block the serial
        // worker (and any selected-session jump) for its whole import.
        let demoteBytes = configuration.largeUnitDemoteBytes
        let work = candidates
            .filter { $0.value.needsImport }
            .sorted { lhs, rhs in
                let lhsLarge = lhs.value.totalBytes > demoteBytes
                let rhsLarge = rhs.value.totalBytes > demoteBytes
                if lhsLarge != rhsLarge { return rhsLarge }
                if lhs.value.latestModified != rhs.value.latestModified {
                    return lhs.value.latestModified > rhs.value.latestModified
                }
                return lhs.key < rhs.key
            }

        return withState {
            guard isRunning, lifecycleGeneration == generation else { return 0 }
            var queued = 0
            for (sessionRawId, candidate) in work where !pendingIds.contains(sessionRawId) {
                pendingIds.insert(sessionRawId)
                // Demoted large units never take the today lane either:
                // the lane exists so today's cost firms up in seconds,
                // and a giant unit there defeats every later jump.
                if candidate.totalBytes <= demoteBytes,
                   candidate.latestModified >= startOfToday {
                    todayQueue.append(sessionRawId)
                } else {
                    backfillQueue.append(sessionRawId)
                }
                queued += 1
            }
            return queued
        }
    }

    // MARK: - Worker pump

    private func pump() {
        let next: (sessionRawId: String, generation: UInt64)? = withState {
            guard isRunning, !isWorking, !isPumpSuspended else { return nil }
            let sessionRawId: String?
            if !selectedQueue.isEmpty {
                sessionRawId = selectedQueue.removeFirst()
            } else if !todayQueue.isEmpty {
                sessionRawId = todayQueue.removeFirst()
            } else if !backfillQueue.isEmpty {
                sessionRawId = backfillQueue.removeFirst()
            } else {
                sessionRawId = nil
            }
            guard let sessionRawId else { return nil }
            isWorking = true
            return (sessionRawId, lifecycleGeneration)
        }
        guard let next else {
            emitIdleIfDrained()
            return
        }

        idleGroup.enter()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.idleGroup.leave() }
            // Per-unit autorelease drain (5.7): on a continuously busy
            // serial queue libdispatch may not pop its pool until the
            // queue idles — at ~24 units/s the transient read buffers
            // accumulated to 6.5 GB across a 10 GB-corpus backfill
            // (the scanners learned the same lesson per file at the
            // Phase 3 gate).
            autoreleasepool {
                self.importUnit(sessionRawId: next.sessionRawId, generation: next.generation)
            }
            self.withState {
                self.isWorking = false
                self.pendingIds.remove(next.sessionRawId)
            }
            self.pump()
        }
    }

    private func importUnit(sessionRawId: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        let isCancelled: @Sendable () -> Bool = { [weak self] in
            !(self?.isCurrent(generation) ?? false)
        }
        do {
            // Unit-scoped fetch (5.7): the full-table fetch here made
            // import throughput quadratic in source count.
            let sources = try store.sourceFiles(sessionRawId: sessionRawId)
            switch source {
            case .claude:
                var importerConfiguration = ClaudeDetailImporter.Configuration()
                importerConfiguration.writeBatchRowLimit = configuration.writeBatchRowLimit
                let importer = ClaudeDetailImporter(
                    writer: store, configuration: importerConfiguration
                )
                try importer.importUnit(
                    ClaudeImportUnit.unit(
                        forSessionRawId: sessionRawId, projectPath: nil, sources: sources
                    ),
                    isCancelled: isCancelled
                )
            case .codex(let codexHome):
                var importerConfiguration = CodexDetailImporter.Configuration()
                importerConfiguration.writeBatchRowLimit = configuration.writeBatchRowLimit
                importerConfiguration.oversizedPieceByteThreshold = configuration.oversizedPieceByteThreshold
                let importer = CodexDetailImporter(
                    writer: store, configuration: importerConfiguration
                )
                try importer.importUnit(
                    CodexImportUnit.unit(
                        forSessionRawId: sessionRawId, codexHome: codexHome, sources: sources
                    ),
                    isCancelled: isCancelled
                )
            }
            guard isCurrent(generation) else { return }
            withState { consecutiveStorageFailures = 0 }
            emit(.unitImported(
                provider: source.provider,
                scopedSessionId: ProviderScopedID(
                    provider: source.provider, rawSessionId: sessionRawId
                ).value,
                coverage: (try? store.coverage())
                    ?? StoreCoverage(
                        totalSources: 0, importedSources: 0,
                        incompleteSources: 0, pendingSources: 0, failedSources: 0
                    )
            ))
        } catch {
            guard isCurrent(generation) else { return }
            // A deterministic per-unit failure (bad bytes, a
            // constraint bug) would otherwise re-queue on every rescan
            // and fail forever — the perpetually-pending sessions of
            // 6.10. Park the unit's unimported sources as `failed`; a
            // file change flips them back to `metadata` via the
            // scanner's fingerprint check, which is exactly the
            // existing "rescan owns retries" contract. Cancellation is
            // NOT an error path (G13) — cancelled sources stay
            // `incomplete` and re-queue freely.
            try? store.markUnimportedSourcesFailed(sessionRawId: sessionRawId)
            emit(.unitFailed(
                provider: source.provider,
                sessionRawId: sessionRawId,
                message: String(describing: error)
            ))
            noteFailureAndRecoverIfPersistent(error, generation: generation)
        }
    }

    // MARK: - Storage failure recovery (plan 5.2b)

    /// 3.8 run-3: when the DB file vanishes (or a foreign instance
    /// rebuilds the same path) every subsequent write fails with an
    /// I/O-class error and the import loop spins — failed units retry
    /// on each rescan against a pool whose storage is gone. After
    /// `storageFailureRecoveryThreshold` CONSECUTIVE storage-classified
    /// failures, rebuild the storage in place (pool swap keeps every
    /// `ProviderStore` reference valid) and rescan from the source
    /// logs. Non-storage failures reset nothing here — they stay
    /// per-unit problems owned by the next rescan.
    private func noteFailureAndRecoverIfPersistent(_ error: Error, generation: UInt64) {
        guard ProviderDatabase.isStorageFailure(error) else { return }
        let shouldRecover: Bool = withState {
            consecutiveStorageFailures += 1
            return consecutiveStorageFailures >= storageFailureRecoveryThreshold
        }
        guard shouldRecover, isCurrent(generation) else { return }

        LoggerService.shared.logFromAnyThread(
            .error,
            "Provider index storage failing persistently (\(source.provider.rawValue)) — "
                + "rebuilding \(store.database.fileURL.path) and re-scanning. Last error: \(error)",
            context: "Store"
        )
        withState {
            consecutiveStorageFailures = 0
            selectedQueue.removeAll()
            todayQueue.removeAll()
            backfillQueue.removeAll()
            pendingIds.removeAll()
        }
        do {
            try store.database.rebuildStorage()
        } catch {
            LoggerService.shared.logFromAnyThread(
                .error,
                "Provider index storage rebuild FAILED (\(source.provider.rawValue)) — "
                    + "imports stay parked until the next rescan: \(error)",
                context: "Store"
            )
            return
        }
        LoggerService.shared.logFromAnyThread(
            .warning,
            "Provider index storage rebuilt fresh (\(source.provider.rawValue)) — re-indexing from source logs",
            context: "Store"
        )
        requestRescan()
    }

    private func emitIdleIfDrained() {
        let shouldEmit: Bool = withState {
            isRunning && !isWorking && !isPumpSuspended
                && selectedQueue.isEmpty && todayQueue.isEmpty && backfillQueue.isEmpty
        }
        guard shouldEmit, let coverage = try? store.coverage() else { return }
        emit(.idle(provider: source.provider, coverage: coverage))
    }

    // MARK: - Plumbing

    private func emit(_ event: ProviderIndexEvent) {
        let sink: EventSink? = withState { eventSink }
        sink?(event)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        withState { isRunning && lifecycleGeneration == generation }
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
