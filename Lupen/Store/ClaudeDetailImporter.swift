//
//  ClaudeDetailImporter.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// One Claude atomic import unit (plan Non-Negotiable Rule 3): every
/// source file of one session — parent transcript(s) plus their
/// `subagents/**` children. Children are never imported alone because
/// subagent/workflow links and cost attribution live only in parent
/// files; continuation files are included because one logical session
/// can span several physical transcripts (merge is by entry sessionId).
struct ClaudeImportUnit: Sendable, Equatable {
    struct SourceFile: Sendable, Equatable {
        let url: URL
        let isSubagent: Bool
        let subagentParentRawId: String?
        let workflowRunId: String?

        init(
            url: URL,
            isSubagent: Bool = false,
            subagentParentRawId: String? = nil,
            workflowRunId: String? = nil
        ) {
            self.url = url
            self.isSubagent = isSubagent
            self.subagentParentRawId = subagentParentRawId
            self.workflowRunId = workflowRunId
        }
    }

    let sessionRawId: String
    let projectPath: String?
    let files: [SourceFile]

    /// Builds the unit for one session from registered sources (the
    /// metadata scanner stamps `session_raw_id` with the owning
    /// session). Parent transcripts import before children; both
    /// path-sorted for determinism.
    static func unit(
        forSessionRawId sessionRawId: String,
        projectPath: String?,
        sources: [StoreSourceFile]
    ) -> ClaudeImportUnit {
        let members = sources
            .filter { $0.sessionRawId == sessionRawId }
            .sorted {
                if $0.isSubagent != $1.isSubagent { return !$0.isSubagent }
                return $0.path < $1.path
            }
            .map { source in
                SourceFile(
                    url: URL(fileURLWithPath: source.path),
                    isSubagent: source.isSubagent,
                    subagentParentRawId: source.subagentParentRawId,
                    workflowRunId: source.workflowRunId
                )
            }
        return ClaudeImportUnit(
            sessionRawId: sessionRawId,
            projectPath: projectPath,
            files: members
        )
    }
}

/// Phase 2.4 scoped Claude importer: parses one atomic unit with the
/// proven legacy pipeline pieces (`RichEntryDecoder` → fresh
/// `ConversationAssembler` → `StepBuilder` previews, `SubAgentLinker`
/// for parent linkage, `SessionAggregator`'s dedup rule for billable
/// lines) and writes SQLite rows only — sessions, requests, turns,
/// steps, subagent/parent links, diagnostics, raw locators, FTS prompt
/// entries — via `ImportWriting.replaceSource` (delete-by-provenance,
/// one transaction per source). No `AppStateStore`, no global graphs
/// (plan Rule 2).
///
/// Cancellation happens at source boundaries (G13): already-replaced
/// sources stay `imported`, untouched ones keep their scanner state,
/// and the session shell is only marked `complete` after every file of
/// the unit landed — a cancelled or partly-missing unit stays
/// `partial`, never silently undercounted (Rule 6).
struct ClaudeDetailImporter: Sendable {

    struct Configuration: Sendable {
        /// Preview cap shared with the sidebar/title chain.
        var titleMaxLength: Int = TurnPreview.defaultMaxLength
        /// Cap for `sessions.first_prompt` (matches the metadata scanner).
        var firstPromptMaxLength: Int = 500
        /// Cap per FTS prompt entry (Decision 3: prompt-level search in
        /// Phase 2; full step text lands with Phase 4).
        var searchContentMaxLength: Int = 2_000
        /// Rows per write transaction inside `replaceSource` — bounds
        /// journal growth and gives cancellation its batch boundaries.
        var writeBatchRowLimit: Int = 2_000
        init() {}
    }

    struct Outcome: Equatable, Sendable {
        var importedSources = 0
        var skippedMissingFiles = 0
        var requestRows = 0
        var turnRows = 0
        var stepRows = 0
        var subagentLinkRows = 0
        var diagnosticRows = 0
        var cancelled = false
        /// True when every file of the unit was imported and the unit
        /// session's shell was promoted to `complete`.
        var unitComplete = false
    }

