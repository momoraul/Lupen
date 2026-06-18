//
//  StoreDTO.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Domain-facing value types for the provider index store. This file is
/// the repository interface vocabulary — it imports Foundation only.
/// GRDB stays inside `ProviderStore` (plan.md Confirmed Decision 1).

// MARK: - Coverage / states

enum StoreDetailState: String, Sendable, Equatable {
    case metadata
    case partial
    case complete
}

enum StoreParseState: String, Sendable, Equatable {
    case pending
    case metadata
    case imported
    case incomplete
    case failed
}

/// Source-level coverage for honest partial results (plan §4).
struct StoreCoverage: Sendable, Equatable {
    let totalSources: Int
    let importedSources: Int
    let incompleteSources: Int
    let pendingSources: Int
    let failedSources: Int

    var isComplete: Bool {
        totalSources == importedSources
    }
}

// MARK: - Source files

/// Cheap change detector for source files. Size+mtime is the same
/// signal the legacy Codex snapshot validation trusts; content hashing
/// would defeat the point of a metadata-priced scan.
enum StoreSourceFingerprint {
    static func make(byteSize: Int64, modifiedAt: Date?) -> String {
        let mtimeMs = modifiedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? -1
        return "\(byteSize)-\(mtimeMs)"
    }
}

struct StoreSourceFile: Sendable, Equatable {
    var id: Int64?
    let path: String
    let byteSize: Int64
    let modifiedAt: Date?
    let fingerprint: String
    var parseState: StoreParseState
    var lineCount: Int?
    var rejectedLineCount: Int?
    var importedAt: Date?
    let sessionRawId: String?
    let isSubagent: Bool
    let subagentParentRawId: String?
    let workflowRunId: String?

    init(
        id: Int64? = nil,
        path: String,
        byteSize: Int64,
        modifiedAt: Date?,
        fingerprint: String,
        parseState: StoreParseState = .pending,
        lineCount: Int? = nil,
        rejectedLineCount: Int? = nil,
        importedAt: Date? = nil,
        sessionRawId: String? = nil,
        isSubagent: Bool = false,
        subagentParentRawId: String? = nil,
        workflowRunId: String? = nil
    ) {
        self.id = id
        self.path = path
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.fingerprint = fingerprint
        self.parseState = parseState
        self.lineCount = lineCount
        self.rejectedLineCount = rejectedLineCount
        self.importedAt = importedAt
        self.sessionRawId = sessionRawId
        self.isSubagent = isSubagent
        self.subagentParentRawId = subagentParentRawId
        self.workflowRunId = workflowRunId
    }
}

// MARK: - Sessions

struct StoreSessionRow: Sendable, Equatable {
    let id: String
    let rawId: String
    var projectPath: String?
    var slug: String?
    var startTime: Date?
    var endTime: Date?
    var cachedTitle: String?
    var customTitle: String?
    var firstPrompt: String?
    var lastGitBranch: String?
    var visible: Bool
    var detailState: StoreDetailState
    /// Compact-continuation parent compaction point (Claude). Sessions
    /// sharing this value are one lineage; populated at detail import from
    /// the file's first `type=system` entry. Nil for standalone sessions.
    var logicalParentUuid: String?

    init(
        id: String,
        rawId: String,
        projectPath: String? = nil,
        slug: String? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        cachedTitle: String? = nil,
        customTitle: String? = nil,
        firstPrompt: String? = nil,
        lastGitBranch: String? = nil,
        visible: Bool = true,
        detailState: StoreDetailState = .metadata,
        logicalParentUuid: String? = nil
    ) {
        self.id = id
        self.rawId = rawId
        self.projectPath = projectPath
        self.slug = slug
        self.startTime = startTime
        self.endTime = endTime
        self.cachedTitle = cachedTitle
        self.customTitle = customTitle
        self.firstPrompt = firstPrompt
        self.lastGitBranch = lastGitBranch
        self.visible = visible
        self.detailState = detailState
        self.logicalParentUuid = logicalParentUuid
    }
}

/// Keyset cursor over (end_time DESC, id DESC). Stable under inserts.
struct StoreSessionPageCursor: Sendable, Equatable {
    let endTime: Date?
    let id: String
}

/// Sidebar visibility/title facts derived from a provider's own session
/// list (Codex `session_index.jsonl`). Unlike seed columns these are
/// re-derived on every metadata scan: `visible` always tracks the
/// index, a non-nil `cachedTitle` (thread name) replaces the stored one.
struct StoreSessionVisibilityUpdate: Sendable, Equatable {
    let sessionId: String
    let visible: Bool
    let cachedTitle: String?
}

struct StoreSessionPage: Sendable, Equatable {
    let rows: [StoreSessionRow]
    let nextCursor: StoreSessionPageCursor?
}

// MARK: - Requests

