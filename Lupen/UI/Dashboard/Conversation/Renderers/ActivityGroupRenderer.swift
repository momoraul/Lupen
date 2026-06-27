//
//  ActivityGroupRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Activity-group card — for very large turns, folds many tool/thinking
/// activities into one collapsed line ("N activities"). Expanding renders the
/// per-activity summary lines as a single text view, so the card count and view
/// cost stay bounded no matter how many steps the turn has (the fix for the
/// multi-thousand-step freeze).
@MainActor
struct ActivityGroupRenderer: BlockRenderer {
    func makeView(for block: ActivityGroupBlock, context: RenderContext) -> NSView {
        let disclosure = DisclosureCardView(summary: summary(block)) {
            let body = ConversationBodyTextView.make()
            body.setBody(NSAttributedString(
                string: block.summaryLines.joined(separator: "\n"),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            return body
        }
        let card = CardContainerView(role: .assistant, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(disclosure)
        return card
    }

    private func summary(_ block: ActivityGroupBlock) -> NSAttributedString {
        ConversationInlineText.symbolPrefixed(
            "gearshape.2.fill",
            text: "\(block.count) activities",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
    }
}
