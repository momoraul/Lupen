//
//  ManageStore.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation
import Observation

/// Observable state for the "Manage Sessions & Storage" window. Renders
/// immediately from the index (plan §3.1) and refines via background FS
/// measurement. A window-only store that never touches the existing
/// `AppStateStore`/index (zero regression).
///
/// Per-provider `ProviderStore`/context are injected by AppDelegate as
/// closures (`sqliteFirstStartups` is dynamic, so accessors rather than a
/// snapshot).
@MainActor
@Observable
final class ManageStore {

    private(set) var rows: [ManageRowModel] = []
    var searchText: String = ""
    var sortKey: ManageRowSort = .size
    var sortAscending: Bool = false
    var scope: ManageScope = .sessions
    var selectedIDs: Set<String> = []
    private(set) var isScanning = false
    /// The session source currently shown. Keyed by its stable id for the
    /// per-source index DB; `provider` (its kind) drives row tagging / copy.
    private(set) var source: SessionSource
    /// All sources offered in the window's switcher (the enabled set).
    private(set) var sources: [SessionSource]
    var provider: ProviderKind { source.kind }
    /// Whether the current source is indexing (sessions are protected and blocked while indexing).
    var isIndexingNow: Bool { isIndexingProvider() }
    /// All-disk tab (read-only) entries — largest occupants first.
    private(set) var diskItems: [DiskSizer.Entry] = []

    private let isIndexingProvider: @MainActor () -> Bool
    private let storeProvider: @MainActor (SessionSource) -> ProviderStore?
    private let contextProvider: @MainActor (SessionSource) -> ManageProviderContext?
    private let requestRescan: @MainActor (SessionSource) -> Void
    private let rebuildIndex: @MainActor (SessionSource) -> Void
    /// Whether a live indexing driver exists for a source. Rebuild/rescan are
    /// no-ops without one (only activated sources have a driver), so the UI
    /// uses this to avoid offering an action that would silently do nothing.
    private let hasLiveDriver: @MainActor (SessionSource) -> Bool
    /// Callback for AppKit views to receive updates (explicit, instead of @Observable auto-tracking).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    private let scanService = ManageScanService()
    private let trashService = ManageTrashService()
    private var scanGeneration = 0
    /// Flag that aborts an in-flight scan (replaced on each load — avoids wasted CPU when toggling).
    private var scanFlag: ScanCancellationFlag?

    init(
        source: SessionSource,
        sources: [SessionSource],
        isIndexingProvider: @escaping @MainActor () -> Bool,
        storeProvider: @escaping @MainActor (SessionSource) -> ProviderStore?,
        contextProvider: @escaping @MainActor (SessionSource) -> ManageProviderContext?,
        requestRescan: @escaping @MainActor (SessionSource) -> Void,
        rebuildIndex: @escaping @MainActor (SessionSource) -> Void,
        hasLiveDriver: @escaping @MainActor (SessionSource) -> Bool = { _ in true }
    ) {
        self.source = source
        self.sources = sources
        self.isIndexingProvider = isIndexingProvider
        self.storeProvider = storeProvider
        self.contextProvider = contextProvider
        self.requestRescan = requestRescan
        self.rebuildIndex = rebuildIndex
        self.hasLiveDriver = hasLiveDriver
    }

    /// Whether the displayed source can be rebuilt/rescanned right now — i.e.
    /// it has a live indexing driver. False for an enabled-but-never-activated
    /// source shown via the read-only switcher.
    var canManageIndex: Bool { hasLiveDriver(source) }

    // MARK: - Derived

    var displayRows: [ManageRowModel] {
        ManageRowFilter.apply(rows, search: searchText, sort: sortKey, ascending: sortAscending)
    }
    var selectedRows: [ManageRowModel] { rows.filter { selectedIDs.contains($0.id) } }
    var selectedCount: Int { selectedIDs.count }
    var selectedReclaimBytes: Int64 { selectedRows.reduce(0) { $0 + $1.sizeBytes } }

    /// All-disk tab (read-only) — large occupants of the provider home as
    /// rows. Outside the session area, so all blocked (in-app deletion
    /// disabled — Reveal only).
    var allDiskRows: [ManageRowModel] {
        diskItems.map { entry in
            ManageRowModel(
                id: entry.url.path,
                provider: provider,
                kind: .diskItem,
                displayTitle: entry.name,
                projectPath: entry.url.path,
                sizeBytes: entry.sizeBytes,
                fileCount: 0,
                filePaths: [entry.url.path],
                status: .blocked,
                classification: .danger,
                protection: .blocked,
                isIndexed: false,
                existsOnDisk: true
            )
        }
    }

