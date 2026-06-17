import Foundation

/// Sums the token usage of sub-agents spawned by a list of parent
/// Steps. Token-level twin of `SubAgentCostAggregator`; the same
/// contract applies — see that file for the full rationale.
///
/// Used by `Turn.aggregateTokensIncludingSubAgents(...)` and
/// `SkillGroupBuilder.SkillGroup.aggregateTokensIncludingSubAgents(...)`
/// to expose an "including sub-agents" token rollup for outline
/// headers — distinct from the bare-self `aggregateTokens` that the
/// rest of the app (and any future Turn-level reporting) relies on.
///
/// **Why a separate helper rather than folding sub-agent tokens into
/// `Turn.aggregateTokens` directly**: same as the Cost twin —
/// session-wide reporting traverses the underlying request/Step
/// graph (`AppStateStore.totalTokens(in:)` reads
/// `TokenCalculator.aggregateTokens(session.requests)`), so every
/// billable request — parent or sub-agent — already gets counted
/// once at the request level. If `Turn.aggregateTokens` ever folded
/// sub-agent tokens in, the request-level path would still be safe
/// (it doesn't read `aggregateTokens`), but any future Turn-level
/// reporter would silently double-count. This helper keeps the
/// "including" rollup as an opt-in derived view used only by the
/// outline UI.
///
/// **Recursion depth**: only direct (1-level *cross-Turn*)
/// sub-agents. Multi-level *within* a single sub-agent Turn is
/// covered for free because `subTurn.aggregateTokens` already sums
/// every Step in that Turn — see `SubAgentCostAggregator` doc for
/// the same caveat (current Claude Code emits nested sub-agent
/// dispatches as additional sidechain Steps inside the existing
/// sub-agent Turn rather than spawning a new file).
enum SubAgentTokenAggregator {

    /// Sum of every direct sub-agent Turn's `aggregateTokens` whose
    /// link is rooted in any of `steps`. Returns a zero
    /// `TokenBreakdown` if no link matches.
    static func subAgentTokens(
        forSteps steps: [Step],
        linksByStepUuid: [String: [SubAgentLinker.Link]],
        subAgentTurnsByAgentId: [String: Turn]
    ) -> TokenBreakdown {
        var subTokens: [TokenBreakdown] = []
        for step in steps {
            guard let links = linksByStepUuid[step.uuid] else { continue }
            for link in links {
                guard let subTurn = subAgentTurnsByAgentId[link.agentId] else { continue }
                subTokens.append(subTurn.aggregateTokens)
            }
        }
        return TokenCalculator.aggregateTokens(subTokens)
    }
}
