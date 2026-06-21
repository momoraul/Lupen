//
//  ConversationBodyTextView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Card body — a selectable `NSTextView` (multi-line drag selection and copy
/// feel natural, and selecting doesn't shift the layout. NSTextField was a poor
/// fit: its field editor can't do multi-line selection and the layout changes
/// on selection).
///
/// The past problem where NSTextView pushed its horizontal width and blocked
/// panel resizing is fixed at the root by pinning the container to the viewport
/// one-way (ConversationDetailView). As an extra guard, this view drops its
/// intrinsic horizontal size (width = noIntrinsicMetric) and lowers horizontal
/// hugging/compression so it never pushes the container width upward.
@MainActor
final class ConversationBodyTextView: NSTextView, NSTextViewDelegate {

    var onRevealFile: ((URL) -> Void)?

    static func make() -> ConversationBodyTextView {
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        // widthTracksTextView is OFF: leaving the container width to the text
        // system's relayout timing falls into a trap where a new card measures
        // its intrinsic height at width 0 (before it receives its frame width),
        // blowing up the line wrapping (reproduces on repeated reselection).
        // Instead, sync the container width to the current bounds width at
        // measure time (see syncContainerWidth).
        container.widthTracksTextView = false
        // lineFragmentPadding 0: drop horizontal padding so body width == container width.
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let view = ConversationBodyTextView(frame: .zero, textContainer: container)
        view.configure()
        return view
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = .zero
        autoresizingMask = [.width]
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .cursor: NSCursor.pointingHand,
        ]
        translatesAutoresizingMaskIntoConstraints = false
        delegate = self
        // Lower horizontal priority so it never pushes the container width
        // upward (guarantees one-way width propagation).
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func setBody(_ attributed: NSAttributedString) {
        textStorage?.setAttributedString(attributed)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return super.intrinsicContentSize
        }
        // Measure height only after matching the container width to the current
        // bounds width. If the width is still 0 (before layout), defer and
        // return 0 — this blocks the width-0 height blow-up. Once the width is
        // set, setFrameSize calls invalidate so it re-measures on the next pass.
        guard syncContainerWidth() else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        // No intrinsic width (follows the container width); height only.
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    /// Sync the text container width to the current bounds width. Returns true
    /// if the width is valid (>0). With widthTracksTextView off, matching it
    /// explicitly at measure time makes height measurement always happen at the
    /// correct width, independent of the text system's relayout timing.
    @discardableResult
    private func syncContainerWidth() -> Bool {
        guard let textContainer else { return false }
        let width = bounds.width
        guard width > 0 else { return false }
        if textContainer.containerSize.width != width {
            textContainer.containerSize = NSSize(
                width: width, height: CGFloat.greatestFiniteMagnitude
            )
        }
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        // A width change re-wraps the text, so match the container width and recompute height.
        if widthChanged {
            syncContainerWidth()
            invalidateIntrinsicContentSize()
        }
    }

    func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let fileURL = link as? URL {
            url = fileURL
        } else if let string = link as? String {
            url = URL(fileURLWithPath: string)
        } else {
            url = nil
        }
        guard let resolved = url else { return false }
        onRevealFile?(resolved)
        return true
    }
}
