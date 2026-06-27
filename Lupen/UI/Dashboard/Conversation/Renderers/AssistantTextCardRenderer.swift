//
//  AssistantTextCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Model reply card — "✦ Assistant · model · cost" header + selectable body.
///
/// Phase B showed the body as newline-preserving plain text (+ image links) so
/// a response is visible on Turn selection (killing "no response available" was
/// the first goal). Rich markdown block rendering (table/code block/list) is
/// added in Phase C by extending this renderer to `MarkdownParser` node rendering.
@MainActor
struct AssistantTextCardRenderer: BlockRenderer {
    func makeView(for block: AssistantTextBlock, context: RenderContext) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(ConversationCardHeader.make(
            headerText(for: block), color: .secondaryLabelColor, symbol: "sparkles",
            iconColor: NSColor.controlAccentColor.withAlphaComponent(0.65)
        ))

        let body = ConversationMarkdownView(markdown: block.markdown, onRevealFile: context.revealInFinder)
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = CardContainerView(role: .assistant, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(stack)
        card.setCopyText(ConversationBlockCopy.plainText(for: block))
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
