import AppKit

/// Composes the status bar icon — two fused lens rings (matching the
/// app icon) + optional severity badge.
///
/// The app icon went through several design iterations (telescope →
/// full binoculars → two fused lens rims); the menu bar icon mirrors
/// the final form so the app reads as the same product across Dock,
/// Finder, Launchpad, and the menu bar. Kept as a **template image**
/// so macOS tints it per appearance (dark menu bar → white rings,
/// light menu bar → black rings) without us having to bundle two
/// colour variants.
///
/// When `ParseDiagnostics` surfaces a warning or error, the icon gets
/// a small colored dot in the top-right corner (Apple Mail / Messages
/// use the same affordance for unread / error states). When clean,
/// the plain two-ring template renders.
@MainActor
enum StatusBarIconComposer {

    /// Which badge to draw (if any).
    enum BadgeSeverity {
        case none
        case warning   // yellow dot — new unknown JSONL type
        case error     // red dot — malformed / missing field / bad timestamp
    }

    /// 5-hour-limit consumption tier. Tints the binocular **rings**
    /// (not the badge dot — that's the parse-diagnostics signal). Both
    /// signals overlay independently: an error-badge red dot can sit on
    /// top of an orange ring without ambiguity.
    ///
    /// `.normal` covers `nil` (API-key users with no 5-hour-window
    /// data) and `< 70%`. Tiers escalate in the standard early /
    /// mid / over progression so the user reads colour without having
    /// to remember an exact threshold.
    enum LimitSeverity {
        case normal     // < 70 % or nil (API-key user)
        case warn70     // 70-89 %
        case warn90     // 90-99 %
        case over100    // ≥ 100 %

        /// Resolves a raw 0…100+ percentage into the tier. `nil` →
        /// `.normal` because API-key users see no limit window at all.
        static func from(usedPercentage: Double?) -> LimitSeverity {
            guard let p = usedPercentage else { return .normal }
            if p >= 100 { return .over100 }
            if p >= 90 { return .warn90 }
            if p >= 70 { return .warn70 }
            return .normal
        }
    }

    /// Point dimensions of the base icon.
    ///
    /// Width chosen so two rings fit side-by-side tangent (no overlap)
    /// without crowding into the badge slot. Height keeps the rings
    /// inside macOS's ~22pt menu-bar content band with breathing room
    /// top and bottom.
    private static let iconSize = NSSize(width: 24, height: 14)

