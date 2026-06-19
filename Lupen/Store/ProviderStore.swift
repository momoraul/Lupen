//
//  ProviderStore.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation
import GRDB

/// GRDB-backed implementation of every repository contract over one
/// provider's index database. The only type that touches GRDB rows; the
/// interfaces above it speak `StoreDTO` values exclusively.
final class ProviderStore: Sendable {
    let database: ProviderDatabase

    init(database: ProviderDatabase) {
        self.database = database
    }

    /// Sort sentinel for sessions without an end time — keyset pagination
    /// needs a total order, and SQLite row-value comparison cannot mix
    /// NULL into it. Predates every real timestamp. Shared with the
    /// schema: the sidebar page index is built on `COALESCE(end_time,
    /// sentinel)` and only matches query text embedding the same literal.
    private static let nullDateSentinel = ProviderDatabaseSchema.nullDateSentinel
}

// MARK: - SessionListRepository

extension ProviderStore: SessionListRepository {
    func sessionPage(
        visibleOnly: Bool,
        projectPath: String?,
        limit: Int,
        cursor: StoreSessionPageCursor?
    ) throws -> StoreSessionPage {
        try database.pool.read { db in
            var conditions: [String] = []
            var arguments: [DatabaseValueConvertible?] = []

            if visibleOnly {
                conditions.append("visible = 1")
                // Redundant compact-continuation snapshots collapse into
                // their canonical leaf — never list them.
                conditions.append("superseded_by IS NULL")
            }
            if let projectPath {
                conditions.append("project_path = ?")
                arguments.append(projectPath)
            }
            if let cursor {
                let cursorEnd: DatabaseValueConvertible = (cursor.endTime as DatabaseValueConvertible?) ?? Self.nullDateSentinel
                // Sentinel interpolated, not bound: a parameter inside
                // COALESCE would defeat the expression-index match.
                conditions.append("(COALESCE(end_time, '\(Self.nullDateSentinel)'), id) < (?, ?)")
                arguments.append(cursorEnd)
                arguments.append(cursor.id)
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT * FROM sessions
                \(whereClause)
                ORDER BY COALESCE(end_time, '\(Self.nullDateSentinel)') DESC, id DESC
                LIMIT ?
                """
            arguments.append(limit + 1)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let mapped = rows.prefix(limit).map(Self.sessionRow(from:))
            let nextCursor: StoreSessionPageCursor? = rows.count > limit
                ? mapped.last.map { StoreSessionPageCursor(endTime: $0.endTime, id: $0.id) }
                : nil
            return StoreSessionPage(rows: Array(mapped), nextCursor: nextCursor)
        }
    }

    func session(id: String) throws -> StoreSessionRow? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])
                .map(Self.sessionRow(from:))
        }
    }

    private static func sessionRow(from row: Row) -> StoreSessionRow {
        StoreSessionRow(
            id: row["id"],
            rawId: row["raw_id"],
            projectPath: row["project_path"],
            slug: row["slug"],
            startTime: row["start_time"],
            endTime: row["end_time"],
            cachedTitle: row["cached_title"],
            customTitle: row["custom_title"],
            firstPrompt: row["first_prompt"],
            lastGitBranch: row["last_git_branch"],
            visible: row["visible"],
            detailState: StoreDetailState(rawValue: row["detail_state"]) ?? .metadata,
            logicalParentUuid: row["logical_parent_uuid"]
        )
    }
}

// MARK: - ConversationRepository

extension ProviderStore: ConversationRepository {
    func turnPage(sessionId: String, limit: Int, afterOrdinal: Int?) throws -> [StoreTurnRow] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM turns
                    WHERE session_id = ? AND ordinal > ?
                    ORDER BY ordinal ASC
                    LIMIT ?
                    """,
                arguments: [sessionId, afterOrdinal ?? -1, limit]
            ).map(Self.turnRow(from:))
        }
    }

    /// Plan 5.3: menu-bar dropdown rows — recent turns across visible
    /// sessions, newest first, sidechain-only turns excluded.
    func recentTurns(since: Date, limit: Int) throws -> [StoreTurnRow] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT turns.* FROM turns
                    JOIN sessions ON sessions.id = turns.session_id
                    WHERE sessions.visible = 1
                      AND turns.sidechain_only = 0
                      AND COALESCE(turns.end_time, turns.start_time) >= ?
                    ORDER BY COALESCE(turns.end_time, turns.start_time) DESC
                    LIMIT ?
                    """,
                arguments: [since, limit]
            ).map(Self.turnRow(from:))
        }
    }

    private static func turnRow(from row: Row) -> StoreTurnRow {
        StoreTurnRow(
            sessionId: row["session_id"],
            id: row["id"],
            ordinal: row["ordinal"],
            startTime: row["start_time"],
            endTime: row["end_time"],
            promptPreview: row["prompt_preview"],
            stepCount: row["step_count"],
            interrupted: row["interrupted"],
            sidechainOnly: row["sidechain_only"],
            aggTokens: TokenBreakdown(
                inputTokens: row["agg_input_tokens"],
                outputTokens: row["agg_output_tokens"],
                reasoningOutputTokens: row["agg_reasoning_tokens"],
                cacheCreationInputTokens: row["agg_cache_creation_tokens"],
                cacheReadInputTokens: row["agg_cache_read_tokens"],
                cacheCreationEphemeral1h: row["agg_cache_eph_1h_tokens"],
                cacheCreationEphemeral5m: row["agg_cache_eph_5m_tokens"],
                contextWindow: row["agg_context_window"]
            ),
            aggCost: CostBreakdown(
                inputCostUSD: row["agg_cost_input_usd"],
                outputCostUSD: row["agg_cost_output_usd"],
                cacheCreate1hCostUSD: row["agg_cost_cache_1h_usd"],
                cacheCreate5mCostUSD: row["agg_cost_cache_5m_usd"],
                cacheReadCostUSD: row["agg_cost_cache_read_usd"]
            ),
            aggModels: (row["agg_models"] as String?)
                .map { $0.split(separator: ",").map(String.init) } ?? [],
            aggComplete: row["agg_complete"]
        )
    }

    func steps(sessionId: String, turnId: String) throws -> [StoreStepRow] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM steps
                    WHERE session_id = ? AND turn_id = ?
                    ORDER BY ordinal ASC
                    """,
                arguments: [sessionId, turnId]
            ).map { row in
                StoreStepRow(
                    sessionId: row["session_id"],
                    turnId: row["turn_id"],
                    uuid: row["uuid"],
                    ordinal: row["ordinal"],
                    kind: row["kind"],
                    timestamp: row["timestamp"],
                    model: row["model"],
                    requestId: row["request_id"],
                    agentId: row["agent_id"],
                    text: row["text"],
                    thinkingText: row["thinking_text"],
                    toolName: row["tool_name"],
                    toolUseId: row["tool_use_id"]
                )
            }
        }
    }

    func subagentLinks(sessionId: String) throws -> [StoreSubagentLinkRow] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM subagent_links WHERE session_id = ? ORDER BY parent_tool_use_id",
                arguments: [sessionId]
            ).map { row in
                StoreSubagentLinkRow(
                    sessionId: row["session_id"],
                    linkKind: row["link_kind"],
                    agentId: row["agent_id"],
                    parentToolUseId: row["parent_tool_use_id"],
                    parentAssistantUuid: row["parent_assistant_uuid"],
                    parentMessageId: row["parent_message_id"],
                    linkDescription: row["link_description"],
                    subagentType: row["subagent_type"],
                    timestamp: row["timestamp"],
                    workflowTaskId: row["workflow_task_id"],
                    workflowRunId: row["workflow_run_id"],
                    workflowName: row["workflow_name"],
                    workflowPhaseTitle: row["workflow_phase_title"],
                    workflowLabel: row["workflow_label"],
                    workflowStatus: row["workflow_status"],
                    workflowModel: row["workflow_model"],
                    workflowAgentState: row["workflow_agent_state"],
                    workflowTelemetryTokens: row["workflow_telemetry_tokens"],
                    workflowToolCalls: row["workflow_tool_calls"],
                    workflowDurationMs: row["workflow_duration_ms"]
                )
            }
        }
    }

    func turnLineLocators(sessionId: String, turnId: String) throws -> [StoreTurnLineLocator] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT l.owner_id AS uuid, s.ordinal AS step_ordinal, f.path AS source_path,
                           l.byte_offset, l.byte_length, f.byte_size, f.modified_at
                    FROM steps s
                    JOIN raw_locators l
                      ON l.session_id = s.session_id
                     AND l.owner_kind = 'stepLine'
                     AND l.owner_id = s.uuid
                    JOIN source_files f ON f.id = l.source_file_id
                    WHERE s.session_id = ?1 AND s.turn_id = ?2
                    UNION ALL
                    SELECT l.owner_id, NULL, f.path, l.byte_offset, l.byte_length,
                           f.byte_size, f.modified_at
                    FROM parent_links p
                    JOIN raw_locators l
                      ON l.session_id = p.session_id
                     AND l.owner_kind = 'stepLine'
                     AND l.owner_id = p.uuid
                    JOIN source_files f ON f.id = l.source_file_id
                    WHERE p.session_id = ?1
                      AND p.parent_uuid IN (SELECT uuid FROM steps WHERE session_id = ?1 AND turn_id = ?2)
                      AND NOT EXISTS (
                          SELECT 1 FROM steps s2
                          WHERE s2.session_id = p.session_id AND s2.uuid = p.uuid
                      )
                    """,
                arguments: [sessionId, turnId]
            ).map { row in
                StoreTurnLineLocator(
                    uuid: row["uuid"],
                    stepOrdinal: row["step_ordinal"],
                    sourcePath: row["source_path"],
                    byteOffset: row["byte_offset"],
                    byteLength: row["byte_length"],
                    sourceByteSize: row["byte_size"],
                    sourceModifiedAt: row["modified_at"]
                )
            }
        }
    }

    func parentLinks(sessionId: String, uuids: [String]) throws -> [StoreParentLinkRow] {
        guard !uuids.isEmpty else { return [] }
        return try database.pool.read { db in
            let placeholders = databaseQuestionMarks(count: uuids.count)
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT session_id, uuid, parent_uuid FROM parent_links
                    WHERE session_id = ? AND uuid IN (\(placeholders))
                    """,
                arguments: StatementArguments([sessionId] + uuids)
            ).map { row in
                StoreParentLinkRow(
                    sessionId: row["session_id"],
                    uuid: row["uuid"],
                    parentUuid: row["parent_uuid"]
                )
            }
        }
    }

    func stepTurnIds(sessionId: String, uuids: [String]) throws -> [String: String] {
        guard !uuids.isEmpty else { return [:] }
        return try database.pool.read { db in
            let placeholders = databaseQuestionMarks(count: uuids.count)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT uuid, turn_id FROM steps
                    WHERE session_id = ? AND uuid IN (\(placeholders))
                    """,
                arguments: StatementArguments([sessionId] + uuids)
            )
            var byUuid: [String: String] = [:]
            for row in rows {
                byUuid[row["uuid"]] = row["turn_id"]
            }
            return byUuid
        }
    }

    func sidechainAgentIds(sessionId: String) throws -> [String: String] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id AS turn_id,
                           (SELECT s.agent_id FROM steps s
                             WHERE s.session_id = t.session_id
                               AND s.turn_id = t.id
                               AND s.agent_id IS NOT NULL
                             ORDER BY s.ordinal ASC LIMIT 1) AS agent_id
                    FROM turns t
                    WHERE t.session_id = ? AND t.sidechain_only = 1
                    """,
                arguments: [sessionId]
            )
            var byTurnId: [String: String] = [:]
            for row in rows {
                if let agentId = row["agent_id"] as String? {
                    byTurnId[row["turn_id"]] = agentId
                }
            }
            return byTurnId
        }
    }
}