    let writer: any ImportWriting
    var configuration = Configuration()

    // MARK: - Import

    @discardableResult
    func importUnit(
        _ unit: ClaudeImportUnit,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Outcome {
        var outcome = Outcome()
        guard !unit.files.isEmpty else { return outcome }

        // Pass 1: stream-decode every file of the unit.
        var parses: [FileParse] = []
        for file in unit.files {
            guard let parse = parseFile(file) else {
                outcome.skippedMissingFiles += 1
                continue
            }
            parses.append(parse)
        }
        guard !parses.isEmpty else { return outcome }

        // Compact subagents replay parent entries verbatim under the
        // SAME (sessionId, uuid) — observed live: agent-acompact-*
        // duplicating 1,188 parent uuids, and sibling children can
        // replay each other too (unit 5d7b9f05: 421). parent_links,
        // steps, and raw_locators all key on (session_id, uuid)-shaped
        // PKs, so one replayed line was a guaranteed SQLITE_CONSTRAINT:
        // the whole unit threw, stayed `incomplete`, and re-queued on
        // every rescan — the forever-pending sessions in Verify Costs.
        // First occurrence wins; parents sort before children in
        // `unit(forSessionRawId:)`, so the authoritative transcript
        // owns the row and replayed copies drop (also keeps replayed
        // usage out of the cost sums).
        var seenEntries = Set<OriginKey>()
        var seenLinks = Set<OriginKey>()
        var seenLocators = Set<OriginKey>()
        for index in parses.indices {
            parses[index].dropReplayedLines(
                entrySeen: &seenEntries, linkSeen: &seenLinks, locatorSeen: &seenLocators
            )
        }

        // Pass 2: assemble the whole unit in one fresh assembler —
        // exactly the legacy semantics (cross-file merge by entry
        // sessionId, sidechain turns, messageId merges, orphan repair).
        let assembler = ConversationAssembler()
        var originByKey: [OriginKey: Int] = [:]
        var allEntries: [RichEntry] = []
        for (index, parse) in parses.enumerated() {
            assembler.registerParentLinks(parse.rawParentLinks)
            for entry in parse.entries {
                originByKey[OriginKey(sessionId: entry.sessionId, uuid: entry.uuid)] = index
            }
            allEntries.append(contentsOf: parse.entries)
        }
        assembler.ingest(allEntries)
        let turnsBySession = assembler.turnsBySession()

        // Pass 3: distribute rows to their owning source's payload.
        var payloads = parses.map { _ in StoreSourcePayload() }

        for (index, parse) in parses.enumerated() {
            payloads[index].parentLinks = parse.parentLinks
            payloads[index].diagnostics = parse.diagnostics
            payloads[index].rawLocators = parse.rawLocators
        }

        appendRequestRows(
            parses: parses, originByKey: originByKey,
            payloads: &payloads, outcome: &outcome
        )
        let linksBySession = appendSubagentLinkRows(
            parses: parses, unit: unit, turnsBySession: turnsBySession,
            payloads: &payloads, outcome: &outcome
        )
        appendConversationRows(
            turnsBySession: turnsBySession, originByKey: originByKey,
            linksBySession: linksBySession,
            payloads: &payloads, outcome: &outcome
        )

        let shells = sessionShells(
            unit: unit, parses: parses, turnsBySession: turnsBySession
        )
        // Shells ride along on every source payload with `partial`
        // state (widening upsert); promotion to `complete` happens only
        // after the whole unit landed.
        for index in payloads.indices {
            payloads[index].sessions = shells
        }

        // Pass 4: provenance-replacing writes per source in bounded
        // batches; cancellation checked at source AND batch boundaries.
        // A source cancelled mid-write stays `incomplete` and restarts
        // from byte 0 on the next import (G13).
        for (index, parse) in parses.enumerated() {
            if isCancelled() {
                outcome.cancelled = true
                break
            }
            let completed = try writer.replaceSource(
                parse.storeSourceFile(unit: unit),
                payload: payloads[index],
                batchRowLimit: configuration.writeBatchRowLimit,
                isCancelled: isCancelled
            )
            guard completed else {
                outcome.cancelled = true
                break
            }
            outcome.importedSources += 1
        }

        outcome.diagnosticRows = payloads.prefix(outcome.importedSources)
            .reduce(0) { $0 + $1.diagnostics.count }

        if !outcome.cancelled, outcome.skippedMissingFiles == 0,
           outcome.importedSources == parses.count {
            // Scope complete → finalize costs (long-context pricing is
            // session-wide; plan 2.6), then promote the shell.
            let finalizer = SessionCostFinalizer(writer: writer)
            for shell in shells {
                try finalizer.finalize(sessionId: shell.id)
            }
            let completed = shells.map { shell -> StoreSessionRow in
                guard shell.rawId == unit.sessionRawId else { return shell }
                var promoted = shell
                promoted.detailState = .complete
                return promoted
            }
            try writer.upsertSessionShells(completed)
            outcome.unitComplete = true
        }
        return outcome
    }

    // MARK: - Pass 1: per-file streaming parse

    private struct FileParse {
        let file: ClaudeImportUnit.SourceFile
        let path: String
        let byteSize: Int64
        let modifiedAt: Date?
        var lineCount = 0
        var rejectedLineCount = 0
        var entries: [RichEntry] = []
        var rawParentLinks: [RichEntryDecoder.ParentLink] = []
        var parentLinks: [StoreParentLinkRow] = []
        var rawLocators: [StoreRawLocatorRow] = []
        var diagnostics: [StoreDiagnosticRow] = []
        var linkerCandidateLines: [Data] = []
        var slug: String?
        var customTitle: String?
        /// Compact-continuation parent compaction point — the
        /// `logicalParentUuid` on the file's first `type=system` entry.
        /// Sessions sharing it are one lineage. Nil for standalone files.
        var logicalParentUuid: String?
        /// Raw session id of the file's first decoded entry — the
        /// session this file actually belongs to (entries are ground
        /// truth; filenames can lie for continuation files).
        var primaryRawSessionId: String?

        func storeSourceFile(unit: ClaudeImportUnit) -> StoreSourceFile {
            StoreSourceFile(
                path: path,
                byteSize: byteSize,
                modifiedAt: modifiedAt,
                fingerprint: StoreSourceFingerprint.make(byteSize: byteSize, modifiedAt: modifiedAt),
                lineCount: lineCount,
                rejectedLineCount: rejectedLineCount,
                sessionRawId: file.isSubagent
                    ? (file.subagentParentRawId ?? primaryRawSessionId ?? unit.sessionRawId)
                    : (primaryRawSessionId ?? unit.sessionRawId),
                isSubagent: file.isSubagent,
                subagentParentRawId: file.subagentParentRawId,
                workflowRunId: file.workflowRunId
            )
        }

        /// Drops lines whose identity already appeared earlier in the
        /// unit (compact-subagent replays). Three independent seen-sets
        /// — `parentLinks` is a SUPERSET of `entries` (header-only
        /// lines link too) and `rawLocators` keys on ownerId, so
        /// filtering all three through one set would orphan link rows.
        /// `rawParentLinks` is left alone on purpose: it only feeds
        /// the assembler's graft registry, which upserts — and the 6.6
        /// lesson is to not hand-prune graft inputs.
        mutating func dropReplayedLines(
            entrySeen: inout Set<OriginKey>,
            linkSeen: inout Set<OriginKey>,
            locatorSeen: inout Set<OriginKey>
        ) {
            entries.removeAll { entry in
                !entrySeen.insert(
                    OriginKey(sessionId: entry.sessionId, uuid: entry.uuid)
                ).inserted
            }
            parentLinks.removeAll { link in
                !linkSeen.insert(
                    OriginKey(sessionId: link.sessionId, uuid: link.uuid)
                ).inserted
            }
            rawLocators.removeAll { locator in
                !locatorSeen.insert(
                    OriginKey(sessionId: locator.sessionId, uuid: locator.ownerId)
                ).inserted
            }
        }
    }

    private struct OriginKey: Hashable {
        let sessionId: String
        let uuid: String
    }

    private func parseFile(_ file: ClaudeImportUnit.SourceFile) -> FileParse? {
        guard let values = try? file.url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ), let size = values.fileSize else { return nil }

        var parse = FileParse(
            file: file,
            path: file.url.standardizedFileURL.path,
            byteSize: Int64(size),
            modifiedAt: values.contentModificationDate
        )
        let slugDecoder = JSONDecoder()

        JSONLLineReader.streamLineRecords(from: file.url) { record in
            parse.lineCount += 1

            if parse.slug == nil,
               record.data.range(of: Self.slugKeyPattern) != nil,
               let slug = (try? slugDecoder.decode(SlugProbe.self, from: record.data))?.slug {
                parse.slug = slug
            }
            if parse.logicalParentUuid == nil,
               record.data.range(of: Self.logicalParentKeyPattern) != nil,
               let lpu = (try? slugDecoder.decode(LogicalParentProbe.self, from: record.data))?.logicalParentUuid {
                parse.logicalParentUuid = lpu
            }
            if !file.isSubagent, Self.mightCarryAgentLinkage(record.data) {
                parse.linkerCandidateLines.append(record.data)
            }

            let (outcome, header, extraRejections) =
                RichEntryDecoder.decodeDetailedWithHeaderAndRejections(record.data)

            if let sessionId = header.sessionId, let uuid = header.uuid {
                parse.rawParentLinks.append(RichEntryDecoder.ParentLink(
                    sessionId: sessionId, uuid: uuid, parentUuid: header.parentUuid
                ))
                parse.parentLinks.append(StoreParentLinkRow(
                    sessionId: Self.scoped(sessionId), uuid: uuid, parentUuid: header.parentUuid
                ))
            }
            if let custom = header.customTitle {
                parse.customTitle = custom   // last /rename wins
            }
            for rejection in extraRejections where rejection.severity != .info {
                parse.diagnostics.append(Self.diagnosticRow(
                    rejection, sessionId: header.sessionId, record: record
                ))
            }

            switch outcome {
            case .entry(let entry):
                if parse.primaryRawSessionId == nil {
                    parse.primaryRawSessionId = entry.sessionId
                }
                parse.entries.append(entry)
                parse.rawLocators.append(StoreRawLocatorRow(
                    sessionId: Self.scoped(entry.sessionId),
                    ownerKind: "stepLine",
                    ownerId: entry.uuid,
                    byteOffset: Int64(record.byteOffset),
                    byteLength: Int64(record.data.count),
                    lineNumber: record.lineOrdinal
                ))
            case .drop(let rejection):
                if rejection.severity != .info {
                    parse.rejectedLineCount += 1
                    parse.diagnostics.append(Self.diagnosticRow(
                        rejection, sessionId: header.sessionId, record: record
                    ))
                }
            }
            return true
        }
        return parse
    }

