//
//  ConversationStoryBuilder.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import Foundation

/// Pure function that converts a `Turn` into the curated `[ConversationBlock]`
/// the Conversation tab draws (no UI dependency → unit-testable).
///
/// Rules (3-tier curation):
/// - `.prompt` → `UserPromptBlock` (primary)
/// - `.reply` text → `AssistantTextBlock` (primary); `thinkingText` → `ThinkingBlock` (secondary)
/// - `.thought` text / `thinkingText` → `ThinkingBlock` (secondary); tools become a group
/// - `.toolCall`/`.thought` tool calls → consecutive same-kind calls merge into one
///   `ToolGroupBlock`, absorbing the matching `.toolResult` (`toolUseId` match) as a result summary
/// - `.stop` (synthetic API error) → `StatusBlock(.apiError)`; other `.stop` → `.stopped`
/// - `.interruption` → `StatusBlock(.interrupted)`
/// - `isSystemInjected` steps are excluded (toggle exposure planned in Phase D)
/// - Turn level: `wasCompactedAway` → `.compactedAway` banner; orphan Turn → `.orphan` banner
///
/// A block whose stepUuid matches the passed `highlight` gets `isHighlighted == true`
/// (Q1: draw the whole Turn but highlight only the selected Step).
enum ConversationStoryBuilder {

    static func build(
        turn: Turn,
        neighbor: Turn? = nil,
        highlight highlightStepUuid: String? = nil
    ) -> [ConversationBlock] {
        var blocks: [ConversationBlock] = []
        func isHL(_ uuid: String) -> Bool { highlightStepUuid == uuid }

        // Index toolResult by toolUseId (for merging with tool calls).
        var resultsByToolUseId: [String: ToolResultInfo] = [:]
        for step in turn.steps where step.kind == .toolResult {
            if let tr = step.toolResult {
                resultsByToolUseId[tr.toolUseId] = tr
            }
        }

        // State for grouping consecutive same-kind tool calls.
        var run: [ToolCallItem] = []
        var runToolName: String?
        var runAnchorUuid: String?
        var runHighlighted = false

        func flushRun() {
            defer { run = []; runToolName = nil; runAnchorUuid = nil; runHighlighted = false }
            guard !run.isEmpty, let name = runToolName, let anchor = runAnchorUuid else { return }
            blocks.append(ToolGroupBlock(
                id: "tg:\(anchor):\(name)",
                toolName: name,
                calls: run,
                isHighlighted: runHighlighted
            ))
        }

        func appendToolCalls(_ step: Step) {
            for call in step.toolCalls {
                if let current = runToolName, current != call.name {
                    flushRun()
                }
                if runToolName == nil { runAnchorUuid = step.uuid }
                runToolName = call.name
                let result = resultsByToolUseId[call.id]
                run.append(ToolCallItem(
                    toolUseId: call.id,
                    toolName: call.name,
                    inputSummary: call.abbreviatedInput(),
                    resultSummary: result?.abbreviatedContent(),
                    isError: result?.isError ?? false,
                    stepUuid: step.uuid
                ))
                if isHL(step.uuid) { runHighlighted = true }
            }
        }

        for step in turn.steps {
            if step.isSystemInjected { continue }
            switch step.kind {
            case .prompt:
                flushRun()
                blocks.append(UserPromptBlock(
                    id: "up:\(step.uuid)",
                    stepUuid: step.uuid,
                    text: step.text,
                    attachments: step.attachments,
                    inlineImageCount: step.images.count,
                    isCompactSummary: step.isCompactSummary,
                    isHighlighted: isHL(step.uuid)
                ))

            case .reply:
                flushRun()
                if let thinking = step.thinkingText, !thinking.isEmpty {
                    blocks.append(ThinkingBlock(
                        id: "th:\(step.uuid)", stepUuid: step.uuid,
                        text: thinking, isHighlighted: isHL(step.uuid)
                    ))
                }
                if let text = step.text, !text.isEmpty {
                    blocks.append(AssistantTextBlock(
                        id: "at:\(step.uuid)", stepUuid: step.uuid, markdown: text,
                        model: step.model, cost: step.cost, tokens: step.tokens,
                        isHighlighted: isHL(step.uuid)
                    ))
                }
                // A reply with no text (usage-only) produces no block.

            case .thought:
                // Pre-tool intermediate note/thinking is secondary. Emitted text
                // breaks the tool group, so flush first.
                if let text = step.text, !text.isEmpty {
                    flushRun()
                    blocks.append(ThinkingBlock(
                        id: "th:\(step.uuid)", stepUuid: step.uuid,
                        text: text, isHighlighted: isHL(step.uuid)
                    ))
                }
                if let thinking = step.thinkingText, !thinking.isEmpty {
                    flushRun()
                    blocks.append(ThinkingBlock(
                        id: "thx:\(step.uuid)", stepUuid: step.uuid,
                        text: thinking, isHighlighted: isHL(step.uuid)
                    ))
                }
                appendToolCalls(step)

            case .toolCall:
                appendToolCalls(step)

            case .toolResult:
                continue // merged into the tool-call block

            case .stop:
                flushRun()
                if step.isSyntheticApiError {
                    blocks.append(StatusBlock(
                        id: "st:\(step.uuid)", kind: .apiError(step.text),
                        isHighlighted: isHL(step.uuid)
                    ))
                } else {
                    blocks.append(StatusBlock(
                        id: "st:\(step.uuid)", kind: .stopped(step.stopReason),
                        isHighlighted: isHL(step.uuid)
                    ))
                }

            case .interruption:
                flushRun()
                blocks.append(StatusBlock(
                    id: "st:\(step.uuid)", kind: .interrupted,
                    isHighlighted: isHL(step.uuid)
                ))
            }
        }
        flushRun()

        // Turn-level status banner.
        if turn.wasCompactedAway(nextTurnInSession: neighbor) {
            blocks.append(StatusBlock(
                id: "st:compacted:\(turn.id)", kind: .compactedAway, isHighlighted: false
            ))
        } else if turn.isOrphan, !blocks.contains(where: { $0 is UserPromptBlock }) {
            blocks.insert(StatusBlock(
                id: "st:orphan:\(turn.id)", kind: .orphan, isHighlighted: false
            ), at: 0)
        }

        return blocks
    }
}
