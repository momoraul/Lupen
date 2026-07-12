import Foundation

/// Provider-aware audit result rendered by the Verify Costs window.
///
/// Computed by `AppStateStore.verifyActiveProviderUsage(completion:)` and
/// rendered by `VerifyCostsViewController`.
///
/// One row per session. The user reads the "Match" column ✓/✗; double-
/// clicking a problematic session drills down to per-line verdicts for
/// that session.
struct ProviderVerificationResult: Sendable {

    /// Immutable provenance for the source that produced this result. The
    /// provider is derived from it so a result cannot describe one source
    /// while rendering another provider's labels.
    let source: VerificationSourceIdentity
    var provider: ProviderKind { source.provider }
    let startedAt: Date
    let completedAt: Date
    let scanElapsed: TimeInterval
    let verifyElapsed: TimeInterval
    let filesScanned: Int

    /// Raw independent-calculation result. Drill-down uses its UsageLine
    /// array for per-line detail.
    let report: GroundTruth.Report

    /// Every divergence between view and truth.
    let divergences: [GroundTruthVerifier.Divergence]

    /// Set of session.ids in the current store. Fast "is it in the view?"
    /// check for the table.
    let viewSessionIds: Set<String>

    /// Sessions the verifier skipped because their index import hasn't
    /// completed (6.8) — surfaced as "Pending", never as mismatches.
    let pendingSessionIds: Set<String>

    /// Aggregate snapshot read by the same SQLite verification pass. Rollups
    /// consume this value instead of re-reading whichever store is active when
    /// the UI renders.
    let sessionUsageAggregatesById: [String: StoreSessionUsageAggregate]

    init(
        source: VerificationSourceIdentity,
        startedAt: Date,
        completedAt: Date,
        scanElapsed: TimeInterval,
        verifyElapsed: TimeInterval,
        filesScanned: Int,
        report: GroundTruth.Report,
        divergences: [GroundTruthVerifier.Divergence],
        viewSessionIds: Set<String>,
        pendingSessionIds: Set<String> = [],
        sessionUsageAggregatesById: [String: StoreSessionUsageAggregate] = [:]
    ) {
        precondition(source.provider == report.provider)
        self.source = source
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.scanElapsed = scanElapsed
        self.verifyElapsed = verifyElapsed
        self.filesScanned = filesScanned
        self.report = report
        self.divergences = divergences
        self.viewSessionIds = viewSessionIds
        self.pendingSessionIds = pendingSessionIds
        self.sessionUsageAggregatesById = sessionUsageAggregatesById
    }

    // MARK: - Per-session roll-up (for the primary table)

    var unknownPricingIssueCount: Int {
        report.issues.reduce(0) { count, issue in
            if case .unknownPricing = issue.kind { return count + 1 }
            return count
        }
    }

    var missingUsageIssueCount: Int {
        report.issues.reduce(0) { count, issue in
            if case .missingUsageEvent = issue.kind { return count + 1 }
            return count
        }
    }

    var sourceRejectedIssueCount: Int {
        report.issues.reduce(0) { count, issue in
            if case .sourceRejected = issue.kind { return count + 1 }
            return count
        }
    }

    var parserRejectedIssueCount: Int {
        report.issues.reduce(0) { count, issue in
            if case .parserRejectedLine = issue.kind { return count + 1 }
            return count
        }
    }

    /// One session row. `matchesView == true` means cost / tokens /
    /// coverage all passed.
    struct SessionRollup: Sendable, Hashable {
        let sessionId: String
        let rawLineCount: Int
        let dedupedLineCount: Int
        let viewRequestCount: Int?
        let truthCostUSD: Double
        let viewCostUSD: Double?
        let costDelta: Double?  // view - truth (nil if session missing in view)
        let truthInputTokens: Int
        let truthCacheReadInputTokens: Int
        let truthOutputTokens: Int
        let truthReasoningOutputTokens: Int
        let viewInputTokens: Int?
        let viewCacheReadInputTokens: Int?
        let viewOutputTokens: Int?
        let viewReasoningOutputTokens: Int?
        let hasUnknownPricing: Bool
        /// Findings that undermine the numbers (cost / token / coverage).
        let errorCount: Int
        /// Estimation/informational findings (unknown pricing, zero-usage).
        let warningCount: Int
        let inViewAndTruth: Bool
        /// Index import incomplete (6.8) — comparisons skipped; shown
        /// as "Pending" instead of ✓/⚠/✗.
        var indexPending: Bool = false

