//
//  ConversationBlock.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import Foundation

/// Curation priority. To keep the view scannable, secondary/hidden blocks
/// render as a collapsed single line by default (the renderer's responsibility).
enum BlockTier: Sendable, Equatable {
    /// Always expanded — my prompt, the model's final reply, error/stop signals.
    case primary
    /// Collapsed single line by default — tool-call groups, thinking.
    case secondary
    /// Toggle/Raw only — system meta, etc. (currently excluded by the builder).
    case hidden
}

/// Conversation speaker role. Used by the renderer to pick gutter/color.
enum BlockRole: Sendable, Equatable {
    case user
    case assistant
    case system
    case subAgent
}

/// A single block drawn by the Conversation tab.
///
/// `ConversationStoryBuilder` curates a `Turn` into an array of these protocol
/// values, and the renderer registry (Phase B) builds a view per type.
/// Unregistered types fall back to `plainTextFallback`, so adding a new block
/// type is safe (fallback invariant — never a blank screen / crash).
protocol ConversationBlock: Sendable {
    var id: String { get }
    var tier: BlockTier { get }
    var role: BlockRole { get }
    /// Whether this block maps to the currently selected Step
    /// (Q1: draw the whole Turn but highlight the selected Step).
    var isHighlighted: Bool { get }
    /// Text shown as a plain fallback when no dedicated renderer is registered.
    var plainTextFallback: String { get }
}

extension ConversationBlock {
    var plainTextFallback: String { "[\(role)]" }
}

// MARK: - Concrete block types

/// My prompt (`.prompt`). Carries attachment / inline-image metadata.
struct UserPromptBlock: ConversationBlock, Equatable {
    let id: String
    let stepUuid: String
    let text: String?
    let attachments: [AttachmentRef]
    let inlineImageCount: Int
    /// If this is the synthetic prompt right after `/compact`, show
    /// "↻ Compact resume" instead of the body.
    let isCompactSummary: Bool
    let isHighlighted: Bool
    var tier: BlockTier { .primary }
    var role: BlockRole { .user }
    var plainTextFallback: String {
        if isCompactSummary { return "↻ Compact resume" }
        return text ?? "(empty prompt)"
    }
}

/// The model's reply body (text of `.reply`). Holds raw markdown; the renderer
/// splits blocks via `MarkdownParser` and draws with `AttributedString(markdown:)`.
struct AssistantTextBlock: ConversationBlock, Equatable {
    let id: String
    let stepUuid: String
    let markdown: String
    let model: String?
    let cost: CostBreakdown?
    let tokens: TokenBreakdown?
    let isHighlighted: Bool
    var tier: BlockTier { .primary }
    var role: BlockRole { .assistant }
    var plainTextFallback: String { markdown }
}

/// Extended thinking (`thinkingText`) or a pre-tool intermediate note (text of `.thought`).
struct ThinkingBlock: ConversationBlock, Equatable {
    let id: String
    let stepUuid: String
    let text: String
    let isHighlighted: Bool
    var tier: BlockTier { .secondary }
    var role: BlockRole { .assistant }
    var plainTextFallback: String { "[thinking] \(text)" }
}

/// A single tool call plus (if present) a summary of its result.
/// `ToolGroupBlock` groups consecutive same-kind calls.
struct ToolCallItem: Sendable, Equatable {
    let toolUseId: String
    let toolName: String
    let inputSummary: String
    let resultSummary: String?
    let isError: Bool
    let stepUuid: String
}

/// A group of consecutive same-kind tool calls — collapsed into one line like "Read · 3 ›".
struct ToolGroupBlock: ConversationBlock, Equatable {
    let id: String
    /// The group's (same-kind) tool name. e.g. "Read", "Bash".
    let toolName: String
    let calls: [ToolCallItem]
    let isHighlighted: Bool
    var tier: BlockTier { .secondary }
    var role: BlockRole { .assistant }
    var count: Int { calls.count }
    var plainTextFallback: String {
        if count == 1, let only = calls.first {
            return "\(toolName): \(only.inputSummary)"
        }
        return "\(toolName) ×\(count)"
    }
}

/// Why a Turn ended abnormally / specially. Used instead of "(no response available)".
enum StatusKind: Sendable, Equatable {
    /// User interrupted (`.interruption`).
    case interrupted
    /// Synthetic termination Claude Code injected on API failure (may carry a body message).
    case apiError(String?)
    /// Non-`end_turn` termination (max_tokens / refusal / custom stop, etc.).
    case stopped(String?)
    /// The reply was summarized/lost by the next turn's `/compact`.
    case compactedAway
    /// An incomplete (orphan) Turn that does not start with a prompt.
    case orphan

    /// One-line description shown to the user.
    var message: String {
        switch self {
        case .interrupted:
            return "✋ User interrupted this request"
        case .apiError(let body):
            if let body, !body.isEmpty { return "⚠ \(body)" }
            return "⚠ This turn ended with an API error"
        case .stopped(let reason):
            return "■ Response ended (\(reason ?? "unknown"))"
        case .compactedAway:
            return "✂ Response was compacted into the next turn"
        case .orphan:
            return "⚠ This turn started without a prompt"
        }
    }
}

struct StatusBlock: ConversationBlock, Equatable {
    let id: String
    let kind: StatusKind
    let isHighlighted: Bool
    var tier: BlockTier { .primary }
    var role: BlockRole { .system }
    var plainTextFallback: String { kind.message }
}
