//
//  TurnAggregateColumns.swift
//  Lupen
//
//  Created by jaden on 2026/06/10.
//

import Foundation

/// Precomputed `turns` columns (plan 2.7, widened to the full
/// breakdowns in 4.1): aggregate tokens/cost including spawned subagent
/// contributions, plus the completeness flag. Reuses the exact outline
/// join — `SubAgentGraftIndex` and `Turn.aggregate*IncludingSubAgents` —
/// so the stored numbers can never diverge from what the legacy Turn
/// header renders. The Turn-header cells (tokens, cost, cache read /
/// write / TTL, reasoning, context window) render entirely from these
/// columns under SQLite-first; steps stay unmaterialized until expand.
///
/// Completeness (Rule 6): a top-level turn is complete only when every
/// link it spawned resolves to an ingested subagent turn; an orphan
/// link (child file missing or not yet imported) marks the turn
/// incomplete rather than silently undercounting. Sidechain turns sum
/// their own steps by definition and are always complete.
struct TurnAggregateColumns: Sendable, Equatable {
    let tokens: TokenBreakdown
    let cost: CostBreakdown
    /// `TurnModelSummary.resolve` order — primary first, then extras.
    /// The Model column renders this without steps (own steps only;
    /// subagent models never roll into the parent's model cell).
    let models: [String]
    let complete: Bool

    var inputTokens: Int { tokens.inputTokens }
    var outputTokens: Int { tokens.outputTokens }
    var costUSD: Double { cost.totalCostUSD }

    private static func modelList(for turn: Turn) -> [String] {
        let resolved = TurnModelSummary.resolve(for: turn)
        guard let primary = resolved.primary else { return [] }
        return [primary] + resolved.extras
    }

    static func make(turn: Turn, graft: SubAgentGraftIndex) -> TurnAggregateColumns {
        if turn.isSidechainOnly {
            return TurnAggregateColumns(
                tokens: turn.aggregateTokens,
                cost: turn.aggregateCost,
                models: modelList(for: turn),
                complete: true
            )
        }
        let tokens = turn.aggregateTokensIncludingSubAgents(
            linksByStepUuid: graft.linksByStepUuid,
            subAgentTurnsByAgentId: graft.subAgentTurnsByAgentId
        )
        let cost = turn.aggregateCostIncludingSubAgents(
            linksByStepUuid: graft.linksByStepUuid,
            subAgentTurnsByAgentId: graft.subAgentTurnsByAgentId
        )
        let linkedAgentIds = turn.steps
            .flatMap { graft.linksByStepUuid[$0.uuid] ?? [] }
            .map(\.agentId)
        let complete = linkedAgentIds.allSatisfy { graft.turn(forAgentId: $0) != nil }
        return TurnAggregateColumns(
            tokens: tokens,
            cost: cost,
            models: modelList(for: turn),
            complete: complete
        )
    }
}