    private struct SlugProbe: Decodable {
        let slug: String?
    }

    private struct LogicalParentProbe: Decodable {
        let logicalParentUuid: String?
    }

    private static let slugKeyPattern = Data("\"slug\"".utf8)
    private static let logicalParentKeyPattern = Data("\"logicalParentUuid\"".utf8)
    private static let toolResultPattern = Data("\"tool_result\"".utf8)
    private static let toolUsePattern = Data("\"tool_use\"".utf8)
    private static let agentNamePattern = Data("\"Agent\"".utf8)
    private static let workflowNamePattern = Data("\"Workflow\"".utf8)

    /// Cheap byte prefilter so the whole file never has to be buffered
    /// for `SubAgentLinker` (memory-audit P1). Superset is fine — the
    /// linker fully decodes whatever it is given; pairing is by
    /// tool_use_id, not adjacency, so dropping unrelated lines between
    /// candidates is safe.
    private static func mightCarryAgentLinkage(_ line: Data) -> Bool {
        if line.range(of: toolResultPattern) != nil { return true }
        guard line.range(of: toolUsePattern) != nil else { return false }
        return line.range(of: agentNamePattern) != nil
            || line.range(of: workflowNamePattern) != nil
    }

    private static func diagnosticRow(
        _ rejection: DecodeRejection,
        sessionId: String?,
        record: JSONLLineReader.LineRecord
    ) -> StoreDiagnosticRow {
        StoreDiagnosticRow(
            sessionId: sessionId.map(Self.scoped),
            severity: severityString(rejection.severity),
            category: rejection.categoryKey,
            lineNumber: record.lineOrdinal,
            byteOffset: Int64(record.byteOffset),
            preview: rejection.humanDescription,
            createdAt: Date()
        )
    }

