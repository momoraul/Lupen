//
//  SessionCostFinalizer.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Phase 2.6 cost finalize pass. Runs once per completed session scope
/// — never per line — because long-context pricing needs every request
/// of the session (`CostCalculator.calculateCosts` two-pass: any
/// request pushing a model over its long-context threshold reprices
/// the model session-wide). Stamps `pricing_version` so a
/// `PricingTable.version` bump turns into a background recompute work
/// list (`sessionIdsWithStaleCosts`) instead of silent staleness, and
/// carries per-request `cost_confidence` through.
struct SessionCostFinalizer: Sendable {

    let writer: any ImportWriting

    /// Recomputes and writes final costs for one session. Returns the
    /// number of finalized request rows.
    @discardableResult
    func finalize(sessionId: String) throws -> Int {
        let rows = try writer.requests(inSession: sessionId)
        guard !rows.isEmpty else { return 0 }

        let costs = CostCalculator.calculateCosts(for: rows.map(Self.parsedRequest(from:)))
        let updates = rows.map { row -> StoreRequestCostUpdate in
            let cost = costs[row.id] ?? nil
            return StoreRequestCostUpdate(
                id: row.id,
                finalCostUSD: cost?.totalCostUSD,
                pricingVersion: PricingTable.version,
                costConfidence: CostConfidence.perRequest(model: row.model, cost: cost).rawValue
            )
        }
        try writer.applyRequestCostFinalization(updates)
        return updates.count
    }

    /// Rebuilds the calculator's input from a stored row. Only id /
    /// model / speed / tokens participate in cost math; identity fields
    /// are carried for completeness.
    private static func parsedRequest(from row: StoreRequestRow) -> ParsedRequest {
        let scoped = ProviderScopedID(value: row.sessionId)
        return ParsedRequest(
            id: row.id,
            messageId: row.messageId,
            sessionId: row.sessionId,
            provider: scoped?.provider ?? .claudeCode,
            rawSessionId: scoped?.rawSessionId ?? row.sessionId,
            model: row.model,
            timestamp: row.timestamp,
            parentUuid: row.parentUuid,
            isSidechain: row.isSidechain,
            speed: row.speed,
            stopReason: row.stopReason,
            tokens: TokenBreakdown(
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                reasoningOutputTokens: row.reasoningOutputTokens,
                cacheCreationInputTokens: row.cacheCreationInputTokens,
                cacheReadInputTokens: row.cacheReadInputTokens,
                cacheCreationEphemeral1h: row.cacheCreationEphemeral1h,
                cacheCreationEphemeral5m: row.cacheCreationEphemeral5m
            )
        )
    }
}
