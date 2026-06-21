//
//  ConversationStoryBuilder.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import Foundation

/// `Turn`을 Conversation 탭이 그릴 큐레이션된 `[ConversationBlock]`으로
/// 변환하는 **순수 함수**(UI 의존 없음 → 단위 테스트 대상).
///
/// 규칙(3-Tier 큐레이션):
/// - `.prompt` → `UserPromptBlock`(primary)
/// - `.reply` 텍스트 → `AssistantTextBlock`(primary), `thinkingText` → `ThinkingBlock`(secondary)
/// - `.thought` 텍스트/`thinkingText` → `ThinkingBlock`(secondary), 도구는 묶음으로
/// - `.toolCall`/`.thought`의 도구 호출 → 연속 동종이면 하나의 `ToolGroupBlock`으로 병합,
///   대응 `.toolResult`(`toolUseId` 매칭)를 결과 요약으로 흡수
/// - `.stop`(합성 API 오류) → `StatusBlock(.apiError)`, 그 외 `.stop` → `.stopped`
/// - `.interruption` → `StatusBlock(.interrupted)`
/// - `isSystemInjected` Step은 제외(Phase D에서 토글 노출 예정)
/// - Turn 레벨: `wasCompactedAway` → `.compactedAway` 배너, 고아 Turn → `.orphan` 배너
///
/// `highlight`로 전달된 stepUuid에 해당하는 블록은 `isHighlighted == true`
/// (Q1: Turn 전체를 그리되 선택 Step만 강조).
enum ConversationStoryBuilder {

    static func build(
        turn: Turn,
        neighbor: Turn? = nil,
        highlight highlightStepUuid: String? = nil
    ) -> [ConversationBlock] {
        var blocks: [ConversationBlock] = []
        func isHL(_ uuid: String) -> Bool { highlightStepUuid == uuid }

        // toolResult를 toolUseId로 인덱싱(도구 호출과 병합용).
        var resultsByToolUseId: [String: ToolResultInfo] = [:]
        for step in turn.steps where step.kind == .toolResult {
            if let tr = step.toolResult {
                resultsByToolUseId[tr.toolUseId] = tr
            }
        }

        // 연속 동종 도구 묶음 상태.
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
                // 텍스트 없는 reply(usage-only)는 블록을 만들지 않는다.

            case .thought:
                // 도구 사용 전 중간 설명/사고는 secondary. 텍스트가 나오면
                // 도구 묶음이 끊기므로 먼저 flush.
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
                continue // 도구 호출 블록에 병합됨

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

        // Turn 레벨 상태 배너.
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
