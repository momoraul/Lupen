//
//  TimelineCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/07/03.
//

import AppKit

/// C-24 — renders the `TimelineBlock` swimlane card at the top of a
/// qualifying turn. Clicking a segment jumps the conversation to the card
/// covering that step (via `RenderContext.jumpToStep`).
@MainActor
struct TimelineCardRenderer: BlockRenderer {
    func makeView(for block: TimelineBlock, context: RenderContext) -> NSView {
        let timeline = TurnTimelineView(model: block.model)
        timeline.onJumpToStep = context.jumpToStep
        let card = CardContainerView(role: block.role, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(timeline)
        return card
    }
}
