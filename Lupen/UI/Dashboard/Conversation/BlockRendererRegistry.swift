//
//  BlockRendererRegistry.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Dependencies (styles/callbacks) shared by blocks at render time. Extensible —
/// add a value here when a new renderer needs one.
@MainActor
struct RenderContext {
    /// Max reading-column width for the body (Q4). Used by Phase C node rendering.
    var readingWidth: CGFloat = 620
    /// Reveal a file path (image/attachment) in Finder on click. Ported for parity.
    var revealInFinder: (URL) -> Void = { url in
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-R", path])
        } else {
            let parent = url.deletingLastPathComponent().path
            if FileManager.default.fileExists(atPath: parent) {
                Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [parent])
            }
        }
    }
}

/// Draws one block type as an NSView. Implement per type and register in the registry.
@MainActor
protocol BlockRenderer {
    associatedtype Block: ConversationBlock
    func makeView(for block: Block, context: RenderContext) -> NSView
}

/// Block type → renderer map. Unregistered types fall back to `PlainTextBlockRenderer`.
///
/// The core of extensibility: to add a new display target, implement
/// `BlockRenderer` and just call `register(_:)` — zero changes to existing code.
/// Even if a renderer is forgotten, the fallback draws plain text so there is no
/// blank screen / crash (fallback invariant).
@MainActor
final class BlockRendererRegistry {
    private var makers: [ObjectIdentifier: (any ConversationBlock, RenderContext) -> NSView?] = [:]
    private let fallback = PlainTextBlockRenderer()

    func register<R: BlockRenderer>(_ renderer: R) {
        let key = ObjectIdentifier(R.Block.self)
        makers[key] = { block, context in
            guard let typed = block as? R.Block else { return nil }
            return renderer.makeView(for: typed, context: context)
        }
    }

    func view(for block: any ConversationBlock, context: RenderContext) -> NSView {
        let key = ObjectIdentifier(type(of: block))
        if let maker = makers[key], let view = maker(block, context) {
            return view
        }
        return fallback.makeView(for: block, context: context)
    }
}

/// Fallback renderer: draws any block's `plainTextFallback` as a selectable
/// plain-text card. Guarantees that even blocks without a dedicated renderer
/// (ToolGroup/Thinking at Phase B) stay at least readable.
@MainActor
struct PlainTextBlockRenderer {
    func makeView(for block: any ConversationBlock, context: RenderContext) -> NSView {
        let isSecondary = block.tier != .primary
        let label = DetailStyles.makeSelectableValueLabel(
            block.plainTextFallback,
            font: .systemFont(ofSize: 12),
            color: isSecondary ? .secondaryLabelColor : .labelColor,
            alignment: .left
        )
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        let card = CardContainerView(role: block.role, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(label)
        return card
    }
}
