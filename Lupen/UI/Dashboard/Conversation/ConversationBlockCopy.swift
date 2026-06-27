//
//  ConversationBlockCopy.swift
//  Lupen
//
//  Created by jaden on 2026/06/28.
//

import Foundation

/// Maps a curated `ConversationBlock` to the plain text the per-card Copy button
/// puts on the pasteboard (D-6). Distinct from `plainTextFallback` (a debug
/// rendering for unregistered blocks): this strips UI decoration so the copied
/// text is the clean content — the prompt, the markdown reply, the thinking, the
/// tool input/result, the status, or the folded activity summary.
///
/// Pure and UI-free, so the per-type mapping is unit-tested directly.
enum ConversationBlockCopy {

    static func plainText(for block: ConversationBlock) -> String {
        switch block {
        case let b as UserPromptBlock:
            if let text = b.text, !text.isEmpty { return text }
            return b.isCompactSummary ? "↻ Compact resume" : ""

        case let b as AssistantTextBlock:
            return b.markdown

        case let b as ThinkingBlock:
            return b.text

        case let b as ToolGroupBlock:
            return b.calls.map { call in
                var line = "\(call.toolName): \(call.inputSummary)"
                if let result = call.resultSummary, !result.isEmpty {
                    line += "\n→ \(result)"
                }
                return line
            }.joined(separator: "\n\n")

        case let b as StatusBlock:
            return b.kind.message

        case let b as ActivityGroupBlock:
            return b.summaryLines.joined(separator: "\n")

        default:
            return block.plainTextFallback
        }
    }
}
