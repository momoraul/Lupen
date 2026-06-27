//
//  ToolGroupCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Tool-group card — collapses into one line like "Read · 3 ›"; expands to show
/// each call's input/result summary (the "N files read" pattern + curation).
@MainActor
struct ToolGroupCardRenderer: BlockRenderer {
    func makeView(for block: ToolGroupBlock, context: RenderContext) -> NSView {
        let disclosure = DisclosureCardView(summary: summary(block)) {
            detail(block)
        }
        let card = CardContainerView(role: .assistant, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(disclosure)
        card.setCopyText(ConversationBlockCopy.plainText(for: block))
        return card
    }

    private func summary(_ block: ToolGroupBlock) -> NSAttributedString {
        let name = StepKindStyle.displayName(forToolName: block.toolName)
        let head = block.count == 1 ? name : "\(name) · \(block.count)"
        let result = NSMutableAttributedString(attributedString:
            ConversationInlineText.symbolPrefixed(
                "wrench.adjustable.fill", text: head,
                font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor
            )
        )
        if let first = block.calls.first, !first.inputSummary.isEmpty {
            result.append(NSAttributedString(string: "  \(first.inputSummary)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        return result
    }

    private func detail(_ block: ToolGroupBlock) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for call in block.calls {
            let line = NSMutableAttributedString(string: "• \(call.inputSummary)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
            if let resultSummary = call.resultSummary, !resultSummary.isEmpty {
                line.append(NSAttributedString(
                    string: "  \(call.isError ? "✗" : "↪") \(resultSummary)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: call.isError ? NSColor.systemRed : NSColor.tertiaryLabelColor,
                    ]
                ))
            }
            let label = DetailStyles.makeSelectableValueLabel(
                "", font: .systemFont(ofSize: 11), color: .labelColor, alignment: .left
            )
            label.attributedStringValue = line
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
}
