import Foundation

enum CostFormatter {
    static let emDash = "\u{2014}"

    static func compact(_ usd: Double?) -> String {
        guard let usd else { return emDash }
        if usd < 0.0005 { return "<$0.001" }
        else if usd < 1.0 { return String(format: "$%.3f", usd) }
        else if usd < 100.0 { return String(format: "$%.2f", usd) }
        else { return String(format: "$%.0f", usd) }
    }

    /// Whole-dollar variant for the menu-bar item when the user opts
    /// into "compact" mode. `$0` is misleading at small amounts (the
    /// user *did* spend money), so anything under $1 reports as `<$1`
    /// — same pattern CCUM and ccusage use for "below visible
    /// precision". `≥ 0.5` rounds up so a $0.50 day shows `$1`, not
    /// `$0`.
    static func compactWhole(_ usd: Double?) -> String {
        guard let usd else { return emDash }
        if usd < 0.5 { return "<$1" }
        return String(format: "$%.0f", usd.rounded())
    }
}

enum CostConfidencePresentation {
    static func label(totalCost: Double, confidence: CostConfidence) -> String {
        switch confidence {
        case .partial:
            return "≈\(CostFormatter.compact(totalCost))"
        case .unavailable:
            return "N/A"
        case .notBillable, .exact:
            return CostFormatter.compact(totalCost)
        }
    }

    static func sidebarTooltip(provider: ProviderKind, confidence: CostConfidence) -> String? {
        guard provider == .codex else { return nil }
        var lines = [
            "Codex cost estimate: fresh input + cached input + output + reasoning output.",
            "CW/TTL are not present in Codex local data.",
        ]
        switch confidence {
        case .partial:
            lines.append("Some requests use unknown or unpriced models, so this is a lower-bound estimate.")
        case .unavailable:
            lines.append("No reliable dollar estimate is shown because local pricing is unavailable for this session.")
        case .notBillable, .exact:
            break
        }
        return lines.joined(separator: "\n")
    }

    static func outlineTooltip(provider: ProviderKind, confidence: CostConfidence) -> String? {
        guard provider == .codex else { return nil }
        let formula = "Codex estimate: fresh input + cached input + output + reasoning output. CW/TTL are not present in Codex local data."
        switch confidence {
        case .exact:
            return formula
        case .partial:
            return "\(formula)\nPartial: at least one Codex request has unavailable model pricing, so this row excludes part of the cost."
        case .unavailable:
            return "\(formula)\nCost unavailable: Lupen does not have pricing for this Codex model yet."
        case .notBillable:
            return nil
        }
    }
}
