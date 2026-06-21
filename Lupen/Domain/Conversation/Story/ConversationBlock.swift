//
//  ConversationBlock.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import Foundation

/// 큐레이션 우선순위. 한눈에 훑게 하기 위해 secondary/hidden은 기본적으로
/// 접힌 한 줄로 렌더된다(렌더러의 책임).
enum BlockTier: Sendable, Equatable {
    /// 항상 펼침 — 내 프롬프트, 모델 최종 답변, 오류/중단 신호.
    case primary
    /// 기본 접힘 한 줄 — 도구 호출 묶음, 사고.
    case secondary
    /// 토글/Raw로만 — 시스템 메타 등(현재는 빌더에서 제외).
    case hidden
}

/// 대화 화자 역할. 렌더러가 거터/색을 정하는 데 쓴다.
enum BlockRole: Sendable, Equatable {
    case user
    case assistant
    case system
    case subAgent
}

/// Conversation 탭이 그리는 한 블록.
///
/// `ConversationStoryBuilder`가 `Turn`을 이 프로토콜 값들의 배열로
/// 큐레이션하고, 렌더러 레지스트리(Phase B)가 타입별로 뷰를 만든다.
/// 미등록 타입은 `plainTextFallback`으로 폴백하므로 새 블록 타입 추가가
/// 안전하다(폴백 불변식 — 절대 빈 화면/크래시 없음).
protocol ConversationBlock: Sendable {
    var id: String { get }
    var tier: BlockTier { get }
    var role: BlockRole { get }
    /// 현재 선택된 Step에 해당하는 블록인지(Q1: Turn 전체를 그리되 선택 Step 강조).
    var isHighlighted: Bool { get }
    /// 전용 렌더러가 없을 때(미등록) 평문으로라도 보여줄 텍스트.
    var plainTextFallback: String { get }
}

extension ConversationBlock {
    var plainTextFallback: String { "[\(role)]" }
}

// MARK: - 구체 블록 타입

/// 내 프롬프트(`.prompt`). 첨부/인라인 이미지 메타를 함께 들고 온다.
struct UserPromptBlock: ConversationBlock, Equatable {
    let id: String
    let stepUuid: String
    let text: String?
    let attachments: [AttachmentRef]
    let inlineImageCount: Int
    /// `/compact` 직후의 합성 프롬프트면 본문 대신 "↻ Compact resume" 표시.
    let isCompactSummary: Bool
    let isHighlighted: Bool
    var tier: BlockTier { .primary }
    var role: BlockRole { .user }
    var plainTextFallback: String {
        if isCompactSummary { return "↻ Compact resume" }
        return text ?? "(빈 프롬프트)"
    }
}

/// 모델의 본문 답변(`.reply`의 텍스트). 마크다운 원문을 담고, 렌더러가
/// `MarkdownParser`로 블록 분리 + `AttributedString(markdown:)`로 그린다.
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

/// 확장 사고(`thinkingText`) 또는 도구 사용 전 중간 설명(`.thought`의 텍스트).
struct ThinkingBlock: ConversationBlock, Equatable {
    let id: String
    let stepUuid: String
    let text: String
    let isHighlighted: Bool
    var tier: BlockTier { .secondary }
    var role: BlockRole { .assistant }
    var plainTextFallback: String { "💭 \(text)" }
}

/// 한 도구 호출 + (있으면) 그 결과의 요약. `ToolGroupBlock`이 동종 호출을 묶는다.
struct ToolCallItem: Sendable, Equatable {
    let toolUseId: String
    let toolName: String
    let inputSummary: String
    let resultSummary: String?
    let isError: Bool
    let stepUuid: String
}

/// 연속된 동종 도구 호출 묶음 — "읽기 파일 3개 ›"처럼 한 줄로 접어 보여준다.
struct ToolGroupBlock: ConversationBlock, Equatable {
    let id: String
    /// 묶음의 도구명(동종). 예: "Read", "Bash".
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

/// Turn이 비정상/특수 종료된 사유. "(no response available)" 대신 이 배너를 쓴다.
enum StatusKind: Sendable, Equatable {
    /// 사용자가 중단(`.interruption`).
    case interrupted
    /// Claude Code가 API 실패에 주입한 합성 종료(본문 메시지 포함 가능).
    case apiError(String?)
    /// `end_turn`이 아닌 종료(max_tokens / refusal / custom stop 등).
    case stopped(String?)
    /// 다음 turn의 `/compact`로 응답이 요약·소실됨.
    case compactedAway
    /// 프롬프트로 시작하지 않는 불완전(고아) Turn.
    case orphan

    /// 사용자에게 보여줄 한 줄 설명.
    var message: String {
        switch self {
        case .interrupted:
            return "✋ 사용자가 이 요청을 중단했습니다"
        case .apiError(let body):
            if let body, !body.isEmpty { return "⚠ \(body)" }
            return "⚠ 이 Turn은 API 오류로 종료되었습니다"
        case .stopped(let reason):
            return "■ 응답이 종료되었습니다 (\(reason ?? "unknown"))"
        case .compactedAway:
            return "✂ 응답이 다음 turn으로 요약되었습니다 (compact)"
        case .orphan:
            return "⚠ 이 Turn은 프롬프트 없이 시작되었습니다"
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
