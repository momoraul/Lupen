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

    let provider: ProviderKind
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

    init(
        provider: ProviderKind = .claudeCode,
        startedAt: Date,
        completedAt: Date,
        scanElapsed: TimeInterval,
        verifyElapsed: TimeInterval,
        filesScanned: Int,
        report: GroundTruth.Report,
        divergences: [GroundTruthVerifier.Divergence],
        viewSessionIds: Set<String>,
        pendingSessionIds: Set<String> = []
    ) {
        self.provider = provider
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.scanElapsed = scanElapsed
        self.verifyElapsed = verifyElapsed
        self.filesScanned = filesScanned
        self.report = report
        self.divergences = divergences
        self.viewSessionIds = viewSessionIds
        self.pendingSessionIds = pendingSessionIds
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
        let matchesView: Bool   // false if any divergence for this session
        let divergenceCount: Int
        let inViewAndTruth: Bool
        /// Index import incomplete (6.8) — comparisons skipped; shown
        /// as "Pending" instead of ✓/✗.
        var indexPending: Bool = false

        var costMatchesExact: Bool {
            guard let delta = costDelta else { return false }
            return abs(delta) < 0.001
        }
    }

    /// Build per-session roll-ups across all truth sessions plus any
    /// extra sessions present only in the view. Sorted by cost descending.
    /// View columns come from the SQLite index aggregates (plan 5.3) —
    /// shell sessions carry no request rows to sum.
    func rollups(withStore store: AppStateStore) -> [SessionRollup] {
        var rollups: [SessionRollup] = []

        let aggregatesBySessionId: [String: StoreSessionUsageAggregate] = {
            guard let sqlStore = store.sqliteConversationSource?.store,
                  let rows = try? sqlStore.sessionUsageAggregates() else { return [:] }
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0) })
        }()

        // Count divergences per sessionId across all kinds.
        var divergenceCountBySession: [String: Int] = [:]
        for d in divergences {
            divergenceCountBySession[d.sessionId, default: 0] += 1
        }
        let unknownPricingSessionIds = Set(report.issues.compactMap { issue -> String? in
            if case .unknownPricing = issue.kind { return issue.sessionId }
            return nil
        })

        // Build rollup for each truth session.
        for (sid, truth) in report.perSession {
            let scopedSid = ProviderScopedID.normalize(sid, defaultProvider: report.provider)
            let viewSession = store.sessions.first(where: { $0.id == sid || $0.id == scopedSid })
            let rowSessionId = viewSession?.id ?? scopedSid
            let aggregate = aggregatesBySessionId[rowSessionId] ?? aggregatesBySessionId[sid]
            let viewRequestCount = viewSession != nil ? (aggregate?.requestCount ?? 0) : nil
            let viewCost: Double? = viewSession != nil ? (aggregate?.costUSD ?? 0) : nil
            let costDelta = viewCost.map { $0 - truth.dedupedTotalCostUSD }
            let divCount = divergenceCountBySession[rowSessionId, default: 0]
                + (rowSessionId == sid ? 0 : divergenceCountBySession[sid, default: 0])
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
                viewInputTokens: viewSession != nil ? (aggregate?.inputTokens ?? 0) : nil,
                viewCacheReadInputTokens: viewSession != nil ? (aggregate?.cacheReadInputTokens ?? 0) : nil,
                viewOutputTokens: viewSession != nil ? (aggregate?.outputTokens ?? 0) : nil,
                viewReasoningOutputTokens: viewSession != nil ? (aggregate?.reasoningOutputTokens ?? 0) : nil,
                hasUnknownPricing: unknownPricingSessionIds.contains(sid) || unknownPricingSessionIds.contains(scopedSid),
                matchesView: divCount == 0,
                divergenceCount: divCount,
                inViewAndTruth: viewSession != nil,
                indexPending: pendingSessionIds.contains(rowSessionId)
                    || pendingSessionIds.contains(sid)
            ))
        }

        // Also surface sessions the view has but ground truth doesn't
        // (billable-line-free sessions — no usage records in JSONL).
        // These should be very rare; show them for completeness.
        let truthIds = Set(report.perSession.keys.flatMap { sid in
            [sid, ProviderScopedID.normalize(sid, defaultProvider: report.provider)]
        })
        for session in store.sessions where !truthIds.contains(session.id) {
            let aggregate = aggregatesBySessionId[session.id]
            let viewCost = aggregate?.costUSD ?? 0
            let divCount = divergenceCountBySession[session.id, default: 0]
            rollups.append(SessionRollup(
                sessionId: session.id,
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
                hasUnknownPricing: unknownPricingSessionIds.contains(session.id),
                matchesView: viewCost == 0 && divCount == 0,
                divergenceCount: divCount + (viewCost == 0 ? 0 : 1),
                inViewAndTruth: false,
                indexPending: pendingSessionIds.contains(session.id)
            ))
        }

        // Cost-descending sort so the most expensive sessions read first.
        return rollups.sorted { a, b in
            a.truthCostUSD > b.truthCostUSD
        }
    }
}

typealias VerifyCostsResult = ProviderVerificationResult
