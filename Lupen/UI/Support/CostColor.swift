import AppKit

/// Decided text + color for a cost figure. Shared single source of truth
/// for the turn outline's Cost column and the sidebar session row, so the
/// two surfaces tint identical amounts identically.
struct CostDisplay {
    let text: String
    let color: NSColor
}

/// Maps (cost, confidence) to the displayed string and semantic color.
/// Rules mirror the historical `TurnOutlineViewController.prefixedCostAttr`
/// exactly — extracted here so the sidebar can reuse them without
/// duplicating the ladder. Pure function; no AppKit state beyond `NSColor`.
enum CostColor {
    /// Accent for "real" amounts (>= $1) on the sidebar. Light mode uses the
    /// systemOrange value (clear on white). Dark mode uses a softer tan that
    /// sits closer to the title's near-white label color, so on a dark row the
    /// cost reads as a gentle highlight rather than a hot orange. Same warm
    /// family as the partial/warning orange; N/A is the slate `unavailable`.
    static let accent = NSColor(name: "CostAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 232.0 / 255, green: 185.0 / 255, blue: 126.0 / 255, alpha: 1)
            : NSColor(srgbRed: 255.0 / 255, green: 149.0 / 255, blue: 0.0, alpha: 1)
    }

    /// Unavailable cost (N/A): a calm slate that reads as "not measured"
    /// rather than competing with the orange cost figures, and distinct from
    /// the plain dim gray used for sub-$1 amounts. Dynamic per appearance —
    /// lighter slate on dark, deeper slate on light.
    static let unavailable = NSColor(name: "CostUnavailable") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 144.0 / 255, green: 160.0 / 255, blue: 180.0 / 255, alpha: 1)
            : NSColor(srgbRed: 94.0 / 255, green: 110.0 / 255, blue: 130.0 / 255, alpha: 1)
    }

    static func display(
        cost: Double,
        confidence: CostConfidence,
        prefix: String = "",
        exactColor: NSColor? = nil,
        warningThreshold: Double = .infinity,
        accentColor: NSColor? = nil
    ) -> CostDisplay {
        if confidence == .unavailable {
            return CostDisplay(text: "\(prefix)N/A", color: unavailable)
        }
        guard cost > 0 else {
            return CostDisplay(text: "\(prefix)\(CostFormatter.emDash)", color: .quaternaryLabelColor)
        }
        let amount = CostFormatter.compact(cost)
        if confidence == .partial {
            return CostDisplay(text: "\(prefix)≈\(amount)", color: .systemOrange)
        } else if cost >= warningThreshold {
            return CostDisplay(text: "\(prefix)\(amount)", color: .systemOrange)
        } else if let exactColor {
            return CostDisplay(text: "\(prefix)\(amount)", color: exactColor)
        } else if let accentColor {
            // Opt-in (sidebar): >= $1 gets the warm accent so the cost reads a
            // touch apart from the title; below $1 stays dim. Callers that
            // don't pass `accentColor` (e.g. the turn outline) keep the legacy
            // dim-below-0.1 / label-color ladder unchanged.
            return CostDisplay(
                text: "\(prefix)\(amount)",
                color: cost >= 1 ? accentColor : .tertiaryLabelColor
            )
        } else if cost <= 0.1 {
            return CostDisplay(text: "\(prefix)\(amount)", color: .tertiaryLabelColor)
        } else {
            return CostDisplay(text: "\(prefix)\(amount)", color: .labelColor)
        }
    }
}
