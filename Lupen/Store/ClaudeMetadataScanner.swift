//
//  ClaudeMetadataScanner.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Phase 2.1 metadata scanner for the Claude provider (plan.md Target
/// Architecture §1): walks the Claude Code projects layout with
/// `FileDiscovery`, registers every transcript in `source_files`, and
/// seeds sidebar session shells — identity, project, slug, first-prompt
/// preview — from a bounded head read. A head window without a decodable
/// prompt leaves the preview NULL (the UI's "title pending" fallback);
/// detail import upgrades it later. Nothing here reads past the head
/// byte budget.
///
/// Writes go through `ImportWriting` only — no GRDB, no `AppStateStore`,
/// no in-memory graph (plan Non-Negotiable Rule 2). The scan is
/// idempotent and incremental:
///   - unchanged sources (fingerprint match) are skipped wholesale,
///     preserving their `parse_state`;
///   - a changed source drops back to `.metadata` (its imported rows
///     stay until the next detail import replaces them by provenance);
///   - vanished sources are deleted (cascade cleans owned rows), and
///     shells no source claims and no detail rows reference are pruned.
///
/// Session identity comes from the head window's first entry
/// `sessionId`, falling back to the filename. Claude continues sessions
/// into new physical files whose names differ from the logical session
/// id, so filename-only identity would seed phantom shells the legacy
/// aggregator (merge by entry sessionId) never showed.
struct ClaudeMetadataScanner: Sendable {

    struct Configuration: Sendable {
        /// Per-file head-read budget. Generous enough to find the first
        /// prompt behind a few oversized meta lines, small enough that a
        /// full-corpus scan stays metadata-priced.
        var headReadByteLimit: Int = 262_144
        /// Cap for the `sessions.first_prompt` search column.
        var firstPromptMaxLength: Int = 500
        /// Cap for the seeded `cached_title` preview.
        var titleMaxLength: Int = TurnPreview.defaultMaxLength

        init() {}
    }

    struct Summary: Equatable, Sendable {
        var discoveredFiles = 0
        var newSources = 0
        var changedSources = 0
        var unchangedSources = 0
        var skippedUnreadable = 0
        var prunedSources = 0
        var seededSessions = 0
        var prunedSessions = 0
    }

    let writer: any ImportWriting
    var configuration = Configuration()

    // MARK: - Scan

