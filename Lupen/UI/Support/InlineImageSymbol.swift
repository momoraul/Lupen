import AppKit

/// Builds baseline-calibrated inline SF Symbol `photo` attachments for use
/// inside attributed strings. Replaces the legacy 🖼️ emoji placeholder with
/// a glyph that matches the system font in both weight and tone — the emoji
/// is rendered by Apple Color Emoji and looks out of place next to regular
/// system-font text.
///
/// Shared by the Turn outline (small 11pt, header 13pt) and the Conversation
/// detail tab (body text), so the attachment glyph is visually identical
/// everywhere an image placeholder can appear.
enum InlineImageSymbol {

    /// Returns an inline `photo` SF Symbol attachment sized to the given
    /// font's pointSize and tinted with the given color. Optionally wraps
    /// the attachment in a `.link` attribute so it is clickable inside an
    /// NSTextView (used by the Conversation detail tab to make `[Image
    /// source: /path]` markers reveal the file in Finder on click).
    ///
    /// The baseline is nudged by `font.descender + 1` so the symbol sits on
    /// the text baseline rather than floating above it — matches how Apple's
    /// Mail.app inlines its own attachment glyphs.
    /// Dim tint used for the `🖼` glyph in the **sidebar session list**.
    /// `.secondaryLabelColor` — one step down from `.labelColor` in the
    /// system grey ramp. Reads as a quiet metadata cue (doesn't pull
    /// the eye off the session title) but stays visible against the
    /// sidebar background; `.tertiaryLabelColor` was too faint in dark
    /// mode and the glyph nearly disappeared.
    ///
    /// The Turn outline keeps its own accent tint (`.systemBlue`) so
    /// attached images read as a first-class marker inside the
    /// conversation — the sidebar preview is secondary content, the
    /// outline is primary.
    static let defaultDimTint: NSColor = .secondaryLabelColor

    /// Replaces every `🖼` code point in `text` with an inline SF
    /// Symbol `photo` attachment, returning an attributed string ready
    /// for `NSTextField.attributedStringValue`. Non-`🖼` runs keep
    /// `font` / `color`; attachments inherit `attachmentColor` (or
    /// `color` if unspecified). Returns a plain attributed string
    /// untouched when `text` has no `🖼`, so callers can unconditionally
    /// route through this helper without branch-checking themselves.
    ///
    /// Use this for cell-level labels (sidebar session title, Turn
    /// header, Turn outline prompt row) — anywhere a string produced
    /// by `TurnPreview` / `Step.oneLineSummary` needs to render with
    /// the same monochrome glyph as the Conversation tab instead of
    /// Apple Color Emoji.
    static func promotingImageGlyphs(
        _ text: String,
        font: NSFont,
        color: NSColor,
        attachmentColor: NSColor? = nil
    ) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        guard text.contains("🖼") else {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }
        let tint = attachmentColor ?? color
        let result = NSMutableAttributedString()
        let parts = text.components(separatedBy: "🖼")
        for (index, part) in parts.enumerated() {
            if !part.isEmpty {
                result.append(NSAttributedString(string: part, attributes: baseAttrs))
            }
            if index < parts.count - 1 {
                result.append(attachment(font: font, color: tint))
            }
        }
        return result
    }

    static func attachment(
        font: NSFont,
        color: NSColor,
        linkURL: URL? = nil
    ) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: "photo", accessibilityDescription: "image")?
            .withSymbolConfiguration(config) else {
            // Fallback — if the symbol ever fails to load, the emoji is still
            // better than nothing.
            let fallback = NSMutableAttributedString(string: "🖼", attributes: [
                .font: font,
                .foregroundColor: color
            ])
            if let linkURL {
                let range = NSRange(location: 0, length: fallback.length)
                fallback.addAttribute(.link, value: linkURL, range: range)
                fallback.addAttribute(.toolTip, value: linkURL.path, range: range)
            }
            return fallback
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: font.descender + 1,
            width: image.size.width,
            height: image.size.height
        )
        let str = NSMutableAttributedString(attachment: attachment)
        if let linkURL {
            let range = NSRange(location: 0, length: str.length)
            str.addAttribute(.link, value: linkURL, range: range)
            str.addAttribute(.toolTip, value: linkURL.path, range: range)
        }
        return str
    }
}
