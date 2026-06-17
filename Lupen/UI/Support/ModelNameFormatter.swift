import Foundation

enum ModelNameFormatter {
    static func short(_ model: String) -> String {
        guard !model.isEmpty else { return "" }
        if let legacy = decodeLegacy(model) { return legacy }
        if model.hasPrefix("claude-") { return String(model.dropFirst("claude-".count)) }
        let lower = model.lowercased()
        if lower.hasPrefix("gpt-") { return formatGPT(lower) }
        if lower.hasPrefix("codex-") { return formatCodex(lower) }
        return model
    }

    private static func formatGPT(_ model: String) -> String {
        let rest = String(model.dropFirst("gpt-".count))
        let parts = rest.split(separator: "-").map(String.init)
        guard let first = parts.first else { return "GPT" }
        var words = ["GPT-\(formatGPTLead(first))"]
        words.append(contentsOf: parts.dropFirst().map(formatSuffixToken(_:)))
        return words.joined(separator: " ")
    }

    private static func formatCodex(_ model: String) -> String {
        let rest = String(model.dropFirst("codex-".count))
        let parts = rest.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return "Codex" }
        return (["Codex"] + parts.map(formatSuffixToken(_:))).joined(separator: " ")
    }

    private static func formatGPTLead(_ token: String) -> String {
        token == "oss" ? "OSS" : token
    }

    private static func formatSuffixToken(_ token: String) -> String {
        switch token {
        case "api":
            return "API"
        case "codex":
            return "Codex"
        case "gpt":
            return "GPT"
        case "mini":
            return "Mini"
        case "nano":
            return "Nano"
        case "oss":
            return "OSS"
        case "preview":
            return "Preview"
        case "turbo":
            return "Turbo"
        default:
            guard let first = token.first, first.isLetter else { return token }
            return first.uppercased() + String(token.dropFirst())
        }
    }

    private static func decodeLegacy(_ model: String) -> String? {
        guard model.hasPrefix("claude-") else { return nil }
        let rest = String(model.dropFirst("claude-".count))
        let parts = rest.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts.last?.count == 8, let _ = Int(parts.last!) else { return nil }
        let vp = Array(parts.dropLast())
        guard let major = vp.first, Int(major) != nil else { return nil }
        if vp.count >= 3, Int(vp[1]) != nil {
            return "\(vp[2...].joined(separator: "-"))-\(major).\(vp[1])"
        } else if vp.count >= 2 {
            return "\(vp[1...].joined(separator: "-"))-\(major)"
        }
        return nil
    }
}
