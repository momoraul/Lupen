import Foundation

/// Verifies that the view (`AppStateStore.sessions` + `turnsBySession`)
/// agrees with the independent ground truth.
///
/// Every divergence is recorded as `.groundTruthDrift` in
/// `AppStateStore.diagnostics` and shown in the Diagnostics window —
/// observed automatically without user intervention.
///
/// ## Checks
///
/// Per session:
///   - cost: `sum(costsByRequestId[r.id])` == `dedupedTotalCostUSD` (within $0.001)
///   - tokens: input / output / cacheCreation / cacheRead / eph1h / eph5m
///   - requestCount: `session.requests.count` == `dedupedLineCount`
///
/// Coverage (per UsageLine):
///   - pickedUuid must appear in `turnsBySession[*].steps[*].uuid` or
///     `session.requests[*].parentUuid`. Missing means the view silently
///     dropped that billable line.
enum GroundTruthVerifier {

    /// One divergence. Human-readable detail is built via `humanDescription`
    /// and pushed into ParseDiagnostics.
    struct Divergence: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case costMismatch(viewUSD: Double, truthUSD: Double)
            case inputTokenMismatch(view: Int, truth: Int)
            case outputTokenMismatch(view: Int, truth: Int)
            case reasoningOutputTokenMismatch(view: Int, truth: Int)
            case cacheCreationInputMismatch(view: Int, truth: Int)
            case cacheReadMismatch(view: Int, truth: Int)
            case cacheCreation1hMismatch(view: Int, truth: Int)
            case cacheCreation5mMismatch(view: Int, truth: Int)
            case requestCountMismatch(view: Int, truth: Int)
            case missingPickedRequestId(requestId: String)
            case sessionMissingInView(sessionId: String)
            case missingUsageEvent(lineNumber: Int)
            case unknownPricing(model: String)
            case sourceRejected(reason: String)
            case parserRejectedLine(category: String, lineNumber: Int, detail: String)
        }
        let sessionId: String
        let kind: Kind

        var humanDescription: String {
            switch kind {
            case .costMismatch(let v, let t):
                return "session=\(sessionId) cost view=$\(format(v)) truth=$\(format(t)) delta=$\(format(v - t))"
            case .inputTokenMismatch(let v, let t):
                return "session=\(sessionId) inputTokens view=\(v) truth=\(t) delta=\(v - t)"
            case .outputTokenMismatch(let v, let t):
                return "session=\(sessionId) outputTokens view=\(v) truth=\(t) delta=\(v - t)"
            case .reasoningOutputTokenMismatch(let v, let t):
                return "session=\(sessionId) reasoningOutputTokens view=\(v) truth=\(t) delta=\(v - t)"
            case .cacheCreationInputMismatch(let v, let t):
                return "session=\(sessionId) cacheCreationInput view=\(v) truth=\(t) delta=\(v - t)"
            case .cacheReadMismatch(let v, let t):
                return "session=\(sessionId) cacheRead view=\(v) truth=\(t) delta=\(v - t)"
            case .cacheCreation1hMismatch(let v, let t):
                return "session=\(sessionId) cacheCreation1h view=\(v) truth=\(t) delta=\(v - t)"
            case .cacheCreation5mMismatch(let v, let t):
                return "session=\(sessionId) cacheCreation5m view=\(v) truth=\(t) delta=\(v - t)"
            case .requestCountMismatch(let v, let t):
                return "session=\(sessionId) requestCount view=\(v) truth=\(t) delta=\(v - t)"
            case .missingPickedRequestId(let rid):
                return "session=\(sessionId) missing billable requestId \(rid.prefix(12))…"
            case .sessionMissingInView(let sid):
                return "session=\(sid) absent from view"
            case .missingUsageEvent(let lineNumber):
                return "session=\(sessionId) token_count line \(lineNumber) has no usable token usage"
            case .unknownPricing(let model):
                return "session=\(sessionId) unknown pricing for model '\(model)'"
            case .sourceRejected(let reason):
                return "session=\(sessionId) source rejected: \(reason)"
            case .parserRejectedLine(let category, let lineNumber, let detail):
                return "session=\(sessionId) parser issue line \(lineNumber) category=\(category): \(detail)"
            }
        }

        private func format(_ x: Double) -> String {
            String(format: "%.6f", x)
        }
    }

    /// Per-session cost tolerance. Anything larger than this implies the
    /// view's cost calculation differs from the truth method, not float noise.
    static let costTolerance: Double = 0.001

    /// SQLite-first verification outcome (plan 6.8): divergences plus
    /// the sessions whose index import hasn't completed. Comparing a
    /// half-imported session against a fresh truth scan yields hundreds
    /// of "missing requestId" lines that mean "backfill in progress",
    /// not accounting drift — those sessions are reported separately so
    /// the UI shows them as pending instead of failing.
    struct SQLiteVerification: Sendable {
        let divergences: [Divergence]
        let pendingSessionIds: Set<String>
    }

    /// SQLite-first verification (plan 4.5): session presence,
    /// but the "view" side is the provider index — per-session request
    /// rows and aggregates instead of in-memory graphs (which are empty
    /// shells under the flag).
    static func verify(
        report: GroundTruth.Report,
        againstSQLite store: ProviderStore
    ) -> SQLiteVerification {
        var pending: Set<String> = []
        var out = report.issues.map { issue in
            Divergence(sessionId: issue.sessionId, kind: Self.kind(for: issue.kind))
        }

        let aggregatesBySession: [String: StoreSessionUsageAggregate] = {
            guard let aggregates = try? store.sessionUsageAggregates() else { return [:] }
            return Dictionary(uniqueKeysWithValues: aggregates.map { ($0.sessionId, $0) })
        }()

        for (sessionId, truth) in report.perSession {
            let scopedSessionId = ProviderScopedID.normalize(
                sessionId, defaultProvider: report.provider
            )
            let viewSessionId: String
            if aggregatesBySession[scopedSessionId] != nil
                || (try? store.session(id: scopedSessionId)) ?? nil != nil {
                viewSessionId = scopedSessionId
            } else if aggregatesBySession[sessionId] != nil
                || (try? store.session(id: sessionId)) ?? nil != nil {
                viewSessionId = sessionId
            } else {
                out.append(Divergence(
                    sessionId: sessionId,
                    kind: .sessionMissingInView(sessionId: sessionId)
                ))
                continue
            }

            // Backfill still owes this session detail rows — every
            // comparison below would just enumerate the gap (6.8).
            let shellState = ((try? store.session(id: viewSessionId)) ?? nil)?.detailState
            if shellState != .complete {
                pending.insert(viewSessionId)
                continue
            }

            let viewRequestIds = Set((try? store.requestIds(sessionId: viewSessionId)) ?? [])
            for rid in truth.pickedRequestIds where !viewRequestIds.contains(rid) {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .missingPickedRequestId(requestId: rid)
                ))
            }

            // A session with shells but zero imported requests compares
            // as all-zero sums — honest when truth also has none, loud
            // divergences otherwise (detail not imported yet).
            let aggregate = aggregatesBySession[viewSessionId]
            let viewRequestCount = aggregate?.requestCount ?? 0
            if viewRequestCount != truth.dedupedLineCount {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .requestCountMismatch(view: viewRequestCount, truth: truth.dedupedLineCount)
                ))
            }
            let viewCost = aggregate?.costUSD ?? 0
            if abs(viewCost - truth.dedupedTotalCostUSD) > Self.costTolerance {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .costMismatch(viewUSD: viewCost, truthUSD: truth.dedupedTotalCostUSD)
                ))
            }
            if (aggregate?.inputTokens ?? 0) != truth.dedupedInputTokens {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .inputTokenMismatch(view: aggregate?.inputTokens ?? 0, truth: truth.dedupedInputTokens)
                ))
            }
            if (aggregate?.outputTokens ?? 0) != truth.dedupedOutputTokens {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .outputTokenMismatch(view: aggregate?.outputTokens ?? 0, truth: truth.dedupedOutputTokens)
                ))
            }
            if (aggregate?.reasoningOutputTokens ?? 0) != truth.dedupedReasoningOutputTokens {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .reasoningOutputTokenMismatch(
                        view: aggregate?.reasoningOutputTokens ?? 0,
                        truth: truth.dedupedReasoningOutputTokens
                    )
                ))
            }
            if (aggregate?.cacheCreationInputTokens ?? 0) != truth.dedupedCacheCreationInputTokens {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .cacheCreationInputMismatch(
                        view: aggregate?.cacheCreationInputTokens ?? 0,
                        truth: truth.dedupedCacheCreationInputTokens
                    )
                ))
            }
            if (aggregate?.cacheReadInputTokens ?? 0) != truth.dedupedCacheReadInputTokens {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .cacheReadMismatch(
                        view: aggregate?.cacheReadInputTokens ?? 0,
                        truth: truth.dedupedCacheReadInputTokens
                    )
                ))
            }
            if (aggregate?.cacheCreationEphemeral1h ?? 0) != truth.dedupedCacheCreationEphemeral1h {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .cacheCreation1hMismatch(
                        view: aggregate?.cacheCreationEphemeral1h ?? 0,
                        truth: truth.dedupedCacheCreationEphemeral1h
                    )
                ))
            }
            if (aggregate?.cacheCreationEphemeral5m ?? 0) != truth.dedupedCacheCreationEphemeral5m {
                out.append(Divergence(
                    sessionId: viewSessionId,
                    kind: .cacheCreation5mMismatch(
                        view: aggregate?.cacheCreationEphemeral5m ?? 0,
                        truth: truth.dedupedCacheCreationEphemeral5m
                    )
                ))
            }
        }

        return SQLiteVerification(divergences: out, pendingSessionIds: pending)
    }

    private static func kind(for issue: GroundTruth.ReportIssue.Kind) -> Divergence.Kind {
        switch issue {
        case .missingUsageEvent(let lineNumber):
            return .missingUsageEvent(lineNumber: lineNumber)
        case .unknownPricing(let model):
            return .unknownPricing(model: model)
        case .sourceRejected(let reason):
            return .sourceRejected(reason: reason)
        case .parserRejectedLine(let category, let lineNumber, let detail):
            return .parserRejectedLine(category: category, lineNumber: lineNumber, detail: detail)
        }
    }
}
