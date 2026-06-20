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
    static func display(
        cost: Double,
        confidence: CostConfidence,
        prefix: String = "",
        exactColor: NSColor? = nil,
        warningThreshold: Double = .infinity
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
        } else if cost <= 0.1 {
            return CostDisplay(text: "\(prefix)\(amount)", color: .tertiaryLabelColor)
        } else {
            return CostDisplay(text: "\(prefix)\(amount)", color: .labelColor)
        }
    }
}
