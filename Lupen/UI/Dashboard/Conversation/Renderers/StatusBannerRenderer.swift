//
//  StatusBannerRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 상태 배너 카드 — 중단/API오류/compact/orphan/stop 사유를 보여준다.
/// "(no response available)" 대신 무슨 일이 있었는지 명확히 전달.
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
