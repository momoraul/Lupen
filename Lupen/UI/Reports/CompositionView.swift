//
//  CompositionView.swift
//  Lupen
//
//  Created by jaden on 2026/07/05.
//

import SwiftUI
import AppKit

/// Composition breakdown (C-25) — "where did this scope's cost / tokens go, by
/// content category?" Shown in Reports (a date range) and in the conversation
/// Detail pane (a session or a turn), so it takes a pre-computed
/// `ContextComposition.Result` plus a `scopeLabel`.
///
/// Two lenses, toggled by a segmented control (default **Cost** — dollars are
/// the on-brand answer; switching to **Tokens** reveals that context volume
/// dwarfs generation even though generation drives the bill):
///
/// - **Cost** — one unified 100% stacked bar of the total $ by category, led by
///   a hero total and a one-line "biggest driver" insight.
/// - **Tokens** — two bars, Generation (output split) and Context (what fills
///   the window), each normalized to its own total.
///
/// Honesty: the totals are real billed numbers; per-category splits are
/// estimated from content length and marked with a leading `~`. Palette is
/// Paul Tol's colour-blind-safe *bright* set; the un-itemizable system baseline
/// uses Tol's neutral grey and is pinned to the end of every bar and table.
@MainActor
struct CompositionView: View {

    let result: ContextComposition.Result
    /// e.g. "this range" (Reports) · "this session" / "this turn" (Detail).
    var scopeLabel: String = "this range"
    /// Individual tool outputs ranked by carry cost — the "Top cost drivers"
    /// list. Empty for turn scope (re-read carry is a multi-turn concept).
    var topToolOutputs: [ToolOutputCost] = []
    /// Fired when the user toggles the lens, so an AppKit host can persist the
    /// choice across selections (SwiftUI `@State` alone resets when the hosting
    /// view is rebuilt) and keep its footer/export in sync.
    var onModeChange: ((Mode) -> Void)?

    enum Mode: String, CaseIterable, Identifiable {
        case cost, tokens
        var id: String { rawValue }
        var title: String { self == .cost ? "Cost" : "Tokens" }
    }

    @State private var mode: Mode
    /// Category under the cursor (bar segment or legend row) — the rest dim.
    @State private var hovered: ContextComposition.Category? = nil

    init(
        result: ContextComposition.Result,
        scopeLabel: String = "this range",
        topToolOutputs: [ToolOutputCost] = [],
        initialMode: Mode = .cost,
        onModeChange: ((Mode) -> Void)? = nil
    ) {
        self.result = result
        self.scopeLabel = scopeLabel
        self.topToolOutputs = topToolOutputs
        self.onModeChange = onModeChange
        self._mode = State(initialValue: initialMode)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                modePicker
                if mode == .cost {
                    costLens
                } else {
                    tokensLens
                }
                if !topToolOutputs.isEmpty {
                    topDriversSection
                }
                estimateNote
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only the hover dim animates; the view never animates on the
            // repeated refreshes that happen as the pane re-renders.
            .animation(.easeOut(duration: 0.14), value: hovered)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: mode) { _, newValue in onModeChange?(newValue) }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Cost lens

