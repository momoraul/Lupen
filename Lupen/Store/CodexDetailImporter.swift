//
//  CodexDetailImporter.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// One Codex atomic import unit (plan Non-Negotiable Rule 3): every
/// rollout file of one visible-session identity group, each read from
/// byte 0. Mid-file ranges are never a valid usage scope — cumulative
/// `previousTotal` dedup is order-dependent, duplicate rollout pieces
/// hand `initialPreviousTotal` across files, and subagent replay
/// trimming needs the parent piece.
struct CodexImportUnit: Sendable, Equatable {
    let sessionRawId: String
    let codexHome: URL
    let files: [URL]

    /// Builds the unit for one identity group from registered sources
    /// (the metadata scanner stamps `session_raw_id` with the group id).
    static func unit(
        forSessionRawId sessionRawId: String,
        codexHome: URL,
        sources: [StoreSourceFile]
    ) -> CodexImportUnit {
        CodexImportUnit(
            sessionRawId: sessionRawId,
            codexHome: codexHome,
            files: sources
                .filter { $0.sessionRawId == sessionRawId }
                .map(\.path)
                .sorted()
                .map(URL.init(fileURLWithPath:))
        )
    }
}

/// Phase 2.5/3.8a scoped Codex importer, streaming edition. The 3.8
/// run-1 trial proved the whole-group materialization unaffordable:
/// one real identity group is 374 files / 102 GB (a 2.3 GB parent plus
/// 373 subagent children), so the importer now processes the group as
/// a per-piece pipeline — read one rollout (raw bytes dropped at
/// collection; downstream consumes locators only) → trim → aggregate →
/// assemble → write that source's rows → release — carrying only
/// KB-scale state between pieces:
///
///   - `CodexSubagentReplayTrimmer.ParentSummary` per raw id (prompts +
///     cumulative totals) instead of the parent's decoded lines;
///   - `SameRawReplayCarry` per duplicate chain (replay-identity keys +
///     per-mode running totals) instead of accumulated previous lines;
///   - the cumulative `initialPreviousTotal` handoff;
///   - per-linked-agent turn accumulation, coalesced and written with
///     the chain's last piece;
///   - parent-turn link references, applied as aggregate adjustments at
///     unit completion (children import after their parent's rows).
///
/// Chains process topologically (parents before children, creation
/// order within a chain), so every consumer of cross-piece state sees
/// it complete. Turn ordinals are written in processing order and
/// renumbered once at unit completion (`renumberTurnOrdinals` mirrors
/// the legacy `turnSort`). The load-bearing per-piece semantics still
/// come verbatim from the legacy pipeline (trimmers, aggregator
/// discriminators, assembler, normalization) — the 2.9 equivalence
/// suites pin the result to the legacy grouped loader.
struct CodexDetailImporter: Sendable {

    struct Configuration: Sendable {
        var titleMaxLength: Int = TurnPreview.defaultMaxLength
        var firstPromptMaxLength: Int = 500
        var searchContentMaxLength: Int = 2_000
        var maxFirstLineBytes: Int = CodexSessionMetadataReader.defaultMaxFirstLineBytes
        /// Rows per write transaction inside `replaceSource` — bounds
        /// journal growth and gives cancellation its batch boundaries.
        var writeBatchRowLimit: Int = 2_000
        init() {}
    }

    struct Outcome: Equatable, Sendable {
        var importedSources = 0
        var skippedUnreadableFiles = 0
        var requestRows = 0
        var turnRows = 0
        var stepRows = 0
        var subagentLinkRows = 0
        var diagnosticRows = 0
        var cancelled = false
        var unitComplete = false
    }

    let writer: any ImportWriting
    var configuration = Configuration()

    // MARK: - Import

