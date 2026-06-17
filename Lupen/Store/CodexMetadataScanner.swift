//
//  CodexMetadataScanner.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Phase 2.2 metadata scanner for the Codex provider (plan.md Target
/// Architecture §1): reads every rollout's ≤1 MiB first-line
/// `session_meta` (`CodexSessionMetadataReader`), recomputes
/// visible-session identity groups with the legacy loader's rules
/// (subagent parent chain, walk bounded to known files), registers each
/// rollout in `source_files` with its group as `session_raw_id` — the
/// atomic import unit of plan rule 3 — and seeds one shell per group.
///
/// `session_index.jsonl` drives the visible-vs-billing split (plan §4 /
/// research G9): membership → `visible`, `thread_name` → `cached_title`.
/// Those are index-derived facts that change without any rollout
/// changing, so they're applied through `applySessionVisibility` on
/// every scan rather than seed (fill-if-null) semantics. An absent or
/// empty index means everything is visible, matching the legacy loader.
///
/// First-line metadata is re-read for all files on every scan — the
/// same cost model as the legacy `CodexSessionIndexBuilder` discovery
/// pass — because group membership is a fileset-global fact: deleting
/// one parent rollout regroups its children. Fingerprints then decide
/// per-source state: unchanged files keep their parse state and import
/// stats; changed ones drop back to `.metadata` (owned rows stay until
/// a detail import replaces them by provenance).
///
/// First-prompt previews are NOT extracted here: a Codex user message
/// lives beyond the first line, and 2.2's scope is meta + index only.
/// Detail import (2.5) fills `first_prompt`.
struct CodexMetadataScanner: Sendable {

    struct Configuration: Sendable {
        var maxFirstLineBytes: Int = CodexSessionMetadataReader.defaultMaxFirstLineBytes
        init() {}
    }

    struct Summary: Equatable, Sendable {
        var discoveredFiles = 0
        var newSources = 0
        var changedSources = 0
        var unchangedSources = 0
        /// First line unreadable as Codex `session_meta` → source kept
        /// as `.failed` so coverage stays honest.
        var failedSources = 0
        var skippedUnreadable = 0
        var prunedSources = 0
        var seededSessions = 0
        var visibleSessions = 0
        var prunedSessions = 0
    }

    let writer: any ImportWriting
    var configuration = Configuration()

    // MARK: - Scan

    @discardableResult
    func scan(codexHome: URL) throws -> Summary {
        let discovery = CodexSessionDiscovery(codexHome: codexHome)
        let files = discovery.discoverRolloutFiles()
        let titleIndex = CodexSessionTitleIndexReader.read(
            from: discovery.codexHome.appendingPathComponent("session_index.jsonl")
        )

        var summary = Summary()
        summary.discoveredFiles = files.count

        let rootPrefix = discovery.sessionsDirectory.standardizedFileURL.path
        let known = try writer.allSourceFiles().filter { Self.isPath($0.path, under: rootPrefix) }
        let knownByPath = Dictionary(uniqueKeysWithValues: known.map { ($0.path, $0) })

        // Pass 1: stat + first-line metadata for every rollout.
        struct ScannedFile {
            let path: String
            let byteSize: Int64
            let modifiedAt: Date?
            let fingerprint: String
            let metadata: CodexSessionMetadata?
        }
        var scanned: [ScannedFile] = []
        for url in files {
            // Per-file pool: first-line reads are re-done for EVERY
            // rollout on every scan (identity groups are global), so
            // autoreleased read buffers must drain per file, not per scan.
            autoreleasepool {
                guard let stat = fileStat(url) else {
                    summary.skippedUnreadable += 1
                    return
                }
                let metadata = try? CodexSessionMetadataReader.readMetadata(
                    from: url, maxFirstLineBytes: configuration.maxFirstLineBytes
                )
                if metadata == nil { summary.failedSources += 1 }
                scanned.append(ScannedFile(
                    path: url.standardizedFileURL.path,
                    byteSize: stat.byteSize,
                    modifiedAt: stat.modifiedAt,
                    fingerprint: StoreSourceFingerprint.make(
                        byteSize: stat.byteSize, modifiedAt: stat.modifiedAt
                    ),
                    metadata: metadata
                ))
            }
        }

        // Pass 2: identity groups over the readable metadata (legacy
        // loader rules — see `rootRawSessionId`).
        let goodMetadata = scanned.compactMap(\.metadata)
        let knownRawIds = Set(goodMetadata.map(\.id))
        let parentByRawId = Self.parentMap(for: goodMetadata)
        let groups = Dictionary(grouping: goodMetadata) { metadata in
            Self.rootRawSessionId(
                startingAt: metadata.id,
                parentByRawSessionId: parentByRawId,
                knownRawSessionIds: knownRawIds
            )
        }

        // Pass 3: desired source rows, diffed against what's registered.
        var sourcesToUpsert: [StoreSourceFile] = []
        var discoveredPaths = Set<String>()
        for file in scanned {
            discoveredPaths.insert(file.path)
            let groupId = file.metadata.map { metadata in
                Self.rootRawSessionId(
                    startingAt: metadata.id,
                    parentByRawSessionId: parentByRawId,
                    knownRawSessionIds: knownRawIds
                )
            }
            var desired = StoreSourceFile(
                path: file.path,
                byteSize: file.byteSize,
                modifiedAt: file.modifiedAt,
                fingerprint: file.fingerprint,
                parseState: file.metadata == nil ? .failed : .metadata,
                sessionRawId: groupId,
                isSubagent: file.metadata?.isSubagentThread ?? false,
                subagentParentRawId: file.metadata?.subagentParentRawSessionId,
                workflowRunId: nil
            )
            guard let existing = knownByPath[file.path] else {
                summary.newSources += 1
                sourcesToUpsert.append(desired)
                continue
            }
            if existing.fingerprint == desired.fingerprint {
                summary.unchangedSources += 1
                // Same bytes: keep import progress; only group facts may
                // move (a sibling appeared or vanished).
                desired.parseState = existing.parseState
                desired.lineCount = existing.lineCount
                desired.rejectedLineCount = existing.rejectedLineCount
                desired.importedAt = existing.importedAt
                desired.id = existing.id
                if desired != existing {
                    sourcesToUpsert.append(desired)
                }
            } else {
                summary.changedSources += 1
                sourcesToUpsert.append(desired)
            }
        }
        try writer.upsertSourceFiles(sourcesToUpsert)

        // Pass 4: one shell seed per identity group. Times stay
        // request-derived (detail import); cwd follows the legacy
        // primary-piece rule; the branch is the newest piece's
        // session_meta git.branch ("last observed").
        let seeds = groups.map { groupId, members -> StoreSessionRow in
            let primary = Self.primaryMetadata(in: members, visibleRawId: groupId)
            return StoreSessionRow(
                id: ProviderScopedID(provider: .codex, rawSessionId: groupId).value,
                rawId: groupId,
                projectPath: primary?.cwd ?? members.compactMap(\.cwd).first,
                lastGitBranch: Self.lastGitBranch(in: members),
                visible: true,
                detailState: .metadata
            )
        }.sorted { $0.id < $1.id }
        try writer.seedSessionShells(seeds)
        summary.seededSessions = seeds.count

        // Pass 5: visibility/title projection from the session index —
        // applied unconditionally so index-only edits propagate.
        let visibilityUpdates = groups.keys.map { groupId in
            StoreSessionVisibilityUpdate(
                sessionId: ProviderScopedID(provider: .codex, rawSessionId: groupId).value,
                visible: titleIndex.isEmpty || titleIndex.contains(sessionId: groupId),
                cachedTitle: titleIndex.title(for: groupId)
            )
        }.sorted { $0.sessionId < $1.sessionId }
        try writer.applySessionVisibility(visibilityUpdates)
        summary.visibleSessions = visibilityUpdates.filter(\.visible).count

        // Prune: vanished rollouts, then unanchored shells.
        let vanished = known.map(\.path).filter { !discoveredPaths.contains($0) }
        try writer.deleteSources(paths: vanished)
        summary.prunedSources = vanished.count
        summary.prunedSessions = try writer.pruneSessionsWithoutSources()

        return summary
    }