    private static func severityString(_ severity: DecodeRejection.Severity) -> String {
        switch severity {
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    // MARK: - Pass 3a: billable request rows

    private func appendRequestRows(
        parses: [FileParse],
        originByKey: [OriginKey: Int],
        payloads: inout [StoreSourcePayload],
        outcome: inout Outcome
    ) {
        // Bucket by (rawSessionId, requestId ?? uuid) with the legacy
        // pick rule, mirroring SessionAggregator across every file of
        // the unit so continuation files dedup exactly like the legacy
        // whole-graph aggregation.
        var buckets: [String: [String: RichEntry]] = [:]
        for parse in parses {
            for entry in parse.entries {
                guard entry.entryType == .assistant, entry.usage != nil else { continue }
                let key = entry.requestId ?? entry.uuid
                if let existing = buckets[entry.sessionId]?[key] {
                    if Self.isBetter(entry, than: existing) {
                        buckets[entry.sessionId]?[key] = entry
                    }
                } else {
                    buckets[entry.sessionId, default: [:]][key] = entry
                }
            }
        }

        for (rawSessionId, bucket) in buckets {
            let scopedSessionId = Self.scoped(rawSessionId)
            for (requestKey, entry) in bucket {
                guard let usage = entry.usage else { continue }
                let tokens = TokenBreakdown.from(usage: usage)
                let cost = CostCalculator.calculateCost(
                    tokens: tokens, model: entry.model, speed: usage.speed
                )
                let row = StoreRequestRow(
                    id: requestKey,
                    sessionId: scopedSessionId,
                    timestamp: entry.timestamp,
                    model: entry.model,
                    messageId: entry.messageId,
                    parentUuid: entry.parentUuid,
                    isSidechain: entry.isSidechain,
                    speed: usage.speed,
                    stopReason: entry.stopReason,
                    inputTokens: tokens.inputTokens,
                    outputTokens: tokens.outputTokens,
                    reasoningOutputTokens: tokens.reasoningOutputTokens,
                    cacheCreationInputTokens: tokens.cacheCreationInputTokens,
                    cacheReadInputTokens: tokens.cacheReadInputTokens,
                    cacheCreationEphemeral1h: tokens.cacheCreationEphemeral1h,
                    cacheCreationEphemeral5m: tokens.cacheCreationEphemeral5m,
                    provisionalCostUSD: cost?.totalCostUSD
                )
                let origin = originByKey[OriginKey(sessionId: rawSessionId, uuid: entry.uuid)] ?? 0
                payloads[origin].requests.append(row)
                outcome.requestRows += 1
            }
        }
        for index in payloads.indices {
            payloads[index].requests.sort { $0.timestamp < $1.timestamp }
        }
    }

    /// Dedup pick rule — must match `SessionAggregator.isBetter` /
    /// `GroundTruthCalculator.pickFinal` (the 0.4 equivalence harness
    /// pins all three together): prefer a final line (stop_reason
    /// present), then max output tokens, then max input tokens.
    private static func isBetter(_ candidate: RichEntry, than current: RichEntry) -> Bool {
        let candidateFinal = candidate.stopReason != nil
        let currentFinal = current.stopReason != nil
        if candidateFinal && !currentFinal { return true }
        if !candidateFinal && currentFinal { return false }
        let candidateOutput = candidate.usage?.outputTokens ?? 0
        let currentOutput = current.usage?.outputTokens ?? 0
        if candidateOutput != currentOutput { return candidateOutput > currentOutput }
        let candidateInput = candidate.usage?.inputTokens ?? 0
        let currentInput = current.usage?.inputTokens ?? 0
        return candidateInput > currentInput
    }

    // MARK: - Pass 3b: turns / steps / FTS

    private func appendConversationRows(
        turnsBySession: [String: [Turn]],
        originByKey: [OriginKey: Int],
        linksBySession: [String: [SubAgentLinker.Link]],
        payloads: inout [StoreSourcePayload],
        outcome: inout Outcome
    ) {
        for (rawSessionId, turns) in turnsBySession {
            let scopedSessionId = Self.scoped(rawSessionId)
            // Same graft join the outline uses (plan 2.7): per-turn
            // aggregates include spawned subagent contributions; a turn
            // whose link has no ingested child stays incomplete (Rule 6).
            let graft = SubAgentGraftIndex.make(
                visibleTurns: turns.filter { !$0.isSidechainOnly },
                allTurns: turns,
                links: linksBySession[scopedSessionId] ?? []
            )
            for (ordinal, turn) in turns.enumerated() {
                let rootOrigin = turn.steps.first.flatMap {
                    originByKey[OriginKey(sessionId: rawSessionId, uuid: $0.uuid)]
                } ?? 0
                let aggregate = TurnAggregateColumns.make(turn: turn, graft: graft)
                payloads[rootOrigin].turns.append(StoreTurnRow(
                    sessionId: scopedSessionId,
                    id: turn.id,
                    ordinal: ordinal,
                    startTime: turn.startTime,
                    endTime: turn.endTime,
                    promptPreview: TurnPreview.make(for: turn, maxLength: configuration.titleMaxLength),
                    stepCount: turn.steps.count,
                    interrupted: turn.isInterrupted,
                    sidechainOnly: turn.isSidechainOnly,
                    aggTokens: aggregate.tokens,
                    aggCost: aggregate.cost,
                    aggModels: aggregate.models,
                    aggComplete: aggregate.complete
                ))
                outcome.turnRows += 1

                for (stepOrdinal, step) in turn.steps.enumerated() {
                    let origin = originByKey[OriginKey(sessionId: rawSessionId, uuid: step.uuid)]
                        ?? rootOrigin
                    payloads[origin].steps.append(StoreStepRow(
                        sessionId: scopedSessionId,
                        turnId: turn.id,
                        uuid: step.uuid,
                        ordinal: stepOrdinal,
                        kind: step.kind.rawValue,
                        timestamp: step.timestamp,
                        model: step.model,
                        requestId: step.requestId,
                        agentId: step.agentId,
                        text: step.text,
                        thinkingText: step.thinkingText,
                        toolName: step.toolCalls.first?.name,
                        toolUseId: step.toolCalls.first?.id ?? step.toolResult?.toolUseId
                    ))
                    outcome.stepRows += 1
                }

                if let prompt = turn.promptStep,
                   let text = prompt.text, !text.isEmpty {
                    payloads[rootOrigin].searchEntries.append(StoreSearchEntry(
                        sessionId: scopedSessionId,
                        turnId: turn.id,
                        stepUuid: prompt.uuid,
                        kind: "prompt",
                        content: String(text.prefix(configuration.searchContentMaxLength))
                    ))
                    if let skill = CostAnalyzer.extractSkillName(
                        from: text, provider: .claudeCode
                    ) {
                        payloads[rootOrigin].skills.append(StoreSkillRow(
                            sessionId: scopedSessionId,
                            turnId: turn.id,
                            skillName: skill
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Pass 3c: subagent links (parent files only)

    private func appendSubagentLinkRows(
        parses: [FileParse],
        unit: ClaudeImportUnit,
        turnsBySession: [String: [Turn]],
        payloads: inout [StoreSourcePayload],
        outcome: inout Outcome
    ) -> [String: [SubAgentLinker.Link]] {
        // The linker records the RAW LINE's uuid as parentAssistantUuid,
        // but the assembler merges same-messageId assistant lines into
        // the FIRST line's step — a streamed `thinking` + `tool_use`
        // pair leaves the tool_use line's uuid pointing at no step row.
        // The stored row must carry the merged STEP uuid: the snapshot's
        // graft join (`stepTurnIds`) and the outline's sibling splice
        // both key on it exactly (the legacy surface scanned toolCalls
        // and never noticed). Map via the turn graph's toolCalls — the
        // same fold the merge performed.
        var stepUuidByToolUseId: [String: [String: String]] = [:]
        for (rawSessionId, turns) in turnsBySession {
            var map: [String: String] = [:]
            for turn in turns {
                for step in turn.steps {
                    for call in step.toolCalls {
                        map[call.id] = step.uuid
                    }
                }
            }
            stepUuidByToolUseId[rawSessionId] = map
        }

        var linksBySession: [String: [SubAgentLinker.Link]] = [:]
        for (index, parse) in parses.enumerated() {
            guard !parse.file.isSubagent, !parse.linkerCandidateLines.isEmpty else { continue }
            let rawSessionId = parse.primaryRawSessionId ?? unit.sessionRawId
            let scopedSessionId = Self.scoped(rawSessionId)
            let stepUuids = stepUuidByToolUseId[rawSessionId] ?? [:]
            let extraction = SubAgentLinker.extractDetailed(
                fromParentLines: parse.linkerCandidateLines,
                parentFileURL: parse.file.url
            )
            linksBySession[scopedSessionId, default: []].append(contentsOf: extraction.links)
            for link in extraction.links {
                payloads[index].subagentLinks.append(StoreSubagentLinkRow(
                    sessionId: scopedSessionId,
                    linkKind: link.linkKind.rawValue,
                    agentId: link.agentId,
                    parentToolUseId: link.parentToolUseId,
                    parentAssistantUuid: stepUuids[link.parentToolUseId] ?? link.parentAssistantUuid,
                    parentMessageId: link.parentMessageId,
                    linkDescription: link.description,
                    subagentType: link.subagentType,
                    timestamp: link.timestamp,
                    workflowTaskId: link.workflowTaskId,
                    workflowRunId: link.workflowRunId,
                    workflowName: link.workflowName,
                    workflowPhaseTitle: link.workflowPhaseTitle,
                    workflowLabel: link.workflowLabel,
                    workflowStatus: link.workflowStatus,
                    workflowModel: link.workflowModel,
                    workflowAgentState: link.workflowAgentState,
                    workflowTelemetryTokens: link.workflowTelemetryTokens,
                    workflowToolCalls: link.workflowToolCalls,
                    workflowDurationMs: link.workflowDurationMs
                ))
                outcome.subagentLinkRows += 1
            }
            for toolUseId in extraction.droppedToolUseIdsMissingAgentId {
                payloads[index].diagnostics.append(StoreDiagnosticRow(
                    sessionId: scopedSessionId,
                    severity: "warning",
                    category: DecodeRejection.subagentLinkageMissingAgentId(toolUseId).categoryKey,
                    lineNumber: nil,
                    byteOffset: nil,
                    preview: DecodeRejection.subagentLinkageMissingAgentId(toolUseId).humanDescription,
                    createdAt: Date()
                ))
            }
        }
        return linksBySession
    }

    // MARK: - Session shells

    private func sessionShells(
        unit: ClaudeImportUnit,
        parses: [FileParse],
        turnsBySession: [String: [Turn]]
    ) -> [StoreSessionRow] {
        // Request-derived time range per session (legacy parity:
        // Session.startTime/endTime come from billable requests only).
        // The same pass tracks the newest request-carried gitBranch —
        // legacy `Session.lastGitBranch` walks the timestamp-sorted
        // requests from the tail for the first non-nil value.
        var requestTimes: [String: (start: Date, end: Date)] = [:]
        var lastBranch: [String: (timestamp: Date, branch: String)] = [:]
        for parse in parses {
            for entry in parse.entries where entry.entryType == .assistant && entry.usage != nil {
                let existing = requestTimes[entry.sessionId]
                requestTimes[entry.sessionId] = (
                    start: min(existing?.start ?? entry.timestamp, entry.timestamp),
                    end: max(existing?.end ?? entry.timestamp, entry.timestamp)
                )
                if let branch = entry.gitBranch,
                   entry.timestamp >= (lastBranch[entry.sessionId]?.timestamp ?? .distantPast) {
                    lastBranch[entry.sessionId] = (entry.timestamp, branch)
                }
            }
        }

        var slugBySession: [String: String] = [:]
        var customTitleBySession: [String: String] = [:]
        var logicalParentBySession: [String: String] = [:]
        for parse in parses {
            guard let rawSessionId = parse.primaryRawSessionId else { continue }
            if let slug = parse.slug, slugBySession[rawSessionId] == nil {
                slugBySession[rawSessionId] = slug
            }
            if let custom = parse.customTitle {
                customTitleBySession[rawSessionId] = custom
            }
            if let lpu = parse.logicalParentUuid, logicalParentBySession[rawSessionId] == nil {
                logicalParentBySession[rawSessionId] = lpu
            }
        }

        var sessionIds = Set(turnsBySession.keys)
        sessionIds.formUnion(requestTimes.keys)
        sessionIds.insert(unit.sessionRawId)

        return sessionIds.sorted().map { rawSessionId in
            let turns = turnsBySession[rawSessionId] ?? []
            let firstTurn = turns.first
            let firstPromptText = turns.lazy
                .compactMap { turn -> String? in
                    guard let prompt = turn.promptStep, !prompt.isSidechain else { return nil }
                    let cleaned = TurnPreview.clean(prompt.text ?? "")
                    return cleaned.isEmpty ? nil : cleaned
                }
                .first
            return StoreSessionRow(
                id: Self.scoped(rawSessionId),
                rawId: rawSessionId,
                projectPath: unit.projectPath,
                slug: slugBySession[rawSessionId],
                startTime: requestTimes[rawSessionId]?.start,
                endTime: requestTimes[rawSessionId]?.end,
                cachedTitle: firstTurn.map {
                    TurnPreview.make(for: $0, maxLength: configuration.titleMaxLength)
                },
                customTitle: customTitleBySession[rawSessionId],
                firstPrompt: firstPromptText.map {
                    TurnPreview.truncate($0, to: configuration.firstPromptMaxLength)
                },
                lastGitBranch: lastBranch[rawSessionId]?.branch,
                visible: true,
                // Promoted to `complete` for the unit session only after
                // every source landed (see importUnit).
                detailState: .partial,
                logicalParentUuid: logicalParentBySession[rawSessionId]
            )
        }
    }

    private static func scoped(_ rawSessionId: String) -> String {
        ProviderScopedID.normalize(rawSessionId, defaultProvider: .claudeCode)
    }
}
