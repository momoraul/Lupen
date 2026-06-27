//
//  ThinkingCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Thinking card — collapses into "Thinking · first line…"; expands to the full thinking text.
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
        let card = CardContainerView(role: .assistant, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(disclosure)
        card.setCopyText(ConversationBlockCopy.plainText(for: block))
        return card
    }

    private func summary(_ block: ThinkingBlock) -> NSAttributedString {
        let firstLine = block.text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let result = NSMutableAttributedString(attributedString:
            ConversationInlineText.symbolPrefixed(
                "brain", text: "Thinking",
                font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor
            )
        )
        if !firstLine.isEmpty {
            result.append(NSAttributedString(string: "  \(firstLine)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        return result
    }
}
