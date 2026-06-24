//
//  ConversationMarkdownView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Markdown body rendering — consecutive text-family nodes (heading/paragraph/
/// list/quote) are merged into a single attributed string and drawn as a single
/// `NSTextView`. This fixes the problem where splitting each node into its own
/// NSTextView blocked drag selection across node boundaries (couldn't select
/// multiple lines within one step). Only tables/code blocks are split into
/// dedicated views (NSGridView / Copy-button code card) to keep rich rendering.
@MainActor
final class ConversationMarkdownView: NSStackView {

    private let onRevealFile: ((URL) -> Void)?

    init(markdown: String, onRevealFile: ((URL) -> Void)?) {
        self.onRevealFile = onRevealFile
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        build(markdown: markdown)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build(markdown: String) {
        var run = NSMutableAttributedString()

        func flushRun() {
            guard run.length > 0 else { return }
            let textView = ConversationBodyTextView.make()
            textView.onRevealFile = onRevealFile
            textView.maxReadingWidth = Self.maxReadingWidth
            textView.setBody(run)
            addArranged(textView)
            run = NSMutableAttributedString()
        }

        for node in MarkdownParser.parse(markdown) {
            switch node {
            case .codeBlock(_, let code):
                flushRun()
                addArranged(CodeBlockView(code: code))
            case .table(let headers, let rows):
                flushRun()
                addArranged(MarkdownTableView(headers: headers, rows: rows))
            default:
                // Accumulate text-family nodes into one NSTextView → select the whole run by drag.
                if run.length > 0 { run.append(NSAttributedString(string: "\n\n")) }
                run.append(Self.attributed(for: node))
            }
        }
        flushRun()
    }

    private func addArranged(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// Reading-width cap for body text (NOT code blocks / tables). Enforced
    /// inside the text view's text container (`ConversationBodyTextView.
    /// maxReadingWidth`), NEVER via an Auto Layout width constraint: a `<=` width
    /// constraint on a child propagates up the equality chain and locks the whole
    /// pane's max width. The text view still follows the container width via
    /// `addArranged` (`== width`); only the glyph wrapping is capped, leaving
    /// empty space on the right on very wide panels.
    static let maxReadingWidth: CGFloat = 700

    // MARK: - Text node → attributed

    private static func attributed(for node: MarkdownNode) -> NSAttributedString {
        switch node {
        case .heading(let level, let text):
            // Tighter line-height + extra space above (not below) so a heading
            // reads as the head of the block that follows, not floating text.
            return ConversationInlineText.markdownInline(
                text, font: headingFont(level: level), color: .labelColor,
                lineHeight: 1.25, spacingBefore: 8
            )
        case .paragraph(let text):
            return ConversationInlineText.markdownInline(text, font: bodyFont, color: .labelColor)
        case .bulletList(let items):
            return list(items.map { (marker: "•  ", text: $0) })
        case .orderedList(let items):
            return list(items.enumerated().map { (marker: "\($0.offset + 1).  ", text: $0.element) })
        case .quote(let lines):
            // No left bar (an earlier design decision); a left indent still keeps
            // the quote identifiable once the surrounding cards are gone.
            return ConversationInlineText.markdownInline(
                lines.joined(separator: "\n"), font: bodyFont, color: .secondaryLabelColor,
                lineHeight: 1.45, headIndent: 12
            )
        case .codeBlock, .table:
            return NSAttributedString() // handled by a dedicated view; never reached here
        }
    }

    private static func list(_ items: [(marker: String, text: String)]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.45
        paragraph.headIndent = 16        // indent the wrapped second line by the marker width (hanging indent)
        paragraph.firstLineHeadIndent = 0
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let line = NSMutableAttributedString(string: item.marker, attributes: [
                .font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
            ])
            line.append(ConversationInlineText.markdownInline(item.text, font: bodyFont, color: .labelColor))
            line.addAttribute(
                .paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: line.length)
            )
            result.append(line)
        }
        return result
    }

    static let bodyFont: NSFont = .systemFont(ofSize: 13)

    static func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = 20
        case 2: size = 17
        case 3: size = 15
        default: size = 14
        }
        return .systemFont(ofSize: size, weight: .semibold)
    }
}

/// Code block — mono text + faint background + left accent + Copy button at top-right.
@MainActor
final class CodeBlockView: NSView {

    private let code: String

    init(code: String) {
        self.code = code
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        applyColors()

        let text = ConversationBodyTextView.make()
        text.setBody(NSAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        addSubview(text)

        let copyButton: NSButton
        if let icon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") {
            copyButton = NSButton(image: icon, target: self, action: #selector(copyCode))
            copyButton.isBordered = false
            copyButton.contentTintColor = .secondaryLabelColor
        } else {
            copyButton = NSButton(title: "Copy", target: self, action: #selector(copyCode))
            copyButton.bezelStyle = .accessoryBarAction
        }
        copyButton.controlSize = .small
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DetailStyles.conversationCodeFillColor.cgColor
        }
    }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

/// Markdown table — header (emphasized) + data rows drawn as a grid via NSGridView.
@MainActor
final class MarkdownTableView: NSView {

    init(headers: [String], rows: [[String]]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup(headers: headers, rows: rows)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup(headers: [String], rows: [[String]]) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = DetailStyles.hairlineWidth(for: self)
        layer?.borderColor = NSColor.separatorColor.cgColor

        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return }

        func cell(_ text: String, bold: Bool) -> NSView {
            let label = DetailStyles.makeSelectableValueLabel(
                text,
                font: .systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
                color: .labelColor,
                alignment: .left
            )
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }

        var gridRows: [[NSView]] = []
        gridRows.append((0..<columnCount).map { cell($0 < headers.count ? headers[$0] : "", bold: true) })
        for row in rows {
            gridRows.append((0..<columnCount).map { cell($0 < row.count ? row[$0] : "", bold: false) })
        }

        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 6
        grid.columnSpacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.borderWidth = DetailStyles.hairlineWidth(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Re-resolve the dynamic border color (cgColor snapshots the appearance
        // at assignment) so a live dark/light switch updates without a rebuild.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
