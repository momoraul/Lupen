//
//  CardContainerView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Common shell for every conversation card. Cards are KEPT — they give the
/// dialogue containment, a single left baseline, and block-level scan anchors —
/// but their chrome is turned down so the body text is the clear focal point:
///
/// - Every primary block (prompt / reply / status) sits in a quiet card: a
///   1-device-pixel hairline border (`DetailStyles.conversationCardBorderColor`) + a
///   faint neutral fill, matching the grouped boxes used elsewhere in the pane.
/// - The reply uses the lightest fill (`sectionBoxFillColor`); the prompt/status
///   a touch more (`conversationPromptFillColor`) so the speaker reads from a
///   subtle asymmetry rather than a role color.
/// - Role is whispered through the header icon tint only — no full-color gutter.
/// - Supporting content (thinking·tools = secondary) gets no shell: just an
///   indented gray line so it recedes.
/// - The selected Step is marked by an accent-colored border + a faint accent
///   fill (selection is one-way, tree → card).
///
/// Hierarchy comes from turning chrome down (quiet border, neutral fill, grayed
/// headers), not from removing the card — a frame-less reply lost its left
/// baseline and containment and read as crude.
@MainActor
final class CardContainerView: NSView {

    private let bodyContainer = NSView()
    private let role: BlockRole
    private let tier: BlockTier
    private let highlighted: Bool

    init(role: BlockRole, tier: BlockTier, highlighted: Bool) {
        self.role = role
        self.tier = tier
        self.highlighted = highlighted
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Primary blocks (and any selected block) get the card shell: border, fill,
    /// padding. Supporting blocks render as an indented, shell-less line.
    private var hasShell: Bool { tier == .primary || highlighted }

    private func setup() {
        layer?.cornerRadius = 8
        layer?.borderWidth = borderWidth()

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyContainer)

        // Shelled cards carry inner padding; supporting lines indent instead.
        let vInset: CGFloat = hasShell ? 10 : 4
        let leadingInset: CGFloat = hasShell ? 14 : 24
        let trailingInset: CGFloat = hasShell ? 14 : 12

        NSLayoutConstraint.activate([
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            bodyContainer.topAnchor.constraint(equalTo: topAnchor, constant: vInset),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vInset),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The border is a device-pixel width, so its point value depends on the
        // display scale — reapply when the window moves between displays.
        layer?.borderWidth = borderWidth()
    }

    /// 1 device pixel normally; 2 device pixels when selected (the accent border
    /// is the selection cue, so it reads a touch heavier). 0 for shell-less
    /// supporting blocks.
    private func borderWidth() -> CGFloat {
        guard hasShell else { return 0 }
        let hairline = DetailStyles.hairlineWidth(for: self)
        return highlighted ? hairline * 2 : hairline
    }

    /// Recompute layer colors for the current appearance (dark/light).
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundFill().cgColor
            layer?.borderColor = borderColor().cgColor
        }
    }

    /// Quiet, neutral fills. The reply gets the lightest tint; the prompt/status
    /// a touch more so the speaker reads from the asymmetry, not a role color.
    private func backgroundFill() -> NSColor {
        if highlighted { return Self.accentColor(for: role).withAlphaComponent(0.10) }
        guard tier == .primary else { return .clear }
        switch role {
        case .user, .system:        return DetailStyles.conversationPromptFillColor
        case .assistant, .subAgent: return DetailStyles.sectionBoxFillColor
        }
    }

    /// Neutral hairline normally; the role accent when selected (the one cue that
    /// marks the tree-selected Step on the otherwise quiet surface).
    private func borderColor() -> NSColor {
        if highlighted { return Self.accentColor(for: role) }
        return hasShell ? DetailStyles.conversationCardBorderColor : .clear
    }

    func setBody(_ view: NSView) {
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
    }

    /// Role accent color (selected border + selected fill + header icon tint).
    /// systemYellow has poor dark contrast, so it is avoided.
    static func accentColor(for role: BlockRole) -> NSColor {
        switch role {
        case .user:      return .systemTeal
        case .assistant: return .controlAccentColor
        case .system:    return .systemOrange
        case .subAgent:  return .systemPurple
        }
    }
}
