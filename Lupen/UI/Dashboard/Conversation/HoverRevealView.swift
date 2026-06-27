//
//  HoverRevealView.swift
//  Lupen
//
//  Created by jaden on 2026/06/28.
//

import AppKit

/// NSView base that reveals a `CardCopyButton` only while the pointer is over
/// the view. Shared by `CardContainerView` and `CodeBlockView` so the
/// tracking-area boilerplate lives in one place.
///
/// It keeps the button visible while a copy confirmation is animating — so the
/// green checkmark is still seen when the pointer leaves right after clicking
/// (the common "copy then move away to paste" gesture).
@MainActor
class HoverRevealView: NSView {

    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    /// The button revealed on hover. Assigning wires confirmation tracking and
    /// the initial (hidden) visibility; `nil` removes tracking.
    var hoverRevealButton: CardCopyButton? {
        didSet {
            oldValue?.onConfirmationChanged = nil
            hoverRevealButton?.onConfirmationChanged = { [weak self] in
                self?.updateHoverButtonVisibility()
            }
            updateHoverButtonVisibility()
            updateTrackingAreas()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        guard hoverRevealButton != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoverButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHoverButtonVisibility()
    }

    private func updateHoverButtonVisibility() {
        guard let button = hoverRevealButton else { return }
        button.isHidden = !(isHovered || button.isShowingConfirmation)
    }
}
