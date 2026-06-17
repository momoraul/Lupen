import Foundation

/// Pure value type computing the data-source answers
/// `TurnOutlineViewController` would give to NSOutlineView for the
/// Phase B sub-agent graft. Extracted from the view controller so
/// the join logic can be unit-tested without an NSOutlineView /
/// run loop.
///
/// Two halves:
///
/// - **`subAgentTurnsByAgentId`** — every sub-agent (sidechain-only)
///   `Turn` keyed by its `agentId`. Sourced from the unfiltered turn
///   list so the filter that hides sidechain Turns from the top-level
///   outline list doesn't also hide them from the graft lookup.
///
/// - **`linksByStepUuid`** — for every visible (non-sidechain) Step
///   whose `toolCalls` include an `Agent` block whose id matches a
///   `SubAgentLinker.Link.parentToolUseId`, the matching links keyed
///   by parent Step uuid. Empty for steps that never spawned a
///   sub-agent. The `numberOfChildren(of:)` query reads this map.
///
/// The view controller calls `make(...)` once per `reloadTurns`
/// pass and stores the result in two private maps that back its
/// `numberOfChildrenOfItem` / `child:ofItem:` answers. The struct
/// itself is immutable; rebuild on every reload — there is no
/// incremental update path.
struct SubAgentGraftIndex: Sendable, Equatable {

    /// agentId → sub-agent's full Turn (sidechain root).
    let subAgentTurnsByAgentId: [String: Turn]

    /// Parent Step uuid → links spawned by that step's `Agent`
    /// tool_use blocks. Map key is the assistant Step's uuid (the
    /// caller of the `Agent` tool). Value preserves link order
    /// (matches the order toolCalls appeared in the assistant
    /// message), which is what NSOutlineView surfaces as child
    /// row order.
    let linksByStepUuid: [String: [SubAgentLinker.Link]]

    // MARK: - Build

    /// Fold the raw inputs into the two maps above. `visibleTurns`
    /// is the post-filter Turn list rendered at outline top level;
    /// `allTurns` includes the sidechain Turns the filter excluded.
    /// `links` is whatever `AppStateStore.subAgentLinks(in:)`
    /// returned for this session.
    static func make(
        visibleTurns: [Turn],
        allTurns: [Turn],
        links: [SubAgentLinker.Link]
    ) -> SubAgentGraftIndex {
        var turns: [String: Turn] = [:]
        for turn in allTurns where turn.isSidechainOnly {
            // Every step in a sub-agent Turn shares one agentId
            // (asserted in SubAgentOutlineGraftTests). Use the
            // first step's value as the canonical key.
            if let aid = turn.steps.first?.agentId {
                turns[aid] = turn
            }
        }
        guard !links.isEmpty else {
            return SubAgentGraftIndex(
                subAgentTurnsByAgentId: turns,
                linksByStepUuid: [:]
            )
        }
        var linksByToolUseId: [String: [SubAgentLinker.Link]] = [:]
        var seenAgentToolUseIds = Set<String>()
        for link in links {
            switch link.linkKind {
            case .agent:
                if seenAgentToolUseIds.insert(link.parentToolUseId).inserted {
                    linksByToolUseId[link.parentToolUseId, default: []].append(link)
                }
            case .workflow:
                linksByToolUseId[link.parentToolUseId, default: []].append(link)
            }
        }
        var byStep: [String: [SubAgentLinker.Link]] = [:]
        for turn in visibleTurns {
            for step in turn.steps {
                for call in step.toolCalls where call.name == "Agent" || call.name == "Workflow" {
                    if let matchingLinks = linksByToolUseId[call.id] {
                        byStep[step.uuid, default: []].append(contentsOf: matchingLinks)
                    }
                }
            }
        }
        return SubAgentGraftIndex(
            subAgentTurnsByAgentId: turns,
            linksByStepUuid: byStep
        )
    }

    // MARK: - Data-source queries (mirror NSOutlineView contract)

    /// Number of `.subAgent` children to surface under the given
    /// parent Step uuid. Returns 0 for steps that never spawned a
    /// sub-agent (which is the vast majority).
    func numberOfChildren(ofStepUuid uuid: String) -> Int {
        linksByStepUuid[uuid]?.count ?? 0
    }

    /// The link at `index` for the given parent Step uuid. `nil`
    /// when the step has no matching links or the index is out of
    /// range — caller is expected to have asked
    /// `numberOfChildren(ofStepUuid:)` first, but the bounds check
    /// is defensive against stale NSOutlineView reuse pools.
    func link(forStepUuid uuid: String, index: Int) -> SubAgentLinker.Link? {
        let links = linksByStepUuid[uuid] ?? []
        guard index >= 0, index < links.count else { return nil }
        return links[index]
    }

    /// The full sub-agent `Turn` an extracted link points at, or
    /// `nil` if the sub-agent file was never ingested (the orphan
    /// case `subagentLinkageOrphanLink` flags). UI fallback path
    /// when nil: render a placeholder and skip the expansion.
    func turn(forAgentId agentId: String) -> Turn? {
        subAgentTurnsByAgentId[agentId]
    }
}
