//
//  ProviderDatabaseSchema.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation
import GRDB

/// Schema DDL for the per-provider index database.
///
/// Versioning policy: there is exactly one `createV1(_:)` for the current
/// `ProviderDatabase.schemaVersion`. Schema changes bump the version and
/// edit this DDL in place — the database is a rebuildable cache, so no
/// ALTER/migration paths exist by design (plan.md Confirmed Decision 4).
///
/// Provenance: every row that is derived from one source file carries
/// `source_file_id` with ON DELETE CASCADE — "delete by provenance, then
/// insert" (re-importing a source) is `DELETE FROM source_files WHERE id=?`
/// plus fresh inserts, in one transaction. `sessions` rows are shared
/// shells (a session can span multiple sources) and are NOT cascade-owned.
///
/// One database per provider — no provider column anywhere.
enum ProviderDatabaseSchema {

    /// NULL-date stand-in for keyset pagination over nullable times: a
    /// row-value comparison against a NULL column would drop the row, so
    /// queries compare `COALESCE(time, sentinel)` instead. The sidebar
    /// page index below embeds the SAME literal — SQLite matches indexed
    /// expressions syntactically, so query text and DDL must agree.
    static let nullDateSentinel = "0000-01-01 00:00:00.000"

    static func createV1(_ db: Database) throws {
        // MARK: source_files — discovery + parse state per source
        try db.create(table: "source_files") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("path", .text).notNull().unique()
            t.column("byte_size", .integer).notNull()
            t.column("modified_at", .datetime)
            t.column("fingerprint", .text).notNull()
            // pending | metadata | imported | incomplete | failed
            t.column("parse_state", .text).notNull().defaults(to: "pending")
            t.column("line_count", .integer)
            t.column("rejected_line_count", .integer)
            t.column("imported_at", .datetime)
            // Claude subagent layout / Codex grouping facts discovered at
            // metadata time; importers use them to assemble atomic units.
            t.column("session_raw_id", .text)
            t.column("is_subagent", .boolean).notNull().defaults(to: false)
            t.column("subagent_parent_raw_id", .text)
            t.column("workflow_run_id", .text)
        }
        try db.create(index: "idx_source_files_state", on: "source_files", columns: ["parse_state"])
        try db.create(index: "idx_source_files_session", on: "source_files", columns: ["session_raw_id"])

        // MARK: sessions — sidebar shells (shared across sources)
        try db.create(table: "sessions") { t in
            t.primaryKey("id", .text)                  // provider-scoped id
            t.column("raw_id", .text).notNull()
            t.column("project_path", .text)
            t.column("slug", .text)
            t.column("start_time", .datetime)
            t.column("end_time", .datetime)
            t.column("cached_title", .text)
            t.column("custom_title", .text)
            t.column("first_prompt", .text)            // sidebar search column
            // Most recent branch observed in the session's log (Claude:
            // last assistant request line carrying one; Codex: newest
            // piece's session_meta git.branch). Sidebar branch row.
            t.column("last_git_branch", .text)
            t.column("visible", .boolean).notNull().defaults(to: true)
            // metadata | partial | complete — scoped-import coverage
            t.column("detail_state", .text).notNull().defaults(to: "metadata")
            // Compact-continuation lineage (Claude). `logical_parent_uuid`
            // is the parent compaction point copied from the file's first
            // `type=system` entry; sessions sharing it are one lineage.
            // `superseded_by` is the canonical leaf's raw id when this
            // session is a redundant earlier snapshot (NULL = canonical /
            // standalone → shown). Set by the post-import lineage resolver;
            // deliberately absent from the shell upsert column list so a
            // re-imported shell never clobbers it.
            t.column("logical_parent_uuid", .text)
            t.column("superseded_by", .text)
        }
        try db.create(index: "idx_sessions_end_time", on: "sessions", columns: ["end_time"])
        try db.create(index: "idx_sessions_project", on: "sessions", columns: ["project_path"])
        try db.create(index: "idx_sessions_raw_id", on: "sessions", columns: ["raw_id"])
        try db.create(index: "idx_sessions_visible", on: "sessions", columns: ["visible"])
        // Serves the sidebar keyset page (`sessionPage`): without it every
        // page re-sorts the whole table into a temp B-tree — measured 2s+
        // per warm launch on a 37k-session index (Phase 3 gate).
        try db.execute(sql: """
            CREATE INDEX idx_sessions_page_order
            ON sessions (COALESCE(end_time, '\(nullDateSentinel)') DESC, id DESC)
            """)

