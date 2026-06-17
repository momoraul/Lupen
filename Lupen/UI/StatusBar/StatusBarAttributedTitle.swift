import AppKit

/// Composes the menu-bar button's `attributedTitle` as a single
/// `NSAttributedString` that interleaves the binocular icon (via
/// inline `NSTextAttachment`) with the today-cost text.
///
/// ## Why a single attributed string instead of `image + title`
///
/// AppKit gives `NSStatusBarButton` both an `image` and a `title`
/// property. Setting them separately produces a faint horizontal gap
/// between glyph and digits — macOS measures the two as independent
/// boxes and inserts default leading whitespace between them. The gap
/// is most visible on Tahoe (macOS 26) but exists on earlier releases
/// too. Embedding the icon as a text-attachment inside the same
/// attributed string defeats that — AppKit lays the run out as one
/// typographic unit, no inter-element padding.
///
/// ## What it composes
///
/// - **Icon attachment**: an `NSImage` produced by
///   `StatusBarIconComposer.icon(for:limit:)`, sized to the menu-bar
///   content band, optionally tinted to surface 5-hour-limit pressure.
/// - **Cost text** (when shown): a monospaced-digit run so digit
///   columns don't jitter as the value crosses `9 → 10` or `99 → 100`.
/// - **Placeholder** (`...`): rendered as plain text when the store
///   hasn't loaded any data yet.
@MainActor
enum StatusBarAttributedTitle {

    /// Result of composing the title. Callers assign `.title` to
    /// `button.attributedTitle` and `.toolTip` to `button.toolTip`.
    /// `.toolTip` is nil unless one of the severity signals is active.
    struct Composed {
        let title: NSAttributedString
        let toolTip: String?
    }

    /// Pre-composed font for the digit run. File-scope `static let`
    /// because the same font is requested every observation tick and
    /// `NSFont.monospacedDigit…` is non-trivial to allocate.
    private static let monoFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular
    )

    /// Compose the attributed title.
    ///
    /// - Parameters:
    ///   - costText: Already-formatted cost string (e.g. `"$4.67"`).
    ///     Pass `nil` to render the icon alone (preference toggled
    ///     off, or a fresh install with nothing indexed yet).
    ///   - placeholder: True during true cold start (no cache, no
    ///     parse yet). Replaces cost with `"..."`.
    ///   - dimmed: Render the cost run in the secondary label color —
    ///     the `$0.00` idle state (6.13) keeps a lower visual weight
    ///     than a real spend total.
    ///   - badge: Parse-diagnostics severity — overlays a small
    ///     coloured dot on the icon's top-right.
    ///   - limit: 5-hour-limit consumption tier — tints the icon's
    ///     ring stroke.
    static func compose(costText: String?,
                        placeholder: Bool,
                        dimmed: Bool = false,
                        badge: StatusBarIconComposer.BadgeSeverity,
                        limit: StatusBarIconComposer.LimitSeverity) -> Composed {
        // 1. Icon as inline attachment. The image is the *only* visual
        //    element when costText is nil — the run starts and ends
        //    with the attachment.
        let attachment = NSTextAttachment()
        let icon = StatusBarIconComposer.icon(for: badge, limit: limit)
        attachment.image = icon
        // Center the icon's vertical midpoint with the digits' visual
        // midpoint. By default, `NSTextAttachment.bounds` anchors the
        // image's *bottom edge* to the text baseline, so a 14pt-tall
        // icon ends up 7pt above the baseline while the digits' visual
        // centre sits at roughly `capHeight / 2 ≈ 4.6 pt` for the
        // 13pt system font. The 2-ish pt mismatch was visible as the
        // icon "floating" above the dollar amount.
        //
        // Target: `bounds.origin.y + iconHeight/2 == capHeight/2`
        //   →    `bounds.origin.y = (capHeight - iconHeight) / 2`
        //
        // For the 13pt menu-bar font this resolves to about −2.4 pt
        // (the icon shifts down by ~2.4 pt). Reading the metric from
        // `monoFont.capHeight` instead of hard-coding makes the
        // alignment stay correct if a future macOS or accessibility
        // setting changes the resolved font size.
        let yOffset = (monoFont.capHeight - icon.size.height) / 2
        attachment.bounds = NSRect(
            x: 0,
            y: yOffset,
            width: icon.size.width,
            height: icon.size.height
        )

        let result = NSMutableAttributedString(attachment: attachment)

        // 2. Cost or placeholder. A non-breaking space ahead of the
        //    digits is the **only** spacing — no NSTextTab, no
        //    paragraph style. Empirically reads as a comfortable
        //    icon-text gap without the AppKit-inserted padding.
        let trailing: String?
        if placeholder {
            trailing = "\u{00A0}..."
        } else if let t = costText {
            trailing = "\u{00A0}\(t)"
        } else {
            trailing = nil
        }

        if let t = trailing {
            let digits = NSAttributedString(
                string: t,
                attributes: [
                    .font: monoFont,
                    .foregroundColor: dimmed
                        ? NSColor.secondaryLabelColor
                        : NSColor.labelColor,
                ]
            )
            result.append(digits)
        }

        return Composed(title: result, toolTip: toolTip(badge: badge, limit: limit))
    }

    /// Per-severity tooltip text. Limit pressure takes priority over
    /// parse diagnostics when both are active because the user can
    /// only read one tooltip at a time, and a depleted 5-hour window
    /// is more time-sensitive than a backlog of parse warnings.
    private static func toolTip(badge: StatusBarIconComposer.BadgeSeverity,
                                limit: StatusBarIconComposer.LimitSeverity) -> String? {
        switch limit {
        case .over100:
            return "Lupen · 5-hour limit reached. Window ▸ Reports for usage timeline."
        case .warn90:
            return "Lupen · 5-hour limit ≥ 90%. Window ▸ Reports for usage timeline."
        case .warn70:
            return "Lupen · 5-hour limit ≥ 70%."
        case .normal:
            break
        }
        switch badge {
        case .none:    return nil
        case .warning: return "Lupen · parse warnings recorded. Window ▸ Diagnostics…"
        case .error:   return "Lupen · parse errors recorded. Window ▸ Diagnostics…"
        }
    }
}
