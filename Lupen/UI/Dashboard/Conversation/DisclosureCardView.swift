//
//  DisclosureCardView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Collapsible card body — clicking the header (▸/▾ + one-line summary) opens
/// the detail. The detail is built lazily on expand (perf gate: collapsed
/// blocks build no body view). Used for "collapsed by default, scan at a
/// glance" blocks like tool groups and thinking.
@MainActor
final class DisclosureCardView: NSView {

    private let chevron = NSTextField(labelWithString: "▸")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailContainer = NSStackView()
    private let makeDetail: () -> NSView
    private var built = false
    private var expanded = false

    init(summary: NSAttributedString, makeDetail: @escaping () -> NSView) {
        self.makeDetail = makeDetail
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup(summary: summary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup(summary: NSAttributedString) {
        chevron.font = .systemFont(ofSize: 10)
        chevron.textColor = .tertiaryLabelColor
        chevron.isBordered = false
        chevron.drawsBackground = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        summaryLabel.attributedStringValue = summary
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.isSelectable = false
        summaryLabel.isBordered = false
        summaryLabel.drawsBackground = false
        // Lower horizontal compression so a long one-line summary doesn't push
        // the card width — it truncates (…) when narrow.
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [chevron, summaryLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
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

    @objc private func toggle() {
        expanded.toggle()
        chevron.stringValue = expanded ? "▾" : "▸"
        if expanded, !built {
            let detail = makeDetail()
            detail.translatesAutoresizingMaskIntoConstraints = false
            detailContainer.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: detailContainer.widthAnchor).isActive = true
            built = true
        }
        detailContainer.isHidden = !expanded
    }
}
