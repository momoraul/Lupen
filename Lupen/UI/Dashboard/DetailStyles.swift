import AppKit

/// Shared style constants + factories used across the bottom detail pane
/// (Tokens / Conversation / Attachments / Raw / Usage tabs).
///
/// Centralising these means every tab renders headers, rows, and dividers
/// at the same pixel weight — previously each `*DetailView` open-coded its
/// own font/colour/inset choices and the panels drifted out of sync
/// (different header colours, inconsistent horizontal insets, one-off
/// typography).
///
/// All factories return selectable-by-default labels for *value* fields.
/// The detail view has to be a working data surface the user can copy
/// numbers/paths/model names out of; Activity Monitor / Xcode Inspector
/// take the same stance for their info panes.
///
/// `@MainActor` isolation: NSFont / NSColor are not `Sendable` under Swift
/// 6 strict concurrency. Since every caller is already on the main thread
/// (NSView subclasses, layout helpers), isolating the whole namespace
/// keeps the static properties legal without per-accessor ceremony.
@MainActor
enum DetailStyles {

    // MARK: - Fonts

    /// Section title used for "Token Breakdown" / "Cost Breakdown" / etc.
    /// 11pt semibold at secondary label colour matches Apple's native
    /// "group header" tone (Finder sidebar group labels, Mail inspector
    /// section titles).
    static let sectionHeaderFont: NSFont = .systemFont(ofSize: 11, weight: .semibold)
    static let sectionHeaderColor: NSColor = .secondaryLabelColor

    /// Row label on the leading side ("Input Tokens", "Cache Read").
    /// Primary label colour so the name reads as the important content.
    static let rowNameFont: NSFont = .systemFont(ofSize: 12, weight: .regular)
    static let rowNameColor: NSColor = .labelColor

    /// Row value on the trailing side — monospaced-digit so columns of
    /// numbers align vertically. Secondary colour for regular rows,
    /// primary for "total" / "bold" rows.
    static let rowValueFont: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let rowValueColor: NSColor = .secondaryLabelColor

    /// Bold variant for totals ("Total Context", "Total Cost").
    static let rowBoldNameFont: NSFont = .systemFont(ofSize: 12, weight: .semibold)
    static let rowBoldValueFont: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let rowBoldColor: NSColor = .labelColor

    // MARK: - Spacing

    /// Horizontal inset around every tab's content area. Matches the
    /// sidebar's 16pt inset so left edges line up across panes.
    static let horizontalInset: CGFloat = 16

    /// Vertical gap between sections (between "Cost" and "Model" blocks, etc).
    static let sectionSpacing: CGFloat = 16

    /// Gap between a section header and its first row.
    static let headerTailSpacing: CGFloat = 6

    /// Gap between rows inside a section.
    static let rowSpacing: CGFloat = 2

    /// Each indent level adds this many points of leading padding. Used
    /// by nested rows (e.g. Ephemeral 1h/5m under Cache Creation).
    static let indentStep: CGFloat = 16

    // MARK: - Inspector-style layout (Tokens tab, System Settings "About" pattern)
    //
    // Pixel-precise guide from UX review (2026-04-18 round 3):
    //   - pane-wide content (NO max-width clamp — let AutoLayout flex)
    //   - 20pt leading/trailing inset from pane edge
    //   - 24pt top / 24pt bottom
    //   - 20pt gap between sections
    //   - 8pt gap from section header → box
    //   - 13pt section header, .semibold, secondaryLabelColor
    //   - grouped NSBox: cornerRadius 8, borderWidth 0.5, separatorColor
    //     border, dynamic fill (white α 0.03 dark / black α 0.02 light)
    //   - box inner padding: top/bottom 12, leading/trailing 16
    //   - row = [label] ← flex spacer → [value, right-aligned]; label and
    //     value use intrinsic hugging, spacer takes the middle
    //   - row heights: regular 24 / sub 22 / emphasis 26
    //   - divider: 0.5pt, leading/trailing inset 16, 8pt top+bottom gaps

    /// Horizontal inset from the detail pane edge to the section box.
    /// Mirrors macOS System Settings "About" grouped inset-list.
    static let paneEdgeInset: CGFloat = 20

    /// Top padding above the first section header and bottom padding
    /// after the last section.
    static let paneVerticalInset: CGFloat = 24

    /// Gap between one section's box and the next section's header.
    static let sectionGap: CGFloat = 20

    /// Gap between a section header label and its grouped box.
    static let headerToBoxGap: CGFloat = 8

    /// Section header font/color (macOS 26 System Settings grouped list
    /// header tone).
    static let inspectorSectionHeaderFont: NSFont = .systemFont(ofSize: 13, weight: .semibold)
    static let inspectorSectionHeaderColor: NSColor = .secondaryLabelColor

