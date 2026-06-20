//
//  ManageStore.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation
import Observation

/// "Manage Sessions & Storage" 윈도우의 관찰 가능 상태. 인덱스에서 즉시
/// 렌더하고(plan §3.1) 백그라운드 FS 실측으로 보정한다. 기존
/// `AppStateStore`/인덱스는 건드리지 않는 창 전용 store(회귀 0).
///
/// provider별 `ProviderStore`·컨텍스트는 AppDelegate가 클로저로 주입한다
/// (`sqliteFirstStartups`는 동적이라 스냅샷이 아닌 접근자로).
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
    private(set) var provider: ProviderKind
    /// 현재 provider가 인덱싱 중인가(인덱싱 중엔 세션이 보호되어 blocked).
    var isIndexingNow: Bool { isIndexingProvider() }
    /// 전체 디스크 탭(읽기전용) 항목 — 큰 점유물 내림차순.
    private(set) var diskItems: [DiskSizer.Entry] = []

    private let isIndexingProvider: @MainActor () -> Bool
    private let storeProvider: @MainActor (ProviderKind) -> ProviderStore?
    private let contextProvider: @MainActor (ProviderKind) -> ManageProviderContext?
    private let requestRescan: @MainActor (ProviderKind) -> Void
    private let rebuildIndex: @MainActor (ProviderKind) -> Void
    /// AppKit 뷰가 갱신을 받기 위한 콜백(@Observable 자동 추적 대신 명시적).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    private let scanService = ManageScanService()
    private let trashService = ManageTrashService()
    private var scanGeneration = 0

    init(
        provider: ProviderKind,
        isIndexingProvider: @escaping @MainActor () -> Bool,
        storeProvider: @escaping @MainActor (ProviderKind) -> ProviderStore?,
        contextProvider: @escaping @MainActor (ProviderKind) -> ManageProviderContext?,
        requestRescan: @escaping @MainActor (ProviderKind) -> Void,
        rebuildIndex: @escaping @MainActor (ProviderKind) -> Void
    ) {
        self.provider = provider
        self.isIndexingProvider = isIndexingProvider
        self.storeProvider = storeProvider
        self.contextProvider = contextProvider
        self.requestRescan = requestRescan
        self.rebuildIndex = rebuildIndex
    }

    // MARK: - Derived

    var displayRows: [ManageRowModel] {
        ManageRowFilter.apply(rows, search: searchText, sort: sortKey, ascending: sortAscending)
    }
    var selectedRows: [ManageRowModel] { rows.filter { selectedIDs.contains($0.id) } }
    var selectedCount: Int { selectedIDs.count }
    var selectedReclaimBytes: Int64 { selectedRows.reduce(0) { $0 + $1.sizeBytes } }

    /// 전체 디스크 탭(읽기전용) — provider 홈의 큰 점유물을 행으로. 세션영역
    /// 밖이므로 전부 blocked(앱 내 삭제 차단 — Reveal만).
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
        var indexBytes: Int64      // index.sqlite3 (메인)
        var walBytes: Int64        // -wal
        var shmBytes: Int64        // -shm
        var snapshotBytes: Int64
        var coverage: StoreCoverage?
        var lastIndexed: Date?     // index.sqlite3 마지막 수정 시각
    }
    private(set) var cacheInfo: CacheInfo?

    /// 관리 창에서 Reveal에 쓰는 provider별 저장 디렉터리.
    var providerSupportRoot: URL {
        LupenPaths.providerRoot(for: provider)
    }

    func loadCacheInfo() {
        let root = LupenPaths.applicationSupportRoot()
        let indexURL = LupenPaths.indexDatabaseURL(for: provider, appSupportRoot: root)
        let indexBytes = DiskSizer.fileAllocatedSize(indexURL)
        let walBytes = DiskSizer.fileAllocatedSize(URL(fileURLWithPath: indexURL.path + "-wal"))
        let shmBytes = DiskSizer.fileAllocatedSize(URL(fileURLWithPath: indexURL.path + "-shm"))
        let snapshotBytes = snapshotURLs(root: root).reduce(Int64(0)) { $0 + DiskSizer.fileAllocatedSize($1) }
        let coverage = try? storeProvider(provider)?.coverage()
        let lastIndexed = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
        cacheInfo = CacheInfo(
            indexBytes: indexBytes, walBytes: walBytes, shmBytes: shmBytes,
            snapshotBytes: snapshotBytes, coverage: coverage, lastIndexed: lastIndexed
        )
    }

    /// 인덱스 재빌드(원본 로그 불변) — 기존 rebuild 경로 재사용.
    func rebuildCacheIndex() {
        rebuildIndex(provider)
        loadCacheInfo()
    }

    /// 스냅샷 JSON 캐시만 삭제(Lupen 파생 데이터 — 재생성됨). 인덱스 DB는
    /// 건드리지 않는다.
    func clearSnapshots() {
        for url in snapshotURLs(root: LupenPaths.applicationSupportRoot()) {
            try? FileManager.default.removeItem(at: url)
        }
        loadCacheInfo()
    }

    private func snapshotURLs(root: URL) -> [URL] {
        [LupenPaths.sessionCacheURL(for: provider, appSupportRoot: root),
         LupenPaths.parseSnapshotURL(for: provider, appSupportRoot: root),
         LupenPaths.offsetsURL(for: provider, appSupportRoot: root)]
    }

    // MARK: - Selection

    /// 단일 선택 시 인스펙터에 표시할 행(여러 개면 nil → 요약).
    var inspectedRow: ManageRowModel? {
        selectedIDs.count == 1 ? rows.first { selectedIDs.contains($0.id) } : nil
    }

    func clearSelection() { selectedIDs = []; onChange?() }

    /// 테이블 행 선택을 반영(인스펙터 + collector). 삭제 가능 여부 게이트는
    /// performTrash가 담당하므로 선택 자체는 모든 행을 허용한다.
    func setSelectedIDs(_ ids: Set<String>) {
        guard ids != selectedIDs else { return }
        selectedIDs = ids
        onChange?()
    }

    func switchProvider(_ newProvider: ProviderKind) {
        guard newProvider != provider else { return }
        provider = newProvider
        selectedIDs = []
        load()
    }

    // MARK: - Load

    func load() {
        guard let store = storeProvider(provider), let context = contextProvider(provider) else {
            rows = []
            diskItems = []
            cacheInfo = nil
            onChange?()
            return
        }
        let indexed = Self.loadIndexed(from: store)
        let classifier = StorageClassifier(scope: context.classifierScope)
        let indexing = isIndexingProvider()
        let prov = provider

        // 1차: 인덱스만(근사 크기) — 즉시 렌더, 잔재/미추적 판정 보류.
        rows = ManageReconciler.reconcile(
            provider: prov, indexed: indexed, diskFiles: [],
            classifier: classifier, isIndexing: indexing, scanned: false
        )
        loadCacheInfo()
        onChange?()

        // 2차: 백그라운드 FS 실측 → 정확 크기·미추적·잔재 보정.
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        Task { @MainActor in
            let disk = await self.scanService.scanSessionArea(roots: context.sessionAreaRoots)
            let items = await self.scanService.scanDiskItems(home: context.providerHome)
            // 더 새로운 load가 시작됐으면 이 결과는 버린다.
            guard generation == self.scanGeneration else { return }
            // 스캔 중 인덱싱 상태가 바뀔 수 있으니 보정 시점에 재평가.
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

    /// 행들을 휴지통으로 보내고 인덱스를 정합시킨다. 실제로 옮겨진 행의
    /// 세션 전체 소스를 인덱스에서 제거한다(동반 디렉터리의 서브에이전트
    /// 포함). 반환된 Outcome으로 Undo 스낵바를 띄운다.
    @discardableResult
    func trash(rows: [ManageRowModel]) async -> ManageTrashService.Outcome {
        let outcome = await trashService.trash(rows.flatMap(\.trashTargets))
        let trashed = Set(outcome.trashedPaths)
        if let store = storeProvider(provider) {
            var indexPaths: [String] = []
            // 부모 파일(jsonl)이 실제로 휴지통에 간 행만 세션 전체 인덱스를
            // 정리한다. companion 디렉터리만 성공하고 부모가 실패한 경우엔
            // 인덱스를 유지(부모가 디스크에 남아 정합 — 부분 실패 안전).
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

    /// Undo — 휴지통에서 복원하고 인덱스 재등록을 트리거(rescan)한 뒤 재렌더.
    func undoTrash(_ entries: [ManageTrashService.RestoreEntry]) async {
        await trashService.restore(entries)
        requestRescan(provider)
        load()
    }

    // MARK: - Index loading (synchronous index reads — fast)

    static func loadIndexed(from store: ProviderStore) -> [ManageReconciler.IndexedSession] {
        let sessions = (try? allSessions(store)) ?? []
        let sources = (try? store.allSourceFiles()) ?? []
        let aggregates = (try? store.sessionListAggregates()) ?? [:]
        let byRaw = Dictionary(grouping: sources) { $0.sessionRawId ?? "" }
        return sessions.map { row in
            ManageReconciler.IndexedSession(
                row: row,
                sourceFiles: byRaw[row.rawId] ?? [],
                aggregate: aggregates[row.id]
            )
        }
    }

    static func allSessions(_ store: ProviderStore) throws -> [StoreSessionRow] {
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