        // MARK: requests — billable usage rows
        try db.create(table: "requests") { t in
            t.primaryKey("id", .text)                  // source-discriminated request id
            t.column("session_id", .text).notNull()
                .references("sessions", onDelete: .cascade)
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.column("timestamp", .datetime).notNull()
            t.column("model", .text)
            t.column("message_id", .text)
            t.column("parent_uuid", .text)
            t.column("is_sidechain", .boolean).notNull().defaults(to: false)
            t.column("speed", .text)
            t.column("stop_reason", .text)
            t.column("input_tokens", .integer).notNull().defaults(to: 0)
            t.column("output_tokens", .integer).notNull().defaults(to: 0)
            t.column("reasoning_output_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_creation_input_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_read_input_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_creation_ephemeral_1h", .integer).notNull().defaults(to: 0)
            t.column("cache_creation_ephemeral_5m", .integer).notNull().defaults(to: 0)
            t.column("provisional_cost_usd", .double)
            t.column("final_cost_usd", .double)        // set by the session finalize pass
            t.column("pricing_version", .integer)
            t.column("cost_confidence", .text)
        }
        try db.create(index: "idx_requests_session_time", on: "requests", columns: ["session_id", "timestamp"])
        try db.create(index: "idx_requests_time", on: "requests", columns: ["timestamp"])
        try db.create(index: "idx_requests_source", on: "requests", columns: ["source_file_id"])
        try db.create(index: "idx_requests_model", on: "requests", columns: ["model"])

        // MARK: request_membership — full per-file billable requestId list
        // (sidechains excluded), BEFORE the global `requests.id` dedup drops
        // replays. `requests` keeps one row per requestId (single-count), so
        // it can't tell which OTHER session files carried that id, nor that
        // file's token values — both facts the lineage resolver needs to (a)
        // pick each requestId's canonical owner and (b) re-home the deduped
        // row to the OWNER's token values (a replay may capture a different
        // streaming snapshot of the same request). One row per (source,
        // requestId); `session_id` is the file's own session. Cascade-owned
        // by the source, so a re-import replaces it like every derived table.
        try db.create(table: "request_membership") { t in
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.column("session_id", .text).notNull()    // scoped id of the carrying file
            t.column("request_id", .text).notNull()
            // The owner's canonical token values, copied onto the deduped
            // `requests` row at re-home so the owner's stored cost equals the
            // ground-truth (which recomputes from the owner's file).
            t.column("model", .text)
            t.column("input_tokens", .integer).notNull().defaults(to: 0)
            t.column("output_tokens", .integer).notNull().defaults(to: 0)
            t.column("reasoning_output_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_creation_input_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_read_input_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_creation_ephemeral_1h", .integer).notNull().defaults(to: 0)
            t.column("cache_creation_ephemeral_5m", .integer).notNull().defaults(to: 0)
            t.primaryKey(["source_file_id", "request_id"])
        }
        try db.create(index: "idx_request_membership_request", on: "request_membership", columns: ["request_id"])
        try db.create(index: "idx_request_membership_session", on: "request_membership", columns: ["session_id"])

