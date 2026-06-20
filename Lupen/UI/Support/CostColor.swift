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
    /// Accent for "real" amounts (>= $1): a warm gold that reads a touch
    /// apart from the title's `labelColor` without clashing, so the title /
    /// cost boundary stays legible even when they nearly touch. Dynamic per
    /// appearance — soft gold on dark, deep amber on light (the light dollar
    /// has to darken since yellow washes out on a white row). Amounts under
    /// $1 stay dim (`tertiaryLabelColor`); N/A and warnings keep their orange.
    nonisolated(unsafe) static let accent = NSColor(name: "CostAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 230.0 / 255, green: 206.0 / 255, blue: 130.0 / 255, alpha: 1)
            : NSColor(srgbRed: 176.0 / 255, green: 122.0 / 255, blue: 10.0 / 255, alpha: 1)
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
            return CostDisplay(text: "\(prefix)N/A", color: .systemOrange)
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