        /// Clean = no errors AND no warnings. Name kept for call sites that
        /// only care whether the row is fully green.
        var matchesView: Bool { errorCount == 0 && warningCount == 0 }
        /// Total findings of any severity (for the detail pane / Markdown).
        var divergenceCount: Int { errorCount + warningCount }
        /// Accounting drift present — the ✗ (red) state.
        var hasError: Bool { errorCount > 0 }
        /// Only warnings present — the ⚠ (orange) state.
        var hasWarningsOnly: Bool { errorCount == 0 && warningCount > 0 }

        var costMatchesExact: Bool {
            guard let delta = costDelta else { return false }
            return abs(delta) < 0.001
        }
    }

    func canonicalSessionID(_ sessionId: String) -> String {
        ProviderScopedID.normalize(sessionId, defaultProvider: report.provider)
    }

    /// Build per-session roll-ups across truth sessions, view-only sessions,
    /// and findings that could not produce either kind of session row.
    /// Sorted by cost descending, then session id for deterministic ties.
    /// View columns come from the captured SQLite aggregate snapshot — shell
    /// sessions carry no request rows to sum. This is intentionally pure: a
    /// source switch after completion cannot redirect the result to another
    /// live store.
    func rollups() -> [SessionRollup] {
        var rollups: [SessionRollup] = []

        // Tally findings per sessionId, split by severity, so a row can be
        // classified as clean / warning-only / error.
        var errorCountBySession: [String: Int] = [:]
        var warningCountBySession: [String: Int] = [:]
        var divergenceSessionIds: Set<String> = []
        for d in divergences {
            let sessionId = canonicalSessionID(d.sessionId)
            divergenceSessionIds.insert(sessionId)
            switch d.severity {
            case .error: errorCountBySession[sessionId, default: 0] += 1
            case .warning: warningCountBySession[sessionId, default: 0] += 1
            }
        }
        let unknownPricingSessionIds = Set(report.issues.compactMap { issue -> String? in
            if case .unknownPricing = issue.kind {
                return canonicalSessionID(issue.sessionId)
            }
            return nil
        })
        let canonicalPendingSessionIds = Set(pendingSessionIds.map(canonicalSessionID))
        var representedSessionIds: Set<String> = []

        // Build rollup for each truth session.
        for (sid, truth) in report.perSession {
            let scopedSid = canonicalSessionID(sid)
            let viewSessionId: String? = if viewSessionIds.contains(scopedSid) {
                scopedSid
            } else if viewSessionIds.contains(sid) {
                sid
            } else {
                nil
            }
            let rowSessionId = viewSessionId ?? scopedSid
            let aggregate = sessionUsageAggregatesById[rowSessionId]
                ?? sessionUsageAggregatesById[sid]
            let viewRequestCount = viewSessionId != nil ? (aggregate?.requestCount ?? 0) : nil
            let viewCost: Double? = viewSessionId != nil ? (aggregate?.costUSD ?? 0) : nil
            let costDelta = viewCost.map { $0 - truth.dedupedTotalCostUSD }
            let canonicalRowSessionId = canonicalSessionID(rowSessionId)
            let errorCount = errorCountBySession[canonicalRowSessionId, default: 0]
            let warningCount = warningCountBySession[canonicalRowSessionId, default: 0]
            rollups.append(SessionRollup(
                sessionId: rowSessionId,
                rawLineCount: truth.rawLineCount,
                dedupedLineCount: truth.dedupedLineCount,
                viewRequestCount: viewRequestCount,
                truthCostUSD: truth.dedupedTotalCostUSD,
                viewCostUSD: viewCost,
                costDelta: costDelta,
                truthInputTokens: truth.dedupedInputTokens,
                truthCacheReadInputTokens: truth.dedupedCacheReadInputTokens,
                truthOutputTokens: truth.dedupedOutputTokens,
                truthReasoningOutputTokens: truth.dedupedReasoningOutputTokens,
                viewInputTokens: viewSessionId != nil ? (aggregate?.inputTokens ?? 0) : nil,
                viewCacheReadInputTokens: viewSessionId != nil ? (aggregate?.cacheReadInputTokens ?? 0) : nil,
                viewOutputTokens: viewSessionId != nil ? (aggregate?.outputTokens ?? 0) : nil,
                viewReasoningOutputTokens: viewSessionId != nil ? (aggregate?.reasoningOutputTokens ?? 0) : nil,
                hasUnknownPricing: unknownPricingSessionIds.contains(scopedSid),
                errorCount: errorCount,
                warningCount: warningCount,
                inViewAndTruth: viewSessionId != nil,
                indexPending: canonicalPendingSessionIds.contains(canonicalRowSessionId)
            ))
            representedSessionIds.insert(scopedSid)
        }

        // Also surface sessions the view has but ground truth doesn't
        // (billable-line-free sessions — no usage records in JSONL).
        // These should be very rare; show them for completeness.
        for sessionId in viewSessionIds {
            let canonicalSessionId = canonicalSessionID(sessionId)
            guard representedSessionIds.insert(canonicalSessionId).inserted else {
                continue
            }
            let aggregate = sessionUsageAggregatesById[sessionId]
            let viewCost = aggregate?.costUSD ?? 0
            // Reverse coverage is represented explicitly by
            // `.sessionMissingInTruth`; keep one authoritative error count
            // instead of synthesizing a second finding from cost alone.
            let errorCount = errorCountBySession[canonicalSessionId, default: 0]
            let warningCount = warningCountBySession[canonicalSessionId, default: 0]
            rollups.append(SessionRollup(
                sessionId: sessionId,
                rawLineCount: 0,
                dedupedLineCount: 0,
                viewRequestCount: aggregate?.requestCount ?? 0,
                truthCostUSD: 0,
                viewCostUSD: viewCost,
                costDelta: viewCost,
                truthInputTokens: 0,
                truthCacheReadInputTokens: 0,
                truthOutputTokens: 0,
                truthReasoningOutputTokens: 0,
                viewInputTokens: aggregate?.inputTokens ?? 0,
                viewCacheReadInputTokens: aggregate?.cacheReadInputTokens ?? 0,
                viewOutputTokens: aggregate?.outputTokens ?? 0,
                viewReasoningOutputTokens: aggregate?.reasoningOutputTokens ?? 0,
                hasUnknownPricing: unknownPricingSessionIds.contains(canonicalSessionId),
                errorCount: errorCount,
                warningCount: warningCount,
                inViewAndTruth: false,
                indexPending: canonicalPendingSessionIds.contains(canonicalSessionId)
            ))
        }

        // A rejected source or parser issue may not yield a truth aggregate or
        // an indexed session. It still needs a visible row; otherwise the
        // summary could report a clean run while error divergences exist.
        for sessionId in divergenceSessionIds {
            guard representedSessionIds.insert(sessionId).inserted else { continue }
            rollups.append(SessionRollup(
                sessionId: sessionId,
                rawLineCount: 0,
                dedupedLineCount: 0,
                viewRequestCount: nil,
                truthCostUSD: 0,
                viewCostUSD: nil,
                costDelta: nil,
                truthInputTokens: 0,
                truthCacheReadInputTokens: 0,
                truthOutputTokens: 0,
                truthReasoningOutputTokens: 0,
                viewInputTokens: nil,
                viewCacheReadInputTokens: nil,
                viewOutputTokens: nil,
                viewReasoningOutputTokens: nil,
                hasUnknownPricing: unknownPricingSessionIds.contains(sessionId),
                errorCount: errorCountBySession[sessionId, default: 0],
                warningCount: warningCountBySession[sessionId, default: 0],
                inViewAndTruth: false,
                indexPending: canonicalPendingSessionIds.contains(sessionId)
            ))
        }

        // Cost-descending sort so the most expensive sessions read first.
        return rollups.sorted { a, b in
            if a.truthCostUSD != b.truthCostUSD {
                return a.truthCostUSD > b.truthCostUSD
            }
            return a.sessionId < b.sessionId
        }
    }
}

typealias VerifyCostsResult = ProviderVerificationResult
