import Foundation

/// The seven Step kinds; every JSONL row classifies into exactly one.
/// See `docs/CONVERSATION-MODEL.md` for the formal definition.
enum StepKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// user role + at least one text block, no tool_result. **Starts a Turn.**
    case prompt
    /// user role with only tool_result blocks; auto-injected response to the prior toolCall.
    case toolResult
    /// assistant + stop_reason=tool_use, no text blocks. Pure tool invocation.
    case toolCall
    /// assistant + stop_reason=tool_use, with text blocks. "I'll do X" alongside a tool call.
    case thought
    /// assistant + stop_reason=end_turn, with text blocks. **Ends a Turn.**
    case reply
    /// assistant + stop_reason is anything other than end_turn (max_tokens, stop_sequence, refusal, ...).
    case stop
    /// user role carrying Claude Code's Esc-interruption auto-message
    /// (`[Request interrupted by user]`) — explicit user halt of an in-flight
    /// task. Slots into the position the toolCall's response would have taken.
    case interruption
}

extension StepKind {
    var startsTurn: Bool { self == .prompt }

    var endsTurn: Bool { self == .reply || self == .stop }

    var isUserRole: Bool { self == .prompt || self == .toolResult || self == .interruption }

    var isAssistantRole: Bool {
        self == .toolCall || self == .thought || self == .reply || self == .stop
    }

    var shortLabel: String {
        switch self {
        case .prompt: return "User"
        case .toolResult: return "Tool Result"
        case .toolCall: return "Tool Call"
        case .thought: return "Thought"
        case .reply: return "Reply"
        case .stop: return "Stop"
        case .interruption: return "Interrupted"
        }
    }
}
