//
//  DisclosureCardView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// The clickable header row of a `DisclosureCardView`.
///
/// Exists as its own type only to answer `accessibilityPerformPress()`:
/// AppKit does not surface an `NSClickGestureRecognizer` as an accessibility
/// action, so a bare stack view would announce "disclosure triangle" and then
/// do nothing when VoiceOver presses it — a worse affordance than none.
@MainActor
private final class DisclosureHeaderView: NSStackView {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}

/// Collapsible card body — clicking the header (a chevron plus a one-line
/// summary) opens the detail. The detail is built lazily on first expand (perf gate: a
/// collapsed block builds no body view). Used both for "collapsed by default,
/// scan at a glance" blocks like tool groups and thinking, and — via
/// `initialExpanded` — for the overview cards that lead a turn and start open.
@MainActor
final class DisclosureCardView: NSView {

    /// An `NSImageView` rather than a text glyph: `▸` at 10pt was too small to
    /// identify as a control at a glance, and a symbol image scales with the
    /// system, stays crisp, and carries its own description.
    private let chevron = NSImageView()
    private let summaryLabel = NSTextField(labelWithString: "")
    /// The clickable row. The disclosure role lives **here**, not on the card:
    /// the header *is* the control, and giving a container that role would
    /// label a group as a button.
    ///
    /// Not because the card would become a leaf — that is a UIKit behaviour.
    /// AppKit's `isAccessibilityElement` only decides whether a view is
    /// exposed; its children are unaffected, which is why `TurnFileAccessView`
    /// can be an element and still have its rows traversed.
    private let header = DisclosureHeaderView()
    /// Big enough to read as a control. The old 10pt text glyph was not.
    private static let chevronSize: CGFloat = 13
    private static let chevronConfiguration = NSImage.SymbolConfiguration(
        pointSize: 11, weight: .semibold
    )
    private let detailContainer = NSStackView()
    private let makeDetail: () -> NSView
    private let onToggle: ((Bool) -> Void)?
    private var built = false
    private var expanded = false

    /// - Parameters:
    ///   - initialExpanded: Defaults to `false` so every existing caller keeps
    ///     its "collapsed on arrival" behaviour untouched. The overview cards
    ///     pass `true`: they are the glance, so hiding them behind a chevron
    ///     would hide the feature itself.
    ///   - onToggle: Called with the new expanded state after every user
    ///     toggle — never during construction, so wiring it to a persistence
    ///     store cannot rewrite what it just restored.
    init(
        summary: NSAttributedString,
        initialExpanded: Bool = false,
        onToggle: ((Bool) -> Void)? = nil,
        makeDetail: @escaping () -> NSView
    ) {
        self.makeDetail = makeDetail
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup(summary: summary)
        // Unconditional so the collapsed default also installs the
        // accessibility role/label/state, not just the expanded one.
        applyExpanded(initialExpanded)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup(summary: NSAttributedString) {
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.imageScaling = .scaleProportionallyDown
        chevron.contentTintColor = .secondaryLabelColor
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: Self.chevronSize),
            chevron.heightAnchor.constraint(equalToConstant: Self.chevronSize),
        ])

        summaryLabel.attributedStringValue = summary
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.isSelectable = false
        summaryLabel.isBordered = false
        summaryLabel.drawsBackground = false
        // Lower horizontal compression so a long one-line summary doesn't push
        // the card width — it truncates (…) when narrow.
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        header.setViews([chevron, summaryLabel], in: .leading)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.orientation = .vertical
        detailContainer.alignment = .leading
        detailContainer.spacing = 4
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.isHidden = true

        let outer = NSStackView(views: [header, detailContainer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: outer.widthAnchor),
            detailContainer.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])

        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
    }

    /// Directly control the expanded state from tests/programmatically (smoke coverage).
    func setExpandedForTesting(_ value: Bool) {
        if value != expanded { toggle() }
    }

    /// Current state, for tests asserting the restored default.
    var isExpandedForTesting: Bool { expanded }

    /// The row that carries the disclosure role, so tests can assert the
    /// accessibility contract without reaching into the view hierarchy.
    var accessibilityHeaderForTesting: NSView { header }

    @objc private func toggle() {
        applyExpanded(!expanded)
        onToggle?(expanded)
    }

    /// State change without the callback — used by `init` so restoring a
    /// persisted state does not immediately report a "toggle" back to the
    /// store that supplied it.
    private func applyExpanded(_ value: Bool) {
        expanded = value
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(Self.chevronConfiguration)
        if expanded, !built {
            let detail = makeDetail()
            detail.translatesAutoresizingMaskIntoConstraints = false
            detailContainer.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: detailContainer.widthAnchor).isActive = true
            built = true
        }
        detailContainer.isHidden = !expanded
        updateAccessibilityState()
    }

    /// VoiceOver: the header row is the control, so it carries the disclosure
    /// role, the summary as its label, and the open/closed state. Without this
    /// the chevron — an image driven by a click recognizer, with no control
    /// semantics of its own — is invisible to assistive technology and the
    /// card cannot be operated.
    ///
    /// The role sits on the header rather than on `self` because the header is
    /// the control; a card carrying a disclosure role would announce a
    /// container as a button, and the detail below it would be read as part of
    /// that control rather than as the group it is.
    private func updateAccessibilityState() {
        header.onPress = { [weak self] in self?.toggle() }
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.disclosureTriangle)
        header.setAccessibilityLabel(Self.accessibilityLabel(from: summaryLabel))
        header.setAccessibilityValue(expanded ? 1 : 0)
        header.setAccessibilityExpanded(expanded)
        // The chevron and the summary text are decoration once the header
        // speaks for both — otherwise VoiceOver reads the glyph, then the
        // summary, then the header's label saying the summary again.
        //
        // Clearing children is what actually works here: an `NSTextField`'s
        // accessibility element is its *cell*, so `setAccessibilityElement`
        // on the field is silently ignored.
        header.setAccessibilityChildren([])
    }

    /// Plain text for VoiceOver.
    ///
    /// Summaries are built by `ConversationInlineText.symbolPrefixed`, which
    /// leads with an SF Symbol as an `NSTextAttachment`. That renders into
    /// `stringValue` as U+FFFC (object replacement character) with no
    /// alternative text, so VoiceOver would open every card by announcing an
    /// unpronounceable glyph. Strip it and any whitespace it leaves behind.
    private static func accessibilityLabel(from field: NSTextField) -> String {
        field.stringValue
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