        // MARK: turns — top-level conversation rows with precomputed
        // aggregates (incl. subagent contributions) so the outline renders
        // without loading steps.
        try db.create(table: "turns") { t in
            t.column("session_id", .text).notNull()
                .references("sessions", onDelete: .cascade)
            t.column("id", .text).notNull()
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.column("ordinal", .integer).notNull()
            t.column("start_time", .datetime)
            t.column("end_time", .datetime)
            t.column("prompt_preview", .text)          // highlight/search/animation column
            t.column("step_count", .integer).notNull().defaults(to: 0)
            t.column("interrupted", .boolean).notNull().defaults(to: false)
            t.column("sidechain_only", .boolean).notNull().defaults(to: false)
            // Full header breakdowns (4.1) — every Turn-header cell
            // (tokens, cost, cache read/write/TTL, reasoning, context
            // window) renders from these without loading steps.
            t.column("agg_input_tokens", .integer).notNull().defaults(to: 0)
            t.column("agg_output_tokens", .integer).notNull().defaults(to: 0)
            t.column("agg_reasoning_tokens", .integer).notNull().defaults(to: 0)
            t.column("agg_cache_creation_tokens", .integer).notNull().defaults(to: 0)
            t.column("agg_cache_read_tokens", .integer).notNull().defaults(to: 0)
            t.column("agg_cache_eph_1h_tokens", .integer).notNull().defaults(to: 0)
            t.column("agg_cache_eph_5m_tokens", .integer).notNull().defaults(to: 0)
            t.column("agg_context_window", .integer)
            t.column("agg_models", .text)              // resolve-ordered, comma-joined
            t.column("agg_cost_input_usd", .double).notNull().defaults(to: 0)
            t.column("agg_cost_output_usd", .double).notNull().defaults(to: 0)
            t.column("agg_cost_cache_1h_usd", .double).notNull().defaults(to: 0)
            t.column("agg_cost_cache_5m_usd", .double).notNull().defaults(to: 0)
            t.column("agg_cost_cache_read_usd", .double).notNull().defaults(to: 0)
            // false while a grouped import hasn't finished the subagent
            // legs — never silently undercount (plan rule 6).
            t.column("agg_complete", .boolean).notNull().defaults(to: false)
            t.primaryKey(["session_id", "id"])
        }
        try db.create(index: "idx_turns_session_ordinal", on: "turns", columns: ["session_id", "ordinal"])
        try db.create(index: "idx_turns_source", on: "turns", columns: ["source_file_id"])

        // MARK: steps — child rows, loaded on expand
        try db.create(table: "steps") { t in
            t.column("session_id", .text).notNull()
                .references("sessions", onDelete: .cascade)
            t.column("turn_id", .text).notNull()
            t.column("uuid", .text).notNull()
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.column("ordinal", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("timestamp", .datetime)
            t.column("model", .text)
            t.column("request_id", .text)
            t.column("agent_id", .text)
            t.column("text", .text)
            t.column("thinking_text", .text)
            t.column("tool_name", .text)
            t.column("tool_use_id", .text)
            t.primaryKey(["session_id", "uuid"])
        }
        try db.create(index: "idx_steps_turn", on: "steps", columns: ["session_id", "turn_id", "ordinal"])
        try db.create(index: "idx_steps_source", on: "steps", columns: ["source_file_id"])
        try db.create(index: "idx_steps_tool_use", on: "steps", columns: ["tool_use_id"])

        // MARK: subagent_links — full SubAgentLinker.Link projection
        try db.create(table: "subagent_links") { t in
            t.column("session_id", .text).notNull()
                .references("sessions", onDelete: .cascade)
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.column("link_kind", .text).notNull()     // agent | workflow
            t.column("agent_id", .text).notNull()
            t.column("parent_tool_use_id", .text).notNull()
            t.column("parent_assistant_uuid", .text).notNull()
            t.column("parent_message_id", .text)
            t.column("link_description", .text)
            t.column("subagent_type", .text)
            t.column("timestamp", .text)
            t.column("workflow_task_id", .text)
            t.column("workflow_run_id", .text)
            t.column("workflow_name", .text)
            t.column("workflow_phase_title", .text)
            t.column("workflow_label", .text)
            t.column("workflow_status", .text)
            t.column("workflow_model", .text)
            t.column("workflow_agent_state", .text)
            t.column("workflow_telemetry_tokens", .integer)
            t.column("workflow_tool_calls", .integer)
            t.column("workflow_duration_ms", .integer)
            // agent_id is part of the key: a Workflow launch records one
            // link per child agent, all sharing the parent tool_use.
            t.primaryKey(["session_id", "parent_tool_use_id", "agent_id"])
        }
        try db.create(index: "idx_subagent_links_agent", on: "subagent_links", columns: ["agent_id"])
        try db.create(index: "idx_subagent_links_source", on: "subagent_links", columns: ["source_file_id"])

        // MARK: parent_links — (uuid → parentUuid) incl. dropped lines,
        // needed for parent-chain walks across filtered entries.
        try db.create(table: "parent_links") { t in
            t.column("session_id", .text).notNull()
            t.column("uuid", .text).notNull()
            t.column("parent_uuid", .text)
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.primaryKey(["session_id", "uuid"])
        }
        try db.create(index: "idx_parent_links_source", on: "parent_links", columns: ["source_file_id"])

        // MARK: diagnostics
        try db.create(table: "diagnostics") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.column("session_id", .text)
            t.column("severity", .text).notNull()      // info | warning | error
            t.column("category", .text).notNull()
            t.column("line_number", .integer)
            t.column("byte_offset", .integer)
            t.column("preview", .text)
            t.column("created_at", .datetime).notNull()
        }
        try db.create(index: "idx_diagnostics_source", on: "diagnostics", columns: ["source_file_id"])
        try db.create(index: "idx_diagnostics_severity", on: "diagnostics", columns: ["severity"])

