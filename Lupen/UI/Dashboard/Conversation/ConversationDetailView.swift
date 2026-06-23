//
//  ConversationDetailView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Body of the Conversation tab — draws a curated `[ConversationBlock]` of a
/// Turn as a card stack. Mirrors the proven Tokens-tab pattern (NSScrollView +
/// flipped documentView + vertical NSStackView) and delegates block→view
/// mapping to `BlockRendererRegistry` (unregistered blocks fall back to plain text).
@MainActor
final class ConversationDetailView: NSView {

    private let scrollView = NSScrollView()
    private let documentView = ConversationFlippedDocumentView()
    private let stack = NSStackView()
    private let registry = BlockRendererRegistry()
    private let renderContext = RenderContext()
    /// Leading/trailing constraints of the currently rendered cards —
    /// deactivated in bulk on rebuild (A1). Without tracking, activating every
    /// time leaves dangling constraints that pile up and break layout on fast
    /// Turn switching.
    private var cardConstraints: [NSLayoutConstraint] = []
    /// Block ids of the currently rendered turn. Lets `configure` tell "same
    /// turn, only the selected Step changed" (keep scroll if the target is
    /// already visible) from "new content" (reveal the target).
    private var renderedBlockIDs: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerRenderers()
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Register dedicated renderers. Adding one `register(_:)` line here adds a
    /// new display target (extension point). Unregistered blocks fall back
    /// safely to `PlainTextBlockRenderer`.
    private func registerRenderers() {
        registry.register(UserPromptCardRenderer())
        registry.register(AssistantTextCardRenderer())
        registry.register(StatusBannerRenderer())
        registry.register(ToolGroupCardRenderer())
        registry.register(ThinkingCardRenderer())
        registry.register(ActivityGroupRenderer())
    }

    private func setup() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 24, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The container (documentView) follows the viewport (clipView) one-way.
            // Pinning all 4 edges to the clipView with == blocks any child card/
            // text intrinsic width from propagating up and constraining the
            // container (= panel/window) width.
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            // The documentView height is determined by the stack (= content)
            // height. Forcing it to at least the viewport height (height >=
            // viewport) combined with stack.bottom == documentView.bottom makes
            // short content stretch the card to fill the viewport height (bug).

            // The stack follows the documentView width exactly (==). No reading-
            // width clamp / centerX / min-max — cards don't own a width
            // constraint; they follow the container.
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Self.contentHorizontalInset),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -Self.contentHorizontalInset),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    /// Horizontal margin for conversation content — a bit more than the shared
    /// inset (16) so cards don't crowd the panel edges.
    private static let contentHorizontalInset: CGFloat = 24

    /// Redraw the card stack from the curated blocks. (Selection skipping is
    /// handled by the parent `DetailViewController` on same-Step rebind — parity
    /// kept — so this rebuilds on every call.)
    func configure(blocks: [ConversationBlock]) {
        // Explicitly deactivate/clear card constraints (A1): avoid dangling pile-up.
        NSLayoutConstraint.deactivate(cardConstraints)
        cardConstraints.removeAll()
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let ids = blocks.map(\.id)
        let sameContent = ids == renderedBlockIDs
        renderedBlockIDs = ids
        var highlightedView: NSView?
        var previous: (view: NSView, tier: BlockTier)?
        for block in blocks {
            let view = registry.view(for: block, context: renderContext)
            stack.addArrangedSubview(view)
            let leading = view.leadingAnchor.constraint(equalTo: stack.leadingAnchor)
            let trailing = view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            cardConstraints.append(contentsOf: [leading, trailing])
            NSLayoutConstraint.activate([leading, trailing])
            if let previous {
                // Cards carry the block boundaries, so the gaps stay modest: a new
                // prompt opens a new round-trip (20), supporting lines (thinking·
                // tools) pack tightly (2), everything else breathes (12).
                let spacing: CGFloat
                if block is UserPromptBlock {
                    spacing = 20
                } else if previous.tier == .secondary && block.tier == .secondary {
                    spacing = 2
                } else {
                    spacing = 12
                }
                stack.setCustomSpacing(spacing, after: previous.view)
            }
            previous = (view, block.tier)
            if block.isHighlighted, highlightedView == nil { highlightedView = view }
        }
        // Force a 3-stage layout for accurate coordinates before scrolling.
        layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        if let highlightedView {
            revealHighlighted(highlightedView, keepIfVisible: sameContent)
        } else if !sameContent {
            // New content with no highlighted Step (e.g. whole-Turn view) → top.
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Scroll only as much as needed to reveal `view`. When `keepIfVisible` (the
    /// same turn is on screen and only the selected Step changed), a fully
    /// visible target is left untouched — no jump to the top. Otherwise the
    /// target is brought into view: minimally for the same turn, or near the top
    /// for new content.
    private func revealHighlighted(_ view: NSView, keepIfVisible: Bool) {
        let rect = view.convert(view.bounds, to: documentView)
        let clip = scrollView.contentView.bounds
        let topInset: CGFloat = 12
        let visibleHeight = clip.height
        let documentHeight = max(documentView.bounds.height, stack.fittingSize.height)
        let maxY = max(0, documentHeight - visibleHeight)

        let fullyVisible = rect.minY >= clip.minY && rect.maxY <= clip.maxY
        if keepIfVisible && fullyVisible { return }

        let targetY: CGFloat
        if !keepIfVisible || rect.minY < clip.minY || rect.height + topInset >= visibleHeight {
            // New content, target above the viewport, or taller than the viewport
            // → align its top (with a small inset).
            targetY = rect.minY - topInset
        } else {
            // Target below the viewport → bring its bottom just into view.
            targetY = rect.maxY - visibleHeight + topInset
        }
        let clamped = min(max(0, targetY), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// `isFlipped = true` document view — so `scroll(.zero)` goes to the top
/// (otherwise NSStackView's default coordinate system puts (0,0) at the bottom
/// and every rebind scrolls to the end).
private final class ConversationFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
