//
//  StoreRepositories.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Read/write contracts over the provider index database. Interfaces use
/// `StoreDTO` value types only; GRDB never crosses these boundaries.
/// All reads take explicit limits and stable cursors (plan Safety Rules).

protocol SessionListRepository: Sendable {
    /// Sessions ordered by (end_time DESC, id DESC), keyset-paged.
    func sessionPage(
        visibleOnly: Bool,
        projectPath: String?,
        limit: Int,
        cursor: StoreSessionPageCursor?
    ) throws -> StoreSessionPage

    func session(id: String) throws -> StoreSessionRow?
}

protocol ConversationRepository: Sendable {
    /// Top-level turn rows ordered by ordinal, paged by `afterOrdinal`.
    func turnPage(sessionId: String, limit: Int, afterOrdinal: Int?) throws -> [StoreTurnRow]

    /// All steps of one turn (loaded on expand).
    func steps(sessionId: String, turnId: String) throws -> [StoreStepRow]

    func subagentLinks(sessionId: String) throws -> [StoreSubagentLinkRow]

    /// Raw-line locators for one turn's scoped re-decode (4.1): the
    /// turn's step lines plus their direct child lines that produced no
    /// step row (meta entries the assembler merges into prompt steps).
    func turnLineLocators(sessionId: String, turnId: String) throws -> [StoreTurnLineLocator]

    /// Parent links restricted to the given line uuids — feeds
    /// `ConversationAssembler.registerParentLinks` for a scoped rebuild.
    func parentLinks(sessionId: String, uuids: [String]) throws -> [StoreParentLinkRow]

    /// `agentId` per sidechain-only turn (first non-null step agent_id) —
    /// the graft join key when steps are not materialized.
    func sidechainAgentIds(sessionId: String) throws -> [String: String]

    /// turn id per step uuid — resolves a subagent link's
    /// `parentAssistantUuid` to the turn its graft node belongs under.
    func stepTurnIds(sessionId: String, uuids: [String]) throws -> [String: String]
}

protocol DetailRepository: Sendable {
    func request(id: String) throws -> StoreRequestRow?
    func rawLocator(sessionId: String, ownerKind: String, ownerId: String) throws -> StoreRawLocatorRow?
}

protocol SearchRepository: Sendable {
    /// FTS5 match over indexed content; coverage tells the caller how
    /// honest the result is (plan §4).
    func search(matching query: String, limit: Int) throws -> [StoreSearchHit]

    /// Distinct sessions whose indexed prompts match the user's free
    /// text (4.3 sidebar content search). The query is sanitized into
    /// prefix-quoted FTS terms — raw FTS5 syntax is not interpreted.
    func searchSessionIds(matching query: String, limit: Int) throws -> [String]
    func coverage() throws -> StoreCoverage
}

protocol ReportsRepository: Sendable {
    func totalCostUSD(from: Date?, to: Date?) throws -> Double
    func costByModel(from: Date?, to: Date?) throws -> [StoreModelAggregate]

    /// Usage totals over billable requests in a range — the menu bar's
    /// today cost/tokens query (plan 3.3). Synthetic and model-less
    /// rows are excluded, matching the legacy aggregate filters.
    func usageTotals(from: Date?, to: Date?) throws -> StoreUsageTotals

    // 4.4 Reports surfaces. All range filters apply to request
    // timestamps (project/model) or turn start times (skills), and all
    // exclude synthetic/model-less rows — legacy aggregate parity.
    func projectAggregates(from: Date?, to: Date?) throws -> [StoreProjectAggregate]
    func projectModelCosts(from: Date?, to: Date?) throws -> [StoreGroupedModelCost]
    func modelUsageAggregates(from: Date?, to: Date?) throws -> [StoreModelUsageAggregate]
    /// Request activity bucketed in LOCAL time (`hourly` picks the
    /// granularity) — cost, request count and total-context tokens.
    func usageBuckets(hourly: Bool, from: Date?, to: Date?) throws -> [StoreUsageBucket]
    /// Sessions / turns bucketed by their start time (local).
    func sessionStartCounts(hourly: Bool, from: Date?, to: Date?) throws -> [StoreBucketCount]
    func turnStartCounts(hourly: Bool, from: Date?, to: Date?) throws -> [StoreBucketCount]
    /// Skill invocations (turns) and bare per-turn request cost — the
    /// skills table is populated at import (4.4).
    func skillAggregates(from: Date?, to: Date?) throws -> [StoreSkillAggregate]
    func skillModelCosts(from: Date?, to: Date?) throws -> [StoreGroupedModelCost]
    /// Flat billable (timestamp, cost) points for the hourly chart.
    func requestCostPoints(from: Date?, to: Date?) throws -> [StoreRequestCostPoint]
}

protocol DiagnosticsRepository: Sendable {
    func severityCounts() throws -> StoreSeverityCounts
}

protocol VerificationRepository: Sendable {
    /// Per-session usage sums for comparison against ground truth.
    func sessionUsageAggregates() throws -> [StoreSessionUsageAggregate]

