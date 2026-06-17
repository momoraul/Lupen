import Foundation
import Observation

@Observable
final class AppStateStore: @unchecked Sendable {

    // MARK: - Observable State

    var sessions: [Session] = []
    var isLoading: Bool = true
    var loadingProgress: String = ""
    /// Launch progress. `loadingProgress: String` above is kept for
    /// backward compatibility; UI should prefer this observable.
    /// See `LaunchProgress` for details.
    var launchProgress: LaunchProgress = LaunchProgress()
    /// True once the store has *any* usable data to display — set by the
    /// SQLite-first projection (and `performInitialParse()` in tests). Distinct from
    /// `isLoading`, which stays true during the background reparse even after the
    /// cache has already populated the UI. The menu bar uses this flag (not
    /// `isLoading`) to decide between the placeholder "..." and the real token count,
    /// so cache-hit launches show the number immediately.
    var hasInitialData: Bool = false
    /// True when THIS launch rebuilt or freshly created the index (schema
    /// bump → wipe-and-reindex, or first run). Set once at startup from the
    /// bootstrap outcome; gates the menu-bar "still building" placeholder so
    /// a warm launch (index already present) never dims its cost.
    var didRebuildThisLaunch: Bool = false
    /// One-way latch: flips true the first time the launch indexing settles
    /// (`launchProgress.phase == .done`). Once set it never clears, so later
    /// incremental imports (a single file change re-queuing one unit) do NOT
    /// re-trigger the full-rebuild treatment in the menu bar.
    var hasCompletedInitialIndex: Bool = false
    var activeSessionId: String? = nil
    var activeSessionLastAppend: Date? = nil

    /// Any active scan/import is in flight — drives the sidebar footer and
    /// the Verify Costs "preliminary" banner (both honest during ordinary
    /// background imports too).
    var isIndexing: Bool {
        launchProgress.phase == .scanningFiles || launchProgress.phase == .indexing
    }

    /// The heavyweight case: this launch is (re)building the whole index and
    /// hasn't finished its first full backfill yet. Drives the menu-bar cost
    /// placeholder so a partially-imported total isn't mistaken for final.
    var isInitialBackfill: Bool {
        didRebuildThisLaunch && !hasCompletedInitialIndex && isIndexing
    }

    /// Currently-viewed session id as reported by the UI
    /// (`TurnOutlineViewController.showSession` writes here). Used
    /// strictly for **diagnostic logging** — specifically to surface
    /// "you are viewing session X but new appends are landing on
    /// session Y" in the file log. Not `@Observable` and has no
    /// behavioural consumers; setting it wrong cannot break the UI.
    ///
    /// Plan 17 follow-up: the "list not updating" symptom is usually
    /// caused by the user's currently-selected session not being the
    /// one Claude Code is appending to (e.g. they ran `claude` instead
    /// of `claude --resume`, spawning a new JSONL). This field lets
    /// the `handleNewData` / `scheduleRebuild` logs call that out
    /// explicitly so the discrepancy is visible without live
    /// observation.
    var uiViewedSessionId: String? = nil
    /// Observable accumulator of JSONL parse rejections. Subscribed by
    /// the status-bar badge and Diagnostics window. See
    /// `docs/PARSE-DIAGNOSTICS.md`. Producer under SQLite-first lands
    /// with plan 5.3c (DB diagnostics projection).
    let diagnostics = ParseDiagnostics()

    // MARK: - Private State

    private(set) var activeProvider: ProviderKind = .claudeCode

    private let claudeProvider: ClaudeProvider

    private let projectsDirectoryOverride: URL?
    var effectiveProjectsDirectory: URL {
        projectsDirectoryOverride ?? claudeProvider.defaultSourceRoot
    }
    var codexHomeForSkillCatalog: URL {
        CodexSessionDiscovery().codexHome.standardizedFileURL
    }

    private let launchDiagnosticsConfig: LaunchDiagnosticsConfig

    // MARK: - Init

    init(
        projectsDirectory: URL? = nil,
        launchDiagnosticsConfig: LaunchDiagnosticsConfig = .current(),
        claudeProvider: ClaudeProvider = ClaudeProvider()
    ) {
        self.projectsDirectoryOverride = projectsDirectory
        self.claudeProvider = claudeProvider
        self.launchDiagnosticsConfig = launchDiagnosticsConfig
    }

    private func scopedClaudeSessionId(_ sessionId: String) -> String {
        ProviderScopedID.normalize(sessionId, defaultProvider: .claudeCode)
    }

