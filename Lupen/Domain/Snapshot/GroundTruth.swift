import Foundation

/// Data types for the independent ground truth. See `GroundTruthCalculator`
/// for the design rationale.
enum GroundTruth {

    /// Severity of a verification finding. `error` means real accounting
    /// drift (cost / token / coverage); `warning` means an estimation
    /// limit or informational note (unknown pricing, zero-usage events)
    /// that does NOT undermine the numbers. The Verify Costs window and
    /// `lupen verify` use this to separate "must fix" from "FYI".
    enum Severity: Sendable, Equatable {
        case warning
        case error
    }

    /// Raw record for one line carrying a `usage` block.
    ///
    /// To check whether the view dropped this line, look up by `uuid`:
    ///   - if no Step in `store.turnsBySession[sessionId]` has a matching
    ///     `uuid`, the line is missing.
    ///   - intermediate streaming-snapshot lines are also excluded from
    ///     ground-truth dedup, so a uuid absent from `pickedUuids` is an
    ///     intentional drop (acceptable).
    struct UsageLine: Sendable, Equatable {
        let filePath: String
        let lineNumber: Int
        let sessionId: String
        let uuid: String
        let entryType: String
        let requestId: String?
        let messageId: String?
        let model: String?
        let stopReason: String?
        let isSidechain: Bool
        let inputTokens: Int
        let outputTokens: Int
        let reasoningOutputTokens: Int
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int
        let cacheCreationEphemeral1h: Int
        let cacheCreationEphemeral5m: Int
        let lineCostUSD: Double

        init(
            filePath: String,
            lineNumber: Int,
            sessionId: String,
            uuid: String,
            entryType: String,
            requestId: String?,
            messageId: String?,
            model: String?,
            stopReason: String?,
            isSidechain: Bool,
            inputTokens: Int,
            outputTokens: Int,
            reasoningOutputTokens: Int = 0,
            cacheCreationInputTokens: Int,
            cacheReadInputTokens: Int,
            cacheCreationEphemeral1h: Int,
            cacheCreationEphemeral5m: Int,
            lineCostUSD: Double
        ) {
            self.filePath = filePath
            self.lineNumber = lineNumber
            self.sessionId = sessionId
            self.uuid = uuid
            self.entryType = entryType
            self.requestId = requestId
            self.messageId = messageId
            self.model = model
            self.stopReason = stopReason
            self.isSidechain = isSidechain
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.reasoningOutputTokens = reasoningOutputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationEphemeral1h = cacheCreationEphemeral1h
            self.cacheCreationEphemeral5m = cacheCreationEphemeral5m
            self.lineCostUSD = lineCostUSD
        }
    }

    /// Final per-session totals after dedup.
    struct SessionGroundTruth: Sendable, Equatable {
        let sessionId: String
        /// Total usage-bearing lines, before dedup.
        let rawLineCount: Int
        /// Lines remaining after dedup = unique requestId count.
        let dedupedLineCount: Int
        let dedupedTotalCostUSD: Double
        let dedupedInputTokens: Int
        let dedupedOutputTokens: Int
        let dedupedReasoningOutputTokens: Int
        let dedupedCacheCreationInputTokens: Int
        let dedupedCacheReadInputTokens: Int
        let dedupedCacheCreationEphemeral1h: Int
        let dedupedCacheCreationEphemeral5m: Int
        /// uuids picked as "final" by ground-truth dedup. Informational
        /// only — when Assembler merges streaming snapshots by messageId,
        /// the view's Step.uuid becomes the first line's uuid, which can
        /// differ from this set (a uuid identity transform, not a silent
        /// drop). Real coverage is checked via `pickedRequestIds`; this
        /// field is for drilldown back to the original line.
        let pickedUuids: Set<String>
        /// Source of truth for the coverage invariant. requestId survives
        /// dedup as a stable identity (maps directly to ParsedRequest.id).
        /// Every value here must appear in `session.requests.map(\.id)`;
        /// any miss is a real silent drop.
        ///
        /// nil-coalesced: when JSONL lacks requestId (rare), uuid is used
        /// instead — matches `pickFinal`.
        let pickedRequestIds: Set<String>

        init(
            sessionId: String,
            rawLineCount: Int,
            dedupedLineCount: Int,
            dedupedTotalCostUSD: Double,
            dedupedInputTokens: Int,
            dedupedOutputTokens: Int,
            dedupedReasoningOutputTokens: Int = 0,
            dedupedCacheCreationInputTokens: Int,
            dedupedCacheReadInputTokens: Int,
            dedupedCacheCreationEphemeral1h: Int,
            dedupedCacheCreationEphemeral5m: Int,
            pickedUuids: Set<String>,
            pickedRequestIds: Set<String>
        ) {
            self.sessionId = sessionId
            self.rawLineCount = rawLineCount
            self.dedupedLineCount = dedupedLineCount
            self.dedupedTotalCostUSD = dedupedTotalCostUSD
            self.dedupedInputTokens = dedupedInputTokens
            self.dedupedOutputTokens = dedupedOutputTokens
            self.dedupedReasoningOutputTokens = dedupedReasoningOutputTokens
            self.dedupedCacheCreationInputTokens = dedupedCacheCreationInputTokens
            self.dedupedCacheReadInputTokens = dedupedCacheReadInputTokens
            self.dedupedCacheCreationEphemeral1h = dedupedCacheCreationEphemeral1h
            self.dedupedCacheCreationEphemeral5m = dedupedCacheCreationEphemeral5m
            self.pickedUuids = pickedUuids
            self.pickedRequestIds = pickedRequestIds
        }
    }

    struct ReportIssue: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case missingUsageEvent(lineNumber: Int)
            case unknownPricing(model: String)
            case sourceRejected(reason: String)
            case parserRejectedLine(category: String, lineNumber: Int, detail: String)
        }

        let sessionId: String
        let kind: Kind
    }

    struct Report: Sendable, Equatable {
        let provider: ProviderKind
        let usageLines: [UsageLine]
        let perSession: [String: SessionGroundTruth]
        let issues: [ReportIssue]

        init(
            provider: ProviderKind = .claudeCode,
            usageLines: [UsageLine],
            perSession: [String: SessionGroundTruth],
            issues: [ReportIssue] = []
        ) {
            self.provider = provider
            self.usageLines = usageLines
            self.perSession = perSession
            self.issues = issues
        }
    }
}