// MARK: - DetailRepository

extension ProviderStore: DetailRepository {
    func request(id: String) throws -> StoreRequestRow? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM requests WHERE id = ?", arguments: [id])
                .map(Self.requestRow(from:))
        }
    }

    func rawLocator(sessionId: String, ownerKind: String, ownerId: String) throws -> StoreRawLocatorRow? {
        try database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM raw_locators
                    WHERE session_id = ? AND owner_kind = ? AND owner_id = ?
                    """,
                arguments: [sessionId, ownerKind, ownerId]
            ).map { row in
                StoreRawLocatorRow(
                    sessionId: row["session_id"],
                    ownerKind: row["owner_kind"],
                    ownerId: row["owner_id"],
                    byteOffset: row["byte_offset"],
                    byteLength: row["byte_length"],
                    lineNumber: row["line_number"]
                )
            }
        }
    }

    private static func requestRow(from row: Row) -> StoreRequestRow {
        StoreRequestRow(
            id: row["id"],
            sessionId: row["session_id"],
            timestamp: row["timestamp"],
            model: row["model"],
            messageId: row["message_id"],
            parentUuid: row["parent_uuid"],
            isSidechain: row["is_sidechain"],
            speed: row["speed"],
            stopReason: row["stop_reason"],
            inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"],
            reasoningOutputTokens: row["reasoning_output_tokens"],
            cacheCreationInputTokens: row["cache_creation_input_tokens"],
            cacheReadInputTokens: row["cache_read_input_tokens"],
            cacheCreationEphemeral1h: row["cache_creation_ephemeral_1h"],
            cacheCreationEphemeral5m: row["cache_creation_ephemeral_5m"],
            provisionalCostUSD: row["provisional_cost_usd"],
            finalCostUSD: row["final_cost_usd"],
            pricingVersion: row["pricing_version"],
            costConfidence: row["cost_confidence"]
        )
    }
}

// MARK: - SearchRepository

extension ProviderStore: SearchRepository {
    func search(matching query: String, limit: Int) throws -> [StoreSearchHit] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT session_id, turn_id, step_uuid, kind,
                           snippet(search_fts, 4, '[', ']', '…', 8) AS snippet
                    FROM search_fts
                    WHERE search_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [query, limit]
            ).map { row in
                StoreSearchHit(
                    sessionId: row["session_id"],
                    turnId: row["turn_id"],
                    stepUuid: row["step_uuid"],
                    kind: row["kind"],
                    snippet: row["snippet"]
                )
            }
        }
    }

    func searchSessionIds(matching query: String, limit: Int) throws -> [String] {
        guard let match = Self.ftsPrefixQuery(from: query) else { return [] }
        return try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT session_id FROM search_fts
                    WHERE search_fts MATCH ?
                    LIMIT ?
                    """,
                arguments: [match, limit]
            )
        }
    }

    /// Free text → FTS5 term query: every whitespace token becomes a
    /// quoted prefix term (`"foo"* "bar"*`), so user input can never be
    /// misread as FTS syntax (quotes, NEAR, column filters…).
    static func ftsPrefixQuery(from raw: String) -> String? {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    func coverage() throws -> StoreCoverage {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT parse_state, COUNT(*) AS n FROM source_files GROUP BY parse_state"
            )
            var counts: [String: Int] = [:]
            for row in rows {
                counts[row["parse_state"]] = row["n"]
            }
            let imported = counts[StoreParseState.imported.rawValue] ?? 0
            let incomplete = counts[StoreParseState.incomplete.rawValue] ?? 0
            let failed = counts[StoreParseState.failed.rawValue] ?? 0
            let pending = (counts[StoreParseState.pending.rawValue] ?? 0)
                + (counts[StoreParseState.metadata.rawValue] ?? 0)
            return StoreCoverage(
                totalSources: counts.values.reduce(0, +),
                importedSources: imported,
                incompleteSources: incomplete,
                pendingSources: pending,
                failedSources: failed
            )
        }
    }
}

// MARK: - ReportsRepository

