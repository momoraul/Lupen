//
//  SQLiteConversationSource.swift
//  Lupen
//
//  Created by jaden on 2026/06/11.
//

import Foundation

/// Conversation-surface reads for SQLite-first mode (plan 4.1).
///
/// Top level: turn-header STUBS from the turns table's aggregate
/// columns. A stub is a `Turn` whose only step is a synthetic prompt
/// carrying `prompt_preview` — the title chain, appearance animation and
/// highlight machinery all read `promptStep.text`. Header numerics never
/// come from stub steps; `Snapshot.aggregates` carries the real columns.
///
/// Children materialize per turn on expand:
/// - Claude turns re-decode their original JSONL lines via
///   `raw_locators` through the importer's exact pipeline
///   (`RichEntryDecoder` → fresh `ConversationAssembler`), so child rows
///   render at full fidelity (tool inputs, results, attachments) without
///   a session-wide parse. The line set includes direct child lines that
///   produced no step row (meta entries the assembler merges back into
///   prompt steps).
/// - Codex turns map from the steps table (identity / order / text /
///   metrics), with tool input/result payloads re-decoded from the
///   turn's rollout lines through the REAL `CodexConversationAssembler`
///   (6.4): assembled steps match back to rows by (byteOffset, kind) —
///   line-local identity that survives normalize-time uuid prefixing.
///   Any line that fails to decode or match degrades that row back to
///   the bare projection, never an error.
struct SQLiteConversationSource: Sendable {

    let store: ProviderStore
    let provider: ProviderKind

    // MARK: - Snapshot (top level)

    struct HeaderAggregate: Sendable, Equatable {
        let stepCount: Int
        let startTime: Date?
        let endTime: Date?
        let tokens: TokenBreakdown
        let cost: CostBreakdown
        /// `TurnModelSummary.resolve` order: primary first, then extras.
        let models: [String]
        let complete: Bool
        let interrupted: Bool
        let sidechainOnly: Bool
    }

    struct Snapshot: Sendable {
        /// Header stubs in ordinal order — sidechain turns included
        /// (the consumer hides them at top level and grafts them).
        let turns: [Turn]
        /// Turn id → the header numbers the aggregate columns carry.
        let aggregates: [String: HeaderAggregate]
        let links: [SubAgentLinker.Link]
        /// Sidechain-only turn id → its agent id (graft target lookup).
        let agentIdByTurnId: [String: String]
        /// Link `parentAssistantUuid` → the turn that step belongs to.
        let turnIdByParentStepUuid: [String: String]
        /// Turns whose reply was compacted away (header badge) —
        /// computed here because stubs cannot answer step-count checks.
        let compactedAwayTurnIds: Set<String>

        static let empty = Snapshot(
            turns: [], aggregates: [:], links: [],
            agentIdByTurnId: [:], turnIdByParentStepUuid: [:],
            compactedAwayTurnIds: []
        )
    }

    func snapshot(sessionId: String) throws -> Snapshot {
        var rows: [StoreTurnRow] = []
        var after: Int?
        while true {
            let page = try store.turnPage(sessionId: sessionId, limit: 500, afterOrdinal: after)
            rows.append(contentsOf: page)
            if page.count < 500 { break }
            after = page.last?.ordinal
        }
        guard !rows.isEmpty else { return .empty }

        let agentIdByTurnId = try store.sidechainAgentIds(sessionId: sessionId)

        var aggregates: [String: HeaderAggregate] = [:]
        var stubs: [Turn] = []
        stubs.reserveCapacity(rows.count)
        for row in rows {
            aggregates[row.id] = HeaderAggregate(
                stepCount: row.stepCount,
                startTime: row.startTime,
                endTime: row.endTime,
                tokens: row.aggTokens,
                cost: row.aggCost,
                models: row.aggModels,
                complete: row.aggComplete,
                interrupted: row.interrupted,
                sidechainOnly: row.sidechainOnly
            )
            stubs.append(Self.headerStub(for: row, agentId: agentIdByTurnId[row.id]))
        }

        // Compacted-away detection needs the chronological neighbour and
        // the REAL step count — both unavailable on stubs, so resolve it
        // here from the rows (same rule as `Turn.wasCompactedAway`).
        var compacted: Set<String> = []
        let chronological = rows.sorted {
            ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast)
        }
        for index in chronological.indices.dropLast() {
            let row = chronological[index]
            guard row.stepCount == 1, !row.sidechainOnly else { continue }
            if chronological[index + 1].promptPreview == TurnPreview.compactResumeLabel {
                compacted.insert(row.id)
            }
        }

