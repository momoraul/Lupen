//
//  FileAccessCardRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/07/26.
//

import AppKit

/// C-22 — renders the `FileAccessBlock` card that leads a selected turn.
///
/// Starts expanded: this card is the glance, so hiding it behind a chevron
/// would hide the feature. Folding it is the opt-out, and
/// `RenderContext.collapsedCards` remembers that across launches.
@MainActor
struct FileAccessCardRenderer: BlockRenderer {
    func makeView(for block: FileAccessBlock, context: RenderContext) -> NSView {
        let store = context.collapsedCards
        let disclosure = DisclosureCardView(
            summary: Self.summary(block),
            initialExpanded: store?.isExpanded(.fileAccess) ?? true,
            onToggle: { expanded in store?.setCollapsed(!expanded, for: .fileAccess) }
        ) {
            let body = TurnFileAccessView(model: block.model)
            body.onJumpToStep = context.jumpToStep
            body.onRevealInFinder = context.revealInFinder
            body.onOpenFile = context.openFile
            // The card is rebuilt on every step selection, so an opened tail
            // would close again the moment the user moved the highlight.
            if store?.areFileRowsExpanded(forTurn: block.id) == true {
                body.setFoldedRowsExpanded(true, notify: false)
            }
            body.onFoldedRowsExpandedChange = { expanded in
                store?.setFileRowsExpanded(expanded, forTurn: block.id)
            }
            // Started here rather than in `init` so a card that opens folded
            // reads nothing at all — the body is built lazily on first expand.
            if let load = block.loadDiffStats {
                body.loadLineDeltas(key: block.diffCacheKey, using: load)
            }
            return body
        }

        let card = CardContainerView(
            role: block.role, tier: block.tier, highlighted: block.isHighlighted
        )
        card.setBody(disclosure)
        return card
    }

    /// The collapsed line still answers "did this turn change anything".
    ///
    /// `square.and.pencil` rather than `pencil.and.outline`: at the 12pt this
    /// draws at, the outline collapses into a filled ring and the pencil into a
    /// stroke across it, so the glyph read as ⊘ — a prohibition sign, which is
    /// close to the opposite of "files were changed". The replacement keeps the
    /// pencil legible and stays a document shape with a tool on it, which is
    /// what pairs it with the exploration symbol.
    static func symbolName(explorationOnly: Bool) -> String {
        explorationOnly ? "doc.text.magnifyingglass" : "square.and.pencil"
    }

    private static func summary(_ block: FileAccessBlock) -> NSAttributedString {
        ConversationInlineText.symbolPrefixed(
            symbolName(explorationOnly: block.model.isExplorationOnly),
            text: block.model.summaryText,
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
    }
}