    private func rawSessionId(from sessionId: String) -> String {
        ProviderScopedID.rawID(from: sessionId)
    }

    private func recordLaunchMemory(
        _ label: String,
        metadata: [String: String] = [:]
    ) {
        LaunchMemoryCheckpoint.record(
            label,
            config: launchDiagnosticsConfig,
            metadata: metadata
        )
    }

    // MARK: - Provider Mode

    /// Plan 3.5 (SQLite-first): a provider switch is a projection swap —
    /// the driver flips the active provider and re-projects from SQLite.
    /// The legacy `switchProvider` graph capture/restore was deleted in
    /// Phase 5.1.
    func setActiveProviderForProjectionSwap(_ provider: ProviderKind) {
        activeProvider = provider
    }

    /// Public entry point for the active provider usage audit engine.
    ///
    /// Invoked when the user clicks "Run" in the Verify Costs window.
    /// **Not** run automatically — auto-running adds tens of seconds to
    /// every launch and floods the diagnostics panel with noise the
    /// user never asked for.
    ///
    /// Steps:
    ///   1. Enumerate active-provider JSONL files.
    ///   2. Background: provider verifier independently computes per-session
    ///      cost / tokens / pickedRequestIds.
    ///   3. Main: compare against the live store state.
    ///   4. Delivers a `VerifyCostsResult` via completion (UI renders
    ///      the divergence table).
    ///
    /// Results are **not** written to ParseDiagnostics — they surface
    /// only in the Verify Costs window. Keeps the Diagnostics window
    /// focused on JSONL format drift and free of audit noise.
    func verifyActiveProviderUsage(
        completion: @escaping @MainActor (VerifyCostsResult) -> Void
    ) {
        let log = LoggerService.shared
        let provider = activeProvider
        let verifier = usageVerifier(for: provider)
        let urls = verificationSourceURLs(for: provider)
        let totalFiles = urls.count
        let providerName = provider.descriptor.displayName
        log.logFromAnyThread(
            .info,
            "Verify Usage (\(providerName)): starting on \(totalFiles) files (background scan)…",
            context: "UsageVerification"
        )
        let startedAt = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, verifier] in
            let scanStart = CFAbsoluteTimeGetCurrent()
            let report = verifier.computeReport(files: urls)
            let scanElapsed = CFAbsoluteTimeGetCurrent() - scanStart
            log.logFromAnyThread(
                .info,
                String(
                    format: "Verify Usage (%@): scan complete in %.2fs (%d usage lines, %d sessions, %d source issues). Verifying against view…",
                    providerName, scanElapsed, report.usageLines.count, report.perSession.count, report.issues.count
                ),
                context: "UsageVerification"
            )

