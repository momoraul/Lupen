//
//  AssistantTextCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 모델 답변 카드 — "✦ Assistant · model · cost" 헤더 + selectable 본문.
///
/// Phase B는 본문을 줄바꿈 보존 평문(+이미지 링크)으로 표시해 Turn 선택 시
/// 응답이 보이게 한다("no response available" 박멸이 1차 목표). 마크다운
/// 블록(테이블/코드블록/리스트) 리치 렌더는 Phase C에서 이 렌더러를
/// `MarkdownParser` 노드 렌더로 확장한다.
@MainActor
struct AssistantTextCardRenderer: BlockRenderer {
    func makeView(for block: AssistantTextBlock, context: RenderContext) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(ConversationCardHeader.make(headerText(for: block), color: .controlAccentColor, symbol: "sparkles"))

        let body = ConversationMarkdownView(markdown: block.markdown, onRevealFile: context.revealInFinder)
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = CardContainerView(role: .assistant, highlighted: block.isHighlighted)
        card.setBody(stack)
        return card
    }

    private func headerText(for block: AssistantTextBlock) -> String {
        var parts = ["Assistant"]
        if let model = block.model, !model.isEmpty {
            parts.append(model)
        }
        if let cost = block.cost {
            let formatted = DetailCostFormatter.format(cost.totalCostUSD)
            if formatted != "—" { parts.append(formatted) }
        }
        return parts.joined(separator: " · ")
    }
}
