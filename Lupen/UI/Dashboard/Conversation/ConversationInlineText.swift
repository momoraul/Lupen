//
//  ConversationInlineText.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Builds attributed text for card bodies/headers.
///
/// Replaces `[Image source: /path]` / `[Image #N]` markers with an inline SF
/// Symbol (photo), and attaches a `file://` link to path markers so a click
/// reveals them in Finder (ported from the old
/// `ConversationDetailView.buildBodyWithImageLinks` — parity kept). Inline
/// markdown emphasis (bold/code/table/etc.) is handled by Phase C node
/// renderers, so it is not done here.
@MainActor
enum ConversationInlineText {

    /// Body text → attributed string with image markers replaced.
    static func body(
        _ text: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.5
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let sources = ImageSourceFormatter.extractSources(from: text)
        let refs = ImageSourceFormatter.extractRefs(from: text)

        struct Replacement: Comparable {
            let range: NSRange
            let fileURL: URL?
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.range.location < rhs.range.location }
        }

        var replacements: [Replacement] = sources.map {
            Replacement(range: $0.range, fileURL: URL(fileURLWithPath: $0.path))
        }
        for refRange in refs
        where !sources.contains(where: { NSIntersectionRange($0.range, refRange).length > 0 }) {
            replacements.append(Replacement(range: refRange, fileURL: nil))
        }

        guard !replacements.isEmpty else {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }

        let result = NSMutableAttributedString(string: text, attributes: baseAttrs)
        for rep in replacements.sorted().reversed() {
            let symbol = InlineImageSymbol.attachment(
                font: font,
                color: rep.fileURL != nil ? .systemBlue : color,
                linkURL: rep.fileURL
            )
            result.replaceCharacters(in: rep.range, with: symbol)
        }
        return result
    }

    /// Glyphs to prepend when a prompt carries inline image blocks.
    /// (Claude Code currently embeds images only as base64 blocks with no text
    /// marker, so we show a visual signal that an attachment was present.)
    static func imageGlyphPrefix(count: Int, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for index in 0..<max(0, count) {
            result.append(InlineImageSymbol.attachment(font: font, color: color))
            if index < count - 1 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
        }
        return result
    }

    /// Attributed string reflecting inline markdown (bold/italic/inline-code/
    /// link) on the base font. Block structure (table/code block/list) is
    /// already split by the caller via `MarkdownParser`, so only inline is
    /// handled here. Falls back to plain text (`body`) on parse failure.
    static func markdownInline(
        _ text: String,
        font: NSFont,
        color: NSColor,
        lineHeight: CGFloat = 1.5,
        spacingBefore: CGFloat = 0,
        headIndent: CGFloat = 0
    ) -> NSAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return body(text, font: font, color: color)
        }
        let result = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: color, range: full)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.headIndent = headIndent
        paragraph.firstLineHeadIndent = headIndent
        result.addAttribute(.paragraphStyle, value: paragraph, range: full)
        result.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            var resolved = font
            if let intent = value as? InlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .italicFontMask)
                }
                if intent.contains(.code) {
                    resolved = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                    // Faint background so inline code stays identifiable as code
                    // once the surrounding text flows chrome-free.
                    result.addAttribute(
                        .backgroundColor,
                        value: NSColor.labelColor.withAlphaComponent(0.08),
                        range: range
                    )
                }
            }
            result.addAttribute(.font, value: resolved, range: range)
        }
        return result
    }

    /// Attributed string with an SF Symbol (not emoji — proper system tint /
    /// dark mode / VoiceOver) prepended to text. Used for card header/summary glyphs.
    static func symbolPrefixed(
        _ symbolName: String, text: String, font: NSFont, color: NSColor,
        iconColor: NSColor? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [iconColor ?? color]))
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0, y: font.descender + 1, width: image.size.width, height: image.size.height
            )
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        }
        result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        return result
    }
}

/// Card-top role/meta header ("You", "Assistant · opus-4-8 · $0.37").
@MainActor
enum ConversationCardHeader {
    static func make(
        _ text: String, color: NSColor, symbol: String? = nil, iconColor: NSColor? = nil
    ) -> NSTextField {
        // medium (not semibold) + monospaced digits: the header recedes behind
        // the body, while the model·cost meta digits still align. The text color
        // is supplied by the caller (kept secondary); the icon may keep a faint
        // role tint via `iconColor`.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let label = DetailStyles.makeChromeLabel(text, font: font, color: color, alignment: .left)
        if let symbol {
            label.attributedStringValue = ConversationInlineText.symbolPrefixed(
                symbol, text: text, font: font, color: color, iconColor: iconColor
            )
        }
        // Truncate + low compression so a long header (model·cost) doesn't push the card width.
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