    // MARK: - Cache inspection

    struct CacheInfo: Sendable, Equatable {
        var indexBytes: Int64      // index.sqlite3 (main)
        var walBytes: Int64        // -wal
        var shmBytes: Int64        // -shm
        var snapshotBytes: Int64
        var coverage: StoreCoverage?
        var lastIndexed: Date?     // index.sqlite3 last-modified time
    }
    private(set) var cacheInfo: CacheInfo?

    /// Per-provider storage directory used by Reveal in the manage window.
    var providerSupportRoot: URL {
        LupenPaths.providerRoot(forSourceId: source.id)
    }

    func loadCacheInfo() {
        let root = LupenPaths.applicationSupportRoot()
        let indexURL = LupenPaths.indexDatabaseURL(forSourceId: source.id, appSupportRoot: root)
        let indexBytes = DiskSizer.fileAllocatedSize(indexURL)
        let walBytes = DiskSizer.fileAllocatedSize(URL(fileURLWithPath: indexURL.path + "-wal"))
        let shmBytes = DiskSizer.fileAllocatedSize(URL(fileURLWithPath: indexURL.path + "-shm"))
        let snapshotBytes = snapshotURLs(root: root).reduce(Int64(0)) { $0 + DiskSizer.fileAllocatedSize($1) }
        let coverage = try? storeProvider(source)?.coverage()
        let lastIndexed = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
        cacheInfo = CacheInfo(
            indexBytes: indexBytes, walBytes: walBytes, shmBytes: shmBytes,
            snapshotBytes: snapshotBytes, coverage: coverage, lastIndexed: lastIndexed
        )
    }

    /// Rebuild the index (original logs untouched) — reuses the existing rebuild path.
    func rebuildCacheIndex() {
        rebuildIndex(source)
        loadCacheInfo()
    }

    /// Delete only the snapshot JSON caches (Lupen-derived data — regenerated).
    /// The index DB is left untouched.
    func clearSnapshots() {
        for url in snapshotURLs(root: LupenPaths.applicationSupportRoot()) {
            try? FileManager.default.removeItem(at: url)
        }
        loadCacheInfo()
    }

    private func snapshotURLs(root: URL) -> [URL] {
        [LupenPaths.sessionCacheURL(forSourceId: source.id, appSupportRoot: root),
         LupenPaths.parseSnapshotURL(forSourceId: source.id, appSupportRoot: root),
         LupenPaths.offsetsURL(forSourceId: source.id, appSupportRoot: root)]
    }

    // MARK: - Selection

    /// Row to show in the inspector on single selection (nil if multiple → summary).
    var inspectedRow: ManageRowModel? {
        selectedIDs.count == 1 ? rows.first { selectedIDs.contains($0.id) } : nil
    }

    func clearSelection() { selectedIDs = []; onChange?() }

    /// Reflect table row selection (inspector + collector). The deletability
    /// gate is performTrash's job, so selection itself allows every row.
    func setSelectedIDs(_ ids: Set<String>) {
        guard ids != selectedIDs else { return }
        selectedIDs = ids
        onChange?()
    }

    func switchSource(_ newSource: SessionSource) {
        guard newSource.id != source.id else { return }
        source = newSource
        selectedIDs = []
        // Clear the previous source's rows immediately to avoid a flicker
        // of wrong-source data before the async load's first render.
        rows = []
        diskItems = []
        load()
    }

    /// Re-push the switcher's source list + active selection. The window is a
    /// reused singleton, so sources added/removed/enabled in Settings (or a
    /// new active source picked in the sidebar) between opens are applied here.
    func updateSources(_ newSources: [SessionSource], active: SessionSource) {
        guard newSources != sources || active.id != source.id else { return }
        sources = newSources
        source = active
        selectedIDs = []
        rows = []
        diskItems = []
        load()
    }

    // MARK: - Load

