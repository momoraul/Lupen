//
//  SQLiteFirstStartup.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Maps SQLite session shells onto the `[Session]` surface the sidebar
/// already consumes (plan 3.2): titles, project, visibility, and the
/// request-derived time range — but never request rows or turns. The
/// sidebar's title chain (custom → cached → slug → id prefix) keeps
/// working; conversation/detail surfaces stay on their own queries.
enum SessionShellProjection {

    static func sessions(
        store: ProviderStore,
        provider: ProviderKind,
        pageSize: Int = 500
    ) throws -> [Session] {
        var rows: [StoreSessionRow] = []
        var cursor: StoreSessionPageCursor?
        repeat {
            let page = try store.sessionPage(
                visibleOnly: false, projectPath: nil, limit: pageSize, cursor: cursor
            )
            rows.append(contentsOf: page.rows)
            cursor = page.nextCursor
        } while cursor != nil

        return rows.map { row in
            Session(
                id: row.id,
                provider: provider,
                rawSessionId: row.rawId,
                requests: [],
                projectPath: row.projectPath,
                isVisibleInSessionList: row.visible,
                cachedTitle: row.cachedTitle,
                customTitle: row.customTitle,
                shellStartTime: row.startTime,
                shellEndTime: row.endTime,
                shellSlug: row.slug,
                shellGitBranch: row.lastGitBranch,
                shellFirstPrompt: row.firstPrompt
            )
        }
    }
}

/// Phase 3.2 startup v2 driver, owned by `AppDelegate` (the ONLY
/// startup path since 5.1; the legacy in-memory startup flag was removed
/// in 5.5): opens the provider's index database, runs
/// the `ProviderIndexCoordinator` (metadata scan → priority imports),
/// and applies sidebar projections into `AppStateStore` on the main
/// actor. The store mutates ONLY here, never from importer threads
/// (plan Rule 2); refreshes are throttled so a long backfill doesn't
/// re-project on every unit.
final class SQLiteFirstStartup: @unchecked Sendable {

    let coordinator: ProviderIndexCoordinator
    private weak var appStore: AppStateStore?
    private let source: ProviderIndexSource
    private let provider: ProviderKind
    /// Whether this launch wiped-and-rebuilt (schema bump) or created the
    /// index fresh — surfaced to `AppStateStore.didRebuildThisLaunch` so the
    /// UI can flag the full backfill (menu-bar placeholder, sidebar footer).
    private let bootstrapOutcome: ProviderDatabase.BootstrapOutcome
    private let refreshThrottle: TimeInterval
    private let rescanDebounce: TimeInterval
    private let isFileWatchingEnabled: Bool
    private let fileWatcher = FileWatcher()
    private var wallClockObserver: NSObjectProtocol?
    private var lastRefresh: Date = .distantPast
    private var refreshScheduled = false
    private var rescanScheduled = false
    /// Convergence guard for the menu-bar today snapshot (3.3 stale-flag
    /// fix). `TodayUsageSnapshot.isComplete` latches whatever the pending
    /// source count was at computation time; if the import queue settles
    /// without a further coordinator event, the stale `false` would
    /// otherwise keep the status bar's "…" placeholder up until the next
    /// hourly wall-clock tick. A single self-terminating retry re-checks
    /// until coverage is complete. Main-actor access only.
    private var todayUsageConvergenceScheduled = false
    /// Steady-state anti-flicker for the menu-bar today number: once
    /// today's total converges, later transient "still importing" reads
    /// (a live append) keep showing the number instead of the "…"
    /// placeholder. Resets on day rollover. Main-actor access only.
    private var todayUsageLatch = TodayUsageLatch()
    private var pendingPriorityIds: Set<String> = []
    /// Plan 3.5: provider switch = projection swap. An inactive driver
    /// keeps scanning/importing its database but never writes into
    /// `AppStateStore`; activating it re-projects instantly from SQLite.
    /// Main-actor access only.
    private var isProjectionActive = true
    private var didRecordSidebarReady = false
    /// 5.3c: cheap change guard so the diagnostics snapshot rebuild
    /// (3 reads + 20-row map) runs only when the persisted issue
    /// counts actually moved. Main-actor access only.
    private var lastDiagnosticsFingerprint: (warning: Int, error: Int)?