    /// Grouped-box (NSBox) corner radius and border.
    static let sectionBoxCornerRadius: CGFloat = 8
    static let sectionBoxBorderWidth: CGFloat = 0.5

    /// Grouped-box padding (inside the NSBox, around the row stack).
    static let sectionBoxInsetH: CGFloat = 16
    static let sectionBoxInsetV: CGFloat = 12

    /// Section-box fill colour — dynamic per appearance.
    ///
    /// `NSColor(name:dynamicProvider:)` resolves fresh on every read, so
    /// appearance changes (dark ↔ light) update automatically without
    /// needing an explicit view refresh. `quaternaryLabelColor` failed
    /// because it already bakes in alpha, and multiplying that via
    /// `withAlphaComponent` produced a muddy, heavy tint instead of the
    /// subtle "grouped inset" tone macOS Settings uses.
    static var sectionBoxFillColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(0.03)
                : NSColor.black.withAlphaComponent(0.02)
        }
    }

    static var sectionBoxBorderColor: NSColor {
        NSColor.separatorColor
    }

    // MARK: - Row typography + heights

    /// Regular row: `Input Tokens` / `25`.
    static let inspectorRowHeightRegular: CGFloat = 24
    static let inspectorRowLabelFontRegular: NSFont = .systemFont(ofSize: 13, weight: .regular)
    static let inspectorRowValueFontRegular: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    /// Sub-row: `    Ephemeral 1h` / `38,295`. 16pt additional leading indent.
    static let inspectorRowHeightSub: CGFloat = 22
    static let inspectorRowLabelFontSub: NSFont = .systemFont(ofSize: 12, weight: .regular)
    static let inspectorRowValueFontSub: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let inspectorSubRowIndent: CGFloat = 16

    /// Emphasis row: `Total Context` / `5,291,576`. Slightly taller.
    static let inspectorRowHeightEmphasis: CGFloat = 26
    static let inspectorRowLabelFontEmphasis: NSFont = .systemFont(ofSize: 13, weight: .semibold)
    static let inspectorRowValueFontEmphasis: NSFont = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)

    /// Divider inside a box — 0.5pt NSView with separatorColor backing.
    static let inspectorDividerThickness: CGFloat = 0.5
    static let inspectorDividerInsetH: CGFloat = 16
    static let inspectorDividerGapAbove: CGFloat = 8
    static let inspectorDividerGapBelow: CGFloat = 8

    // MARK: - Factories

    /// Selectable + copyable value label. Looks identical to a plain
    /// `NSTextField(labelWithString:)` but the user can click-drag to
    /// select the text and Cmd-C to copy. This is a hard requirement
    /// for the detail view — it's a data surface, not decorative chrome.
    ///
    /// Uses `wrappingLabelWithString:` which produces a label that is
    /// selectable by default (unlike `labelWithString:` which sets
    /// `isSelectable = false`). The wrapping mode is harmless for single
    /// lines and lets multi-line values (e.g. long model names, paths)
    /// flow naturally if the cell is wide enough.
    static func makeSelectableValueLabel(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .right
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        // `wrappingLabelWithString` leaves `isSelectable = true`, but we
        // re-assert here as a documentation anchor: if Apple ever flips
        // the default, this still renders as a selectable cell.
        field.isSelectable = true
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        // Single-line by default; values are one-liners. If a specific
        // field wants wrapping (e.g. a multi-line reason), the caller
        // can set `maximumNumberOfLines = 0` after construction.
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Non-selectable decorative label for static chrome (section
    /// headers, row names). Uses the classic `labelWithString:` API —
    /// no selection handle, no dragging. Users never need to copy
    /// "Cache Creation"; they copy the *value* next to it.
    static func makeChromeLabel(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        return field
    }

}

// MARK: - Cost formatting

/// Smart cost formatter — precision scales with magnitude so micro-costs
/// are still legible without rendering every row with 3 decimal places.
///
///   0             → "—"   (em-dash = "nothing billed")
///   < 0.001       → "<$0.001"
///   < 0.01        → "$0.XXX"  (3 decimals so sub-cent costs show)
///   >= 0.01       → "$X.XX"   (2 decimals across the normal range)
///   negative/NaN  → "—"       (defensive fallback; should never happen)
///
/// Kept as a free-standing enum (non-`@MainActor`) so unit tests can call
/// it directly without actor hops. `DetailStyles` is `@MainActor` because
/// of its NSFont/NSColor statics; pure string formatting has no reason to
/// share that isolation.
enum DetailCostFormatter {
    static func format(_ usd: Double) -> String {
        guard usd.isFinite, usd >= 0 else { return "—" }
        if usd == 0 { return "—" }
        if usd < 0.001 { return "<$0.001" }
        if usd < 0.01 { return String(format: "$%.3f", usd) }
        return String(format: "$%.2f", usd)
    }
}