extension ProviderStore: ReportsRepository {
    func totalCostUSD(from: Date?, to: Date?) throws -> Double {
        try database.pool.read { db in
            try Double.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(COALESCE(final_cost_usd, provisional_cost_usd, 0)), 0)
                    FROM requests
                    WHERE (? IS NULL OR timestamp >= ?) AND (? IS NULL OR timestamp <= ?)
                    """,
                arguments: [from, from, to, to]
            ) ?? 0
        }
    }

    func usageTotals(from: Date?, to: Date?) throws -> StoreUsageTotals {
        try database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS request_count,
                           COALESCE(SUM(input_tokens), 0) AS input_tokens,
                           COALESCE(SUM(output_tokens), 0) AS output_tokens,
                           COALESCE(SUM(reasoning_output_tokens), 0) AS reasoning_output_tokens,
                           COALESCE(SUM(cache_creation_input_tokens), 0) AS cache_creation_input_tokens,
                           COALESCE(SUM(cache_read_input_tokens), 0) AS cache_read_input_tokens,
                           COALESCE(SUM(COALESCE(final_cost_usd, provisional_cost_usd, 0)), 0) AS cost_usd
                    FROM requests
                    WHERE model IS NOT NULL AND model != '<synthetic>'
                      AND (? IS NULL OR timestamp >= ?) AND (? IS NULL OR timestamp <= ?)
                    """,
                arguments: [from, from, to, to]
            )
            guard let row else {
                return StoreUsageTotals(
                    requestCount: 0, inputTokens: 0, outputTokens: 0,
                    reasoningOutputTokens: 0, cacheCreationInputTokens: 0,
                    cacheReadInputTokens: 0, costUSD: 0
                )
            }
            return StoreUsageTotals(
                requestCount: row["request_count"],
                inputTokens: row["input_tokens"],
                outputTokens: row["output_tokens"],
                reasoningOutputTokens: row["reasoning_output_tokens"],
                cacheCreationInputTokens: row["cache_creation_input_tokens"],
                cacheReadInputTokens: row["cache_read_input_tokens"],
                costUSD: row["cost_usd"]
            )
        }
    }

    func projectAggregates(from: Date?, to: Date?) throws -> [StoreProjectAggregate] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT s.project_path AS project_path,
                           COUNT(DISTINCT r.session_id) AS session_count,
                           COALESCE(SUM(COALESCE(r.final_cost_usd, r.provisional_cost_usd, 0)), 0) AS cost_usd
                    FROM requests r
                    JOIN sessions s ON s.id = r.session_id
                    WHERE r.model IS NOT NULL AND r.model != '<synthetic>'
                      AND (? IS NULL OR r.timestamp >= ?) AND (? IS NULL OR r.timestamp <= ?)
                    GROUP BY s.project_path
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreProjectAggregate(
                    projectPath: row["project_path"],
                    sessionCount: row["session_count"],
                    costUSD: row["cost_usd"]
                )
            }
        }
    }

    func projectModelCosts(from: Date?, to: Date?) throws -> [StoreGroupedModelCost] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT COALESCE(s.project_path, '') AS group_key, r.model AS model,
                           COALESCE(SUM(COALESCE(r.final_cost_usd, r.provisional_cost_usd, 0)), 0) AS cost_usd
                    FROM requests r
                    JOIN sessions s ON s.id = r.session_id
                    WHERE r.model IS NOT NULL AND r.model != '<synthetic>'
                      AND (? IS NULL OR r.timestamp >= ?) AND (? IS NULL OR r.timestamp <= ?)
                    GROUP BY group_key, r.model
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreGroupedModelCost(
                    groupKey: row["group_key"], model: row["model"], costUSD: row["cost_usd"]
                )
            }
        }
    }

    func modelUsageAggregates(from: Date?, to: Date?) throws -> [StoreModelUsageAggregate] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT model,
                           COUNT(*) AS usage_count,
                           COALESCE(SUM(COALESCE(final_cost_usd, provisional_cost_usd, 0)), 0) AS cost_usd,
                           COALESCE(SUM(CASE WHEN speed = 'fast' THEN 1 ELSE 0 END), 0) AS fast_count
                    FROM requests
                    WHERE model IS NOT NULL AND model != '<synthetic>'
                      AND (? IS NULL OR timestamp >= ?) AND (? IS NULL OR timestamp <= ?)
                    GROUP BY model
                    ORDER BY cost_usd DESC
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreModelUsageAggregate(
                    model: row["model"],
                    usageCount: row["usage_count"],
                    costUSD: row["cost_usd"],
                    fastCount: row["fast_count"]
                )
            }
        }
    }

    private static func bucketExpr(_ column: String, hourly: Bool) -> String {
        hourly
            ? "strftime('%Y-%m-%d %H:00:00', \(column), 'localtime')"
            : "date(\(column), 'localtime')"
    }

    func usageBuckets(hourly: Bool, from: Date?, to: Date?) throws -> [StoreUsageBucket] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.bucketExpr("timestamp", hourly: hourly)) AS bucket_key,
                           COALESCE(SUM(COALESCE(final_cost_usd, provisional_cost_usd, 0)), 0) AS cost_usd,
                           COUNT(*) AS request_count,
                           COALESCE(SUM(input_tokens + output_tokens
                               + cache_creation_input_tokens + cache_read_input_tokens), 0) AS token_count
                    FROM requests
                    WHERE model IS NOT NULL AND model != '<synthetic>'
                      AND (? IS NULL OR timestamp >= ?) AND (? IS NULL OR timestamp <= ?)
                    GROUP BY bucket_key
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreUsageBucket(
                    bucketKey: row["bucket_key"],
                    costUSD: row["cost_usd"],
                    requestCount: row["request_count"],
                    tokenCount: row["token_count"]
                )
            }
        }
    }

    /// Plan 5.3: Reports footer counters — requests + distinct sessions
    /// with request activity inside the bounds (synthetic/model-less
    /// rows excluded, matching the legacy footer), plus turns started
    /// inside the bounds.
    func requestActivityCounts(
        from: Date?, to: Date?
    ) throws -> (requestCount: Int, sessionCount: Int, turnCount: Int) {
        try database.pool.read { db in
            let requestRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS n, COUNT(DISTINCT session_id) AS s
                    FROM requests
                    WHERE model IS NOT NULL AND model != '<synthetic>'
                      AND (? IS NULL OR timestamp >= ?) AND (? IS NULL OR timestamp <= ?)
                    """,
                arguments: [from, from, to, to]
            )
            let turnCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM turns
                    WHERE start_time IS NOT NULL
                      AND (? IS NULL OR start_time >= ?) AND (? IS NULL OR start_time <= ?)
                    """,
                arguments: [from, from, to, to]
            ) ?? 0
            return (requestRow?["n"] ?? 0, requestRow?["s"] ?? 0, turnCount)
        }
    }

    func sessionStartCounts(hourly: Bool, from: Date?, to: Date?) throws -> [StoreBucketCount] {
        try startCounts(table: "sessions", column: "start_time", hourly: hourly, from: from, to: to)
    }

    func turnStartCounts(hourly: Bool, from: Date?, to: Date?) throws -> [StoreBucketCount] {
        try startCounts(table: "turns", column: "start_time", hourly: hourly, from: from, to: to)
    }

    private func startCounts(
        table: String, column: String, hourly: Bool, from: Date?, to: Date?
    ) throws -> [StoreBucketCount] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.bucketExpr(column, hourly: hourly)) AS bucket_key,
                           COUNT(*) AS n
                    FROM \(table)
                    WHERE \(column) IS NOT NULL
                      AND (? IS NULL OR \(column) >= ?) AND (? IS NULL OR \(column) <= ?)
                    GROUP BY bucket_key
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreBucketCount(bucketKey: row["bucket_key"], count: row["n"])
            }
        }
    }

    /// Bridge: distinct (session, turn, request) triples via steps —
    /// requests carry no turn id; steps do. Shared by the skill queries.
    private static let turnRequestBridge = """
        (SELECT DISTINCT session_id, turn_id, request_id
           FROM steps WHERE request_id IS NOT NULL) br
        """

    func skillAggregates(from: Date?, to: Date?) throws -> [StoreSkillAggregate] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT sk.skill_name AS skill_name,
                           COUNT(DISTINCT sk.session_id || '|' || sk.turn_id) AS invocations,
                           COALESCE(SUM(COALESCE(r.final_cost_usd, r.provisional_cost_usd, 0)), 0) AS cost_usd
                    FROM skills sk
                    JOIN turns t ON t.session_id = sk.session_id AND t.id = sk.turn_id
                    LEFT JOIN \(Self.turnRequestBridge)
                      ON br.session_id = sk.session_id AND br.turn_id = sk.turn_id
                    LEFT JOIN requests r ON r.id = br.request_id
                    WHERE (? IS NULL OR t.start_time >= ?) AND (? IS NULL OR t.start_time <= ?)
                    GROUP BY sk.skill_name
                    ORDER BY cost_usd DESC
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreSkillAggregate(
                    skillName: row["skill_name"],
                    invocationCount: row["invocations"],
                    costUSD: row["cost_usd"]
                )
            }
        }
    }

    func skillModelCosts(from: Date?, to: Date?) throws -> [StoreGroupedModelCost] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT sk.skill_name AS group_key, r.model AS model,
                           COALESCE(SUM(COALESCE(r.final_cost_usd, r.provisional_cost_usd, 0)), 0) AS cost_usd
                    FROM skills sk
                    JOIN turns t ON t.session_id = sk.session_id AND t.id = sk.turn_id
                    JOIN \(Self.turnRequestBridge)
                      ON br.session_id = sk.session_id AND br.turn_id = sk.turn_id
                    JOIN requests r ON r.id = br.request_id
                    WHERE r.model IS NOT NULL AND r.model != '<synthetic>'
                      AND (? IS NULL OR t.start_time >= ?) AND (? IS NULL OR t.start_time <= ?)
                    GROUP BY group_key, r.model
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreGroupedModelCost(
                    groupKey: row["group_key"], model: row["model"], costUSD: row["cost_usd"]
                )
            }
        }
    }

    /// Highest-cost sessions over the range (for `lupen top`). Matches the
    /// sidebar's visibility rule (`visible = 1 AND superseded_by IS NULL`) so
    /// compact-continuation replay shells don't appear — their cost is
    /// re-homed to the canonical session anyway.
    func topSessionCosts(from: Date?, to: Date?, limit: Int) throws -> [StoreSessionCost] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT r.session_id AS session_id,
                           s.project_path AS project_path,
                           COALESCE(s.custom_title, s.cached_title, s.first_prompt) AS title,
                           COUNT(*) AS request_count,
                           COALESCE(SUM(COALESCE(r.final_cost_usd, r.provisional_cost_usd, 0)), 0) AS cost_usd
                    FROM requests r
                    JOIN sessions s ON s.id = r.session_id
                    WHERE r.model IS NOT NULL AND r.model != '<synthetic>'
                      AND s.visible = 1 AND s.superseded_by IS NULL
                      AND (? IS NULL OR r.timestamp >= ?) AND (? IS NULL OR r.timestamp <= ?)
                    GROUP BY r.session_id
                    ORDER BY cost_usd DESC, r.session_id
                    LIMIT ?
                    """,
                arguments: [from, from, to, to, limit]
            ).map { row in
                StoreSessionCost(
                    sessionId: row["session_id"],
                    projectPath: row["project_path"],
                    title: row["title"],
                    requestCount: row["request_count"],
                    costUSD: row["cost_usd"]
                )
            }
        }
    }

    /// Count of the distinct sessions `topSessionCosts` ranks from — visible,
    /// non-superseded sessions with billable activity in the window. Shares
    /// `topSessionCosts`'s predicate exactly so `top`'s "of N" footer matches
    /// its rows (superseded replay shells, whose cost is re-homed onto their
    /// canonical session, are excluded — counting them would inflate N above
    /// the rankable population).
    func visibleSessionCount(from: Date?, to: Date?) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT r.session_id)
                    FROM requests r
                    JOIN sessions s ON s.id = r.session_id
                    WHERE r.model IS NOT NULL AND r.model != '<synthetic>'
                      AND s.visible = 1 AND s.superseded_by IS NULL
                      AND (? IS NULL OR r.timestamp >= ?) AND (? IS NULL OR r.timestamp <= ?)
                    """,
                arguments: [from, from, to, to]
            ) ?? 0
        }
    }

    func requestCostPoints(from: Date?, to: Date?) throws -> [StoreRequestCostPoint] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT timestamp,
                           COALESCE(final_cost_usd, provisional_cost_usd, 0) AS cost_usd
                    FROM requests
                    WHERE model IS NOT NULL AND model != '<synthetic>'
                      AND (? IS NULL OR timestamp >= ?) AND (? IS NULL OR timestamp <= ?)
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreRequestCostPoint(timestamp: row["timestamp"], costUSD: row["cost_usd"])
            }
        }
    }

    func costByModel(from: Date?, to: Date?) throws -> [StoreModelAggregate] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT model,
                           COUNT(*) AS request_count,
                           SUM(input_tokens) AS input_tokens,
                           SUM(output_tokens) AS output_tokens,
                           COALESCE(SUM(COALESCE(final_cost_usd, provisional_cost_usd, 0)), 0) AS cost_usd
                    FROM requests
                    WHERE model IS NOT NULL
                      AND (? IS NULL OR timestamp >= ?) AND (? IS NULL OR timestamp <= ?)
                    GROUP BY model
                    ORDER BY cost_usd DESC
                    """,
                arguments: [from, from, to, to]
            ).map { row in
                StoreModelAggregate(
                    model: row["model"],
                    requestCount: row["request_count"],
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    costUSD: row["cost_usd"]
                )
            }
        }
    }
}

// MARK: - DiagnosticsRepository

extension ProviderStore: DiagnosticsRepository {
    /// Plan 5.3c: per-category counts for the Diagnostics window.
    func diagnosticCategoryCounts() throws -> [String: Int] {
        try database.pool.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT category, COUNT(*) AS n FROM diagnostics GROUP BY category"
            ) {
                counts[row["category"]] = row["n"]
            }
            return counts
        }
    }

    /// Plan 5.3c: newest persisted diagnostics for the sample list.
    func recentDiagnostics(limit: Int) throws -> [StoreDiagnosticRow] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM diagnostics ORDER BY id DESC LIMIT ?",
                arguments: [limit]
            ).map { row in
                StoreDiagnosticRow(
                    sessionId: row["session_id"],
                    severity: row["severity"],
                    category: row["category"],
                    lineNumber: row["line_number"],
                    byteOffset: row["byte_offset"],
                    preview: row["preview"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    /// Plan 5.3c: timestamp of the oldest persisted issue, nil if clean.
    func firstDiagnosticAt() throws -> Date? {
        try database.pool.read { db in
            try Date.fetchOne(db, sql: "SELECT MIN(created_at) FROM diagnostics")
        }
    }

    func severityCounts() throws -> StoreSeverityCounts {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT severity, COUNT(*) AS n FROM diagnostics GROUP BY severity"
            )
            var counts: [String: Int] = [:]
            for row in rows {
                counts[row["severity"]] = row["n"]
            }
            return StoreSeverityCounts(
                info: counts["info"] ?? 0,
                warning: counts["warning"] ?? 0,
                error: counts["error"] ?? 0
            )
        }
    }
}

// MARK: - VerificationRepository

extension ProviderStore: VerificationRepository {
    func sessionUsageAggregates() throws -> [StoreSessionUsageAggregate] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT session_id,
                           COUNT(*) AS request_count,
                           SUM(input_tokens) AS input_tokens,
                           SUM(output_tokens) AS output_tokens,
                           SUM(reasoning_output_tokens) AS reasoning_output_tokens,
                           SUM(cache_creation_input_tokens) AS cache_creation_input_tokens,
                           SUM(cache_read_input_tokens) AS cache_read_input_tokens,
                           SUM(cache_creation_ephemeral_1h) AS cache_creation_ephemeral_1h,
                           SUM(cache_creation_ephemeral_5m) AS cache_creation_ephemeral_5m,
                           COALESCE(SUM(COALESCE(final_cost_usd, provisional_cost_usd, 0)), 0) AS cost_usd
                    FROM requests
                    GROUP BY session_id
                    ORDER BY session_id
                    """
            ).map { row in
                StoreSessionUsageAggregate(
                    sessionId: row["session_id"],
                    requestCount: row["request_count"],
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    reasoningOutputTokens: row["reasoning_output_tokens"],
                    cacheCreationInputTokens: row["cache_creation_input_tokens"],
                    cacheReadInputTokens: row["cache_read_input_tokens"],
                    cacheCreationEphemeral1h: row["cache_creation_ephemeral_1h"],
                    cacheCreationEphemeral5m: row["cache_creation_ephemeral_5m"],
                    costUSD: row["cost_usd"]
                )
            }
        }
    }

    func requestIds(sessionId: String) throws -> [String] {
        try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM requests WHERE session_id = ? ORDER BY id",
                arguments: [sessionId]
            )
        }
    }

    // MARK: - Compact / resume lineage

    /// Per-session billable requestId sets from `request_membership` (the
    /// full pre-dedup file membership). Every session is a lineage candidate
    /// now — any two can share a replayed requestId regardless of
    /// `logical_parent_uuid` — so the resolver works from this whole-corpus
    /// membership instead of re-reading JSONL.
    func sessionRequestMemberships() throws -> [ClaudeContinuationLineage.SessionInput] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.raw_id AS raw_id, m.request_id AS request_id
                FROM request_membership m
                JOIN sessions s ON s.id = m.session_id
                """)
            var requestIdsByRaw: [String: Set<String>] = [:]
            for row in rows {
                let raw: String = row["raw_id"]
                requestIdsByRaw[raw, default: []].insert(row["request_id"])
            }
            return requestIdsByRaw.map { raw, ids in
                ClaudeContinuationLineage.SessionInput(
                    rawId: raw, logicalParentUuid: nil, requestIds: ids
                )
            }
        }
    }

    /// Applies a lineage resolution: re-homes each shared requestId onto its
    /// canonical owner — moving the deduped row to the owner's session AND
    /// rewriting its token columns to the OWNER's file values (a replay can
    /// catch a different streaming snapshot of the same request, so the
    /// first-imported row may not match the owner's file the ground-truth
    /// recomputes from). Then re-finalizes the affected sessions' costs
    /// (long-context pricing is session-scoped) and stamps `superseded_by`
    /// on pure replays. Idempotent — the `!= owner` guard makes a settled
    /// map a no-op, so steady-state idles do no work.
    func applyContinuationLineage(_ resolution: ClaudeContinuationLineage.Resolution) throws {
        guard !resolution.canonicalByRawId.isEmpty else { return }
        var rehomedRows = 0
        try database.pool.write { db in
            // Per-requestId re-home: only rows whose owner actually changed
            // are touched; the SET pulls the owner's canonical token values
            // from `request_membership`.
            for (requestId, ownerRaw) in resolution.ownerByRequestId {
                let owner = ProviderScopedID(provider: .claudeCode, rawSessionId: ownerRaw).value
                try db.execute(
                    sql: """
                        UPDATE requests SET
                            session_id = :owner,
                            model = (SELECT model FROM request_membership
                                     WHERE session_id = :owner AND request_id = :rid LIMIT 1),
                            input_tokens = (SELECT input_tokens FROM request_membership
                                     WHERE session_id = :owner AND request_id = :rid LIMIT 1),
                            output_tokens = (SELECT output_tokens FROM request_membership
                                     WHERE session_id = :owner AND request_id = :rid LIMIT 1),
                            reasoning_output_tokens = (SELECT reasoning_output_tokens FROM request_membership
                                     WHERE session_id = :owner AND request_id = :rid LIMIT 1),
                            cache_creation_input_tokens = (SELECT cache_creation_input_tokens FROM request_membership
                                     WHERE session_id = :owner AND request_id = :rid LIMIT 1),
                            cache_read_input_tokens = (SELECT cache_read_input_tokens FROM request_membership
                                     WHERE session_id = :owner AND request_id = :rid LIMIT 1),
                            cache_creation_ephemeral_1h = (SELECT cache_creation_ephemeral_1h FROM request_membership
                                     WHERE session_id = :owner AND request_id = :rid LIMIT 1),
                            cache_creation_ephemeral_5m = (SELECT cache_creation_ephemeral_5m FROM request_membership
                                     WHERE session_id = :owner AND request_id = :rid LIMIT 1)
                        WHERE id = :rid AND session_id != :owner
                        """,
                    arguments: ["owner": owner, "rid": requestId]
                )
                rehomedRows += db.changesCount
            }
            // Visibility: pure replays hide behind their leaf; everyone else
            // is (re)cleared to visible.
            for (rawId, leafRawId) in resolution.canonicalByRawId {
                if resolution.hidden.contains(rawId) {
                    try db.execute(
                        sql: "UPDATE sessions SET superseded_by = ? WHERE raw_id = ?",
                        arguments: [leafRawId, rawId]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE sessions SET superseded_by = NULL WHERE raw_id = ?",
                        arguments: [rawId]
                    )
                }
            }
        }

        // Re-home moved rows and rewrote tokens, so the affected sessions'
        // costs are stale — long-context pricing is decided per session.
        // Only runs when something actually moved (settled idles skip it).
        guard rehomedRows > 0 else { return }
        let finalizer = SessionCostFinalizer(writer: self)
        for rawId in resolution.affectedRawIds {
            try finalizer.finalize(
                sessionId: ProviderScopedID(provider: .claudeCode, rawSessionId: rawId).value
            )
        }
    }
}

// MARK: - ImportWriting

extension ProviderStore: ImportWriting {
    @discardableResult
    func upsertSourceFile(_ source: StoreSourceFile) throws -> Int64 {
        try database.pool.write { db in
            try Self.upsertSourceFile(source, db: db)
        }
    }

    func upsertSessionShells(_ sessions: [StoreSessionRow]) throws {
        try database.pool.write { db in
            try Self.upsertSessionShells(sessions, db: db)
        }
    }

    @discardableResult
    func replaceSource(
        _ source: StoreSourceFile,
        payload: StoreSourcePayload,
        batchRowLimit: Int,
        isCancelled: () -> Bool
    ) throws -> Bool {
        // Cancelled before any write: leave the previous import intact.
        if isCancelled() { return false }

        // Pessimistic open (one transaction): delete-by-provenance —
        // dropping the source row cascades every row it owns; rows owned
        // by other sources in the same session are untouched (schema
        // contract, tested in ProviderDatabaseSchemaTests) — then
        // re-register the source as `incomplete` and seed the shells.
        // If the batches below never finish, coverage shows the truth
        // and the next replacement deletes the partial rows.
        var pending = source
        pending.parseState = .incomplete
        pending.importedAt = nil
        var sourceId: Int64 = 0
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM source_files WHERE path = ?", arguments: [source.path])
            sourceId = try Self.upsertSourceFile(pending, db: db)
            try Self.upsertSessionShells(payload.sessions, db: db)
        }

        // Bounded batches, cancellation checked at every boundary.
        let rows = Self.payloadRows(payload)
        let limit = max(1, batchRowLimit)
        var index = 0
        while index < rows.count {
            if isCancelled() { return false }
            let step = min(limit, rows.count - index)
            let chunk = rows[index..<(index + step)]
            try database.pool.write { db in
                for row in chunk {
                    try Self.insert(row, sourceId: sourceId, db: db)
                }
            }
            index += step
        }

        // Billable membership (pre-dedup): `payload.requests` carries every
        // billable request in THIS file, including ones the global
        // `requests.id` dedup will drop because an earlier-imported replay
        // owns them. Recording it (with this file's token values) lets the
        // lineage resolver pick each requestId's canonical owner and re-home
        // the deduped row to the owner's tokens — without re-reading JSONL.
        // Sidechains are excluded: a subagent's requestIds belong to the
        // parent and must NOT inflate its owner rank (the resolver compares
        // main-conversation requestId sets only). Cascade-owned by the
        // source, so the delete above already cleared the old.
        let billable = payload.requests.filter { !$0.isSidechain }
        if !billable.isEmpty {
            try database.pool.write { db in
                for request in billable {
                    try db.execute(
                        sql: """
                            INSERT INTO request_membership (
                                source_file_id, session_id, request_id, model,
                                input_tokens, output_tokens, reasoning_output_tokens,
                                cache_creation_input_tokens, cache_read_input_tokens,
                                cache_creation_ephemeral_1h, cache_creation_ephemeral_5m
                            ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                            ON CONFLICT(source_file_id, request_id) DO NOTHING
                            """,
                        arguments: [
                            sourceId, request.sessionId, request.id, request.model,
                            request.inputTokens, request.outputTokens, request.reasoningOutputTokens,
                            request.cacheCreationInputTokens, request.cacheReadInputTokens,
                            request.cacheCreationEphemeral1h, request.cacheCreationEphemeral5m
                        ]
                    )
                }
            }
        }

        var imported = source
        imported.parseState = .imported
        imported.importedAt = Date()
        _ = try database.pool.write { db in
            try Self.upsertSourceFile(imported, db: db)
        }
        return true
    }

    /// One payload row, type-erased so `replaceSource` can chunk the
    /// whole payload into uniform write batches. Order mirrors the
    /// original single-transaction insert order.
    private enum PayloadRow {
        case request(StoreRequestRow)
        case turn(StoreTurnRow)
        case step(StoreStepRow)
        case subagentLink(StoreSubagentLinkRow)
        case parentLink(StoreParentLinkRow)
        case diagnostic(StoreDiagnosticRow)
        case rawLocator(StoreRawLocatorRow)
        case skill(StoreSkillRow)
        case searchEntry(StoreSearchEntry)
    }

    private static func payloadRows(_ payload: StoreSourcePayload) -> [PayloadRow] {
        var rows: [PayloadRow] = []
        rows.reserveCapacity(
            payload.requests.count + payload.turns.count + payload.steps.count
                + payload.subagentLinks.count + payload.parentLinks.count
                + payload.diagnostics.count + payload.rawLocators.count
                + payload.skills.count + payload.searchEntries.count
        )
        rows.append(contentsOf: payload.requests.map(PayloadRow.request))
        rows.append(contentsOf: payload.turns.map(PayloadRow.turn))
        rows.append(contentsOf: payload.steps.map(PayloadRow.step))
        rows.append(contentsOf: payload.subagentLinks.map(PayloadRow.subagentLink))
        rows.append(contentsOf: payload.parentLinks.map(PayloadRow.parentLink))
        rows.append(contentsOf: payload.diagnostics.map(PayloadRow.diagnostic))
        rows.append(contentsOf: payload.rawLocators.map(PayloadRow.rawLocator))
        rows.append(contentsOf: payload.skills.map(PayloadRow.skill))
        rows.append(contentsOf: payload.searchEntries.map(PayloadRow.searchEntry))
        return rows
    }

    private static func insert(_ row: PayloadRow, sourceId: Int64, db: Database) throws {
        switch row {
        case .request(let request):
            // `requests.id` is the bare requestId, globally unique by design:
            // each billable request is one row, so `SUM(requests)` totals
            // count it once. Compact-continuation sessions replay a prior
            // session's transcript verbatim — the SAME requestIds appear in
            // multiple session files, each a separate import unit. A plain
            // INSERT threw `UNIQUE constraint failed: requests.id` on the
            // second unit, parking the whole (clean) unit as `failed`.
            //
            // The row keeps a single `source_file_id` whose deletion CASCADEs.
            // On a CONFLICT we must RE-BIND that owner to the importing file:
            // a replayed requestId's one row would otherwise stay pinned to
            // whichever file imported it first, and when THAT file is later
            // re-indexed (file-watch touch) its cascade deletes the row while
            // every other carrier just `DO NOTHING`s — so the row vanishes
            // even though a live file still carries it, and the per-file
            // `request_membership` (PK per source) drifts ahead of `requests`
            // (Verify Costs then flags the gap as missing billable requestIds).
            // Re-binding `source_file_id = excluded` keeps the row tied to a
            // file whose payload still contains it, so a later cascade always
            // re-creates it. Only the owner moves — session_id / tokens / cost
            // stay put and the idle lineage re-home + finalizer reconcile them
            // (the content sessionId is identical across replays, so the row's
            // session was never wrong; only its lifecycle was fragile). Single-
            // count is preserved (still one row); clean imports never CONFLICT,
            // so this is a no-op there.
            try db.execute(
                sql: """
                    INSERT INTO requests (
                        id, session_id, source_file_id, timestamp, model, message_id,
                        parent_uuid, is_sidechain, speed, stop_reason,
                        input_tokens, output_tokens, reasoning_output_tokens,
                        cache_creation_input_tokens, cache_read_input_tokens,
                        cache_creation_ephemeral_1h, cache_creation_ephemeral_5m,
                        provisional_cost_usd, final_cost_usd, pricing_version, cost_confidence
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET source_file_id = excluded.source_file_id
                    """,
                arguments: [
                    request.id, request.sessionId, sourceId, request.timestamp,
                    request.model, request.messageId, request.parentUuid,
                    request.isSidechain, request.speed, request.stopReason,
                    request.inputTokens, request.outputTokens, request.reasoningOutputTokens,
                    request.cacheCreationInputTokens, request.cacheReadInputTokens,
                    request.cacheCreationEphemeral1h, request.cacheCreationEphemeral5m,
                    request.provisionalCostUSD, request.finalCostUSD,
                    request.pricingVersion, request.costConfidence
                ]
            )
        case .turn(let turn):
            try db.execute(
                sql: """
                    INSERT INTO turns (
                        session_id, id, source_file_id, ordinal, start_time, end_time,
                        prompt_preview, step_count, interrupted, sidechain_only,
                        agg_input_tokens, agg_output_tokens, agg_reasoning_tokens,
                        agg_cache_creation_tokens, agg_cache_read_tokens,
                        agg_cache_eph_1h_tokens, agg_cache_eph_5m_tokens, agg_context_window,
                        agg_models,
                        agg_cost_input_usd, agg_cost_output_usd, agg_cost_cache_1h_usd,
                        agg_cost_cache_5m_usd, agg_cost_cache_read_usd, agg_complete
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT DO NOTHING
                    """,
                arguments: [
                    turn.sessionId, turn.id, sourceId, turn.ordinal,
                    turn.startTime, turn.endTime, turn.promptPreview, turn.stepCount,
                    turn.interrupted, turn.sidechainOnly,
                    turn.aggTokens.inputTokens, turn.aggTokens.outputTokens,
                    turn.aggTokens.reasoningOutputTokens,
                    turn.aggTokens.cacheCreationInputTokens, turn.aggTokens.cacheReadInputTokens,
                    turn.aggTokens.cacheCreationEphemeral1h, turn.aggTokens.cacheCreationEphemeral5m,
                    turn.aggTokens.contextWindow,
                    turn.aggModels.isEmpty ? nil : turn.aggModels.joined(separator: ","),
                    turn.aggCost.inputCostUSD, turn.aggCost.outputCostUSD,
                    turn.aggCost.cacheCreate1hCostUSD, turn.aggCost.cacheCreate5mCostUSD,
                    turn.aggCost.cacheReadCostUSD, turn.aggComplete
                ]
            )
        case .step(let step):
            try db.execute(
                sql: """
                    INSERT INTO steps (
                        session_id, turn_id, uuid, source_file_id, ordinal, kind,
                        timestamp, model, request_id, agent_id, text, thinking_text,
                        tool_name, tool_use_id
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT DO NOTHING
                    """,
                arguments: [
                    step.sessionId, step.turnId, step.uuid, sourceId, step.ordinal,
                    step.kind, step.timestamp, step.model, step.requestId, step.agentId,
                    step.text, step.thinkingText, step.toolName, step.toolUseId
                ]
            )
        case .subagentLink(let link):
            try db.execute(
                sql: """
                    INSERT INTO subagent_links (
                        session_id, source_file_id, link_kind, agent_id,
                        parent_tool_use_id, parent_assistant_uuid, parent_message_id,
                        link_description, subagent_type, timestamp,
                        workflow_task_id, workflow_run_id, workflow_name,
                        workflow_phase_title, workflow_label, workflow_status,
                        workflow_model, workflow_agent_state,
                        workflow_telemetry_tokens, workflow_tool_calls, workflow_duration_ms
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT DO NOTHING
                    """,
                arguments: [
                    link.sessionId, sourceId, link.linkKind, link.agentId,
                    link.parentToolUseId, link.parentAssistantUuid, link.parentMessageId,
                    link.linkDescription, link.subagentType, link.timestamp,
                    link.workflowTaskId, link.workflowRunId, link.workflowName,
                    link.workflowPhaseTitle, link.workflowLabel, link.workflowStatus,
                    link.workflowModel, link.workflowAgentState,
                    link.workflowTelemetryTokens, link.workflowToolCalls, link.workflowDurationMs
                ]
            )
        case .parentLink(let parentLink):
            try db.execute(
                sql: """
                    INSERT INTO parent_links (session_id, uuid, parent_uuid, source_file_id)
                    VALUES (?,?,?,?)
                    ON CONFLICT DO NOTHING
                    """,
                arguments: [parentLink.sessionId, parentLink.uuid, parentLink.parentUuid, sourceId]
            )
        case .diagnostic(let diagnostic):
            try db.execute(
                sql: """
                    INSERT INTO diagnostics (
                        source_file_id, session_id, severity, category,
                        line_number, byte_offset, preview, created_at
                    ) VALUES (?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    sourceId, diagnostic.sessionId, diagnostic.severity, diagnostic.category,
                    diagnostic.lineNumber, diagnostic.byteOffset, diagnostic.preview,
                    diagnostic.createdAt
                ]
            )
        case .rawLocator(let locator):
            try db.execute(
                sql: """
                    INSERT INTO raw_locators (
                        session_id, owner_kind, owner_id, source_file_id,
                        byte_offset, byte_length, line_number
                    ) VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT DO NOTHING
                    """,
                arguments: [
                    locator.sessionId, locator.ownerKind, locator.ownerId, sourceId,
                    locator.byteOffset, locator.byteLength, locator.lineNumber
                ]
            )
        case .skill(let skill):
            try db.execute(
                sql: """
                    INSERT INTO skills (session_id, turn_id, source_file_id, skill_name)
                    VALUES (?,?,?,?)
                    ON CONFLICT DO NOTHING
                    """,
                arguments: [skill.sessionId, skill.turnId, sourceId, skill.skillName]
            )
        case .searchEntry(let entry):
            try db.execute(
                sql: """
                    INSERT INTO search_fts (session_id, turn_id, step_uuid, kind, content, source_file_id)
                    VALUES (?,?,?,?,?,?)
                    """,
                arguments: [entry.sessionId, entry.turnId, entry.stepUuid, entry.kind, entry.content, sourceId]
            )
        }
    }

    func setSourceParseState(path: String, state: StoreParseState) throws {
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE source_files SET parse_state = ? WHERE path = ?",
                arguments: [state.rawValue, path]
            )
        }
    }

    func sourceFile(path: String) throws -> StoreSourceFile? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM source_files WHERE path = ?", arguments: [path])
                .map(Self.sourceFileRow(from:))
        }
    }

    /// Plan 5.7: one atomic unit's sources only. The coordinator calls
    /// this per unit import — fetching ALL sources per unit made the
    /// backfill quadratic in source count (0.16 units/s at 41.6k
    /// sources on the 10 GB corpus).
    func sourceFiles(sessionRawId: String) throws -> [StoreSourceFile] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM source_files WHERE session_raw_id = ?",
                arguments: [sessionRawId]
            ).map(Self.sourceFileRow(from:))
        }
    }

    func allSourceFiles() throws -> [StoreSourceFile] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM source_files ORDER BY path")
                .map(Self.sourceFileRow(from:))
        }
    }

    func upsertSourceFiles(_ sources: [StoreSourceFile]) throws {
        guard !sources.isEmpty else { return }
        try database.pool.write { db in
            for source in sources {
                try Self.upsertSourceFile(source, db: db)
            }
        }
    }

    func deleteSources(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        // Chunked IN-lists keep us well under SQLite's bound-variable
        // limit; everything still commits as one transaction.
        let chunkSize = 500
        try database.pool.write { db in
            var index = 0
            while index < paths.count {
                let chunk = Array(paths[index..<min(index + chunkSize, paths.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM source_files WHERE path IN (\(placeholders))",
                    arguments: StatementArguments(chunk.map { $0 as DatabaseValueConvertible? })
                )
                index += chunkSize
            }
        }
    }

    func seedSessionShells(_ sessions: [StoreSessionRow]) throws {
        guard !sessions.isEmpty else { return }
        try database.pool.write { db in
            for session in sessions {
                try db.execute(
                    sql: """
                        INSERT INTO sessions (
                            id, raw_id, project_path, slug, start_time, end_time,
                            cached_title, custom_title, first_prompt, last_git_branch,
                            visible, detail_state, logical_parent_uuid
                        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET
                            project_path = COALESCE(sessions.project_path, excluded.project_path),
                            slug = COALESCE(sessions.slug, excluded.slug),
                            start_time = CASE
                                WHEN excluded.start_time IS NULL THEN sessions.start_time
                                WHEN sessions.start_time IS NULL THEN excluded.start_time
                                WHEN excluded.start_time < sessions.start_time THEN excluded.start_time
                                ELSE sessions.start_time END,
                            end_time = CASE
                                WHEN excluded.end_time IS NULL THEN sessions.end_time
                                WHEN sessions.end_time IS NULL THEN excluded.end_time
                                WHEN excluded.end_time > sessions.end_time THEN excluded.end_time
                                ELSE sessions.end_time END,
                            cached_title = COALESCE(sessions.cached_title, excluded.cached_title),
                            custom_title = COALESCE(sessions.custom_title, excluded.custom_title),
                            first_prompt = COALESCE(sessions.first_prompt, excluded.first_prompt),
                            last_git_branch = COALESCE(sessions.last_git_branch, excluded.last_git_branch),
                            logical_parent_uuid = COALESCE(sessions.logical_parent_uuid, excluded.logical_parent_uuid)
                        """,
                    arguments: [
                        session.id, session.rawId, session.projectPath, session.slug,
                        session.startTime, session.endTime, session.cachedTitle,
                        session.customTitle, session.firstPrompt, session.lastGitBranch,
                        session.visible, session.detailState.rawValue, session.logicalParentUuid
                    ]
                )
            }
        }
    }

    func applySessionVisibility(_ updates: [StoreSessionVisibilityUpdate]) throws {
        guard !updates.isEmpty else { return }
        try database.pool.write { db in
            for update in updates {
                try db.execute(
                    sql: """
                        UPDATE sessions
                        SET visible = ?, cached_title = COALESCE(?, cached_title)
                        WHERE id = ?
                        """,
                    arguments: [update.visible, update.cachedTitle, update.sessionId]
                )
            }
        }
    }

    /// Plan 5.3 (sidebar metrics): per-session aggregates for the
    /// session-list cells. One GROUP BY over requests plus one over
    /// subagent_links, merged by session id. Confidence tallies mirror
    /// `CostConfidence.evaluate` (Codex only; Claude renders exact).
    func sessionListAggregates() throws -> [String: StoreSessionListAggregate] {
        try database.pool.read { db in
            var bySession: [String: StoreSessionListAggregate] = [:]
            let usageRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT session_id,
                           COUNT(*) AS request_count,
                           SUM(input_tokens + output_tokens + reasoning_output_tokens
                               + cache_creation_input_tokens + cache_read_input_tokens) AS context_tokens,
                           COALESCE(SUM(COALESCE(final_cost_usd, provisional_cost_usd, 0)), 0) AS cost_usd,
                           SUM(CASE WHEN COALESCE(cost_confidence, '') != 'notBillable' THEN 1 ELSE 0 END) AS billable_count,
                           SUM(CASE WHEN cost_confidence = 'unavailable' THEN 1 ELSE 0 END) AS unavailable_count,
                           GROUP_CONCAT(DISTINCT model) AS models
                    FROM requests
                    GROUP BY session_id
                    """
            )
            for row in usageRows {
                let sessionId: String = row["session_id"]
                // Model ids never contain commas, so GROUP_CONCAT's
                // default separator splits losslessly; NULL models are
                // skipped by SQLite before concatenation.
                let modelList: String? = row["models"]
                bySession[sessionId] = StoreSessionListAggregate(
                    sessionId: sessionId,
                    requestCount: row["request_count"],
                    contextTokens: row["context_tokens"],
                    costUSD: row["cost_usd"],
                    billableRequestCount: row["billable_count"],
                    unavailableRequestCount: row["unavailable_count"],
                    models: Set(modelList.map { $0.split(separator: ",").map(String.init) } ?? [])
                )
            }
            let linkRows = try Row.fetchAll(
                db,
                sql: "SELECT session_id, COUNT(*) AS link_count FROM subagent_links GROUP BY session_id"
            )
            for row in linkRows {
                let sessionId: String = row["session_id"]
                var aggregate = bySession[sessionId] ?? StoreSessionListAggregate(
                    sessionId: sessionId, requestCount: 0, contextTokens: 0,
                    costUSD: 0, billableRequestCount: 0, unavailableRequestCount: 0
                )
                aggregate.subagentLinkCount = row["link_count"]
                bySession[sessionId] = aggregate
            }
            return bySession
        }
    }

    /// Plan 5.3: source path for "Reveal in Finder" — the session's
    /// primary (non-subagent) source file, newest first when a session
    /// spans continuation files.
    func primarySourcePath(sessionRawId: String) throws -> String? {
        try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT path FROM source_files
                    WHERE session_raw_id = ? AND is_subagent = 0
                    ORDER BY modified_at DESC, path ASC
                    LIMIT 1
                    """,
                arguments: [sessionRawId]
            )
        }
    }

    /// Plan 5.2 (rebuild index): drops every indexed row — sources,
    /// sessions, and all cascade-owned payload — plus the standalone
    /// FTS table, in one transaction. The schema and the pool stay
    /// open; the next metadata scan re-registers everything as new.
    func wipeAllIndexedData() throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM search_fts")
            try db.execute(sql: "DELETE FROM source_files")
            try db.execute(sql: "DELETE FROM sessions")
        }
    }

    @discardableResult
    func pruneSessionsWithoutSources() throws -> Int {
        try database.pool.write { db in
            try db.execute(
                sql: """
                    DELETE FROM sessions
                    WHERE raw_id NOT IN (
                        SELECT session_raw_id FROM source_files WHERE session_raw_id IS NOT NULL
                    )
                    AND id NOT IN (SELECT session_id FROM requests)
                    AND id NOT IN (SELECT session_id FROM turns)
                    """
            )
            return db.changesCount
        }
    }

    private static func sourceFileRow(from row: Row) -> StoreSourceFile {
        StoreSourceFile(
            id: row["id"],
            path: row["path"],
            byteSize: row["byte_size"],
            modifiedAt: row["modified_at"],
            fingerprint: row["fingerprint"],
            parseState: StoreParseState(rawValue: row["parse_state"]) ?? .pending,
            lineCount: row["line_count"],
            rejectedLineCount: row["rejected_line_count"],
            importedAt: row["imported_at"],
            sessionRawId: row["session_raw_id"],
            isSubagent: row["is_subagent"],
            subagentParentRawId: row["subagent_parent_raw_id"],
            workflowRunId: row["workflow_run_id"]
        )
    }

    func requests(inSession sessionId: String) throws -> [StoreRequestRow] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM requests WHERE session_id = ? ORDER BY timestamp, id",
                arguments: [sessionId]
            ).map(Self.requestRow(from:))
        }
    }

    func applyRequestCostFinalization(_ updates: [StoreRequestCostUpdate]) throws {
        guard !updates.isEmpty else { return }
        try database.pool.write { db in
            for update in updates {
                try db.execute(
                    sql: """
                        UPDATE requests
                        SET final_cost_usd = ?, pricing_version = ?, cost_confidence = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        update.finalCostUSD, update.pricingVersion,
                        update.costConfidence, update.id
                    ]
                )
            }
        }
    }

    /// Parks a failed unit's unimported sources so the queue stops
    /// retrying a deterministic failure on every rescan (6.10). The
    /// scanner's fingerprint check un-parks them (back to `metadata`)
    /// the moment the file changes on disk.
    func markUnimportedSourcesFailed(sessionRawId: String) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE source_files SET parse_state = 'failed'
                    WHERE session_raw_id = ?
                      AND parse_state IN ('pending', 'metadata', 'incomplete')
                    """,
                arguments: [sessionRawId]
            )
        }
    }

    func pendingSourceCount(modifiedSince date: Date) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM source_files
                    WHERE modified_at >= ?
                      AND parse_state IN ('pending', 'metadata', 'incomplete')
                    """,
                arguments: [date]
            ) ?? 0
        }
    }

    func renumberTurnOrdinals(sessionId: String) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                    WITH ranked AS (
                        SELECT id AS tid,
                               ROW_NUMBER() OVER (
                                   ORDER BY COALESCE(start_time, '\(Self.nullDateSentinel)') ASC, id ASC
                               ) - 1 AS ord
                        FROM turns WHERE session_id = ?1
                    )
                    UPDATE turns
                    SET ordinal = (SELECT ord FROM ranked WHERE ranked.tid = turns.id)
                    WHERE session_id = ?1
                    """,
                arguments: [sessionId]
            )
        }
    }

    func applyTurnAggregateAdjustments(_ adjustments: [StoreTurnAggregateAdjustment]) throws {
        guard !adjustments.isEmpty else { return }
        try database.pool.write { db in
            for adjustment in adjustments {
                try db.execute(
                    sql: """
                        UPDATE turns
                        SET agg_input_tokens = agg_input_tokens + ?,
                            agg_output_tokens = agg_output_tokens + ?,
                            agg_reasoning_tokens = agg_reasoning_tokens + ?,
                            agg_cache_creation_tokens = agg_cache_creation_tokens + ?,
                            agg_cache_read_tokens = agg_cache_read_tokens + ?,
                            agg_cache_eph_1h_tokens = agg_cache_eph_1h_tokens + ?,
                            agg_cache_eph_5m_tokens = agg_cache_eph_5m_tokens + ?,
                            agg_context_window = CASE
                                WHEN agg_context_window IS NULL AND ? IS NULL THEN NULL
                                ELSE MAX(COALESCE(agg_context_window, 0), COALESCE(?, 0))
                            END,
                            agg_cost_input_usd = agg_cost_input_usd + ?,
                            agg_cost_output_usd = agg_cost_output_usd + ?,
                            agg_cost_cache_1h_usd = agg_cost_cache_1h_usd + ?,
                            agg_cost_cache_5m_usd = agg_cost_cache_5m_usd + ?,
                            agg_cost_cache_read_usd = agg_cost_cache_read_usd + ?,
                            agg_complete = ?
                        WHERE session_id = ? AND id = ?
                        """,
                    arguments: [
                        adjustment.addTokens.inputTokens, adjustment.addTokens.outputTokens,
                        adjustment.addTokens.reasoningOutputTokens,
                        adjustment.addTokens.cacheCreationInputTokens,
                        adjustment.addTokens.cacheReadInputTokens,
                        adjustment.addTokens.cacheCreationEphemeral1h,
                        adjustment.addTokens.cacheCreationEphemeral5m,
                        adjustment.addTokens.contextWindow, adjustment.addTokens.contextWindow,
                        adjustment.addCost.inputCostUSD, adjustment.addCost.outputCostUSD,
                        adjustment.addCost.cacheCreate1hCostUSD,
                        adjustment.addCost.cacheCreate5mCostUSD,
                        adjustment.addCost.cacheReadCostUSD,
                        adjustment.complete,
                        adjustment.sessionId, adjustment.turnId
                    ]
                )
            }
        }
    }

    func sessionIdsWithStaleCosts(pricingVersion: Int) throws -> [String] {
        try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT session_id FROM requests
                    WHERE pricing_version IS NULL OR pricing_version != ?
                    ORDER BY session_id
                    """,
                arguments: [pricingVersion]
            )
        }
    }

    // MARK: Shared write helpers (run inside a caller's transaction)

    @discardableResult
    private static func upsertSourceFile(_ source: StoreSourceFile, db: Database) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO source_files (
                    path, byte_size, modified_at, fingerprint, parse_state,
                    line_count, rejected_line_count, imported_at,
                    session_raw_id, is_subagent, subagent_parent_raw_id, workflow_run_id
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET
                    byte_size = excluded.byte_size,
                    modified_at = excluded.modified_at,
                    fingerprint = excluded.fingerprint,
                    parse_state = excluded.parse_state,
                    line_count = excluded.line_count,
                    rejected_line_count = excluded.rejected_line_count,
                    imported_at = excluded.imported_at,
                    session_raw_id = excluded.session_raw_id,
                    is_subagent = excluded.is_subagent,
                    subagent_parent_raw_id = excluded.subagent_parent_raw_id,
                    workflow_run_id = excluded.workflow_run_id
                """,
            arguments: [
                source.path, source.byteSize, source.modifiedAt, source.fingerprint,
                source.parseState.rawValue, source.lineCount, source.rejectedLineCount,
                source.importedAt, source.sessionRawId, source.isSubagent,
                source.subagentParentRawId, source.workflowRunId
            ]
        )
        guard let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM source_files WHERE path = ?",
            arguments: [source.path]
        ) else {
            throw DatabaseError(message: "source_files upsert lost row for \(source.path)")
        }
        return id
    }

    /// Shell upsert with widening semantics: incoming non-nil detail
    /// columns overwrite, nil leaves existing values; `end_time` takes the
    /// later, `start_time` the earlier of both; `detail_state` never
    /// downgrades away from `complete`.
    private static func upsertSessionShells(_ sessions: [StoreSessionRow], db: Database) throws {
        for session in sessions {
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                        id, raw_id, project_path, slug, start_time, end_time,
                        cached_title, custom_title, first_prompt, last_git_branch,
                        visible, detail_state, logical_parent_uuid
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                        project_path = COALESCE(excluded.project_path, sessions.project_path),
                        slug = COALESCE(excluded.slug, sessions.slug),
                        start_time = CASE
                            WHEN excluded.start_time IS NULL THEN sessions.start_time
                            WHEN sessions.start_time IS NULL THEN excluded.start_time
                            WHEN excluded.start_time < sessions.start_time THEN excluded.start_time
                            ELSE sessions.start_time END,
                        end_time = CASE
                            WHEN excluded.end_time IS NULL THEN sessions.end_time
                            WHEN sessions.end_time IS NULL THEN excluded.end_time
                            WHEN excluded.end_time > sessions.end_time THEN excluded.end_time
                            ELSE sessions.end_time END,
                        cached_title = COALESCE(excluded.cached_title, sessions.cached_title),
                        custom_title = COALESCE(excluded.custom_title, sessions.custom_title),
                        first_prompt = COALESCE(excluded.first_prompt, sessions.first_prompt),
                        last_git_branch = COALESCE(excluded.last_git_branch, sessions.last_git_branch),
                        visible = excluded.visible,
                        detail_state = CASE
                            WHEN sessions.detail_state = 'complete' THEN sessions.detail_state
                            ELSE excluded.detail_state END,
                        logical_parent_uuid = COALESCE(excluded.logical_parent_uuid, sessions.logical_parent_uuid)
                    """,
                arguments: [
                    session.id, session.rawId, session.projectPath, session.slug,
                    session.startTime, session.endTime, session.cachedTitle,
                    session.customTitle, session.firstPrompt, session.lastGitBranch,
                    session.visible, session.detailState.rawValue, session.logicalParentUuid
                ]
            )
        }
    }
}