    @discardableResult
    func scan(projectsDirectory: URL) throws -> Summary {
        let discovered = FileDiscovery().discoverJSONLFiles(in: projectsDirectory)
        var summary = Summary()
        summary.discoveredFiles = discovered.count

        // Pruning is scoped to the scanned root so a partial scan can
        // never delete sources registered from elsewhere.
        let rootPrefix = projectsDirectory.standardizedFileURL.path
        let known = try writer.allSourceFiles().filter { Self.isPath($0.path, under: rootPrefix) }
        let knownByPath = Dictionary(uniqueKeysWithValues: known.map { ($0.path, $0) })

        var sourcesToUpsert: [StoreSourceFile] = []
        var seeds: [String: ShellSeed] = [:]
        var discoveredPaths = Set<String>()

        for file in discovered {
            // Per-file pool: `readHead`'s buffers come back autoreleased
            // and would otherwise accumulate across the whole scan — at
            // 40k+ sessions (10 GB generated corpus) that is gigabytes.
            autoreleasepool {
                let path = file.url.standardizedFileURL.path
                discoveredPaths.insert(path)

                guard let stat = fileStat(file.url) else {
                    summary.skippedUnreadable += 1
                    return
                }
                let fingerprint = StoreSourceFingerprint.make(byteSize: stat.byteSize, modifiedAt: stat.modifiedAt)

                if let existing = knownByPath[path], existing.fingerprint == fingerprint {
                    // Same bytes as last scan: state (including `.imported`)
                    // and the shells it seeded are already in place.
                    summary.unchangedSources += 1
                    return
                }
                if knownByPath[path] == nil {
                    summary.newSources += 1
                } else {
                    summary.changedSources += 1
                }

                let head = file.isSubagent ? HeadSummary() : readHead(of: file.url)
                let sessionRawId = file.isSubagent
                    ? file.subagentParentSessionId   // nil in the flat legacy layout
                    : Self.owningSessionRawId(file: file, head: head)

                sourcesToUpsert.append(StoreSourceFile(
                    path: path,
                    byteSize: stat.byteSize,
                    modifiedAt: stat.modifiedAt,
                    fingerprint: fingerprint,
                    parseState: .metadata,
                    sessionRawId: sessionRawId,
                    isSubagent: file.isSubagent,
                    subagentParentRawId: file.subagentParentSessionId,
                    workflowRunId: file.workflowRunId
                ))

                if !file.isSubagent {
                    Self.merge(
                        ShellSeed(
                            rawId: Self.owningSessionRawId(file: file, head: head),
                            projectPath: file.projectPath,
                            slug: head.slug,
                            customTitle: head.customTitle,
                            cachedTitle: head.cachedTitle,
                            firstPrompt: head.firstPrompt,
                            promptTimestamp: head.promptTimestamp,
                            promptSourcePath: head.promptTimestamp != nil ? path : nil
                        ),
                        into: &seeds
                    )
                } else if let parentRawId = file.subagentParentSessionId {
                    // The parent session is real even when its own transcript
                    // is missing — the directory layout names it, and the
                    // child's entries belong to it (research.md §1.4).
                    Self.merge(ShellSeed(rawId: parentRawId, projectPath: file.projectPath), into: &seeds)
                }
            }
        }

        try writer.upsertSourceFiles(sourcesToUpsert)

        let shellRows = seeds.values.map(\.sessionRow).sorted { $0.id < $1.id }
        try writer.seedSessionShells(shellRows)
        summary.seededSessions = shellRows.count

        let vanished = known.map(\.path).filter { !discoveredPaths.contains($0) }
        try writer.deleteSources(paths: vanished)
        summary.prunedSources = vanished.count
        summary.prunedSessions = try writer.pruneSessionsWithoutSources()

        return summary
    }

    // MARK: - Shell seeds

    /// One scan's worth of shell facts for a session, merged across the
    /// session's files. The prompt block (title/first prompt/timestamp)
    /// travels together and the earliest prompt wins — directory
    /// enumeration order is not chronological, and a continuation file's
    /// head prompt must not displace the session's true opening prompt.
    private struct ShellSeed {
        let rawId: String
        let projectPath: String
        var slug: String?
        var customTitle: String?
        var cachedTitle: String?
        var firstPrompt: String?
        var promptTimestamp: Date?
        var promptSourcePath: String?

        init(
            rawId: String,
            projectPath: String,
            slug: String? = nil,
            customTitle: String? = nil,
            cachedTitle: String? = nil,
            firstPrompt: String? = nil,
            promptTimestamp: Date? = nil,
            promptSourcePath: String? = nil
        ) {
            self.rawId = rawId
            self.projectPath = projectPath
            self.slug = slug
            self.customTitle = customTitle
            self.cachedTitle = cachedTitle
            self.firstPrompt = firstPrompt
            self.promptTimestamp = promptTimestamp
            self.promptSourcePath = promptSourcePath
        }

        var sessionRow: StoreSessionRow {
            StoreSessionRow(
                id: ProviderScopedID(provider: .claudeCode, rawSessionId: rawId).value,
                rawId: rawId,
                projectPath: projectPath,
                slug: slug,
                cachedTitle: cachedTitle,
                customTitle: customTitle,
                firstPrompt: firstPrompt,
                visible: true,
                detailState: .metadata
            )
        }

        mutating func absorb(_ other: ShellSeed) {
            if slug == nil { slug = other.slug }
            if customTitle == nil { customTitle = other.customTitle }
            if shouldAdoptPrompt(from: other) {
                cachedTitle = other.cachedTitle
                firstPrompt = other.firstPrompt
                promptTimestamp = other.promptTimestamp
                promptSourcePath = other.promptSourcePath
            }
        }

