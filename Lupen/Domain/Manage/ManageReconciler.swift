//
//  ManageReconciler.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Builds the manage-list rows by cross-checking index (immediate) data
/// against filesystem measurement.
/// (research-ccmgr.md §1.6 — tracked/untracked/index-remnant three states)
///
/// Pure function — takes already-queried arrays and only computes
/// (ProviderStore/FS access is the caller's job — `ManageStore`/
/// `ManageScanService` — for testability).
struct ManageReconciler {

    /// The input bundle for one session as the index knows it.
    struct IndexedSession: Sendable {
        let row: StoreSessionRow
        let sourceFiles: [StoreSourceFile]
        let aggregate: StoreSessionListAggregate?
    }

    /// A disk file found by the session-area scan.
    struct DiskFile: Sendable, Equatable {
        let path: String
        let sizeBytes: Int64
        let modifiedAt: Date?
    }

    /// - Parameter scanned: Whether filesystem measurement is done. If false,
    ///   first-pass (index-only) render — sessions are assumed to exist on disk
    ///   (avoids false index-remnant calls) and no orphans are produced. If
    ///   true, also confirms existence via diskFiles and finds untracked files.
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

        // 1) Indexed sessions — tracked or index remnant.
        for session in indexed {
            let allPaths = session.sourceFiles.map(\.path)
            claimed.formUnion(allPaths)

            let parentPaths = session.sourceFiles.filter { !$0.isSubagent }.map(\.path)
            let existsOnDisk = scanned ? allPaths.contains { diskByPath[$0] != nil } : true
            let indexSize = session.sourceFiles.reduce(Int64(0)) { $0 + $1.byteSize }
            let lastMod = session.sourceFiles.compactMap(\.modifiedAt).max() ?? session.row.endTime

            // Claude session's companion directory `<sessionId>/` (holds
            // subagents) — moved wholesale together with the parent jsonl on Trash.
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
                // Original is not on disk — file deletion is meaningless; this is an index-prune target.
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

        // 2) Untracked orphans — `.jsonl` in the session area that the index
        //    doesn't know about. Not produced before measurement
        //    (scanned=false), since disk state is unknown.
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

    /// Row status (emoji column). Priority: blocked > error (index remnant/
    /// parse failure) > untracked > indexing > recently active > normal.
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
            // For Claude, project_path is an encoded directory name → decode to the real path.
            return (title, raw.map { ProjectPathDecoder.decodeFullPath($0) }, raw)
        case .codex:
            // For Codex, project_path is already the real cwd.
            return (title, raw, nil)
        }
    }
}