struct StoreRequestRow: Sendable, Equatable {
    let id: String
    let sessionId: String
    let timestamp: Date
    let model: String?
    let messageId: String?
    let parentUuid: String?
    let isSidechain: Bool
    let speed: String?
    let stopReason: String?
    let inputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationEphemeral1h: Int
    let cacheCreationEphemeral5m: Int
    var provisionalCostUSD: Double?
    var finalCostUSD: Double?
    var pricingVersion: Int?
    var costConfidence: String?

    init(
        id: String,
        sessionId: String,
        timestamp: Date,
        model: String?,
        messageId: String? = nil,
        parentUuid: String? = nil,
        isSidechain: Bool = false,
        speed: String? = nil,
        stopReason: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        cacheCreationEphemeral1h: Int = 0,
        cacheCreationEphemeral5m: Int = 0,
        provisionalCostUSD: Double? = nil,
        finalCostUSD: Double? = nil,
        pricingVersion: Int? = nil,
        costConfidence: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.model = model
        self.messageId = messageId
        self.parentUuid = parentUuid
        self.isSidechain = isSidechain
        self.speed = speed
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationEphemeral1h = cacheCreationEphemeral1h
        self.cacheCreationEphemeral5m = cacheCreationEphemeral5m
        self.provisionalCostUSD = provisionalCostUSD
        self.finalCostUSD = finalCostUSD
        self.pricingVersion = pricingVersion
        self.costConfidence = costConfidence
    }
}

/// One request's finalized cost columns (plan 2.6): written by the
/// per-session finalize pass once a scope completes, never per line —
/// long-context pricing needs the whole session's requests.
struct StoreRequestCostUpdate: Sendable, Equatable {
    let id: String
    let finalCostUSD: Double?
    let pricingVersion: Int
    let costConfidence: String
}

/// Additive correction to a turn's precomputed aggregate columns
/// (plan 3.8a): linked subagent contributions arrive after the parent
/// turn's row was streamed out, so the importer adjusts at unit end
/// instead of retaining the group in memory.
struct StoreTurnAggregateAdjustment: Sendable, Equatable {
    let sessionId: String
    let turnId: String
    let addTokens: TokenBreakdown
    let addCost: CostBreakdown
    let complete: Bool
}

// MARK: - Turns / steps

struct StoreTurnRow: Sendable, Equatable {
    let sessionId: String
    let id: String
    let ordinal: Int
    let startTime: Date?
    let endTime: Date?
    let promptPreview: String?
    let stepCount: Int
    let interrupted: Bool
    let sidechainOnly: Bool
    /// Full header breakdowns (4.1) — the Turn-header cells render from
    /// these without materializing steps. Subagent contributions
    /// included per `TurnAggregateColumns`.
    let aggTokens: TokenBreakdown
    let aggCost: CostBreakdown
    /// `TurnModelSummary.resolve` order: primary first, then extras.
    let aggModels: [String]
    let aggComplete: Bool

    var aggInputTokens: Int { aggTokens.inputTokens }
    var aggOutputTokens: Int { aggTokens.outputTokens }
    var aggCostUSD: Double? { aggCost.totalCostUSD }
}

struct StoreStepRow: Sendable, Equatable {
    let sessionId: String
    let turnId: String
    let uuid: String
    let ordinal: Int
    let kind: String
    let timestamp: Date?
    let model: String?
    let requestId: String?
    let agentId: String?
    let text: String?
    let thinkingText: String?
    let toolName: String?
    let toolUseId: String?
}

/// One raw line of a turn for scoped re-decode (4.1): where the bytes
/// live and whether the line produced a step row (`stepOrdinal == nil`
/// for merged meta lines). Source size/mtime feed the
/// `RawPayloadLocator` staleness fingerprint (4.2).
struct StoreTurnLineLocator: Sendable, Equatable {
    let uuid: String
    let stepOrdinal: Int?
    let sourcePath: String
    let byteOffset: Int64?
    let byteLength: Int64?
    let sourceByteSize: Int64
    let sourceModifiedAt: Date?
}

// MARK: - Links / diagnostics / locators / skills / search

struct StoreSubagentLinkRow: Sendable, Equatable {
    let sessionId: String
    let linkKind: String
    let agentId: String
    let parentToolUseId: String
    let parentAssistantUuid: String
    let parentMessageId: String?
    let linkDescription: String?
    let subagentType: String?
    let timestamp: String?
    let workflowTaskId: String?
    let workflowRunId: String?
    let workflowName: String?
    let workflowPhaseTitle: String?
    let workflowLabel: String?
    let workflowStatus: String?
    let workflowModel: String?
    let workflowAgentState: String?
    let workflowTelemetryTokens: Int?
    let workflowToolCalls: Int?
    let workflowDurationMs: Int?
}

struct StoreParentLinkRow: Sendable, Equatable {
    let sessionId: String
    let uuid: String
    let parentUuid: String?
}

