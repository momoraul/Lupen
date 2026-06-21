//
//  ThinkingCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 사고 카드 — "💭 Thinking · 첫 줄…" 한 줄로 접고, 펼치면 전체 사고 텍스트.
@MainActor
struct ThinkingCardRenderer: BlockRenderer {
    func makeView(for block: ThinkingBlock, context: RenderContext) -> NSView {
        let disclosure = DisclosureCardView(summary: summary(block)) {
            let body = ConversationBodyTextView.make()
            body.setBody(NSAttributedString(
                string: block.text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            return body
        }
        let card = CardContainerView(role: .assistant, highlighted: block.isHighlighted)
        card.setBody(disclosure)
        return card
    }

    private func summary(_ block: ThinkingBlock) -> NSAttributedString {
        let firstLine = block.text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let result = NSMutableAttributedString(string: "💭 Thinking", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if !firstLine.isEmpty {
            result.append(NSAttributedString(string: "  \(firstLine)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        return result
    }
}
