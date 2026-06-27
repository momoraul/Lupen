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

    // MARK: - In-conversation find (D-3)
    private let findBar = ConversationFindBar(frame: .zero)
    /// `scrollView.top == self.top` when the find bar is hidden; swapped for
    /// `scrollView.top == findBar.bottom` while finding so the bar doesn't
    /// cover the first card.
    private var scrollTopToContainer: NSLayoutConstraint!
    private var scrollTopToFindBar: NSLayoutConstraint!
    /// Text views searched in the current find session, in document order —
    /// `ConversationFindEngine.Match.textIndex` indexes into this.
    private var findTextViews: [ConversationBodyTextView] = []
    private var findMatches: [ConversationFindEngine.Match] = []
    private var findCurrentIndex: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerRenderers()
        setup()
        setupFindBar()
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

        scrollTopToContainer = scrollView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            scrollTopToContainer,
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
        // The card views were rebuilt, so any prior find snapshot is stale.
        // Re-run the query against the fresh text views (no-op when not finding).
        if isFinding {
            updateFind(query: findBar.query, reveal: false)
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

    // MARK: - In-conversation find (D-3)

    private func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        addSubview(findBar)

        scrollTopToFindBar = scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: topAnchor),
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            findBar.heightAnchor.constraint(equalToConstant: ConversationFindBar.barHeight),
        ])

        findBar.onQueryChanged = { [weak self] query in self?.updateFind(query: query, reveal: true) }
        findBar.onNext = { [weak self] in self?.stepFind(forward: true) }
        findBar.onPrevious = { [weak self] in self?.stepFind(forward: false) }
        findBar.onClose = { [weak self] in self?.endFind() }
    }

    /// True while the find bar is mounted and visible.
    var isFinding: Bool { !findBar.isHidden }

    /// Reveal the find bar and focus its field. Re-applies the current query so
    /// reopening over an existing search restores its highlights.
    func beginFind() {
        guard !isFinding else { findBar.focusField(); return }
        findBar.isHidden = false
        scrollTopToContainer.isActive = false
        scrollTopToFindBar.isActive = true
        updateFind(query: findBar.query, reveal: true)
        findBar.focusField()
    }

    /// Hide the find bar and drop all match highlights.
    func endFind() {
        guard isFinding else { return }
        clearHighlights()
        findTextViews = []
        findMatches = []
        findCurrentIndex = nil
        scrollTopToFindBar.isActive = false
        scrollTopToContainer.isActive = true
        findBar.isHidden = true
    }

    /// Advance to the next / previous match (wraps). No-op without matches.
    func findNext() { stepFind(forward: true) }
    func findPrevious() { stepFind(forward: false) }

    private func stepFind(forward: Bool) {
        guard !findMatches.isEmpty else { NSSound.beep(); return }
        findCurrentIndex = ConversationFindEngine.step(
            current: findCurrentIndex, count: findMatches.count, forward: forward
        )
        applyHighlights()
        revealCurrentMatch()
        findBar.setCount(current: findCurrentIndex, total: findMatches.count)
    }

    /// Rebuild the match set for `query` against the live card text views.
    private func updateFind(query: String, reveal: Bool) {
        findTextViews = conversationTextViews()
        let texts = findTextViews.map(\.string)
        findMatches = ConversationFindEngine.matches(in: texts, query: query)
        findCurrentIndex = findMatches.isEmpty ? nil : 0
        applyHighlights()
        if reveal { revealCurrentMatch() }
        findBar.setCount(current: findCurrentIndex, total: findMatches.count)
    }

    /// All `ConversationBodyTextView`s in the card stack, in document order
    /// (depth-first) — covers prompt/assistant/thinking/activity bodies, whether
    /// direct card bodies or sections inside a `ConversationMarkdownView`.
    private func conversationTextViews() -> [ConversationBodyTextView] {
        var found: [ConversationBodyTextView] = []
        func walk(_ view: NSView) {
            for sub in view.subviews {
                if let tv = sub as? ConversationBodyTextView { found.append(tv) }
                walk(sub)
            }
        }
        for card in stack.arrangedSubviews { walk(card) }
        return found
    }

    private func clearHighlights() {
        for textView in findTextViews {
            guard let lm = textView.layoutManager else { continue }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        }
    }

    private func applyHighlights() {
        clearHighlights()
        for (i, match) in findMatches.enumerated() {
            guard findTextViews.indices.contains(match.textIndex) else { continue }
            let textView = findTextViews[match.textIndex]
            // Defensive: a temporary attribute on a range past the view's
            // current length throws NSRangeException. The range is rebuilt from
            // this same view's string, so it holds today — guard anyway against
            // a future renderer that mutates a body in place without a rebuild.
            guard let lm = textView.layoutManager,
                  NSMaxRange(match.range) <= (textView.string as NSString).length else { continue }
            // Current match gets a stronger tint; black foreground keeps the
            // matched text legible on the yellow/orange in both appearances
            // (mirrors QueryHighlighter's contrast handling).
            let background = (i == findCurrentIndex)
                ? NSColor.systemOrange
                : NSColor.findHighlightColor
            lm.addTemporaryAttributes(
                [.backgroundColor: background, .foregroundColor: NSColor.black],
                forCharacterRange: match.range
            )
        }
    }

    private func revealCurrentMatch() {
        guard let index = findCurrentIndex, findMatches.indices.contains(index) else { return }
        let match = findMatches[index]
        guard findTextViews.indices.contains(match.textIndex) else { return }
        let textView = findTextViews[match.textIndex]
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              NSMaxRange(match.range) <= (textView.string as NSString).length else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let inDocument = textView.convert(rect, to: documentView)
        scrollDocumentRectIntoView(inDocument)
    }

    /// Scroll the minimum amount to bring `rect` (in documentView coords) into
    /// view, leaving room below the find bar at the top. (Named to avoid
    /// colliding with `NSView.scrollRectToVisible(_:)`.)
    private func scrollDocumentRectIntoView(_ rect: NSRect) {
        let clip = scrollView.contentView.bounds
        let visibleHeight = clip.height
        let documentHeight = max(documentView.bounds.height, stack.fittingSize.height)
        let maxY = max(0, documentHeight - visibleHeight)
        let topInset = ConversationFindBar.barHeight + 8

        var targetY = clip.origin.y
        if rect.minY < clip.minY + topInset {
            targetY = rect.minY - topInset
        } else if rect.maxY > clip.maxY {
            targetY = rect.maxY - visibleHeight + 12
        }
        let clamped = min(max(0, targetY), maxY)
        guard abs(clamped - clip.origin.y) > 0.5 else { return }
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