    func load() {
        guard let store = storeProvider(source), let context = contextProvider(source) else {
            rows = []
            diskItems = []
            cacheInfo = nil
            isScanning = false
            onChange?()
            return
        }
        let classifier = StorageClassifier(scope: context.classifierScope)
        let prov = provider

        // Cancel any in-flight scan and start a new generation. Both the
        // index read (synchronous DB queries over many sessions) and FS
        // measurement run in the background to keep the main thread
        // responsive (plan §3 — zero main-thread blocking).
        scanFlag?.cancel()
        let flag = ScanCancellationFlag()
        scanFlag = flag
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        onChange?()

        Task { @MainActor in
            // Pass 1: index only (approximate size) — defer index-remnant/
            // untracked judgement. Run loadIndexed detached so it doesn't
            // block main, and verify this is still the latest load before applying.
            let indexed = await Task.detached(priority: .userInitiated) {
                Self.loadIndexed(from: store)
            }.value
            guard generation == self.scanGeneration else { return }
            self.rows = ManageReconciler.reconcile(
                provider: prov, indexed: indexed, diskFiles: [],
                classifier: classifier, isIndexing: self.isIndexingProvider(), scanned: false
            )
            self.loadCacheInfo()
            self.onChange?()

            // Pass 2: background FS measurement → refine exact size, untracked,
            // and index remnants (cancellable).
            let disk = await self.scanService.scanSessionArea(
                roots: context.sessionAreaRoots, isCancelled: { flag.isCancelled })
            let items = await self.scanService.scanDiskItems(
                home: context.providerHome, isCancelled: { flag.isCancelled })
            // Discard this result if a newer load has started.
            guard generation == self.scanGeneration else { return }
            // Indexing state may change during the scan, so re-evaluate at refine time.
            self.rows = ManageReconciler.reconcile(
                provider: prov, indexed: indexed, diskFiles: disk,
                classifier: classifier, isIndexing: self.isIndexingProvider(), scanned: true
            )
            self.diskItems = items.sorted { $0.sizeBytes > $1.sizeBytes }
            self.isScanning = false
            self.onChange?()
        }
    }

    // MARK: - Deletion (trash + index reconcile + Undo)

    /// Send rows to the Trash and reconcile the index. Removes the entire
    /// session's sources from the index for rows that actually moved
    /// (including subagents in the companion directory). Use the returned
    /// Outcome to show the Undo snackbar.
    @discardableResult
    func trash(rows: [ManageRowModel]) async -> ManageTrashService.Outcome {
        let outcome = await trashService.trash(rows.flatMap(\.trashTargets))
        let trashed = Set(outcome.trashedPaths)
        if let store = storeProvider(source) {
            var indexPaths: [String] = []
            // Only prune the whole session's index for rows whose parent file
            // (jsonl) actually went to the Trash. If only the companion
            // directory succeeded and the parent failed, keep the index
            // (the parent remains on disk, staying consistent — safe partial failure).
            for row in rows where row.filePaths.contains(where: { trashed.contains($0) }) {
                if let raw = row.rawSessionId, let sources = try? store.sourceFiles(sessionRawId: raw) {
                    indexPaths.append(contentsOf: sources.map(\.path))
                } else {
                    indexPaths.append(contentsOf: row.filePaths)
                }
            }
            if !indexPaths.isEmpty {
                try? store.deleteSources(paths: indexPaths)
                _ = try? store.pruneSessionsWithoutSources()
            }
        }
        selectedIDs = []
        load()
        return outcome
    }

    /// Undo — restore from the Trash, trigger index re-registration (rescan), then re-render.
    func undoTrash(_ entries: [ManageTrashService.RestoreEntry]) async {
        await trashService.restore(entries)
        requestRescan(source)
        load()
    }

    // MARK: - Index loading (synchronous index reads — fast)

    nonisolated static func loadIndexed(from store: ProviderStore) -> [ManageReconciler.IndexedSession] {
        let sessions = (try? allSessions(store)) ?? []
        let sources = (try? store.allSourceFiles()) ?? []
        let byRaw = Dictionary(grouping: sources) { $0.sessionRawId ?? "" }
        return sessions.map { row in
            ManageReconciler.IndexedSession(
                row: row,
                sourceFiles: byRaw[row.rawId] ?? [],
                aggregate: nil   // unused by reconcile — avoids sessionListAggregates() GROUP BY cost.
            )
        }
    }

    nonisolated static func allSessions(_ store: ProviderStore) throws -> [StoreSessionRow] {
        var out: [StoreSessionRow] = []
        var cursor: StoreSessionPageCursor?
        repeat {
            let page = try store.sessionPage(visibleOnly: false, projectPath: nil, limit: 500, cursor: cursor)
            out.append(contentsOf: page.rows)
            cursor = page.nextCursor
        } while cursor != nil
        return out
    }
}
