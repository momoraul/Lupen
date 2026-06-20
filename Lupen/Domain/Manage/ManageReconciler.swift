//
//  ManageReconciler.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 인덱스(즉시) 데이터와 파일시스템 실측을 대조해 관리 리스트 행을 만든다.
/// (research-ccmgr.md §1.6 — 추적/미추적/잔재 3상태)
///
/// 순수 함수 — 이미 조회된 배열을 받아 계산만 한다(ProviderStore/FS 접근은
/// 호출부 `ManageStore`/`ManageScanService`가 담당, 테스트 용이).
struct ManageReconciler {

    /// 인덱스가 아는 한 세션의 입력 묶음.
    struct IndexedSession: Sendable {
        let row: StoreSessionRow
        let sourceFiles: [StoreSourceFile]
        let aggregate: StoreSessionListAggregate?
    }

    /// 세션영역 스캔에서 발견한 디스크 파일.
    struct DiskFile: Sendable, Equatable {
        let path: String
        let sizeBytes: Int64
        let modifiedAt: Date?
    }

    /// - Parameter scanned: 파일시스템 실측이 끝났는가. false면 1차(인덱스만)
    ///   렌더 — 세션은 디스크에 있다고 가정(잔재 오판 방지)하고 orphan은 내지
    ///   않는다. true면 diskFiles로 존재 확인·미추적 발견까지 한다.
    static func reconcile(
        provider: ProviderKind,
        indexed: [IndexedSession],
        diskFiles: [DiskFile],
        classifier: StorageClassifier,
        isIndexing: Bool,
        scanned: Bool = true,
        now: Date = Date()
    ) -> [ManageRowModel] {
        let diskByPath = Dictionary(diskFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set<String>()
        var rows: [ManageRowModel] = []

        // 1) 인덱스 세션 — 추적 또는 잔재.
        for session in indexed {
            let allPaths = session.sourceFiles.map(\.path)
            claimed.formUnion(allPaths)

            let parentPaths = session.sourceFiles.filter { !$0.isSubagent }.map(\.path)
            let existsOnDisk = scanned ? allPaths.contains { diskByPath[$0] != nil } : true
            let indexSize = session.sourceFiles.reduce(Int64(0)) { $0 + $1.byteSize }
            let lastMod = session.sourceFiles.compactMap(\.modifiedAt).max() ?? session.row.endTime

            // Claude 세션의 동반 디렉터리 `<sessionId>/`(서브에이전트 보관) —
            // 휴지통 시 부모 jsonl과 함께 통째로 옮긴다.
            var companion: String?
            if provider == .claudeCode,
               session.sourceFiles.contains(where: { $0.isSubagent }),
               let parent = parentPaths.first {
                companion = URL(fileURLWithPath: parent).deletingPathExtension().path
            }

            let kind: ManageItemKind = existsOnDisk ? .session : .indexRemnant
            let classification: StorageClassification
            let protection: StorageProtection
            if kind == .indexRemnant {
                // 원본이 디스크에 없음 — 파일 삭제는 의미 없고 인덱스 prune 대상.
                classification = .unclassified
                protection = .locked
            } else {
                (classification, protection) = classifier.classify(
                    path: parentPaths.first ?? allPaths.first ?? "",
                    isIndexed: true,
                    isIndexing: isIndexing,
                    lastModified: lastMod,
                    now: now
                )
            }

            let hasFailed = session.sourceFiles.contains { $0.parseState == .failed }
            let status = Self.status(
                isIndexing: isIndexing, isIndexed: true, protection: protection,
                hasFailed: hasFailed, lastModified: lastMod, now: now
            )
            let described = describe(session: session, provider: provider)
            rows.append(ManageRowModel(
                id: session.row.id,
                provider: provider,
                kind: kind,
                displayTitle: described.title,
                rawSessionId: session.row.rawId,
                projectPath: described.decodedPath,
                encodedProject: described.encoded,
                branch: session.row.lastGitBranch,
                firstPrompt: session.row.firstPrompt,
                createdAt: session.row.startTime,
                lastActivity: lastMod,
                sizeBytes: indexSize,
                isEstimatedSize: true,
                fileCount: session.sourceFiles.count,
                filePaths: parentPaths,
                companionDirectory: companion,
                parseState: nil,
                status: status,
                classification: classification,
                protection: protection,
                isIndexed: true,
                existsOnDisk: existsOnDisk
            ))
        }

        // 2) 미추적 orphan — 세션영역에 있으나 인덱스가 모르는 `.jsonl`.
        //    실측 전(scanned=false)에는 디스크를 모르므로 만들지 않는다.
        if scanned {
            for file in diskFiles where !claimed.contains(file.path) && file.path.hasSuffix(".jsonl") {
                let url = URL(fileURLWithPath: file.path)
                let (classification, protection) = classifier.classify(
                    path: file.path,
                    isIndexed: false,
                    isIndexing: isIndexing,
                    lastModified: file.modifiedAt,
                    now: now
                )
                let status = Self.status(
                    isIndexing: isIndexing, isIndexed: false, protection: protection,
                    hasFailed: false, lastModified: file.modifiedAt, now: now
                )
                rows.append(ManageRowModel(
                    id: file.path,
                    provider: provider,
                    kind: .orphanFile,
                    displayTitle: url.lastPathComponent,
                    projectPath: url.deletingLastPathComponent().path,
                    encodedProject: nil,
                    branch: nil,
                    firstPrompt: nil,
                    createdAt: file.modifiedAt,
                    lastActivity: file.modifiedAt,
                    sizeBytes: file.sizeBytes,
                    isEstimatedSize: false,
                    fileCount: 1,
                    filePaths: [file.path],
                    companionDirectory: nil,
                    parseState: nil,
                    status: status,
                    classification: classification,
                    protection: protection,
                    isIndexed: false,
                    existsOnDisk: true
                ))
            }
        }

        return rows
    }

    // MARK: - Helpers

    /// 행 상태(이모지 컬럼). 우선순위: 차단 > 에러(잔재/파싱실패) > 미추적 >
    /// 인덱싱 중 > 최근 활동 > 정상.
    static func status(
        isIndexing: Bool,
        isIndexed: Bool,
        protection: StorageProtection,
        hasFailed: Bool,
        lastModified: Date?,
        now: Date,
        activeWindow: TimeInterval = 600
    ) -> ManageStatus {
        if protection == .blocked { return .blocked }
        if protection == .locked || hasFailed { return .error }
        if !isIndexed { return .untracked }
        if isIndexing { return .indexing }
        if let lastModified, now.timeIntervalSince(lastModified) < activeWindow {
            return .recentlyActive
        }
        return .normal
    }

    private static func describe(
        session: IndexedSession,
        provider: ProviderKind
    ) -> (title: String, decodedPath: String?, encoded: String?) {
        let title = ManageTitleFormatter.sessionTitle(
            firstPrompt: session.row.firstPrompt,
            cachedTitle: session.row.cachedTitle,
            customTitle: session.row.customTitle
        )
        let raw = session.row.projectPath
        switch provider {
        case .claudeCode:
            // Claude는 project_path가 인코딩된 디렉터리명 → 실제 경로로 디코드.
            return (title, raw.map { ProjectPathDecoder.decodeFullPath($0) }, raw)
        case .codex:
            // Codex는 project_path가 이미 실제 cwd.
            return (title, raw, nil)
        }
    }
}
