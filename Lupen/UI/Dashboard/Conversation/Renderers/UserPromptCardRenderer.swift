//
//  UserPromptCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// My prompt card — a "You" header + selectable body (+ attached image glyphs).
@MainActor
struct UserPromptCardRenderer: BlockRenderer {
    func makeView(for block: UserPromptBlock, context: RenderContext) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(ConversationCardHeader.make("You", color: .systemTeal, symbol: "bubble.left.fill"))

        let font = NSFont.systemFont(ofSize: 13)
        let body = ConversationBodyTextView.make()
        body.onRevealFile = context.revealInFinder

        let attributed = NSMutableAttributedString()
        if block.isCompactSummary {
            attributed.append(NSAttributedString(
                string: "↻ Compact resume",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        } else {
            if block.inlineImageCount > 0 {
                attributed.append(ConversationInlineText.imageGlyphPrefix(
                    count: block.inlineImageCount, font: font, color: .labelColor
                ))
                attributed.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            if let text = block.text, !text.isEmpty {
                attributed.append(ConversationInlineText.body(text, font: font, color: .labelColor))
            } else if block.inlineImageCount == 0 {
                attributed.append(NSAttributedString(
                    string: "(empty prompt)",
                    attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            }
        }
        body.setBody(attributed)
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = CardContainerView(role: .user, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(stack)
        return card
    }
}
