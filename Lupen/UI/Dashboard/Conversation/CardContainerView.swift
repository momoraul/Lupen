//
//  CardContainerView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Common shell for every conversation card: a role gutter + a tier-based
/// surface (background/border/gutter width) + a body slot.
///
/// Role (user/assistant/system/subAgent) picks the color; tier
/// (primary/secondary) picks the strength, so important dialogue (prompts /
/// final replies = primary) reads more sharply than supporting content
/// (tools / thinking = secondary). The selected Step card is emphasized with an
/// accent border. The surface tint is a low-alpha foreground overlay
/// (labelColor, etc.) so it keeps contrast against the background in both dark
/// and light modes (fixes the dark-mode sink of the old textBackgroundColor
/// approach).
@MainActor
final class CardContainerView: NSView {

    private let gutter = NSView()
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

    private func setup() {
        layer?.cornerRadius = 8
        // Only body (primary) / selected cards draw a shell (background/border/
        // gutter). Supporting (secondary: thinking·tools) cards render as an
        // indented single line with no shell → less noise, body stands out.
        let showShell = tier == .primary || highlighted
        layer?.borderWidth = highlighted ? 1.5 : (showShell ? 0.75 : 0)

        gutter.wantsLayer = true
        gutter.layer?.cornerRadius = 2
        gutter.isHidden = !showShell
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyContainer)

        let verticalInset: CGFloat = showShell ? 12 : 4      // supporting cards are flatter
        let bodyLeadingInset: CGFloat = showShell ? 0 : 26   // supporting cards are indented
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            gutter.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            gutter.widthAnchor.constraint(equalToConstant: 4),

            bodyContainer.leadingAnchor.constraint(
                equalTo: showShell ? gutter.trailingAnchor : leadingAnchor,
                constant: showShell ? 10 : bodyLeadingInset
            ),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bodyContainer.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Recompute layer colors for the current appearance (dark/light).
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let showShell = tier == .primary || highlighted
            layer?.backgroundColor = showShell
                ? Self.surfaceColor(role: role, tier: tier, highlighted: highlighted).cgColor
                : NSColor.clear.cgColor
            layer?.borderColor = (highlighted
                ? Self.accentColor(for: role).withAlphaComponent(0.7)
                : NSColor.separatorColor.withAlphaComponent(0.5)).cgColor
            gutter.layer?.backgroundColor = Self.accentColor(for: role).cgColor
        }
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

    /// Role accent color (gutter + emphasis border). systemYellow has poor dark
    /// contrast, so it is avoided.
    static func accentColor(for role: BlockRole) -> NSColor {
        switch role {
        case .user:      return .systemTeal
        case .assistant: return .controlAccentColor
        case .system:    return .systemOrange
        case .subAgent:  return .systemPurple
        }
    }

    /// Role×tier surface tint. A low-alpha foreground overlay keeps contrast in
    /// both dark and light modes. primary (prompts·replies) is stronger,
    /// secondary (tools·thinking) is lighter → hierarchy.
    static func surfaceColor(role: BlockRole, tier: BlockTier, highlighted: Bool) -> NSColor {
        if highlighted { return accentColor(for: role).withAlphaComponent(0.12) }
        let base: NSColor
        switch role {
        case .user:      base = .systemTeal
        case .assistant: base = .labelColor   // neutral foreground — dark = white low-alpha, light = black low-alpha
        case .system:    base = .systemOrange
        case .subAgent:  base = .systemPurple
        }
        return base.withAlphaComponent(tier == .primary ? 0.09 : 0.04)
    }
}