    /// Produces the menu bar icon. **Non-template** because the glyph
    /// carries its own warm gold + cream palette (matching the app
    /// icon) and a specular highlight — features a template's single-
    /// tint semantic can't express. Colours are appearance-aware via
    /// `NSAppearance.currentDrawing()` inside the drawing handler, so
    /// the same `NSImage` re-renders correctly when the user toggles
    /// system dark/light mode.
    ///
    /// `limit` tints the ring stroke (yellow / orange / red at 70 / 90
    /// / 100 % thresholds). Independent from `for` (parse-diagnostics
    /// badge dot) — both signals can fire simultaneously.
    static func icon(for severity: BadgeSeverity,
                     limit: LimitSeverity = .normal) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { rect in
            drawRings(in: rect, limit: limit)
            if severity != .none {
                // Badge: ~5pt dot, top-right, 0.5pt inset.
                let dotDiameter: CGFloat = 5
                let inset: CGFloat = 0.5
                let dotRect = NSRect(
                    x: rect.maxX - dotDiameter - inset,
                    y: rect.maxY - dotDiameter - inset,
                    width: dotDiameter,
                    height: dotDiameter
                )
                let color: NSColor = severity == .error ? .systemRed : .systemOrange
                color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Shared geometry constants so tests and production render with
    /// the same numbers.
    struct RingGeometry {
        let leftCenter: NSPoint
        let rightCenter: NSPoint
        let radius: CGFloat
        let strokeWidth: CGFloat
    }

    /// Resolves ring geometry for a given icon bounds. Centres at
    /// 25% / 75% of the width on the vertical midline; radius tuned so
    /// the two rings are **exactly tangent** (centre distance = 2 ×
    /// radius), giving the "joined" binocular read without the
    /// over-fused blob of a heavy overlap.
    static func geometry(in rect: NSRect) -> RingGeometry {
        let radius = rect.width * 0.25
        let leftCenter  = NSPoint(x: rect.minX + rect.width * 0.25, y: rect.midY)
        let rightCenter = NSPoint(x: rect.minX + rect.width * 0.75, y: rect.midY)
        return RingGeometry(
            leftCenter: leftCenter,
            rightCenter: rightCenter,
            radius: radius,
            strokeWidth: 1.5
        )
    }

    /// Draws two tangent rings with cream interior + gold rim +
    /// specular highlight into the current graphics context. Palette
    /// switches per appearance so both a translucent dark menu bar
    /// and a translucent light menu bar carry enough contrast. When
    /// `limit` is non-`.normal` the rim swaps to a system warning hue
    /// so the user spots their 5-hour-limit pressure without opening
    /// any dashboard.
    private static func drawRings(in rect: NSRect, limit: LimitSeverity = .normal) {
        let geo = geometry(in: rect)
        let palette = Palette.forCurrentAppearance(limit: limit)

        // 1) Inner fill — low-alpha cream disc, giving each lens a
        //    subtle warm "glow" without overpowering the rim.
        palette.interior.setFill()
        for centre in [geo.leftCenter, geo.rightCenter] {
            let innerRadius = geo.radius - geo.strokeWidth * 0.5
            let disc = NSBezierPath(ovalIn: NSRect(
                x: centre.x - innerRadius, y: centre.y - innerRadius,
                width: innerRadius * 2, height: innerRadius * 2
            ))
            disc.fill()
        }

        // 2) Gold rim — solid stroke. `strokeWidth / 2` inset so the
        //    painted outer edge lands exactly on `geo.radius`.
        palette.rim.setStroke()
        for centre in [geo.leftCenter, geo.rightCenter] {
            let rRect = NSRect(
                x: centre.x - geo.radius + geo.strokeWidth / 2,
                y: centre.y - geo.radius + geo.strokeWidth / 2,
                width: (geo.radius - geo.strokeWidth / 2) * 2,
                height: (geo.radius - geo.strokeWidth / 2) * 2
            )
            let path = NSBezierPath(ovalIn: rRect)
            path.lineWidth = geo.strokeWidth
            path.stroke()
        }

        // 3) Specular highlight — small dot inside each lens, biased
        //    toward the upper-left quadrant so it reads as "light from
        //    the upper-left" (the convention shared with the app icon
        //    and most Apple-shipped glyphs). The earlier iteration
        //    pulled it 2pt inward and the dot ended up too close to
        //    the lens centre; 1pt keeps the visual "detached from the
        //    rim" gap the user asked for while preserving the
        //    upper-left bias. Brightness is `labelColor @ 0.55`,
        //    midway between the rim (1.0) and the interior fill
        //    (~0.22), so it reads as a glassy catch-light rather than
        //    a bright pop.
        palette.specular.setFill()
        let highlightRadius = geo.radius * 0.22
        for centre in [geo.leftCenter, geo.rightCenter] {
            let dotCentre = NSPoint(
                x: centre.x - geo.radius * 0.40 + 1,
                y: centre.y + geo.radius * 0.40 - 1
            )
            let dotRect = NSRect(
                x: dotCentre.x - highlightRadius,
                y: dotCentre.y - highlightRadius,
                width: highlightRadius * 2,
                height: highlightRadius * 2
            )
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    /// Appearance-aware palette for the menu-bar glyph.
    ///
    /// Monochrome rim to match neighbouring menu-bar text (NSLabelColor
    /// resolves per appearance → white on dark bars, near-black on
    /// light bars). Only the **interior** carries a warm cream tint at
    /// a low alpha so it reads as a subtle glass-lens glow rather than
    /// a coloured spot. Specular dot is `labelColor @ 0.55` so its
    /// brightness lands **midway between the solid rim and the
    /// low-alpha interior** on both appearances.
    private struct Palette {
        let rim: NSColor
        let interior: NSColor
        let specular: NSColor

        static func forCurrentAppearance(limit: LimitSeverity = .normal) -> Palette {
            let appearance = NSAppearance.currentDrawing()
            let isDark = appearance.bestMatch(
                from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]
            ).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? true

            // Rim default: pure `labelColor` so the rings match the
            // adjacent clock / app-menu text. When `limit` escalates,
            // swap to a system warning hue — these colours render
            // correctly in both light and dark menu bars without
            // appearance-specific tuning. Specular stays at
            // labelColor @ 0.55 alpha so the catch-light reads as a
            // glassy reflection regardless of rim tint.
            let rim: NSColor
            switch limit {
            case .normal:   rim = .labelColor
            case .warn70:   rim = .systemYellow
            case .warn90:   rim = .systemOrange
            case .over100:  rim = .systemRed
            }
            let specular = NSColor.labelColor.withAlphaComponent(0.55)

            // Interior cream flavoured per appearance: a light cream
            // at 28% alpha on dark bars reads as a faint warm glow;
            // on light bars the same hue would vanish into the
            // near-white background, so a darker warm-amber at 22%
            // alpha is substituted. Warmth stays constant; only
            // lightness flips per appearance.
            let interior: NSColor
            if isDark {
                interior = NSColor(srgbRed: 0.941, green: 0.918, blue: 0.859, alpha: 0.28)
            } else {
                interior = NSColor(srgbRed: 0.424, green: 0.318, blue: 0.118, alpha: 0.22)
            }
            return Palette(rim: rim, interior: interior, specular: specular)
        }
    }
}