    @discardableResult
    func importUnit(
        _ unit: CodexImportUnit,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Outcome {
        var outcome = Outcome()
        guard !unit.files.isEmpty else { return outcome }

        let titleIndex = CodexSessionTitleIndexReader.read(
            from: unit.codexHome.appendingPathComponent("session_index.jsonl")
        )

        // Phase 0: first-line metadata for every rollout (KB-scale).
        var pieces: [PieceMeta] = []
        for url in unit.files {
            guard let piece = readPieceMeta(url, titleIndex: titleIndex) else {
                outcome.skippedUnreadableFiles += 1
                continue
            }
            pieces.append(piece)
        }
        guard !pieces.isEmpty else { return outcome }

        var plan = GroupPlan(unit: unit, pieces: pieces, titleIndex: titleIndex)
        // Skill catalog once per unit (plan 4.4) — import-time `$skill`
        // extraction matches the Reports-side known-names gate.
        plan.knownSkillNames = CodexSkillCatalog.currentSkillNames(
            codexHome: unit.codexHome
        )
        var state = StreamState()

        // Streaming pass: chains topologically, pieces in creation order.
        chainLoop: for chain in plan.chains {
            var carry = CodexUsageSessionLoader.SameRawReplayCarry()
            var chainLastTotal: CodexTokenUsage?
            var chainSummary = CodexSubagentReplayTrimmer.ParentSummary()

            for (pieceIndex, piece) in chain.pieces.enumerated() {
                if isCancelled() {
                    outcome.cancelled = true
                    break chainLoop
                }
                let isLastOfChain = pieceIndex == chain.pieces.count - 1
                let completed = try autoreleasepool {
                    try importPiece(
                        piece,
                        chain: chain,
                        isLastOfChain: isLastOfChain,
                        plan: plan,
                        carry: &carry,
                        chainLastTotal: &chainLastTotal,
                        chainSummary: &chainSummary,
                        state: &state,
                        outcome: &outcome,
                        isCancelled: isCancelled
                    )
                }
                guard completed else {
                    outcome.cancelled = true
                    break chainLoop
                }
                outcome.importedSources += 1
            }
            state.parentSummaries[chain.rawId] = chainSummary
        }

        if !outcome.cancelled, outcome.skippedUnreadableFiles == 0,
           outcome.importedSources == pieces.count {
            // Display order + linked-subagent contributions land once
            // the whole unit is on disk.
            try writer.renumberTurnOrdinals(sessionId: plan.scopedSessionId)
            try writer.applyTurnAggregateAdjustments(
                state.turnAggregateAdjustments(sessionId: plan.scopedSessionId)
            )
            try SessionCostFinalizer(writer: writer).finalize(sessionId: plan.scopedSessionId)
            var shell = plan.sessionShell(
                state: state, firstPromptMaxLength: configuration.firstPromptMaxLength
            )
            shell.detailState = .complete
            try writer.upsertSessionShells([shell])
            outcome.unitComplete = true
        }
        return outcome
    }

    // MARK: - Phase 0 types

    private struct PieceMeta {
        let url: URL
        let path: String
        let byteSize: Int64
        let modifiedAt: Date?
        let metadata: CodexSessionMetadata
    }

    private struct Chain {
        let rawId: String
        let pieces: [PieceMeta]
        /// Duplicate rollouts (N files, one raw id) enable source
        /// discriminators and same-raw replay trimming — legacy rule.
        var usesDiscriminator: Bool { pieces.count > 1 }
    }

    /// Identity facts derived from first-line metadata only.
    private struct GroupPlan {
        let visibleRawId: String
        let scopedSessionId: String
        let chains: [Chain]
        let directChildMetadataById: [String: CodexSessionMetadata]
        let visible: Bool
        let cachedTitle: String?
        let projectPath: String?
        /// Newest piece's `session_meta` git.branch (scanner rule shared
        /// via `CodexMetadataScanner.lastGitBranch`).
        let lastGitBranch: String?
        /// Skill catalog for import-time `$skill` extraction (plan 4.4)
        /// — loaded once per unit from the unit's codexHome.
        var knownSkillNames: Set<String>? = nil

        init(unit: CodexImportUnit, pieces: [PieceMeta], titleIndex: CodexSessionTitleIndex) {
            visibleRawId = unit.sessionRawId
            scopedSessionId = ProviderScopedID(
                provider: .codex, rawSessionId: unit.sessionRawId
            ).value

            var byRawId: [String: [PieceMeta]] = [:]
            for piece in pieces {
                byRawId[piece.metadata.id, default: []].append(piece)
            }
            for rawId in byRawId.keys {
                byRawId[rawId]?.sort { lhs, rhs in
                    let lhsTime = lhs.metadata.createdAt ?? .distantPast
                    let rhsTime = rhs.metadata.createdAt ?? .distantPast
                    if lhsTime != rhsTime { return lhsTime < rhsTime }
                    return lhs.path < rhs.path
                }
            }

            // Topological chain order: parents before children so the
            // parent summary is complete when a child trims against it.
            let knownRawIds = Set(byRawId.keys)
            var parentByRawId: [String: String] = [:]
            for piece in pieces {
                guard let parent = piece.metadata.subagentParentRawSessionId,
                      parent != piece.metadata.id,
                      parentByRawId[piece.metadata.id] == nil else { continue }
                parentByRawId[piece.metadata.id] = parent
            }
            func depth(of rawId: String) -> Int {
                var current = rawId
                var visited: Set<String> = [rawId]
                var result = 0
                while let parent = parentByRawId[current],
                      parent != current,
                      knownRawIds.contains(parent),
                      visited.insert(parent).inserted {
                    current = parent
                    result += 1
                }
                return result
            }
            chains = byRawId
                .map { Chain(rawId: $0.key, pieces: $0.value) }
                .sorted { lhs, rhs in
                    let lhsDepth = depth(of: lhs.rawId)
                    let rhsDepth = depth(of: rhs.rawId)
                    if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                    let lhsTime = lhs.pieces.first?.metadata.createdAt ?? .distantPast
                    let rhsTime = rhs.pieces.first?.metadata.createdAt ?? .distantPast
                    if lhsTime != rhsTime { return lhsTime < rhsTime }
                    return lhs.rawId < rhs.rawId
                }

            var childMetadata: [String: CodexSessionMetadata] = [:]
            for piece in pieces {
                let metadata = piece.metadata
                guard metadata.id != unit.sessionRawId,
                      metadata.subagentParentRawSessionId == unit.sessionRawId,
                      childMetadata[metadata.id] == nil else { continue }
                childMetadata[metadata.id] = metadata
            }
            directChildMetadataById = childMetadata

            visible = true

            // Legacy primary-piece rule for cwd/title: the root's own
            // piece when present, else the earliest-created piece.
            let primary = pieces.first { $0.metadata.id == unit.sessionRawId }
                ?? pieces.min { lhs, rhs in
                    let lhsTime = lhs.metadata.createdAt ?? .distantPast
                    let rhsTime = rhs.metadata.createdAt ?? .distantPast
                    if lhsTime != rhsTime { return lhsTime < rhsTime }
                    return lhs.metadata.id < rhs.metadata.id
                }
            cachedTitle = primary?.metadata.titleHint
                ?? pieces.compactMap(\.metadata.titleHint).first
            projectPath = primary?.metadata.cwd
                ?? pieces.compactMap(\.metadata.cwd).first
            lastGitBranch = CodexMetadataScanner.lastGitBranch(in: pieces.map(\.metadata))
        }

        func sessionShell(state: StreamState, firstPromptMaxLength: Int) -> StoreSessionRow {
            StoreSessionRow(
                id: scopedSessionId,
                rawId: visibleRawId,
                projectPath: projectPath,
                slug: nil,
                startTime: state.firstRequestTime,
                endTime: state.lastRequestTime,
                // thread_name only — the legacy Codex sidebar shows the
                // id prefix for index-less sessions (3.7 parity).
                cachedTitle: cachedTitle,
                customTitle: nil,
                firstPrompt: state.firstPrompt.map {
                    TurnPreview.truncate($0, to: firstPromptMaxLength)
                },
                lastGitBranch: lastGitBranch,
                visible: visible,
                detailState: .partial
            )
        }
    }

    // MARK: - Streaming state (KB-scale carries between pieces)

    private struct StreamState {
        var parentSummaries: [String: CodexSubagentReplayTrimmer.ParentSummary] = [:]
        var seenAgentIds: Set<String> = []
        /// Linked agents' normalized turns, accumulated only while that
        /// agent's chain is processing; coalesced with its last piece.
        var sidechainTurns: [String: [Turn]] = [:]
        var sidechainFallbackId: [String: String] = [:]
        /// agentId → coalesced contribution (the legacy graft adds the
        /// agent's single coalesced turn to the parent turn's header).
        var agentContribution: [String: (tokens: TokenBreakdown, cost: CostBreakdown)] = [:]
        /// Parent turn id → agent ids its steps spawned (graft refs).
        var linkedAgentsByTurnId: [String: Set<String>] = [:]
        var nextTurnOrdinal = 0
        var firstRequestTime: Date?
        var lastRequestTime: Date?
        var firstPrompt: String?
        var firstPromptTime: Date?

        mutating func notedRequestTime(_ timestamp: Date) {
            firstRequestTime = min(firstRequestTime ?? timestamp, timestamp)
            lastRequestTime = max(lastRequestTime ?? timestamp, timestamp)
        }

        mutating func notePrompt(_ text: String, at time: Date?) {
            let stamp = time ?? .distantFuture
            if firstPrompt == nil || stamp < (firstPromptTime ?? .distantFuture) {
                firstPrompt = text
                firstPromptTime = stamp
            }
        }

        func turnAggregateAdjustments(sessionId: String) -> [StoreTurnAggregateAdjustment] {
            linkedAgentsByTurnId.sorted { $0.key < $1.key }.map { turnId, agentIds in
                var tokenParts: [TokenBreakdown] = []
                var costParts: [CostBreakdown] = []
                var complete = true
                for agentId in agentIds {
                    guard let contribution = agentContribution[agentId] else {
                        complete = false   // child never produced a turn (Rule 6)
                        continue
                    }
                    tokenParts.append(contribution.tokens)
                    costParts.append(contribution.cost)
                }
                return StoreTurnAggregateAdjustment(
                    sessionId: sessionId,
                    turnId: turnId,
                    addTokens: TokenCalculator.aggregateTokens(tokenParts),
                    addCost: TokenCalculator.aggregateCosts(costParts),
                    complete: complete
                )
            }
        }
    }

    // MARK: - Per-piece pipeline

    private func importPiece(
        _ piece: PieceMeta,
        chain: Chain,
        isLastOfChain: Bool,
        plan: GroupPlan,
        carry: inout CodexUsageSessionLoader.SameRawReplayCarry,
        chainLastTotal: inout CodexTokenUsage?,
        chainSummary: inout CodexSubagentReplayTrimmer.ParentSummary,
        state: inout StreamState,
        outcome: inout Outcome,
        isCancelled: @Sendable () -> Bool
    ) throws -> Bool {
        // 1. Stream-read this rollout. Raw line bytes are dropped at
        //    collection — the assembler and aggregator consume locators
        //    only; rejected lines keep their bytes out-of-band counts.
        var decodedLines: [CodexLineReader.DecodedLine] = []
        var rejected: [(line: CodexLineReader.RejectedLine, ordinal: Int, offset: UInt64)] = []
        CodexLineReader.streamEntries(from: piece.url) { streamed in
            switch streamed {
            case .decoded(let line):
                decodedLines.append(CodexLineReader.DecodedLine(
                    entry: line.entry, rawData: Data(), rawLocator: line.rawLocator
                ))
            case .rejected(let line, let ordinal, let offset):
                rejected.append((line, ordinal, offset))
            }
            return true
        }
        let rawLineCount = decodedLines.count + rejected.count

        // The parent summary absorbs the UNTRIMMED lines — the legacy
        // trimmer received the parent's raw read.
        defer {
            chainSummary.absorb(decodedLines)
            decodedLines = []
        }

        // 2. Subagent replay trim against the parent's summary.
        let parentSummary = piece.metadata.subagentParentRawSessionId
            .flatMap { state.parentSummaries[$0] }
            ?? CodexSubagentReplayTrimmer.ParentSummary()
        let subagentTrim = CodexSubagentReplayTrimmer.trim(
            decodedLines, metadata: piece.metadata, parentSummary: parentSummary
        )

        // 3. Same-raw replay trim against the chain carry.
        let sameRawTrim: CodexUsageSessionLoader.SameRawReplayTrim
        if chain.usesDiscriminator {
            sameRawTrim = CodexUsageSessionLoader.trimSameRawReplay(
                subagentTrim.decodedLines, carry: carry
            )
        } else {
            sameRawTrim = CodexUsageSessionLoader.SameRawReplayTrim(
                decodedLines: subagentTrim.decodedLines, droppedLineCount: 0
            )
        }
        let keptLines = sameRawTrim.decodedLines

        // 4. Cumulative chain handoff.
        let initialPreviousTotal = subagentTrim.initialPreviousTotal
            ?? (chain.usesDiscriminator ? chainLastTotal : nil)

        // 5. Aggregate with the legacy discriminator wrap.
        let sourceDiscriminator = chain.usesDiscriminator
            ? CodexSourceDiscriminator.key(for: piece.metadata.fileURL)
            : nil
        let aggregation = CodexUsageSessionLoader.codexUsageAggregation(
            metadata: piece.metadata,
            decodedLines: keptLines,
            initialPreviousTotal: initialPreviousTotal,
            sourceDiscriminator: sourceDiscriminator
        )
        let pieceCosts = CostCalculator.calculateCosts(for: aggregation.requests)

        let isLinkedSubagent = CodexUsageSessionLoader.shouldGraftAsDirectCodexSubagent(
            metadata: piece.metadata,
            visibleRawSessionId: plan.visibleRawId,
            linkedAgentIds: state.seenAgentIds
        )

        var payload = StoreSourcePayload()

        // 6. Request rows (identity-remapped to the visible session).
        for request in aggregation.requests {
            let remapped = request.withSessionIdentity(
                provider: .codex,
                rawSessionId: plan.visibleRawId,
                scopedSessionId: plan.scopedSessionId
            ).withSidechain(isLinkedSubagent)
            let tokens = remapped.tokens
            payload.requests.append(StoreRequestRow(
                id: remapped.id,
                sessionId: plan.scopedSessionId,
                timestamp: remapped.timestamp,
                model: remapped.model,
                messageId: remapped.messageId,
                parentUuid: remapped.parentUuid,
                isSidechain: remapped.isSidechain,
                speed: remapped.speed,
                stopReason: remapped.stopReason,
                inputTokens: tokens.inputTokens,
                outputTokens: tokens.outputTokens,
                reasoningOutputTokens: tokens.reasoningOutputTokens,
                cacheCreationInputTokens: tokens.cacheCreationInputTokens,
                cacheReadInputTokens: tokens.cacheReadInputTokens,
                cacheCreationEphemeral1h: tokens.cacheCreationEphemeral1h,
                cacheCreationEphemeral5m: tokens.cacheCreationEphemeral5m,
                provisionalCostUSD: (pieceCosts[request.id] ?? nil)?.totalCostUSD
            ))
            outcome.requestRows += 1
            state.notedRequestTime(remapped.timestamp)

            if let locator = aggregation.rawPayloadLocatorByRequestId[request.id] {
                payload.rawLocators.append(StoreRawLocatorRow(
                    sessionId: plan.scopedSessionId,
                    ownerKind: "requestTokenCount",
                    ownerId: remapped.id,
                    byteOffset: locator.byteOffset.map(Int64.init),
                    byteLength: locator.lineByteCount.map(Int64.init),
                    lineNumber: locator.lineOrdinal
                ))
            }
        }

        // 7. Assemble + normalize this piece's conversation.
        let assembled = CodexConversationAssembler.assemble(
            metadata: piece.metadata,
            decodedLines: keptLines,
            usageRequests: aggregation.requests.map { $0.withSidechain(isLinkedSubagent) },
            costsByRequestId: pieceCosts
        )
        let normalizedTurns = CodexUsageSessionLoader.normalizeTurns(
            assembled,
            to: plan.scopedSessionId,
            sourceSessionId: piece.metadata.scopedId,
            sourceDiscriminator: sourceDiscriminator,
            sidechainAgentId: isLinkedSubagent ? piece.metadata.id : nil
        )

        // 8. Root pieces: extract subagent links while resident.
        var pieceLinks: [SubAgentLinker.Link] = []
        if piece.metadata.id == plan.visibleRawId {
            pieceLinks = CodexUsageSessionLoader.codexSubagentLinks(
                fromNormalizedParentTurns: normalizedTurns,
                directChildMetadataById: plan.directChildMetadataById,
                seenAgentIds: &state.seenAgentIds
            )
            for link in pieceLinks {
                payload.subagentLinks.append(Self.linkRow(link, sessionId: plan.scopedSessionId))
                outcome.subagentLinkRows += 1
            }
        }

        // 9. Turn/step/search rows. Linked agents accumulate and write
        //    one coalesced turn with their chain's last piece.
        if isLinkedSubagent {
            state.sidechainTurns[piece.metadata.id, default: []]
                .append(contentsOf: normalizedTurns)
            if state.sidechainFallbackId[piece.metadata.id] == nil {
                let prefix = sourceDiscriminator.map {
                    "\(piece.metadata.scopedId):source:\($0)"
                }
                state.sidechainFallbackId[piece.metadata.id] = prefix.map {
                    "\($0):\(piece.metadata.id)"
                } ?? "\(piece.metadata.scopedId):\(piece.metadata.id)"
            }
            if isLastOfChain {
                let agentId = piece.metadata.id
                if let coalesced = CodexUsageSessionLoader.coalescedSidechainTurn(
                    state.sidechainTurns[agentId] ?? [],
                    sessionId: plan.scopedSessionId,
                    agentId: agentId,
                    fallbackId: state.sidechainFallbackId[agentId]
                        ?? "\(plan.scopedSessionId):\(agentId)"
                ) {
                    appendTurnRows(
                        [coalesced], links: [], plan: plan,
                        payload: &payload, state: &state, outcome: &outcome
                    )
                    state.agentContribution[agentId] = (
                        tokens: coalesced.aggregateTokens,
                        cost: coalesced.aggregateCost
                    )
                }
                state.sidechainTurns[agentId] = nil
            }
        } else {
            appendTurnRows(
                normalizedTurns, links: pieceLinks, plan: plan,
                payload: &payload, state: &state, outcome: &outcome
            )
        }

        // 10. Diagnostics: positional rejects + legacy shape warnings.
        for reject in rejected {
            let rejection = DecodeRejection.malformedJSON(reject.line.errorDescription)
            payload.diagnostics.append(StoreDiagnosticRow(
                sessionId: plan.scopedSessionId,
                severity: Self.severityString(rejection.severity),
                category: rejection.categoryKey,
                lineNumber: reject.ordinal,
                byteOffset: Int64(reject.offset),
                preview: rejection.humanDescription,
                createdAt: Date()
            ))
        }
        let batch = CodexLineDiagnostics.batch(
            fileURL: piece.metadata.fileURL,
            decodedLines: keptLines,
            usageRequests: aggregation.requests,
            skippedForkReplayCount: aggregation.skippedForkReplayCount
        )
        var shapeRejections = batch.items.map(\.rejection)
        if aggregation.skippedDuplicateCumulativeCount > 0 {
            shapeRejections.append(.codexSkippedDuplicateCumulativeTotals(
                aggregation.skippedDuplicateCumulativeCount
            ))
        }
        for rejection in shapeRejections where rejection.severity != .info {
            payload.diagnostics.append(StoreDiagnosticRow(
                sessionId: plan.scopedSessionId,
                severity: Self.severityString(rejection.severity),
                category: rejection.categoryKey,
                lineNumber: nil,
                byteOffset: nil,
                preview: rejection.humanDescription,
                createdAt: Date()
            ))
        }
        outcome.diagnosticRows += payload.diagnostics.count

        // 11. Shell rides along (partial; widening upsert).
        payload.sessions = [plan.sessionShell(
            state: state, firstPromptMaxLength: configuration.firstPromptMaxLength
        )]

        // 12. Provenance-replacing write for THIS source, then update
        //     the chain carries from the kept lines.
        let source = StoreSourceFile(
            path: piece.path,
            byteSize: piece.byteSize,
            modifiedAt: piece.modifiedAt,
            fingerprint: StoreSourceFingerprint.make(
                byteSize: piece.byteSize, modifiedAt: piece.modifiedAt
            ),
            lineCount: rawLineCount,
            rejectedLineCount: rejected.count,
            sessionRawId: plan.visibleRawId,
            isSubagent: piece.metadata.isSubagentThread,
            subagentParentRawId: piece.metadata.subagentParentRawSessionId,
            workflowRunId: nil
        )
        let completed = try writer.replaceSource(
            source, payload: payload,
            batchRowLimit: configuration.writeBatchRowLimit,
            isCancelled: isCancelled
        )
        guard completed else { return false }

        if chain.usesDiscriminator {
            CodexUsageSessionLoader.appendSameRawReplayKeys(of: keptLines, to: &carry)
            chainLastTotal = CodexUsageSessionLoader.lastEffectiveTotal(
                in: keptLines, initialPreviousTotal: initialPreviousTotal
            ) ?? chainLastTotal
        }
        return true
    }

    /// Writes top-level turn rows for one piece: per-turn aggregate
    /// columns via the shared outline join (2.7); parent turns that
    /// spawned linked agents record the reference for the unit-end
    /// adjustment and start incomplete (children import later).
    private func appendTurnRows(
        _ turns: [Turn],
        links: [SubAgentLinker.Link],
        plan: GroupPlan,
        payload: inout StoreSourcePayload,
        state: inout StreamState,
        outcome: inout Outcome
    ) {
        let graft = SubAgentGraftIndex.make(
            visibleTurns: turns.filter { !$0.isSidechainOnly },
            allTurns: turns,
            links: links
        )
        for turn in turns {
            let linkedAgentIds = Set(
                turn.steps.flatMap { graft.linksByStepUuid[$0.uuid] ?? [] }.map(\.agentId)
            )
            let aggregate = TurnAggregateColumns.make(turn: turn, graft: graft)
            let referencesPendingChildren = !linkedAgentIds.isEmpty
            payload.turns.append(StoreTurnRow(
                sessionId: plan.scopedSessionId,
                id: turn.id,
                ordinal: state.nextTurnOrdinal,
                startTime: turn.startTime,
                endTime: turn.endTime,
                promptPreview: TurnPreview.make(for: turn, maxLength: configuration.titleMaxLength),
                stepCount: turn.steps.count,
                interrupted: turn.isInterrupted,
                sidechainOnly: turn.isSidechainOnly,
                aggTokens: aggregate.tokens,
                aggCost: aggregate.cost,
                aggModels: aggregate.models,
                aggComplete: referencesPendingChildren ? false : aggregate.complete
            ))
            state.nextTurnOrdinal += 1
            outcome.turnRows += 1
            if referencesPendingChildren {
                state.linkedAgentsByTurnId[turn.id, default: []].formUnion(linkedAgentIds)
            }

            for (stepOrdinal, step) in turn.steps.enumerated() {
                payload.steps.append(StoreStepRow(
                    sessionId: plan.scopedSessionId,
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

                if let locator = step.rawJSONLocator {
                    payload.rawLocators.append(StoreRawLocatorRow(
                        sessionId: plan.scopedSessionId,
                        ownerKind: "stepLine",
                        ownerId: step.uuid,
                        byteOffset: locator.byteOffset.map(Int64.init),
                        byteLength: locator.lineByteCount.map(Int64.init),
                        lineNumber: locator.lineOrdinal
                    ))
                }
            }

            if let prompt = turn.promptStep, let text = prompt.text, !text.isEmpty {
                if !prompt.isSidechain {
                    let cleaned = TurnPreview.clean(text)
                    if !cleaned.isEmpty {
                        state.notePrompt(cleaned, at: prompt.timestamp)
                    }
                }
                payload.searchEntries.append(StoreSearchEntry(
                    sessionId: plan.scopedSessionId,
                    turnId: turn.id,
                    stepUuid: prompt.uuid,
                    kind: "prompt",
                    content: String(text.prefix(configuration.searchContentMaxLength))
                ))
                if let skill = CostAnalyzer.extractSkillName(
                    from: text,
                    provider: .codex,
                    knownCodexSkillNames: plan.knownSkillNames
                ) {
                    payload.skills.append(StoreSkillRow(
                        sessionId: plan.scopedSessionId,
                        turnId: turn.id,
                        skillName: skill
                    ))
                }
            }
        }
    }

    // MARK: - Helpers

    private func readPieceMeta(_ url: URL, titleIndex: CodexSessionTitleIndex) -> PieceMeta? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ), let size = values.fileSize else { return nil }
        guard let baseMetadata = try? CodexSessionMetadataReader.readMetadata(
            from: url, maxFirstLineBytes: configuration.maxFirstLineBytes
        ) else { return nil }
        return PieceMeta(
            url: url,
            path: url.standardizedFileURL.path,
            byteSize: Int64(size),
            modifiedAt: values.contentModificationDate,
            metadata: baseMetadata.withTitleHint(titleIndex.title(for: baseMetadata.id))
        )
    }

    private static func linkRow(
        _ link: SubAgentLinker.Link, sessionId: String
    ) -> StoreSubagentLinkRow {
        StoreSubagentLinkRow(
            sessionId: sessionId,
            linkKind: link.linkKind.rawValue,
            agentId: link.agentId,
            parentToolUseId: link.parentToolUseId,
            parentAssistantUuid: link.parentAssistantUuid,
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
        )
    }

    private static func severityString(_ severity: DecodeRejection.Severity) -> String {
        switch severity {
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }
}