        // MARK: raw_locators — lazy access to original JSONL bytes
        try db.create(table: "raw_locators") { t in
            t.column("session_id", .text).notNull()
            t.column("owner_kind", .text).notNull()    // stepLine | requestTokenCount | diagnosticLine
            t.column("owner_id", .text).notNull()      // step uuid / request id / diagnostic key
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.column("byte_offset", .integer)
            t.column("byte_length", .integer)
            t.column("line_number", .integer)
            t.primaryKey(["session_id", "owner_kind", "owner_id"])
        }
        try db.create(index: "idx_raw_locators_source", on: "raw_locators", columns: ["source_file_id"])

        // MARK: skills — provider-aware skill extraction per turn (Reports)
        try db.create(table: "skills") { t in
            t.column("session_id", .text).notNull()
                .references("sessions", onDelete: .cascade)
            t.column("turn_id", .text).notNull()
            t.column("source_file_id", .integer).notNull()
                .references("source_files", onDelete: .cascade)
            t.column("skill_name", .text).notNull()    // prefix-free key, e.g. "flow-all"
            t.primaryKey(["session_id", "turn_id", "skill_name"])
        }
        try db.create(index: "idx_skills_name", on: "skills", columns: ["skill_name"])
        try db.create(index: "idx_skills_source", on: "skills", columns: ["source_file_id"])

        // MARK: search_fts — reserved in Phase 1 (Decision 3): prompt
        // previews populate it in Phase 2, full step text in Phase 4.
        try db.create(virtualTable: "search_fts", using: FTS5()) { t in
            t.column("session_id").notIndexed()
            t.column("turn_id").notIndexed()
            t.column("step_uuid").notIndexed()
            t.column("kind").notIndexed()              // prompt | reply | thinking | title
            t.column("content")
            // Provenance (v9). Appended LAST so `content` keeps column
            // index 4 — the `snippet(search_fts, 4, …)` call depends on it.
            t.column("source_file_id").notIndexed()
        }
        // FTS5 can't carry a foreign key, so the re-import cascade that
        // drops a `source_files` row would orphan this table's rows and
        // double-count them on the next re-index. This trigger is the
        // cascade equivalent — it covers replaceSource, deleteSources,
        // and any raw delete of a source row.
        try db.execute(sql: """
            CREATE TRIGGER search_fts_source_delete AFTER DELETE ON source_files BEGIN
                DELETE FROM search_fts WHERE source_file_id = OLD.id;
            END
            """)
    }
}