        let links = try store.subagentLinks(sessionId: sessionId).map(Self.link(from:))
        let turnIdByParentStepUuid = try store.stepTurnIds(
            sessionId: sessionId,
            uuids: links.map(\.parentAssistantUuid)
        )

        return Snapshot(
            turns: stubs,
            aggregates: aggregates,
            links: links,
            agentIdByTurnId: agentIdByTurnId,
            turnIdByParentStepUuid: turnIdByParentStepUuid,
            compactedAwayTurnIds: compacted
        )
    }

    // MARK: - Steps on expand

    /// Materializes one turn's UI-grade steps. Never touches any line
    /// outside the turn — bounded work regardless of session size.
    func materializeSteps(sessionId: String, turnId: String) throws -> [Step] {
        switch provider {
        case .claudeCode:
            let steps = try claudeSteps(sessionId: sessionId, turnId: turnId)
            // Sources can vanish between import and expand (vacuumed
            // logs); fall back to the table projection rather than an
            // empty child list.
            return steps.isEmpty
                ? try tableSteps(sessionId: sessionId, turnId: turnId)
                : steps
        case .codex:
            return try tableSteps(sessionId: sessionId, turnId: turnId)
        }
    }

    /// Claude: scoped re-decode of the turn's raw lines through the
    /// import pipeline (full fidelity).
    private func claudeSteps(sessionId: String, turnId: String) throws -> [Step] {
        let locators = try store.turnLineLocators(sessionId: sessionId, turnId: turnId)
        guard !locators.isEmpty else { return [] }

        var entries: [RichEntry] = []
        entries.reserveCapacity(locators.count)
        for (path, fileLocators) in Dictionary(grouping: locators, by: \.sourcePath) {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                continue
            }
            defer { try? handle.close() }
            let ordered = fileLocators.sorted { ($0.byteOffset ?? 0) < ($1.byteOffset ?? 0) }
            for locator in ordered {
                guard let offset = locator.byteOffset,
                      let length = locator.byteLength, length > 0,
                      (try? handle.seek(toOffset: UInt64(offset))) != nil,
                      let data = try? handle.read(upToCount: Int(length)),
                      !data.isEmpty else { continue }
                let line = data.last == UInt8(ascii: "\n") ? Data(data.dropLast()) : data
                let (outcome, _, _) = RichEntryDecoder.decodeDetailedWithHeaderAndRejections(line)
                if case .entry(let entry) = outcome {
                    entries.append(entry)
                }
            }
        }
        guard !entries.isEmpty else { return [] }

        // The importer's exact composition: parent links registered, one
        // fresh assembler over the turn's entries. The turn's chain roots
        // at its own prompt (its parent line is outside the subset), so
        // the assembler reproduces exactly this turn's steps — including
        // meta-entry merges and attachment resolution.
        //
        // Entries normalize to the SCOPED session id before assembly
        // (6.3): every other surface — turn stubs, table-projected
        // steps, `DetailSelectionID`, the outline's selection identity
        // keys — speaks scoped ids, and raw-id steps broke step
        // selection restore (`step:<raw>:…` never matches the
        // `step:<scoped>:…` the restore path constructs). Parent links
        // register under the same scoped namespace — the assembler only
        // needs entries and links to agree on the key space.
        let assembler = ConversationAssembler()
        let linkRows = try store.parentLinks(sessionId: sessionId, uuids: entries.map(\.uuid))
        assembler.registerParentLinks(linkRows.map { row in
            RichEntryDecoder.ParentLink(
                sessionId: row.sessionId,
                uuid: row.uuid,
                parentUuid: row.parentUuid
            )
        })
        _ = assembler.ingest(entries.map { $0.withSessionId(sessionId) })
        let assembled = assembler.turnsBySession().values.flatMap { $0 }.flatMap(\.steps)

        // DB step ordinals are the authoritative display order (the
        // importer enumerated the assembler's order); meta-merged lines
        // produce no step row and are already folded into their prompt.
        var ordinalByUuid: [String: Int] = [:]
        for locator in locators {
            if let ordinal = locator.stepOrdinal {
                ordinalByUuid[locator.uuid] = ordinal
            }
        }
        // Index locators by uuid once — attaching per step with first(where:)
        // was O(n²) and froze the UI on multi-thousand-step turns.
        let locatorByUuid = Dictionary(locators.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return assembled
            .filter { ordinalByUuid[$0.uuid] != nil }
            .sorted { (ordinalByUuid[$0.uuid] ?? 0) < (ordinalByUuid[$1.uuid] ?? 0) }
            .map { attachLocator(to: $0, using: locatorByUuid) }
    }

    /// Steps-table projection: display-grade rows (Codex default; Claude
    /// fallback when raw lines are gone). Codex tool rows additionally
    /// hydrate input/result payloads from their locator lines (6.4).
    private func tableSteps(sessionId: String, turnId: String) throws -> [Step] {
        let sidechainOnly = try store.sidechainAgentIds(sessionId: sessionId)[turnId] != nil
        let locators = (try? store.turnLineLocators(sessionId: sessionId, turnId: turnId)) ?? []
        let rows = try store.steps(sessionId: sessionId, turnId: turnId)
        let payloads = provider == .codex
            ? codexToolPayloads(rows: rows, locators: locators)
            : [:]
        // Index locators by uuid once — O(1) attach instead of O(n²) first(where:).
        let locatorByUuid = Dictionary(locators.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            let payload = payloads[row.uuid]
            var toolCalls: [ToolUseInfo] = []
            if let toolName = row.toolName {
                toolCalls.append(ToolUseInfo(
                    id: row.toolUseId ?? "\(row.uuid):tool",
                    name: toolName,
                    inputJSON: payload?.inputJSON ?? "{}"
                ))
            }
            // Result content comes from the line; the pairing id stays
            // the DB's (normalize-prefixed) toolUseId so call/result
            // lookups keep agreeing across the surface.
            let toolResult = payload?.result.map {
                ToolResultInfo(
                    toolUseId: row.toolUseId ?? $0.toolUseId,
                    content: $0.content,
                    isError: $0.isError
                )
            }
            let step = Step(
                uuid: row.uuid,
                parentUuid: nil,
                sessionId: row.sessionId,
                timestamp: row.timestamp ?? .distantPast,
                kind: StepKind(rawValue: row.kind) ?? .thought,
                isSidechain: sidechainOnly || row.agentId != nil,
                agentId: row.agentId,
                text: row.text,
                thinkingText: row.thinkingText,
                toolCalls: toolCalls,
                toolResult: toolResult,
                requestId: row.requestId,
                model: row.model
            )
            return attachLocator(to: step, using: locatorByUuid)
        }
    }

    /// Per-line tool payloads for a Codex turn (6.4 — the 4.1 recorded
    /// gap). The steps table stores tool identity (name / toolUseId) but
    /// not the payloads: input JSON and result content live only in the
    /// rollout JSONL (by design — raw lines are the payload store).
    ///
    /// Mechanics: read the tool rows' locator lines (per source file —
    /// coalesced sidechain turns span pieces), decode them with
    /// `CodexLineReader`, assemble through the REAL
    /// `CodexConversationAssembler` so the extraction logic has a single
    /// owner, then match assembled steps back to rows by
    /// (byteOffset, kind). The offset half survives normalize-time uuid
    /// prefixing and partial-subset ordinal drift; the kind half splits
    /// an MCP end line, which yields a toolCall AND a toolResult step
    /// from ONE offset. Usage hydration is skipped — only the tool
    /// payload fields are read off the assembled steps.
    ///
    /// Every failure path (vanished source, unreadable meta, rejected
    /// line, unmatched step) just leaves those rows on the bare table
    /// projection — never an error, never a partial row mix-up.
    private func codexToolPayloads(
        rows: [StoreStepRow],
        locators: [StoreTurnLineLocator]
    ) -> [String: (inputJSON: String?, result: ToolResultInfo?)] {
        let toolKinds: Set<String> = [
            StepKind.toolCall.rawValue, StepKind.toolResult.rawValue,
        ]
        let toolRows = rows.filter { toolKinds.contains($0.kind) }
        guard !toolRows.isEmpty else { return [:] }

        let locatorByUuid = Dictionary(
            locators.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Assemble each source file's tool lines once.
        var assembledByLineKind: [String: Step] = [:]
        let toolLocators = toolRows.compactMap { locatorByUuid[$0.uuid] }
        for (path, fileLocators) in Dictionary(grouping: toolLocators, by: \.sourcePath) {
            let url = URL(fileURLWithPath: path)
            guard let metadata = try? CodexSessionMetadataReader.readMetadata(from: url),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }

            var decodedLines: [CodexLineReader.DecodedLine] = []
            var seenOffsets: Set<Int64> = []
            let ordered = fileLocators.sorted { ($0.byteOffset ?? 0) < ($1.byteOffset ?? 0) }
            for locator in ordered {
                guard let offset = locator.byteOffset,
                      seenOffsets.insert(offset).inserted,
                      let length = locator.byteLength, length > 0,
                      (try? handle.seek(toOffset: UInt64(offset))) != nil,
                      let data = try? handle.read(upToCount: Int(length)),
                      !data.isEmpty else { continue }
                let line = data.last == UInt8(ascii: "\n") ? Data(data.dropLast()) : data
                guard let decoded = CodexLineReader.decodeLines(from: [line]).decodedLines.first
                else { continue }
                // Re-attach the locator (decodeLines has no file context)
                // — the assembler copies it onto the step, which is how
                // the (offset, kind) match key comes back out.
                decodedLines.append(CodexLineReader.DecodedLine(
                    entry: decoded.entry,
                    rawData: Data(),
                    rawLocator: RawPayloadLocator(
                        provider: .codex,
                        kind: .stepLine,
                        sourceURL: url,
                        byteOffset: UInt64(offset),
                        lineOrdinal: nil,
                        lineByteCount: locator.byteLength.map(Int.init),
                        fingerprint: RawPayloadLocator.SourceFingerprint(
                            fileSize: UInt64(locator.sourceByteSize),
                            modificationTime: nil
                        )
                    )
                ))
            }
            guard !decodedLines.isEmpty else { continue }

            let turns = CodexConversationAssembler.assemble(
                metadata: metadata, decodedLines: decodedLines
            )
            for step in turns.flatMap(\.steps) {
                guard let offset = step.rawJSONLocator?.byteOffset else { continue }
                let key = "\(offset):\(step.kind.rawValue)"
                if assembledByLineKind[key] == nil {
                    assembledByLineKind[key] = step
                }
            }
        }
        guard !assembledByLineKind.isEmpty else { return [:] }

        var payloads: [String: (inputJSON: String?, result: ToolResultInfo?)] = [:]
        for row in toolRows {
            guard let offset = locatorByUuid[row.uuid]?.byteOffset,
                  let step = assembledByLineKind["\(offset):\(row.kind)"]
            else { continue }
            payloads[row.uuid] = (
                inputJSON: step.toolCalls.first?.inputJSON,
                result: step.toolResult
            )
        }
        return payloads
    }

    // MARK: - Sidebar content search (4.3)

    /// Distinct sessions whose indexed prompts match `query` — one FTS
    /// probe per sidebar filter pass. Metadata-only sessions are not in
    /// the FTS yet; they stay findable through the shell fields
    /// (title / slug / project) the filter checks first.
    func sessionIdsMatchingPrompts(_ query: String, limit: Int = 2_000) -> Set<String> {
        Set((try? store.searchSessionIds(matching: query, limit: limit)) ?? [])
    }

    // MARK: - Raw-line locators (4.2)

    /// Detail tabs (Raw / Usage / inline images) read original bytes
    /// through `step.rawJSONLocator` — attach it from the DB locator so
    /// `AppStateStore.rawJSON(for:)` resolves without the legacy
    /// project-path scan (which SQLite mode cannot serve).
    private func attachLocator(to step: Step, using locatorByUuid: [String: StoreTurnLineLocator]) -> Step {
        guard step.rawJSONLocator == nil,
              let locator = locatorByUuid[step.uuid],
              let byteOffset = locator.byteOffset
        else { return step }
        // Fingerprint carries size only: DATETIME storage truncates
        // sub-millisecond mtime, so an equality check would reject every
        // read. Size still guards offset validity (appends keep old
        // offsets valid); rewrites demote the source at the next scan
        // and re-import replaces these locators.
        let payloadLocator = RawPayloadLocator(
            provider: provider,
            kind: .stepLine,
            sourceURL: URL(fileURLWithPath: locator.sourcePath),
            byteOffset: UInt64(byteOffset),
            lineOrdinal: nil,
            lineByteCount: locator.byteLength.map(Int.init),
            fingerprint: RawPayloadLocator.SourceFingerprint(
                fileSize: UInt64(locator.sourceByteSize),
                modificationTime: nil
            )
        )
        return Step(
            uuid: step.uuid,
            parentUuid: step.parentUuid,
            sessionId: step.sessionId,
            timestamp: step.timestamp,
            kind: step.kind,
            isSystemInjected: step.isSystemInjected,
            isSidechain: step.isSidechain,
            agentId: step.agentId,
            isCompactSummary: step.isCompactSummary,
            text: step.text,
            thinkingText: step.thinkingText,
            images: step.images,
            imageSourcePaths: step.imageSourcePaths,
            mentionedFilePaths: step.mentionedFilePaths,
            attachments: step.attachments,
            toolCalls: step.toolCalls,
            toolResult: step.toolResult,
            requestId: step.requestId,
            requestIds: step.requestIds,
            messageId: step.messageId,
            model: step.model,
            speed: step.speed,
            stopReason: step.stopReason,
            stopReasonKind: step.stopReasonKind,
            tokens: step.tokens,
            cost: step.cost,
            rawJSON: step.rawJSON,
            rawJSONLocator: payloadLocator
        )
    }

    // MARK: - Mapping

    private static func headerStub(for row: StoreTurnRow, agentId: String?) -> Turn {
        // Assembler invariant preserved: `Turn.id == promptStep.uuid` for
        // non-orphan turns — selection identity keys and the compact-badge
        // renderer rely on it.
        let prompt = Step(
            uuid: row.id,
            parentUuid: nil,
            sessionId: row.sessionId,
            timestamp: row.startTime ?? .distantPast,
            kind: .prompt,
            isSidechain: row.sidechainOnly,
            agentId: agentId,
            isCompactSummary: row.promptPreview == TurnPreview.compactResumeLabel,
            text: row.promptPreview
        )
        return Turn(
            id: row.id,
            sessionId: row.sessionId,
            steps: [prompt],
            isInterrupted: row.interrupted
        )
    }

    private static func link(from row: StoreSubagentLinkRow) -> SubAgentLinker.Link {
        SubAgentLinker.Link(
            linkKind: SubAgentLinker.LinkKind(rawValue: row.linkKind) ?? .agent,
            agentId: row.agentId,
            parentToolUseId: row.parentToolUseId,
            parentAssistantUuid: row.parentAssistantUuid,
            parentMessageId: row.parentMessageId,
            description: row.linkDescription,
            subagentType: row.subagentType,
            timestamp: row.timestamp,
            workflowTaskId: row.workflowTaskId,
            workflowRunId: row.workflowRunId,
            workflowName: row.workflowName,
            workflowPhaseTitle: row.workflowPhaseTitle,
            workflowLabel: row.workflowLabel,
            workflowStatus: row.workflowStatus,
            workflowModel: row.workflowModel,
            workflowAgentState: row.workflowAgentState,
            workflowTelemetryTokens: row.workflowTelemetryTokens,
            workflowToolCalls: row.workflowToolCalls,
            workflowDurationMs: row.workflowDurationMs
        )
    }
}