            DispatchQueue.main.async {
                guard let self else { return }
                let verifyStart = CFAbsoluteTimeGetCurrent()
                // SQLite-first: the in-memory graphs are shells — compare
                // against the provider index instead (plan 4.5).
                let verification: GroundTruthVerifier.SQLiteVerification =
                    self.sqliteConversationSource.map {
                        verifier.verify(report: report, againstSQLite: $0.store)
                    } ?? GroundTruthVerifier.SQLiteVerification(
                        divergences: [], pendingSessionIds: []
                    )
                let divergences = verification.divergences
                let verifyElapsed = CFAbsoluteTimeGetCurrent() - verifyStart
                let completedAt = Date()
                let totalElapsed = completedAt.timeIntervalSince(startedAt)

                let summary = String(
                    format: "Verify Usage (%@): COMPLETE in %.2fs (scan=%.2fs verify=%.2fs) — %d divergences, %d sessions pending import",
                    providerName, totalElapsed, scanElapsed, verifyElapsed,
                    divergences.count, verification.pendingSessionIds.count
                )
                if divergences.isEmpty {
                    log.logFromAnyThread(.success, summary, context: "UsageVerification")
                } else {
                    log.logFromAnyThread(.warning, summary, context: "UsageVerification")
                }

                let result = VerifyCostsResult(
                    provider: provider,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    scanElapsed: scanElapsed,
                    verifyElapsed: verifyElapsed,
                    filesScanned: totalFiles,
                    report: report,
                    divergences: divergences,
                    viewSessionIds: Set(self.sessions.map(\.id)),
                    pendingSessionIds: verification.pendingSessionIds
                )
                completion(result)
            }
        }
    }

    func verifyAgainstGroundTruth(
        completion: @escaping @MainActor (VerifyCostsResult) -> Void
    ) {
        verifyActiveProviderUsage(completion: completion)
    }

    private func usageVerifier(for provider: ProviderKind) -> any ProviderUsageVerifier {
        switch provider {
        case .claudeCode:
            return ClaudeUsageVerifier()
        case .codex:
            return CodexUsageVerifier()
        }
    }

    private func verificationSourceURLs(for provider: ProviderKind) -> [URL] {
        switch provider {
        case .claudeCode:
            return claudeProvider.discoverFiles(in: effectiveProjectsDirectory).map(\.url)
        case .codex:
            // SQLite-first: the index's source registry IS the rollout
            // list (the legacy in-memory map died with the graphs).
            let paths = (try? sqliteConversationSource?.store.allSourceFiles()) ?? []
            return paths.map { URL(fileURLWithPath: $0.path) }
                .sorted { $0.path < $1.path }
        }
    }

    // MARK: - Lazy rawJSON loader (Plan 13 Phase 8)

    /// In-memory cache of lazily-loaded JSONL lines keyed by Step uuid.
    /// Bounded via simple drop-all-on-overflow — the Raw / Usage tabs are
    /// click-driven so hundreds of distinct lookups per session is rare.
    private var rawJSONCache: [String: Data] = [:]
    private let rawJSONCacheCapacity = 256
    private var rawJSONCacheBytes = 0
    private let rawJSONCacheByteCapacity = 8 * 1024 * 1024

    /// Returns the original JSONL line bytes for `step`, scanning the
    /// session's file on disk if the Step's in-memory `rawJSON` is nil
    /// (the case after a snapshot-restored launch).
    ///
    /// Resolution order:
    ///   1. `step.rawJSON` (live-parsed Steps still carry it in memory)
    ///   2. `rawJSONCache[step.uuid]` (previously loaded on this run)
    ///   3. Parent file: `<projects>/<projectPath>/<sessionId>.jsonl`
    ///   4. Sub-agent files: `<projects>/<projectPath>/<sessionId>/subagents/*.jsonl`
    ///      (iterated only when the parent file doesn't contain the uuid —
    ///      sidechain Steps carry the parent sessionId, so the parent
    ///      attempt is the common path and bails quickly on miss)
    ///
    /// Returns nil if the file is missing, unreadable, or the uuid isn't
    /// present (most likely: the JSONL was rotated / edited out-of-band
    /// between snapshot save and this call).
    ///
    /// Plan 13 Phase 8 rationale: `Step.rawJSON` is excluded from snapshot
    /// serialisation because the base64-encoded raw bytes made up 90% of
    /// the 1.15 GB snapshot file. This lazy loader keeps the Raw / Usage
    /// detail tabs functional after a snapshot-restored launch without
    /// paying the disk / decode cost up-front.
    func rawJSON(for step: Step) -> Data? {
        if let inline = step.rawJSON { return inline }
        if let cached = rawJSONCache[step.uuid] { return cached }
        if let locator = step.rawJSONLocator,
           let bytes = JSONLLineReader.readLine(at: locator) {
            cacheRawJSON(uuid: step.uuid, data: bytes)
            return bytes
        }
        // SQLite-first materialization attaches a locator to every step
        // (plan 4.2) — a miss here means the source file was rewritten
        // under us; the next rescan re-imports and refreshes locators.
        LoggerService.shared.logFromAnyThread(
            .debug,
            "rawJSON lazy-load: no locator for uuid \(step.uuid)",
            context: "RawJSON"
        )
        return nil
    }

    private func cacheRawJSON(uuid: String, data: Data) {
        if let old = rawJSONCache.removeValue(forKey: uuid) {
            rawJSONCacheBytes = max(0, rawJSONCacheBytes - old.count)
        }
        guard data.count <= rawJSONCacheByteCapacity else { return }
        if rawJSONCache.count >= rawJSONCacheCapacity
            || rawJSONCacheBytes + data.count > rawJSONCacheByteCapacity {
            rawJSONCache.removeAll(keepingCapacity: true)
            rawJSONCacheBytes = 0
        }
        rawJSONCache[uuid] = data
        rawJSONCacheBytes += data.count
    }

    private func clearRawJSONCache() {
        rawJSONCache.removeAll(keepingCapacity: true)
        rawJSONCacheBytes = 0
    }



    // MARK: - Convenience Accessors

    func projectLabel(for sessionId: String) -> String? {
        let key = scopedClaudeSessionId(sessionId)
        guard let raw = sessions.first(where: { $0.id == sessionId || $0.id == key })?.projectPath,
              !raw.isEmpty else { return nil }
        return ProjectLabelFormatter.decode(raw)
    }

    /// Returns the JSONL file URL for a given sessionId, or nil if not found.
    func jsonlFileURL(for sessionId: String) -> URL? {
        // SQLite-first: the index knows every session's source files;
        // serve the primary one (newest non-subagent).
        if let source = sqliteConversationSource,
           let path = try? source.store.primarySourcePath(
               sessionRawId: ProviderScopedID.rawID(from: sessionId)
           ) {
            return URL(fileURLWithPath: path)
        }
        // Last resort (Claude layout): construct from the shell's
        // project path — covers a not-yet-indexed source.
        let key = scopedClaudeSessionId(sessionId)
        guard let session = sessions.first(where: { $0.id == sessionId || $0.id == key }),
              let projectPath = session.projectPath else { return nil }
        let dir = effectiveProjectsDirectory.appendingPathComponent(projectPath)
        return dir.appendingPathComponent("\(session.rawSessionId).jsonl")
    }

    /// SQLite-first today usage (plan 3.3), written by
    /// `SQLiteFirstStartup` on the main actor. Non-nil routes the
    /// menu-bar aggregates below to SQL; nil keeps the legacy
    /// in-memory computation.
    var sqliteTodayUsage: TodayUsageSnapshot?

    /// Plan 5.3: sidebar cell metrics projected from SQL on the same
    /// throttled cadence as `sessions` — requests/tokens/cost/Codex
    /// confidence/subagent badge per session. Replaces the legacy
    /// per-cell sums over `session.requests` + `costsByRequestId`.
    var sessionListAggregates: [String: StoreSessionListAggregate] = [:]

    /// SQLite-first conversation reads (plan 4.1), installed by the
    /// ACTIVE provider's `SQLiteFirstStartup` on the main actor.
    /// Non-nil routes `TurnOutlineViewController` to turn-header stubs
    /// from the aggregate columns + per-turn scoped step decode; nil
    /// keeps the legacy in-memory turn graph.
    var sqliteConversationSource: SQLiteConversationSource?

    /// Bumped by the active driver on its throttled refresh cadence so
    /// the conversation outline re-snapshots after imports land.
    var sqliteConversationGeneration: Int = 0

    /// UI → driver channel (plan §1 import priority ②): selecting a
    /// session jumps its atomic unit to the front of the import queue.
    /// Installed by the ACTIVE provider's `SQLiteFirstStartup` alongside
    /// `sqliteConversationSource`; the argument is the raw session id.
    var prioritizeSessionImport: ((String) -> Void)?

    /// True while today's numbers are known-incomplete (sources touched
    /// today still importing) — the status bar shows its placeholder
    /// instead of an undercounted figure.
    var isTodayUsagePending: Bool {
        sqliteTodayUsage.map { !$0.isComplete } ?? false
    }

    var todayAggregateCost: Double {
        sqliteTodayUsage?.costUSD ?? 0
    }

    var todayAggregateTokens: Int {
        sqliteTodayUsage?.contextTokens ?? 0
    }

    var isRenderingActiveProviderSessions: Bool {
        sessions.allSatisfy { $0.provider == activeProvider }
    }

    /// Window during which the sidebar's green "active" dot stays lit for a
    /// session. 10 minutes matches user intuition for a Claude Code session
    /// that might be thinking, rendering a long tool result, or briefly
    /// paused between prompts — short enough that the dot doesn't linger
    /// forever on a truly idle row, long enough that a normal
    /// think-and-respond cycle doesn't flicker it off/on.
    ///
    /// The activity signal is the session's **endTime** (= timestamp of its
    /// last parsed request). Not file-append activity, which used to be the
    /// signal via `activeSessionId` / `activeSessionLastAppend` but caused
    /// the dot to land on a session whose parent JSONL was receiving
    /// auxiliary lines (tool results, carry-forward custom-title, filtered
    /// summaries) even though no new assistant completion had been recorded
    /// there — meaning the top-of-list session (sorted by endTime DESC)
    /// didn't get the dot. endTime keeps the dot aligned with the sort
    /// order and with what the user actually sees as "new activity."
    static let idleThreshold: TimeInterval = 600

    /// True iff this session had a parsed request within the last
    /// `idleThreshold` seconds. Drives the sidebar's green dot.
    ///
    /// Pure function of `session.endTime` and the wall clock; multiple
    /// sessions can be active simultaneously (one Claude Code window per
    /// terminal is a real pattern). Callers that want a consistent snapshot
    /// across a single UI pass should evaluate once at reload-time and
    /// cache the result.
    func isSessionActive(_ session: Session, now: Date = Date()) -> Bool {
        guard let endTime = session.endTime else { return false }
        return now.timeIntervalSince(endTime) <= Self.idleThreshold
    }

    /// Legacy diagnostic accessor. The UI no longer consults this for the
    /// green dot (endTime-based `isSessionActive(_:)` replaced it), but the
    /// `handleNewData` logs still surface `activeSessionId` / `viewed ≠
    /// target` mismatches for debugging "list not updating" complaints —
    /// keeping this property keeps those logs' semantics intact.
    var activeSession: Session? {
        guard let id = activeSessionId else { return nil }
        if let lastAppend = activeSessionLastAppend,
           Date().timeIntervalSince(lastAppend) > Self.idleThreshold { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Filter

    /// Return the sessions that match `filter`, sorted by `startTime`
    /// descending (matches sidebar default ordering).
    ///
    /// The implementation is an in-memory linear scan — fine for the
    /// current Lupen scale (hundreds of sessions, thousands of
    /// turns). If scale grows into tens of thousands, we'd add a
    /// precomputed index for query text and model, but that's a
    /// premature optimization today.
    ///
    /// Filter evaluation order (each stage further narrows the set):
    ///   1. `projectFilter` — equality on raw encoded `projectPath`.
    ///   2. `dateRange` — inclusive `[start, end]` against `startTime`
    ///      (both bounds count as in-range).
    ///   3. `models` — intersection non-empty between the session's
    ///      requests and the filter set. A session passes if *any* of
    ///      its requests is one of the allowed models.
    ///   4. `query` — case-insensitive substring, searched (in order of
    ///      match priority): project label, session slug, then *every*
    ///      Turn's `promptStep.text` in the session (not just the first
    ///      Turn — users want to find sessions by what they asked at
    ///      any point during the conversation). Short-circuits at first
    ///      hit per session. Assistant reply text is deliberately not
    ///      searched — we're answering "what did I ask about" not
    ///      "what did Claude say" (Plan 3 Open Question #2).
    ///
    /// An empty `filter` short-circuits past all four stages and just
    /// returns a sorted copy of `sessions`.
    func filteredSessions(
        _ filter: SessionFilter,
        provider: ProviderKind? = nil,
        now: Date = Date(),
        includeHiddenBillingSessions: Bool = false
    ) -> [Session] {
        let providerScoped = provider.map { provider in
            sessions.filter { $0.provider == provider }
        } ?? sessions
        let source = includeHiddenBillingSessions
            ? providerScoped
            : providerScoped.filter(\.isVisibleInSessionList)
        // Empty-filter fast path: still needs the DESC sort, but skips
        // every per-session predicate evaluation.
        let base: [Session]
        if filter.isEmpty {
            base = source
        } else {
            // Pre-resolve the dateRange bounds once so we don't pay the
            // Calendar lookup per session for presets like `.thisWeek`.
            let resolvedBounds = filter.dateRange?.resolveBounds(now: now)

            // SQLite-first content search (4.3): one FTS probe per
            // filter pass replaces the per-session Turn scan —
            // `turnsBySession` is empty when shells come from SQLite.
            // Skipped entirely when the scope is session-level only
            // (`.sessions`): with `contentMatchIds == nil`,
            // `sessionMatchesQuery` matches project / slug / title and
            // never dives into conversation content.
            let contentMatchIds = (filter.query.isEmpty || filter.searchScope == .sessions)
                ? nil
                : sqliteConversationSource?.sessionIdsMatchingPrompts(filter.query)

            base = source.filter { session in
                // Stage 1: project equality.
                if let projectFilter = filter.projectFilter,
                   session.projectPath != projectFilter {
                    return false
                }
                // Stage 2: date range. Sessions without any requests have
                // no `startTime` and can't be in any window — exclude.
                if let bounds = resolvedBounds {
                    guard let startTime = session.startTime,
                          startTime >= bounds.start,
                          startTime <= bounds.end
                    else { return false }
                }
                // Stage 3: model set. Empty set means "all models" so
                // the intersection check is skipped. Shells have no
                // request rows (6.2) — their models come from the SQL
                // sidebar aggregates instead.
                if !filter.models.isEmpty {
                    let sessionModels = session.requests.isEmpty
                        ? (sessionListAggregates[session.id]?.models ?? [])
                        : Set(session.requests.compactMap { $0.model })
                    if sessionModels.isDisjoint(with: filter.models) {
                        return false
                    }
                }
                // Stage 4: free-text query. Short-circuits at the first
                // match across project label, slug, and first Turn
                // prompt text.
                if !filter.query.isEmpty {
                    return sessionMatchesQuery(
                        session, query: filter.query, contentMatchIds: contentMatchIds
                    )
                }
                return true
            }
        }
        // Sort descending by startTime; sessions without a startTime
        // sink to the bottom (treat as `.distantPast`).
        return base.sorted { lhs, rhs in
            (lhs.startTime ?? .distantPast) > (rhs.startTime ?? .distantPast)
        }
    }

    /// Per-session match for `filter.query`. Split out so the outer
    /// filter loop reads linearly and the match policy can evolve
    /// without rewriting the loop.
    ///
    /// Search priority (short-circuits on first hit):
    ///   1. Project label (cheap, reflects the sidebar header).
    ///   2. Session slug (`harmonic-nibbling-meerkat`-style).
    ///   3. *Every* Turn's `promptStep.text`. This is the whole point
    ///      of sidebar search — users ask "which session was that cache
    ///      thing I asked about?" and the answer is rarely in the very
    ///      first Turn. An earlier revision only checked `firstTurn`
    ///      for a false perf win; that matched the type-level shape
    ///      but lost most of the search's practical value.
    ///
    /// Assistant reply text is *not* searched. Plan 3 Open Question #2
    /// came down on "what did I ask" over "what did Claude answer" —
    /// searching replies would flood the result list with tool-call
    /// noise every time a common word appeared in an answer.
    private func sessionMatchesQuery(
        _ session: Session,
        query: String,
        contentMatchIds: Set<String>? = nil
    ) -> Bool {
        // Project label — short, user-recognizable form.
        let projectLabel = ProjectLabelFormatter.decode(session.projectPath ?? "")
        if !projectLabel.isEmpty,
           projectLabel.localizedCaseInsensitiveContains(query) {
            return true
        }
        // Claude Code slug — a power user may remember the slug of a
        // particular session.
        if let slug = session.slug,
           slug.localizedCaseInsensitiveContains(query) {
            return true
        }
        if let customTitle = session.customTitle,
           customTitle.localizedCaseInsensitiveContains(query) {
            return true
        }
        if let cachedTitle = session.cachedTitle,
           cachedTitle.localizedCaseInsensitiveContains(query) {
            return true
        }
        // Every Turn's user prompt. `turnsBySession[id]` is an already-
        // sorted array — O(1) dict lookup + linear scan over the
        // session's Turns. For a typical Lupen workload (hundreds
        // of sessions × ~20 Turns on avg) that's ~20k substring checks
        // per `filteredSessions` call, well inside the typing-debounce
        // budget.
        // SQLite-first: prompt content matched via one FTS probe for
        // the whole filter pass (4.3) — supersedes the Turn scan.
        if let contentMatchIds {
            return contentMatchIds.contains(session.id)
        }
        return false
    }

    // MARK: - Testing Support

    func setActiveSessionForTesting(id: String?, lastAppend: Date?) {
        activeSessionId = id; activeSessionLastAppend = lastAppend
    }

    /// Exposes the live-update path so tests can exercise file-append
    /// semantics without spinning up the real FileWatcher. Routes through
    /// `handleNewData`, meaning all the production guards (the
    /// `customTitlesUpdated` early-return escape, the bookmark update,
    /// and the debounced `scheduleRebuild`) run verbatim.
    ///
    /// Paired with `flushPendingRebuildForTesting` so a test can drive
    /// one full append → rebuild → cache-save cycle synchronously.
    func rawJSONCacheStatsForTesting() -> (count: Int, bytes: Int) {
        (rawJSONCache.count, rawJSONCacheBytes)
    }

    func injectSessionsForTesting(_ newSessions: [Session]) {
        sessions = newSessions.map { $0.withProviderScopedIdentity() }
    }

    func injectProviderLoadingForTesting(
        provider: ProviderKind,
        isLoading: Bool,
        loadingProgress: String = ""
    ) {
        activeProvider = provider
        self.isLoading = isLoading
        self.loadingProgress = loadingProgress
        launchProgress = isLoading ? .transition(to: .scanningFiles) : .transition(to: .done)
    }
}
