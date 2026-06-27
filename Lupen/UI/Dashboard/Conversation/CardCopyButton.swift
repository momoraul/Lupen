//
//  CardCopyButton.swift
//  Lupen
//
//  Created by jaden on 2026/06/28.
//

import AppKit

/// Small borderless "copy" button with built-in confirmation feedback (D-6).
/// Clicking copies its text to the general pasteboard and briefly swaps the
/// `doc.on.doc` glyph for a green `checkmark` (~1.2 s) so the copy is visibly
/// acknowledged — the affordance the conversation cards, code blocks, and the
/// Raw tab share, replacing the old feedback-less code-block button.
@MainActor
final class CardCopyButton: NSButton {

    private var copyText: String = ""
    private var revertWorkItem: DispatchWorkItem?

    /// How long the checkmark confirmation shows before reverting. A var so
    /// tests can shorten it instead of waiting the full UI duration.
    static var confirmationSeconds: TimeInterval = 1.2

    private static let copyIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
    private static let doneIcon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")

    /// Visible only when showing the post-copy confirmation — exposed as a test
    /// seam so the copy + acknowledgement can be asserted without a timer wait.
    private(set) var isShowingConfirmation = false

    /// Fired whenever `isShowingConfirmation` flips (copy starts, reverts, or is
    /// reset). A hover host listens so it can keep the button visible for the
    /// duration of the confirmation even if the pointer has left.
    var onConfirmationChanged: (() -> Void)?

    static func make(copyText: String) -> CardCopyButton {
        let button = CardCopyButton(frame: .zero)
        button.configure(copyText: copyText)
        return button
    }

    private func configure(copyText: String) {
        self.copyText = copyText
        image = Self.copyIcon
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        controlSize = .small
        toolTip = "Copy"
        target = self
        action = #selector(performCopy)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    /// Update the text copied on the next click (a reused button, e.g. the Raw
    /// tab's, points at new content). Drops any in-flight confirmation so a
    /// stale checkmark doesn't carry across to the new content.
    func setCopyText(_ text: String) {
        copyText = text
        revertWorkItem?.cancel()
        revertWorkItem = nil
        if isShowingConfirmation { restoreCopyGlyph() }
    }

    @objc private func performCopy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        showConfirmation()
    }

    private func showConfirmation() {
        isShowingConfirmation = true
        image = Self.doneIcon
        contentTintColor = .systemGreen
        toolTip = "Copied"
        onConfirmationChanged?()

        revertWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreCopyGlyph() }
        revertWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationSeconds, execute: work)
    }

    private func restoreCopyGlyph() {
        image = Self.copyIcon
        contentTintColor = .secondaryLabelColor
        toolTip = "Copy"
        isShowingConfirmation = false
        onConfirmationChanged?()
    }
}
