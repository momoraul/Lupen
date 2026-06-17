import AppKit

/// UI display style per StepKind — role icon, color, text.
///
/// Concept: prompt = human, all other assistant kinds = AI (sparkle).
/// Per-kind distinction is conveyed via color.
enum StepKindStyle {

    /// Prompt uses `bubble.left.fill` (user's speech / message) rather than
    /// `person.crop.circle.fill` (identity) to match the "Turn = exchange of
    /// messages" conceptual model. Thought moves to `brain` so the bubble
    /// metaphor stays exclusive to user prompts.
    static func roleSymbol(for kind: StepKind) -> String {
        switch kind {
        case .prompt: return "bubble.left.fill"
        case .thought: return "brain"
        case .toolCall: return "wrench.adjustable.fill"
        case .toolResult: return "arrow.turn.down.right"
        case .reply: return "checkmark.bubble.fill"
        case .stop: return "exclamationmark.octagon.fill"
        case .interruption: return "hand.raised.fill"
        }
    }

    /// Role icon tint color.
    ///
    /// **Monochrome-first principle** (Apple HIG "deference"): Mail / Notes /
    /// Xcode Issue Navigator keep list rows mostly monochromatic and reserve
    /// color for **meaning signals**. Six colors at once in a single Turn
    /// turns a "quiet data app" into a rainbow.
    ///
    /// - Regular Step (thought/toolCall/toolResult): grayscale
    /// - Boundary Step (prompt/reply): prompt = labelColor, reply = green
    ///   (Turn entry / exit point signal — limited color use, like Mail's
    ///   read/unread)
    /// - Signal Step (stop/interruption): real warning — color preserved
    static func roleTint(for kind: StepKind) -> NSColor {
        switch kind {
        case .prompt: return .labelColor               // entry point — strong tone
        case .reply: return .systemGreen               // exit point — "completed" signal
        case .thought: return .secondaryLabelColor     // quiet
        case .toolCall: return .secondaryLabelColor    // quiet
        case .toolResult: return .tertiaryLabelColor   // quietest (subordinate to toolCall)
        case .stop: return .systemOrange               // real signal — preserved
        case .interruption: return .systemRed          // real signal — preserved
        }
    }

    /// Short text label — for accessibility / tooltip / debug.
    static func label(for kind: StepKind) -> String {
        switch kind {
        case .prompt: return "Prompt"
        case .toolCall: return "Tool"
        case .thought: return "Thought"
        case .toolResult: return "Result"
        case .reply: return "Reply"
        case .stop: return "Stop"
        case .interruption: return "Interrupted"
        }
    }

    /// Step text color.
    ///
    /// **Apple Mail "subject bold + meta dim" pattern**: a Turn's entry/exit
    /// points (prompt / reply) are emphasized with `.labelColor`, while the
    /// intermediate execution trace (thought / toolCall / toolResult) is
    /// downtoned with `.secondaryLabelColor`. Inside an expanded Turn the
    /// "I asked → here is the answer" start-end pair surfaces as a scan
    /// anchor, and the execution flow between them recedes as subordinate.
    static func textColor(for kind: StepKind) -> NSColor {
        switch kind {
        case .prompt: return .labelColor               // entry point — strong
        case .reply: return .labelColor                // exit point — strong
        case .thought: return .secondaryLabelColor     // downtoned
        case .toolCall: return .secondaryLabelColor    // downtoned
        case .toolResult: return .secondaryLabelColor  // downtoned
        case .stop: return .labelColor
        case .interruption: return .systemRed
        }
    }

    static func displayName(forToolName name: String) -> String {
        switch name {
        case "exec_command", "shell_command":
            return "Bash"
        case "read_file":
            return "Read"
        case "write_file", "apply_diff", "apply_patch":
            return "Edit"
        case "read_dir", "list_dir":
            return "Glob"
        case "spawn_agent", "close_agent", "wait_agent":
            return "Agent"
        case "patch_apply_end":
            return "Patch"
        case "mcp_tool_call_end":
            return "MCP Tool"
        default:
            return name.isEmpty ? "Tool" : name
        }
    }
}
