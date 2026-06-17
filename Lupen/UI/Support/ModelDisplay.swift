import AppKit

/// Per-family visual treatment for the "Model" column in the Turn outline.
///
/// Maps a raw Claude model id (`"claude-opus-4-7-20251022"`,
/// `"claude-sonnet-4-5"`, `"claude-haiku-4-5-20251001"`, …) to a pricing
/// **tier** and the text tint that tier renders as. The column uses
/// colored text rather than a pill / badge — Xcode Issue Navigator's
/// severity-tinted filename pattern — so the indicator rides inside the
/// normal NSTextField without eating extra row height.
///
/// Palette rationale (macos-ux-designer review):
///   * **Fable → `.systemIndigo`** — the tier above Opus. NOT pink:
///     dark-mode systemPink measures hue 348° vs systemRed's 359° —
///     visually the same red, and red already means deltas/errors/
///     cache-miss here, so fable rows read as failures. Indigo
///     (hue 234°, R109 G124 B255) sits between Opus purple (293°)
///     and Sonnet blue (206°) — premium-family adjacency without
///     colliding with either (28°+ apart, distinct chroma) and with
///     no error semantics anywhere in the app.
///   * **Opus → `.systemPurple`** — premium tier, matches Anthropic brand.
///   * **Sonnet → `.systemBlue`** — default / standard tier, accent-adjacent.
///   * **Haiku → `.systemTeal`** — fast tier. Intentionally **teal**, not
///     cyan: `.systemCyan` is reserved for `SkillGroup` / `SubAgent`
///     rows and mixing the two would make Haiku rows read as "part of
///     the sub-agent section."
///   * **GPT / Codex → `.systemGreen`** — OpenAI-family models get a
///     distinct non-Claude tint without competing with existing Claude
///     model colors.
///   * **Unknown / missing → `.secondaryLabelColor`** — a future model
///     or a non-assistant step still wants a legible fallback.
///
/// Dynamic system colors handle dark mode automatically; no dark-mode
/// override needed.
enum ModelDisplay {

    /// Claude pricing tier bucket. Driven purely by substring match on
    /// the model id so new version suffixes (`-4-7`, `-4-5-20251001`)
    /// Just Work without a table update.
    enum Tier: Int, Comparable {
        /// Highest-priority display slot. Ordering reflects typical
        /// cost / capability ladder, which is also the default sort
        /// order when the user clicks the Model column header
        /// (Fable → Opus → Sonnet → Haiku → GPT/Codex → Unknown).
        case fable = 0
        case opus = 1
        case sonnet = 2
        case haiku = 3
        case gpt = 4
        case unknown = 5

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Classify a raw model id into a tier. Case-insensitive substring
    /// match — `claude-opus-4-7-20251022`, `opus-4-7`, `Opus 4.7` all
    /// resolve to `.opus`.
    static func tier(for model: String?) -> Tier {
        guard let m = model?.lowercased(), !m.isEmpty else { return .unknown }
        if m.contains("fable")  { return .fable }
        if m.contains("opus")   { return .opus }
        if m.contains("sonnet") { return .sonnet }
        if m.contains("haiku")  { return .haiku }
        if m.hasPrefix("gpt-") || m.hasPrefix("codex-") || m.contains("openai") {
            return .gpt
        }
        return .unknown
    }

    /// Text tint for a tier. System dynamic colors, so light / dark
    /// adaptation is automatic.
    static func color(for tier: Tier) -> NSColor {
        switch tier {
        case .fable:   return .systemIndigo
        case .opus:    return .systemPurple
        case .sonnet:  return .systemBlue
        case .haiku:   return .systemTeal
        case .gpt:     return .systemGreen
        case .unknown: return .secondaryLabelColor
        }
    }

    /// Convenience: tint directly from a model id. Equivalent to
    /// `color(for: tier(for: model))` but collapses the two-step dance
    /// at call sites that never need the intermediate `Tier` value.
    static func color(for model: String?) -> NSColor {
        color(for: tier(for: model))
    }

    /// VoiceOver-friendly expansion of a short model label. Takes the
    /// `ModelNameFormatter.short` output (`"opus-4-7"`, `"sonnet-4-5"`)
    /// and returns a spoken form (`"Opus 4.7"`, `"Sonnet 4.5"`) so
    /// screen readers don't announce the hyphens verbatim.
    ///
    /// Unknown shapes pass through unchanged — better to read a raw id
    /// than to drop information.
    static func voiceOverLabel(short: String) -> String {
        guard !short.isEmpty else { return "" }
        // Split on "-" and decide: a token that's entirely digits joins
        // neighbouring digit tokens with a dot (`"4-7"` → `"4.7"`); all
        // other tokens keep their hyphenation but capitalise the first
        // (family) token.
        var parts = short.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return short }
        parts[0] = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
        // Coalesce trailing numeric components into a dotted version.
        var out: [String] = [parts[0]]
        var pendingVersion: [String] = []
        for token in parts.dropFirst() {
            if token.allSatisfy(\.isNumber) {
                pendingVersion.append(token)
            } else {
                if !pendingVersion.isEmpty {
                    out.append(pendingVersion.joined(separator: "."))
                    pendingVersion.removeAll()
                }
                out.append(token)
            }
        }
        if !pendingVersion.isEmpty {
            out.append(pendingVersion.joined(separator: "."))
        }
        return out.joined(separator: " ")
    }
}
