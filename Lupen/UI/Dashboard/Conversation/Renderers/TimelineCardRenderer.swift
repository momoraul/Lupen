//
//  TimelineCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/07/03.
//

import AppKit

/// C-24 — renders the `TimelineBlock` swimlane card near the top of a
/// qualifying turn. Clicking a segment jumps the conversation to the card
/// covering that step (via `RenderContext.jumpToStep`).
///
/// Starts expanded and can be folded away, with the choice remembered — the
/// same contract as the file-access card it sits under.
@MainActor
struct TimelineCardRenderer: BlockRenderer {
    func makeView(for block: TimelineBlock, context: RenderContext) -> NSView {
        let store = context.collapsedCards
        let disclosure = DisclosureCardView(
            summary: Self.summary(block),
            initialExpanded: store?.isExpanded(.timeline) ?? true,
            onToggle: { expanded in store?.setCollapsed(!expanded, for: .timeline) }
        ) {
            let timeline = TurnTimelineView(model: block.model)
            timeline.onJumpToStep = context.jumpToStep
            return timeline
        }

        let card = CardContainerView(
            role: block.role, tier: block.tier, highlighted: block.isHighlighted
        )
        card.setBody(disclosure)
        return card
    }

    private static func summary(_ block: TimelineBlock) -> NSAttributedString {
        ConversationInlineText.symbolPrefixed(
            "clock",
            text: block.model.summaryText,
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
    }
}