    /// Request ids of one session — picked-request-id coverage in the
    /// VerifyCosts SQLite leg (4.5).
    func requestIds(sessionId: String) throws -> [String]
}

protocol ImportWriting: Sendable {
    /// Registers (or refreshes) a discovered source and returns its id.
    /// Existing row for the same path keeps its id; metadata columns and
    /// fingerprint are updated.
    @discardableResult
    func upsertSourceFile(_ source: StoreSourceFile) throws -> Int64

    /// Batch variant of `upsertSourceFile` — one transaction for a whole
    /// metadata-scan pass instead of one WAL commit per file.
    func upsertSourceFiles(_ sources: [StoreSourceFile]) throws

    /// Every registered source. The metadata scanner diffs this against
    /// the filesystem (fingerprint skip + vanished-source pruning);
    /// per-provider databases keep the table small enough for a full read.
    func allSourceFiles() throws -> [StoreSourceFile]

    /// Deletes source rows by path, cascading every row they own.
    /// Called for sources whose file vanished from disk.
    func deleteSources(paths: [String]) throws

    /// Upserts session shells written by detail imports. Detail columns
    /// (titles, first prompt) only widen: non-nil incoming values
    /// overwrite, nil leaves existing data.
    func upsertSessionShells(_ sessions: [StoreSessionRow]) throws

    /// Weakest-writer shell upsert for the metadata scan: identity/title
    /// columns fill only where currently NULL, so a seed can never
    /// overwrite what a detail import derived; times widen; `visible`
    /// and `detail_state` are left untouched on conflict.
    func seedSessionShells(_ sessions: [StoreSessionRow]) throws

    /// Applies index-derived visibility/title facts on top of seeded
    /// shells (Codex `session_index.jsonl`). Runs on every scan so
    /// index-only edits — thread renamed, hidden, deleted — propagate
    /// without any rollout file changing.
    func applySessionVisibility(_ updates: [StoreSessionVisibilityUpdate]) throws

    /// Deletes session shells that no source claims (by raw id) and no
    /// detail rows (requests/turns) reference — i.e. every file that fed
    /// the session is gone. Returns the number of pruned shells.
    @discardableResult
    func pruneSessionsWithoutSources() throws -> Int

    /// Provenance-guarded source replacement with bounded write
    /// transactions (plan §2 mechanics): deletes the source row —
    /// cascading every row it owns — re-inserts it as `incomplete`,
    /// writes payload rows in batches of at most `batchRowLimit` rows
    /// per transaction with `isCancelled` checked at every batch
    /// boundary, then marks the source `imported`. Returns false when
    /// cancelled: the source stays `incomplete` with partial rows that
    /// the next replacement deletes by provenance — restart from byte 0
    /// is idempotent (G13, no mid-file checkpoints).
    @discardableResult
    func replaceSource(
        _ source: StoreSourceFile,
        payload: StoreSourcePayload,
        batchRowLimit: Int,
        isCancelled: () -> Bool
    ) throws -> Bool

    func setSourceParseState(path: String, state: StoreParseState) throws

    func sourceFile(path: String) throws -> StoreSourceFile?

    /// Every request row of one session, ordered by (timestamp, id) —
    /// the input of the cost finalize pass (long-context detection is
    /// session-scoped).
    func requests(inSession sessionId: String) throws -> [StoreRequestRow]

    /// Writes finalized cost columns in one transaction.
    func applyRequestCostFinalization(_ updates: [StoreRequestCostUpdate]) throws

    /// Sessions whose request rows were finalized against a different
    /// pricing-table revision (or never finalized) — the background
    /// recompute work list after a `PricingTable.version` bump.
    func sessionIdsWithStaleCosts(pricingVersion: Int) throws -> [String]

    /// Sources modified at/after `date` that still await import
    /// (pending/metadata/incomplete). Zero ⇒ the range's numbers are
    /// complete — the menu bar drops its coverage placeholder (3.3).
    /// `failed` sources are excluded: they will never import, and an
    /// eternal placeholder would be the wrong kind of honest.
    func pendingSourceCount(modifiedSince date: Date) throws -> Int

    /// Rewrites a session's turn ordinals to the display order
    /// (start_time, id — mirrors the legacy `turnSort`). The streaming
    /// group importer writes turns in piece-processing order because
    /// cross-piece time interleaving is unknowable mid-stream (3.8a).
    func renumberTurnOrdinals(sessionId: String) throws

    /// Applies linked-subagent contributions onto parent turn rows at
    /// unit completion (3.8a) — additive token/cost deltas plus the
    /// final completeness verdict (Rule 6).
    func applyTurnAggregateAdjustments(_ adjustments: [StoreTurnAggregateAdjustment]) throws
}

extension ImportWriting {
    /// Single-shot replacement: one effective transaction, no
    /// cancellation. Convenience for tests and small payloads.
    func replaceSource(_ source: StoreSourceFile, payload: StoreSourcePayload) throws {
        _ = try replaceSource(
            source, payload: payload, batchRowLimit: Int.max, isCancelled: { false }
        )
    }
}