    init(
        source: ProviderIndexSource,
        appStore: AppStateStore,
        databaseURL: URL? = nil,
        refreshThrottle: TimeInterval = 0.5,
        rescanDebounce: TimeInterval = 0.5,
        isFileWatchingEnabled: Bool = true
    ) throws {
        let resolvedURL = databaseURL ?? LupenPaths
            .providerRoot(for: source.provider)
            .appendingPathComponent("index.sqlite3")
        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try ProviderDatabase.open(at: resolvedURL)
        self.bootstrapOutcome = database.outcome
        self.coordinator = ProviderIndexCoordinator(
            source: source,
            store: ProviderStore(database: database)
        )
        self.appStore = appStore
        self.source = source
        self.provider = source.provider
        self.refreshThrottle = refreshThrottle
        self.rescanDebounce = rescanDebounce
        self.isFileWatchingEnabled = isFileWatchingEnabled
    }

    deinit {
        if let wallClockObserver {
            NotificationCenter.default.removeObserver(wallClockObserver)
        }
    }

    func start() {
        Task { @MainActor [weak self] in
            guard let self, self.isProjectionActive, let appStore = self.appStore else { return }
            self.installConversationSource()
            // A schema bump (wipe-and-reindex) or first run backfills the
            // whole corpus; the UI uses this to show "rebuilding" instead of
            // a silently partial total.
            appStore.didRebuildThisLaunch = self.bootstrapOutcome != .opened
            var progress = LaunchProgress()
            progress.phase = .scanningFiles
            progress.startedAt = Date()
            appStore.launchProgress = progress
            // Warm index: serve the existing shells before the rescan
            // finishes — a daily launch must not hold the sidebar blank
            // behind tens of thousands of file stats. A fresh index has
            // no rows yet; it becomes ready at the first scan completion.
            self.refreshSessions(force: true)
            if !appStore.sessions.isEmpty {
                appStore.hasInitialData = true
                appStore.isLoading = false
                self.recordSidebarReadyIfNeeded(appStore: appStore, pendingUnits: nil)
            }
        }
        coordinator.start { [weak self] event in
            Task { @MainActor [weak self] in
                self?.apply(event)
            }
        }
        if isFileWatchingEnabled {
            startWatching()
        }
        observeWallClock()
    }

    func stop() {
        fileWatcher.stopAll()
        coordinator.stop()
    }

    // MARK: - Projection swap (plan 3.5)

    /// Makes this driver the one rendering into `AppStateStore` and
    /// re-projects immediately — the swap is a pair of SQLite reads,
    /// never a parse.
    @MainActor
    func activateProjection() {
        isProjectionActive = true
        installConversationSource()
        refreshSessions(force: true)
        guard let appStore else { return }
        appStore.hasInitialData = true
        appStore.isLoading = false
    }

    /// Background indexing continues; only the store writes stop.
    @MainActor
    func deactivateProjection() {
        isProjectionActive = false
    }