        private func shouldAdoptPrompt(from other: ShellSeed) -> Bool {
            guard let otherTimestamp = other.promptTimestamp else { return false }
            guard let mineTimestamp = promptTimestamp else { return true }
            if otherTimestamp != mineTimestamp { return otherTimestamp < mineTimestamp }
            return (other.promptSourcePath ?? "") < (promptSourcePath ?? "")
        }
    }

    private static func merge(_ seed: ShellSeed, into seeds: inout [String: ShellSeed]) {
        if var existing = seeds[seed.rawId] {
            existing.absorb(seed)
            seeds[seed.rawId] = existing
        } else {
            seeds[seed.rawId] = seed
        }
    }

    // MARK: - Bounded head read

    private struct HeadSummary {
        var entrySessionId: String?
        var slug: String?
        var customTitle: String?
        var cachedTitle: String?
        var firstPrompt: String?
        var promptTimestamp: Date?
    }

    /// Top-level `slug` rides on conversational lines but is not part of
    /// `RichEntry`; probed separately so the legacy hot-path decode
    /// shapes stay untouched.
    private struct SlugProbe: Decodable {
        let slug: String?
    }

    private func readHead(of url: URL) -> HeadSummary {
        var summary = HeadSummary()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return summary }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: configuration.headReadByteLimit),
              !head.isEmpty else { return summary }

        var lines = head.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let hitBudget = head.count == configuration.headReadByteLimit
        if hitBudget, head.last != UInt8(ascii: "\n"), !lines.isEmpty {
            lines.removeLast()   // never decode half a record
        }

        let slugDecoder = JSONDecoder()
        var promptFound = false

        for rawLine in lines where !rawLine.isEmpty {
            let lineData = Data(rawLine)

            if summary.slug == nil,
               let slug = (try? slugDecoder.decode(SlugProbe.self, from: lineData))?.slug {
                summary.slug = slug
            }

            let (outcome, header) = RichEntryDecoder.decodeDetailedWithHeader(lineData)
            if let custom = header.customTitle {
                summary.customTitle = custom   // last /rename in the window wins
            }
            guard case .entry(let entry) = outcome else { continue }
            if summary.entrySessionId == nil {
                summary.entrySessionId = entry.sessionId
            }
            if !promptFound, !entry.isSidechain, StepBuilder.classify(entry) == .prompt {
                promptFound = true
                let step = StepBuilder.build(from: entry)
                summary.cachedTitle = TurnPreview.make(
                    promptStep: step, maxLength: configuration.titleMaxLength
                )
                let cleaned = TurnPreview.clean(step.text ?? "")
                summary.firstPrompt = cleaned.isEmpty
                    ? nil
                    : TurnPreview.truncate(cleaned, to: configuration.firstPromptMaxLength)
                summary.promptTimestamp = entry.timestamp
            }
            // No early exit: custom-title lines are last-wins and can sit
            // anywhere in the window, and the window is byte-bounded anyway.
        }
        return summary
    }

    // MARK: - Session attribution

    /// The session a non-subagent transcript belongs to. Normally its
    /// filename IS its sessionId, so the fast path just returns it. The two
    /// diverge only when the file's first entry carries a DIFFERENT sessionId,
    /// which happens two ways:
    ///   - a pure continuation whose lines ALL carry the parent's id (the file
    ///     is just more of the parent session) → attribute to the parent;
    ///   - a `--resume` that replays the parent's transcript keeping the
    ///     parent id, but stamps its OWN id on the continued lines → attribute
    ///     to the filename; otherwise the resumed session's shell is orphaned
    ///     and stuck `partial` forever ("indexing" that never finishes).
    /// They are told apart by whether the file actually contains a line of its
    /// own (filename) id. The whole-file probe runs ONLY for the rare file
    /// whose head id ≠ filename — never on the normal hot path.
    private static func owningSessionRawId(file: FileDiscovery.DiscoveredFile, head: HeadSummary) -> String {
        guard let entryId = head.entrySessionId, entryId != file.sessionId else {
            return file.sessionId
        }
        return fileContainsSessionId(file.url, file.sessionId) ? file.sessionId : entryId
    }

    private static func fileContainsSessionId(_ url: URL, _ sessionId: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return data.range(of: Data("\"sessionId\":\"\(sessionId)\"".utf8)) != nil
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