    // MARK: - Identity grouping (legacy CodexUsageSessionLoader rules)

    /// id → declared parent thread id; first declaration wins, self-loops
    /// ignored.
    static func parentMap(for metadataList: [CodexSessionMetadata]) -> [String: String] {
        var map: [String: String] = [:]
        for metadata in metadataList {
            guard let parent = metadata.subagentParentRawSessionId,
                  parent != metadata.id,
                  map[metadata.id] == nil else { continue }
            map[metadata.id] = parent
        }
        return map
    }

    /// Walks the subagent parent chain to the visible root. The walk is
    /// bounded to ids that actually have files — a child whose parent
    /// rollout is missing is its own visible session — and cycle-guarded.
    static func rootRawSessionId(
        startingAt rawSessionId: String,
        parentByRawSessionId: [String: String],
        knownRawSessionIds: Set<String>
    ) -> String {
        var current = rawSessionId
        var visited: Set<String> = [rawSessionId]
        while let parent = parentByRawSessionId[current],
              parent != current,
              knownRawSessionIds.contains(parent),
              visited.insert(parent).inserted {
            current = parent
        }
        return current
    }

    /// The piece that speaks for the group: the root's own rollout when
    /// present, else the earliest-created piece (id tiebreak).
    private static func primaryMetadata(
        in members: [CodexSessionMetadata], visibleRawId: String
    ) -> CodexSessionMetadata? {
        if let root = members.first(where: { $0.id == visibleRawId }) {
            return root
        }
        return members.min { lhs, rhs in
            let lhsTime = lhs.createdAt ?? .distantPast
            let rhsTime = rhs.createdAt ?? .distantPast
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            return lhs.id < rhs.id
        }
    }

    /// "Last observed" branch for a group: the newest-created piece that
    /// carries `git.branch` (id tiebreak — mirrors `primaryMetadata`).
    /// Shared with `CodexDetailImporter` so seed and import agree.
    static func lastGitBranch(in members: [CodexSessionMetadata]) -> String? {
        members
            .filter { $0.gitBranch != nil }
            .max { lhs, rhs in
                let lhsTime = lhs.createdAt ?? .distantPast
                let rhsTime = rhs.createdAt ?? .distantPast
                if lhsTime != rhsTime { return lhsTime < rhsTime }
                return lhs.id < rhs.id
            }?
            .gitBranch
    }

    // MARK: - Filesystem facts

    private func fileStat(_ url: URL) -> (byteSize: Int64, modifiedAt: Date?)? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ), let size = values.fileSize else { return nil }
        return (Int64(size), values.contentModificationDate)
    }

    private static func isPath(_ path: String, under rootPrefix: String) -> Bool {
        path == rootPrefix || path.hasPrefix(rootPrefix + "/")
    }
}