    @ViewBuilder
    private var costLens: some View {
        if result.hasCostData {
            let segs = costSegments()
            VStack(alignment: .leading, spacing: 14) {
                costHero
                stackedBar(segs)
                legend(segs, total: result.totalCostUSD, isCost: true)
                Text("What your \(scopeWord) spend went toward. Output generation (thinking · replies · tool calls) is billed at a premium, so it usually dominates cost even when it's a small share of token volume.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            unavailableCost
        }
    }

    private var costHero: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(heroUSD(result.totalCostUSD))
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text("Total cost · \(scopeLabel)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let top = result.topCost {
                (Text(top.category.label).fontWeight(.semibold)
                 + Text(" was the biggest cost — ")
                 + Text("\(exactUSD(top.costUSD)) (\(percent(top.share)))").fontWeight(.semibold))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var unavailableCost: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cost breakdown unavailable")
                .font(.system(size: 13, weight: .medium))
            Text("No priced requests in \(scopeLabel). Switch to Tokens to see the content breakdown.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    // MARK: - Tokens lens

    @ViewBuilder
    private var tokensLens: some View {
        VStack(alignment: .leading, spacing: 18) {
            tokenSection(
                title: "Generation",
                caption: generationCaption,
                segs: tokenSegments(result.generation),
                total: result.generationTokens,
                footnote: "Where the model's output tokens went. Thinking is billed as output — a large share often explains a pricey session."
            )
            tokenSection(
                title: "Context",
                caption: "≈ \(TimelineOverviewView.formatTokens(result.contextTokens)) tokens of content",
                segs: tokenSegments(result.context),
                total: result.contextTokens,
                footnote: "What fills the context carried each turn. “System & tools” is a per-session baseline (system prompt · tool schemas · initial context) that can't be itemized."
            )
        }
    }

    private var generationCaption: String {
        var parts = ["\(TimelineOverviewView.formatTokens(result.generationTokens)) output tokens"]
        if let share = result.thinkingShare, share > 0 {
            parts.append("\(percent(share)) thinking")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func tokenSection(
        title: String, caption: String, segs: [Seg], total: Int, footnote: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(caption)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            stackedBar(segs)
            legend(segs, total: Double(total), isCost: false)
            Text(footnote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Stacked bar

    /// One bar segment. `value` is $ (cost lens) or est tokens (tokens lens).
    private struct Seg: Identifiable {
        let category: ContextComposition.Category
        let value: Double
        let isEstimate: Bool
        var id: String { category.rawValue }
    }

    private func stackedBar(_ segs: [Seg]) -> some View {
        let total = segs.reduce(0) { $0 + $1.value }
        let isCost = mode == .cost
        return GeometryReader { geo in
            // A small minimum width keeps sub-1% categories visible and
            // hoverable — but only when there's room, so a narrow Detail pane
            // (or a transient 0-width layout pass) never overflows and clips
            // the pinned baseline segment. The legend carries the exact value.
            let floor: CGFloat = (total > 0 && geo.size.width >= 40) ? 2 : 0
            HStack(spacing: 1) {
                ForEach(segs) { seg in
                    color(for: seg.category)
                        .opacity(dimmed(seg.category) ? 0.4 : 1)
                        .frame(width: max(floor, geo.size.width * fraction(seg.value, total)))
                        .onHover { hovered = $0 ? seg.category : nil }
                        .help("\(seg.category.label): \(valueText(seg.value, isCost: isCost)) · \(percent(fraction(seg.value, total)))")
                }
            }
        }
        .frame(height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Legend / value table

    private func legend(_ segs: [Seg], total: Double, isCost: Bool) -> some View {
        VStack(spacing: 2) {
            ForEach(segs) { seg in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(color(for: seg.category))
                        .frame(width: 10, height: 10)
                    Text(seg.category.label)
                        .font(.system(size: 12))
                    if !seg.isEstimate {
                        Text("actual")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                    Spacer(minLength: 8)
                    Text(percent(fraction(seg.value, total)))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                    Text((seg.isEstimate ? "~" : "") + valueText(seg.value, isCost: isCost))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: 78, alignment: .trailing)
                }
                .opacity(dimmed(seg.category) ? 0.45 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? seg.category : nil }
            }
        }
    }

    // MARK: - Top cost drivers

    private var topDriversSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)
            HStack(alignment: .firstTextBaseline) {
                Text("Top cost drivers")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("largest tool outputs by carry cost")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 3) {
                ForEach(Array(topToolOutputs.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.toolName)
                                .font(.system(size: 12, weight: .medium))
                            if let summary = item.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
                        Text("~\(TimelineOverviewView.formatTokens(item.estTokens)) · ×\(item.turnsCarried)")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("~" + exactUSD(item.estCostUSD))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
            }
            Text("Carry cost ≈ output size × turns re-read × cache-read rate — an early, large tool output is re-read (and re-billed) every following turn. Estimated; a /compact resets carry (not modeled, so long compacted sessions may over-count). Ranking order is the robust signal.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Header note

    private var estimateNote: some View {
        Label(
            "Totals are your exact billed numbers. Category splits are estimated (~) from content length (~\(String(format: "%.1f", ContextComposition.defaultCharsPerToken)) chars/token).",
            systemImage: "info.circle"
        )
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Segment builders (baseline pinned last)

    private func costSegments() -> [Seg] {
        ordered(result.cost.map { Seg(category: $0.category, value: $0.costUSD, isEstimate: $0.isEstimate) })
    }

    private func tokenSegments(_ slices: [ContextComposition.Slice]) -> [Seg] {
        ordered(slices.map { Seg(category: $0.category, value: Double($0.estTokens), isEstimate: $0.isEstimate) })
    }

    /// Largest value first, with the system baseline always last (ONS "other"
    /// rule) so the bar and table read stably regardless of its magnitude.
    private func ordered(_ segs: [Seg]) -> [Seg] {
        segs.sorted { a, b in
            if a.category == .systemBaseline { return false }
            if b.category == .systemBaseline { return true }
            return a.value > b.value
        }
    }

    // MARK: - Helpers

    private func dimmed(_ c: ContextComposition.Category) -> Bool {
        hovered != nil && hovered != c
    }

    private func fraction(_ v: Double, _ total: Double) -> Double {
        total > 0 ? v / total : 0
    }

    private func percent(_ f: Double) -> String {
        let p = f * 100
        if p <= 0 { return "0%" }
        if p < 1 { return "<1%" }
        return "\(Int(p.rounded()))%"
    }

    private func valueText(_ v: Double, isCost: Bool) -> String {
        isCost ? exactUSD(v) : TimelineOverviewView.formatTokens(Int(v.rounded()))
    }

    /// Row-level $ — exact to the cent, with a sub-cent floor.
    private func exactUSD(_ v: Double) -> String {
        if v <= 0 { return "$0" }
        if v < 0.01 { return "<$0.01" }
        if v < 1 { return String(format: "$%.3f", v) }
        return String(format: "$%.2f", v)
    }

    /// Hero $ — humanized for large amounts, exact below $1000.
    private func heroUSD(_ v: Double) -> String {
        if v <= 0 { return "$0.00" }
        if v < 0.01 { return "<$0.01" }
        if v < 1000 { return String(format: "$%.2f", v) }
        return String(format: "$%.1fK", v / 1000)
    }

    private var scopeWord: String {
        scopeLabel.replacingOccurrences(of: "this ", with: "")
    }

    private func color(for c: ContextComposition.Category) -> Color {
        Color(nsColor: Self.paletteColors[c] ?? .secondaryLabelColor)
    }

    /// Paul Tol *bright* — colour-blind-safe; the system baseline uses Tol's
    /// neutral grey. Dynamic light/dark variants (brighter, lightly desaturated
    /// on dark) so the marks read on both appearances. Built once — the palette
    /// is static, so it must not re-allocate per body render.
    private static let paletteColors: [ContextComposition.Category: NSColor] = {
        func dyn(_ light: (Int, Int, Int), _ dark: (Int, Int, Int)) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let (r, g, b) = isDark ? dark : light
                return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                               blue: CGFloat(b) / 255, alpha: 1)
            }
        }
        return [
            .thinking:       dyn((170, 51, 119), (194, 102, 160)),
            .reply:          dyn((68, 119, 170), (102, 153, 204)),
            .toolCall:       dyn((238, 102, 119), (240, 136, 148)),
            .prompt:         dyn((34, 136, 51), (76, 175, 99)),
            .toolInput:      dyn((204, 187, 68), (219, 208, 107)),
            .toolOutput:     dyn((102, 204, 238), (143, 217, 242)),
            .systemBaseline: dyn((178, 178, 178), (146, 146, 146)),
        ]
    }()
}