    /// Plan 5.2: user-triggered "Rebuild Index" — wipe every derived
    /// row and re-scan the source logs in the background. The wipe runs
    /// against the open pool (never delete DB files under a live writer
    /// — the 3.8 run-3 disk-I/O lesson); the next scan re-registers all
    /// sources as new and imports re-run in the usual priority order.
    /// Source JSONL logs are never touched.
    @MainActor
    func rebuildIndex() {
        if isProjectionActive, let appStore {
            appStore.sessions = []
            appStore.sessionListAggregates = [:]
            appStore.diagnostics.restore(.empty)
            lastDiagnosticsFingerprint = nil
            appStore.sqliteTodayUsage = nil
            appStore.isLoading = true
            var progress = LaunchProgress()
            progress.phase = .scanningFiles
            progress.startedAt = Date()
            appStore.launchProgress = progress
        }
        let store = coordinator.store
        let coordinator = self.coordinator
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try store.wipeAllIndexedData()
            } catch {
                LoggerService.shared.logFromAnyThread(
                    .error,
                    "Rebuild index: wipe failed — \(error)",
                    context: "Store"
                )
                return
            }
            coordinator.requestRescan()
        }
    }

    /// Routes the conversation outline to this driver's index
    /// (plan 4.1). Called on activation and at `start()` — the
    /// projection-active driver owns the store's conversation reads.
    @MainActor
    private func installConversationSource() {
        appStore?.sqliteConversationSource = SQLiteConversationSource(
            store: coordinator.store,
            provider: provider
        )
        appStore?.prioritizeSessionImport = { [weak self] rawSessionId in
            self?.prioritizeSelectedSession(rawSessionId)
        }
    }

    /// Plan §1 import priority ② — the user selected a session, so its
    /// atomic unit jumps the queue. Guarded by the same needs-import
    /// predicate as the scan's queue builder (pending/metadata/
    /// incomplete): `prioritize` alone would re-queue ALREADY-imported
    /// units and re-import a session on every click.
    func prioritizeSelectedSession(_ rawSessionId: String) {
        let store = coordinator.store
        let coordinator = self.coordinator
        DispatchQueue.global(qos: .userInitiated).async {
            guard let sources = try? store.sourceFiles(sessionRawId: rawSessionId),
                  !sources.isEmpty,
                  sources.contains(where: { source in
                      switch source.parseState {
                      case .pending, .metadata, .incomplete: return true
                      case .imported, .failed: return false
                      }
                  })
            else { return }
            coordinator.prioritize(sessionRawId: rawSessionId)
        }
    }

    // MARK: - Live updates (plan 3.4)

    /// FSEvents → debounced rescan: the scanner demotes exactly the
    /// changed sources, the coordinator re-queues their units, and the
    /// touched session jumps the queue so an open conversation updates
    /// first. Units always restart from byte 0 (G13) — re-import is
    /// idempotent, so there is no tail-cursor state to corrupt.
    private func startWatching() {
        let directory: URL
        switch source {
        case .claude(let projectsDirectory): directory = projectsDirectory
        case .codex(let codexHome): directory = codexHome
        }
        fileWatcher.setCallbacks(
            onFileAppend: { [weak self] url, _ in
                self?.handleFileEvent(url: url)
            },
            onDirectoryChange: { [weak self] in
                self?.handleFileEvent(url: nil)
            }
        )
        fileWatcher.startWatching(directory: directory)
    }

    private func handleFileEvent(url: URL?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url,
               let sourceRow = try? self.coordinator.store.sourceFile(
                   path: url.standardizedFileURL.path
               ),
               let sessionRawId = sourceRow.sessionRawId {
                self.pendingPriorityIds.insert(sessionRawId)
            }
            self.scheduleRescan()
        }
    }

    @MainActor
    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        let delay = rescanDebounce
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.rescanScheduled = false
            let priorityIds = self.pendingPriorityIds
            self.pendingPriorityIds.removeAll()
            // Rescan first (FIFO on the coordinator queue), then jump
            // the touched sessions ahead of the re-queued backlog.
            self.coordinator.requestRescan()
            for sessionRawId in priorityIds.sorted() {
                self.coordinator.prioritize(sessionRawId: sessionRawId)
            }
        }
    }

    /// Sessions already queued for a stale-pricing re-import this run —
    /// a session whose sources vanished can never refresh its rows, so
    /// without this guard every idle tick would re-queue it forever.
    /// Main-actor access only.
    private var staleCostRequeueAttempted: Set<String> = []

    /// 6.8: `requests.pricing_version` rows older than the current
    /// `PricingTable.version` get their whole unit re-imported (turn
    /// aggregate columns reprice too — a row-level finalize would leave
    /// the turn headers at the old totals). Bare `prioritize` is the
    /// right tool here: unlike the selection path, re-importing an
    /// already-imported unit is exactly the point.
    /// Compact-continuation lineage collapse. Re-homes redundant snapshot
    /// sessions onto their canonical leaf and stamps `superseded_by` so the
    /// sidebar shows one session per conversation and Verify Costs stops
    /// flagging the replay overlap. DB-only and idempotent; the file reads
    /// touch only the few sessions carrying a `logical_parent_uuid`.
    /// Coalesces overlapping resolve passes: now that re-home fires on BOTH
    /// `.idle` AND coverage-complete (not just idle), rapid events could
    /// otherwise stack concurrent whole-corpus resolves. The in-flight run
    /// reads the latest membership when it starts, so a skipped trigger is
    /// covered by the next event (idle / next settled scan).
    @MainActor private var lineageResolveInFlight = false

    @MainActor
    private func resolveContinuationLineages() {
        guard !lineageResolveInFlight else { return }
        lineageResolveInFlight = true
        let store = coordinator.store
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolution = try? ClaudeContinuationResolver.run(store: store)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lineageResolveInFlight = false
                if let resolution, !resolution.hidden.isEmpty {
                    self.refreshSessions(force: true)
                }
            }
        }
    }

    @MainActor
    private func requeueStaleCostSessionsOnce() {
        let store = coordinator.store
        let coordinator = self.coordinator
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let stale = try? store.sessionIdsWithStaleCosts(
                pricingVersion: PricingTable.version
            ), !stale.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let fresh = stale.filter { !self.staleCostRequeueAttempted.contains($0) }
                guard !fresh.isEmpty else { return }
                self.staleCostRequeueAttempted.formUnion(fresh)
                LoggerService.shared.logFromAnyThread(
                    .info,
                    "Re-importing \(fresh.count) session(s) priced at an old pricing-table version (now v\(PricingTable.version))",
                    context: "Store"
                )
                for scopedId in fresh {
                    coordinator.prioritize(
                        sessionRawId: ProviderScopedID.rawID(from: scopedId)
                    )
                }
            }
        }
    }

    /// Midnight rollover (closes the 3.3 gap): the menu-bar today
    /// snapshot recomputes on every wall-clock hour tick, not just on
    /// coordinator events.
    private func observeWallClock() {
        wallClockObserver = NotificationCenter.default.addObserver(
            forName: WallClockCoordinator.wallClockTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTodayUsage()
            }
        }
    }

    // MARK: - Main-actor projection application

    @MainActor
    private func apply(_ event: ProviderIndexEvent) {
        if case .unitFailed(_, let sessionRawId, let message) = event {
            LoggerService.shared.logFromAnyThread(
                .warning,
                "SQLite-first import failed for \(sessionRawId): \(message)",
                context: "Store"
            )
            return
        }
        if case .idle = event {
            // Pricing-table bumps without a schema bump leave imported
            // rows priced at the old version (6.8 — the fable rows sat
            // at $0 after a v1-priced rebuild). Once the queue drains,
            // re-import any session still carrying stale pricing; runs
            // for active AND inactive drivers (it only touches the DB).
            requeueStaleCostSessionsOnce()
            // Collapse compact-continuation snapshots into their canonical
            // leaf once the imports they depend on have landed (DB-only).
            resolveContinuationLineages()
        }
        guard isProjectionActive else { return }
        switch event {
        case .metadataScanCompleted(_, let pendingUnits, let coverage):
            refreshSessions(force: true)
            guard let appStore else { return }
            appStore.hasInitialData = true
            // Sidebar is usable from shells; detail imports continue in
            // the background with unit-counted coverage (3.6).
            appStore.isLoading = false
            appStore.loadingProgress = pendingUnits > 0
                ? "Indexing \(pendingUnits) sessions in background..."
                : ""
            // `.done` needs BOTH "this scan queued nothing new" AND
            // complete coverage — a mid-backfill rescan queues zero NEW
            // units while the in-flight ones (e.g. the jumbo group) are
            // still importing (5.7 acceptance-run finding: the launch
            // overlay flipped to done mid-jumbo on a live-corpus event).
            let isSettled = pendingUnits == 0 && coverage.isComplete
            var progress = LaunchProgress()
            progress.phase = isSettled ? .done : .indexing
            progress.pendingUnits = pendingUnits
            progress.processedUnits = 0
            progress.startedAt = Date()
            appStore.launchProgress = progress
            if isSettled {
                appStore.hasCompletedInitialIndex = true
                // Re-home as soon as coverage is complete — don't wait for a
                // separate `.idle` event (which a warm launch with nothing
                // queued may never emit). Shrinks the "imported but not yet
                // re-homed" window that made Verify Costs look mismatched
                // mid-rebuild. Idempotent + in-flight-guarded.
                resolveContinuationLineages()
            }
            recordSidebarReadyIfNeeded(appStore: appStore, pendingUnits: pendingUnits)
        case .unitImported:
            refreshSessions(force: false)
            if let appStore, appStore.launchProgress.phase == .indexing {
                appStore.launchProgress.processedUnits += 1
            }
        case .idle:
            refreshSessions(force: true)
            guard let appStore else { return }
            appStore.loadingProgress = ""
            appStore.hasCompletedInitialIndex = true
            if appStore.launchProgress.phase != .done {
                var progress = appStore.launchProgress
                progress.phase = .done
                progress.processedUnits = progress.pendingUnits
                appStore.launchProgress = progress
            }
        case .unitFailed:
            break   // handled (and logged) before the projection guard
        }
    }

    /// Phase 3 startup budget surface (plan 0.5): the first moment this
    /// driver's projection serves rows — at `start()` on a warm index,
    /// otherwise at the first completed metadata scan. Recorded once.
    @MainActor
    private func recordSidebarReadyIfNeeded(appStore: AppStateStore, pendingUnits: Int?) {
        guard !didRecordSidebarReady else { return }
        didRecordSidebarReady = true
        var metadata = [
            "provider": provider.rawValue,
            "sessions": "\(appStore.sessions.count)"
        ]
        if let pendingUnits {
            metadata["pendingUnits"] = "\(pendingUnits)"
        }
        LaunchMemoryCheckpoint.record(
            "app.sqliteFirst.sidebarReady",
            config: .current(),
            metadata: metadata
        )
    }

    @MainActor
    private func refreshSessions(force: Bool) {
        guard isProjectionActive else { return }
        if !force {
            let now = Date()
            guard now.timeIntervalSince(lastRefresh) >= refreshThrottle else {
                scheduleTrailingRefresh()
                return
            }
        }
        refreshScheduled = false
        lastRefresh = Date()
        guard let appStore,
              let sessions = try? SessionShellProjection.sessions(
                  store: coordinator.store, provider: provider
              ) else { return }
        appStore.sessions = sessions
        // Sidebar cell metrics ride the same cadence (5.3) — without
        // them the cells would render zero cost/requests from the empty
        // shell `requests` arrays.
        appStore.sessionListAggregates =
            (try? coordinator.store.sessionListAggregates()) ?? [:]
        refreshDiagnostics(appStore: appStore)
        // Menu-bar today usage rides the same refresh cadence (3.3);
        // so does the conversation outline's re-snapshot signal (4.1).
        refreshTodayUsage()
        appStore.sqliteConversationGeneration &+= 1
    }

    /// 5.3c: project the index's persisted warning/error diagnostics
    /// into the `ParseDiagnostics` surface (status-bar badge, dropdown
    /// counts, Diagnostics window) — nothing else produces it under
    /// SQLite-first.
    @MainActor
    private func refreshDiagnostics(appStore: AppStateStore) {
        guard let severity = try? coordinator.store.severityCounts() else { return }
        let fingerprint = (warning: severity.warning, error: severity.error)
        if let last = lastDiagnosticsFingerprint,
           last == fingerprint {
            return
        }
        guard let snapshot = DiagnosticsProjection.snapshot(store: coordinator.store) else {
            return
        }
        lastDiagnosticsFingerprint = fingerprint
        appStore.diagnostics.restore(snapshot)
    }

    /// Delay before re-checking an incomplete today snapshot. Long
    /// enough to let an in-flight unit finish, short enough that the
    /// menu-bar placeholder clears promptly after the queue drains.
    private static let todayUsageConvergenceDelay: TimeInterval = 3

    @MainActor
    private func refreshTodayUsage() {
        guard isProjectionActive else { return }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let projected = TodayUsageProjection.snapshot(store: coordinator.store)
        // Steady-state hysteresis: hold the number once today converged so
        // active Claude Code appends don't flicker the "…" placeholder.
        let snapshot = todayUsageLatch.resolve(projected, startOfToday: startOfToday)
        appStore?.sqliteTodayUsage = snapshot
        // Before the first convergence, `isComplete` is a point-in-time
        // read of the pending count. When the last of today's sources
        // finishes after this projection — and no `.idle`/import event
        // follows — the stale `false` would keep "…" up until the next
        // hourly tick. Re-check shortly so it resolves in seconds instead.
        // After convergence the latch forces `true`, so the heartbeat
        // naturally stops.
        if snapshot?.isComplete == false {
            scheduleTodayUsageConvergence()
        }
    }

    /// Re-projects the today snapshot a short moment later, but only
    /// while it stays incomplete: one retry is ever in flight, and it
    /// stops re-arming the moment coverage completes or the driver goes
    /// inactive — so active imports get a cheap 3 s heartbeat and a
    /// settled queue converges once and stops.
    @MainActor
    private func scheduleTodayUsageConvergence() {
        guard !todayUsageConvergenceScheduled else { return }
        todayUsageConvergenceScheduled = true
        let delay = Self.todayUsageConvergenceDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.todayUsageConvergenceScheduled = false
            guard self.isProjectionActive else { return }
            self.refreshTodayUsage()
        }
    }

    /// Coalesces a burst of unit imports into one trailing projection.
    @MainActor
    private func scheduleTrailingRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let delay = refreshThrottle
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.refreshScheduled else { return }
            self.refreshSessions(force: true)
        }
    }
}
