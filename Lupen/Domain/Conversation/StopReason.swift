import Foundation

/// Typed-enum view of the closed set of strings the Claude API writes to
/// an `assistant` entry's `message.stop_reason`.
///
/// The raw string is preserved verbatim on `Step.stopReason`. This enum is
/// the derived "known case" view used for Turn-boundary classification and
/// UI display. Unknown values stay as `nil` here; the raw string survives
/// on Step and the `unknownStopReason` diagnostic catches new values.
///
/// See `research-turn-model.md` §3 for the full taxonomy.
enum StopReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// Normal Turn end — assistant passes the mic back to the user.
    case endTurn = "end_turn"
    /// Turn continues with a tool_use block; awaits the next user-role tool_result.
    case toolUse = "tool_use"
    /// Output truncated at max_tokens. Treated as Turn end (mic released);
    /// usage-based cost is still accurate.
    case maxTokens = "max_tokens"
    /// Custom stop sequence matched. Terminates Turn.
    case stopSequence = "stop_sequence"
    /// Anthropic safety refusal. Terminates Turn.
    case refusal = "refusal"
    /// 2025 server-tool iteration pause. **Turn continues** — the next
    /// iteration's tool_result / assistant follows. Without this value the
    /// Turn would be misread as an early end (research-turn-model §2.6).
    case pauseTurn = "pause_turn"

    /// Build from a raw string. Returns nil for unknown values; we
    /// deliberately omit a `.unknown` case so switches stay exhaustive.
    /// No information is lost — the raw string stays on `Step.stopReason`.
    init?(rawString: String?) {
        guard let raw = rawString else { return nil }
        self.init(rawValue: raw)
    }

    /// Whether this stop_reason terminates the Turn (research-turn-model §3).
    ///
    /// - `.endTurn`, `.maxTokens`, `.stopSequence`, `.refusal` -> terminate
    /// - `.toolUse`, `.pauseTurn` -> continue
    var terminatesTurn: Bool {
        switch self {
        case .toolUse, .pauseTurn:
            return false
        case .endTurn, .maxTokens, .stopSequence, .refusal:
            return true
        }
    }
}
