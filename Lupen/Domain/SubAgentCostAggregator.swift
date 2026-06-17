import Foundation

/// Sums the costs of sub-agents spawned by a list of parent Steps.
///
/// Used by `Turn.aggregateCostIncludingSubAgents(...)` and
/// `SkillGroupBuilder.SkillGroup.aggregateCostIncludingSubAgents(...)`
/// to expose an "including sub-agents" cost rollup for outline
/// headers — distinct from the bare-self `aggregateCost` that powers
/// session-wide reporting (see `AppStateStore.subAgentTotalCost(in:)`
/// for the inverse view: sub-agents only).
///
/// **Why a separate helper rather than folding sub-agent cost into
/// `Turn.aggregateCost` directly**: session-wide reporting traverses
/// the underlying request/Step graph, not Turn-level rollups:
///   - `CostAnalyzer.byProject` reads from `costsByRequestId` — every
///     billable request (parent or sub-agent) is counted once at the
///     request level.
///   - `CostAnalyzer.bySkill` filters Turns by `/skill` prompt
///     extraction; sub-agent Turns don't carry a slash-command
///     prompt, so they naturally don't match (the dedup is by-filter
///     rather than by-design, but the net effect is correct).
/// If `Turn.aggregateCost` ever folded sub-agent cost in, the byProject
/// path would still be safe (it doesn't read aggregateCost), but any
/// future Turn-level reporter would silently double-count: each
/// sub-agent Turn already contributes its own aggregateCost as a
/// separate Turn in `turnsBySession`. This helper keeps the
/// "including" rollup as an opt-in derived view that only the outline
/// UI uses, preserving the safe Turn-level invariant for any future
/// reporting reader.
///
/// Lookup maps come from the parent session's `SubAgentGraftIndex`
/// (or its UI-side mirror in `TurnOutlineViewController`):
///   - `linksByStepUuid` — parent Step uuid → `SubAgentLinker.Link`s
///     spawned by that step's `Agent` tool_use blocks.
///   - `subAgentTurnsByAgentId` — `agentId` → the sub-agent's full
///     Turn (sidechain root).
///
/// Missing entries are silently skipped: a link without a matching
/// sub-agent Turn (mid-parse, dropped fixtures, etc.) contributes
/// nothing rather than throwing. The rollup is best-effort.
///
/// **Recursion depth**: only direct (1-level *cross-Turn*) sub-agents
/// are summed. The "1-level" caveat refers strictly to crossing Turn
/// boundaries — multi-level coverage *within* a single sub-agent
/// Turn comes for free because `subTurn.aggregateCost` already sums
/// every step in that Turn (empirically — current CC emits any nested
/// sub-agent calls as additional sidechain Steps inside the existing
/// sub-agent Turn rather than spawning a new file; no production
/// code enforces this, so it could change. `FileDiscovery` only
/// walks top-level `subagents/` directories, so a hypothetical
/// nested file would be invisible to discovery anyway). True
/// cross-file nested sub-agents (parent → sub-agent file →
/// sub-sub-agent file) would under-count here and need a recursive
/// walk across graft indexes — out of scope for the current rollup.
enum SubAgentCostAggregator {

    /// Sum of every direct sub-agent Turn spawned by any of the
    /// `steps`. Returns a zero CostBreakdown if no link matches.
    static func subAgentCost(
        forSteps steps: [Step],
        linksByStepUuid: [String: [SubAgentLinker.Link]],
        subAgentTurnsByAgentId: [String: Turn]
    ) -> CostBreakdown {
        var subCosts: [CostBreakdown?] = []
        for step in steps {
            guard let links = linksByStepUuid[step.uuid] else { continue }
            for link in links {
                guard let subTurn = subAgentTurnsByAgentId[link.agentId] else { continue }
                subCosts.append(subTurn.aggregateCost)
            }
        }
        return TokenCalculator.aggregateCosts(subCosts)
    }
}
