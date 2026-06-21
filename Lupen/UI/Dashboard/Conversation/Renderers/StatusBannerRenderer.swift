//
//  StatusBannerRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Status banner card — shows the interrupted / API-error / compact / orphan /
/// stop reason. Conveys what happened instead of "(no response available)".
@MainActor
struct StatusBannerRenderer: BlockRenderer {
    func makeView(for block: StatusBlock, context: RenderContext) -> NSView {
        let label = DetailStyles.makeSelectableValueLabel(
            block.kind.message,
            font: .systemFont(ofSize: 12),
            color: color(for: block.kind),
            alignment: .left
        )
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping

        let card = CardContainerView(role: .system, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(label)
        return card
    }

    private func color(for kind: StatusKind) -> NSColor {
        switch kind {
        case .interrupted: return .systemRed
        case .apiError:    return .systemOrange
        case .stopped:     return .secondaryLabelColor
        case .compactedAway: return .secondaryLabelColor
        case .orphan:      return .systemOrange
        }
    }
}
