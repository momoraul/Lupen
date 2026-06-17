//
//  TurnOutlineColumnConfiguration.swift
//  Lupen
//
//  Created by jaden on 2026-05-26.
//

import Foundation

struct TurnOutlineColumnDescriptor: Equatable, Sendable {
    let id: String
    let title: String
    let headerToolTip: String?
    let sortKey: String?
    let isVisible: Bool
}

enum TurnOutlineColumnConfiguration {
    static func descriptors(for provider: ProviderKind) -> [TurnOutlineColumnDescriptor] {
        switch provider {
        case .claudeCode:
            return [
                .init(id: "prompt", title: "Conversation", headerToolTip: nil, sortKey: "prompt", isVisible: true),
                .init(id: "time", title: "Started", headerToolTip: nil, sortKey: "time", isVisible: true),
                .init(id: "model", title: "Model", headerToolTip: "Model used for the request. Opus (premium), Sonnet (standard), Haiku (fast).", sortKey: "model", isVisible: true),
                .init(id: "cost", title: "Cost", headerToolTip: nil, sortKey: "cost", isVisible: true),
                .init(id: "cacheTTL", title: "TTL", headerToolTip: "Cache creation TTL — 5m (default, cheaper write) or 1h (premium, 2x write cost).", sortKey: nil, isVisible: true),
                .init(id: "contextWindow", title: "Ctx", headerToolTip: "Unavailable for Claude Code local data.", sortKey: "contextWindow", isVisible: false),
                .init(id: "tokens", title: "Tokens", headerToolTip: nil, sortKey: "tokens", isVisible: true),
                .init(id: "cacheRead", title: "CR", headerToolTip: "Cache Read", sortKey: "cacheRead", isVisible: true),
                .init(id: "cacheWrite", title: "CW", headerToolTip: "Cache Write", sortKey: "cacheWrite", isVisible: true),
                .init(id: "reasoning", title: "Reasoning", headerToolTip: "Reasoning output tokens.", sortKey: "reasoning", isVisible: false),
            ]
        case .codex:
            return [
                .init(id: "prompt", title: "Conversation", headerToolTip: nil, sortKey: "prompt", isVisible: true),
                .init(id: "time", title: "Started", headerToolTip: nil, sortKey: "time", isVisible: true),
                .init(id: "model", title: "Model", headerToolTip: "OpenAI model recorded in the local Codex rollout.", sortKey: "model", isVisible: true),
                .init(id: "cost", title: "Cost", headerToolTip: "Estimated from local Codex token counts and Lupen's pricing table. N/A means pricing is unavailable for at least one model.", sortKey: "cost", isVisible: true),
                .init(id: "tokens", title: "Tokens", headerToolTip: "Input + output tokens. Cached input and reasoning are shown separately.", sortKey: "tokens", isVisible: true),
                .init(id: "cacheRead", title: "Cached", headerToolTip: "Cached input tokens reported by Codex.", sortKey: "cacheRead", isVisible: true),
                .init(id: "contextWindow", title: "Ctx", headerToolTip: "Model context window tokens reported by Codex when present.", sortKey: "contextWindow", isVisible: true),
                .init(id: "cacheWrite", title: "CW", headerToolTip: "Unavailable for Codex local data.", sortKey: "cacheWrite", isVisible: false),
                .init(id: "cacheTTL", title: "TTL", headerToolTip: "Unavailable for Codex local data.", sortKey: nil, isVisible: false),
                .init(id: "reasoning", title: "Reasoning", headerToolTip: "Reasoning output tokens billed at the output-token rate.", sortKey: "reasoning", isVisible: true),
            ]
        }
    }

    static func descriptor(for id: String, provider: ProviderKind) -> TurnOutlineColumnDescriptor? {
        descriptors(for: provider).first { $0.id == id }
    }

    static func visibleIDs(for provider: ProviderKind) -> [String] {
        descriptors(for: provider)
            .filter(\.isVisible)
            .map(\.id)
    }

    static func isSortKeyVisible(_ sortKey: String, provider: ProviderKind) -> Bool {
        descriptors(for: provider).contains { descriptor in
            descriptor.isVisible && descriptor.sortKey == sortKey
        }
    }
}
