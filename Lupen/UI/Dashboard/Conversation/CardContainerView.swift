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
    private var copyButton: CardCopyButton?
    /// Body trailing: pinned to the card edge normally, re-pinned to the copy
    /// button's leading while a button is mounted so a long header (model · cost)
    /// never draws behind the icon. The column stays reserved even while the
    /// button is hover-hidden, so revealing it on hover doesn't reflow the body.
    private var bodyTrailingDefault: NSLayoutConstraint!
    private var bodyTrailingToButton: NSLayoutConstraint?
    private var hoverTrackingArea: NSTrackingArea?

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

        bodyTrailingDefault = bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset)
        NSLayoutConstraint.activate([
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            bodyTrailingDefault,
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

    /// Mount (or clear) the per-card Copy button in the top-trailing corner
    /// (D-6). Overlaid above the body so it doesn't shift content; the card
    /// header truncates behind it. Empty/nil text removes the button.
    func setCopyText(_ text: String?) {
        copyButton?.removeFromSuperview()
        copyButton = nil
        bodyTrailingToButton?.isActive = false
        bodyTrailingToButton = nil
        bodyTrailingDefault.isActive = true

        guard let text, !text.isEmpty else {
            updateTrackingAreas()
            return
        }
        let button = CardCopyButton.make(copyText: text)
        button.isHidden = true   // revealed on hover (mouseEntered)
        addSubview(button)       // added after bodyContainer → sits above it
        copyButton = button
        let topInset: CGFloat = hasShell ? 6 : 2

        // Reserve the button's column so body content never renders behind it.
        bodyTrailingDefault.isActive = false
        let toButton = bodyContainer.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8)
        bodyTrailingToButton = toButton

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toButton,
        ])
        updateTrackingAreas()
    }

    // MARK: - Hover reveal

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        // Only cards that actually have a copy button need hover tracking.
        guard copyButton != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        copyButton?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        copyButton?.isHidden = true
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