struct StoreDiagnosticRow: Sendable, Equatable {
    let sessionId: String?
    let severity: String
    let category: String
    let lineNumber: Int?
    let byteOffset: Int64?
    let preview: String?
    let createdAt: Date
}

struct StoreRawLocatorRow: Sendable, Equatable {
    let sessionId: String
    let ownerKind: String
    let ownerId: String
    let byteOffset: Int64?
    let byteLength: Int64?
    let lineNumber: Int?
}

struct StoreSkillRow: Sendable, Equatable {
    let sessionId: String
    let turnId: String
    let skillName: String
}

// MARK: - Reports aggregates (4.4)

struct StoreProjectAggregate: Sendable, Equatable {
    let projectPath: String?
    let sessionCount: Int
    let costUSD: Double
}

/// (group, model) → cost rows for primary-model argmax folds; the
/// group key is a project path or a skill name depending on the query.
struct StoreGroupedModelCost: Sendable, Equatable {
    let groupKey: String
    let model: String
    let costUSD: Double
}

struct StoreModelUsageAggregate: Sendable, Equatable {
    let model: String
    let usageCount: Int
    let costUSD: Double
    let fastCount: Int
}

/// One local-time bucket of request activity. `bucketKey` is
/// `yyyy-MM-dd` (day) or `yyyy-MM-dd HH:00:00` (hour) in local time.
struct StoreUsageBucket: Sendable, Equatable {
    let bucketKey: String
    let costUSD: Double
    let requestCount: Int
    let tokenCount: Int
}

struct StoreBucketCount: Sendable, Equatable {
    let bucketKey: String
    let count: Int
}

struct StoreSkillAggregate: Sendable, Equatable {
    let skillName: String
    let invocationCount: Int
    let costUSD: Double
}

/// One session's cost over a range, with a human label, for `lupen top`.
struct StoreSessionCost: Sendable, Equatable {
    let sessionId: String
    let projectPath: String?
    let title: String?
    let requestCount: Int
    let costUSD: Double
}

/// Flat (timestamp, cost) request points — the hourly-efficiency
/// chart's input shape.
struct StoreRequestCostPoint: Sendable, Equatable {
    let timestamp: Date
    let costUSD: Double
}

struct StoreSearchEntry: Sendable, Equatable {
    let sessionId: String
    let turnId: String?
    let stepUuid: String?
    let kind: String
    let content: String
}

struct StoreSearchHit: Sendable, Equatable {
    let sessionId: String
    let turnId: String?
    let stepUuid: String?
    let kind: String
    let snippet: String
}

// MARK: - Aggregates

/// Whole-range usage totals over billable requests (synthetic and
/// model-less rows excluded — mirrors the legacy menu-bar filters).
struct StoreUsageTotals: Sendable, Equatable {
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let costUSD: Double

    /// The menu bar's token figure (legacy `totalContextTokens` sum).
    var contextTokens: Int {
        inputTokens + outputTokens + reasoningOutputTokens
            + cacheCreationInputTokens + cacheReadInputTokens
    }
}

struct StoreModelAggregate: Sendable, Equatable {
    let model: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

struct StoreSessionUsageAggregate: Sendable, Equatable {
    let sessionId: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationEphemeral1h: Int
    let cacheCreationEphemeral5m: Int
    let costUSD: Double
}

/// Sidebar cell metrics (plan 5.3): one row per session — request
/// count, context-token sum, cost (final-over-provisional), Codex
/// confidence tallies, and the subagent-link badge count.
struct StoreSessionListAggregate: Sendable, Equatable {
    let sessionId: String
    let requestCount: Int
    let contextTokens: Int
    let costUSD: Double
    let billableRequestCount: Int
    let unavailableRequestCount: Int
    var subagentLinkCount: Int = 0
    /// Distinct request models (plan 6.2): feeds the sidebar model
    /// filter's options and per-session matching on shells. Raw ids —
    /// the `<synthetic>` sentinel stays in (option builders exclude it,
    /// matching keeps legacy `requests.compactMap(\.model)` parity).
    var models: Set<String> = []
}

struct StoreSeverityCounts: Sendable, Equatable {
    let info: Int
    let warning: Int
    let error: Int
}

// MARK: - Import payload

/// Everything one source contributes, written in a single transaction by
/// `replaceSource` (delete-by-provenance + insert).
struct StoreSourcePayload: Sendable, Equatable {
    var sessions: [StoreSessionRow] = []
    var requests: [StoreRequestRow] = []
    var turns: [StoreTurnRow] = []
    var steps: [StoreStepRow] = []
    var subagentLinks: [StoreSubagentLinkRow] = []
    var parentLinks: [StoreParentLinkRow] = []
    var diagnostics: [StoreDiagnosticRow] = []
    var rawLocators: [StoreRawLocatorRow] = []
    var skills: [StoreSkillRow] = []
    var searchEntries: [StoreSearchEntry] = []

    init() {}
}
