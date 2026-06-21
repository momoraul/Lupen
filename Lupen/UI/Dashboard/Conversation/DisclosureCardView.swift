//
//  DisclosureCardView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 접었다 펼치는 카드 본문 — 헤더(▸/▾ + 한 줄 요약)를 클릭하면 상세가
/// 열린다. 상세는 펼칠 때 lazy 생성(성능 게이트: 접힌 블록은 본문 뷰를
/// 만들지 않음). 도구 묶음·사고처럼 "기본 접힘, 한눈에 훑기" 블록에 쓴다.
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
        // 긴 한 줄 요약이 카드 폭을 밀어내지 않도록 가로 compression을 낮춰
        // 좁아지면 말줄임(…)되게 한다.
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

    /// 테스트/프로그램에서 펼침 상태를 직접 제어(스모크 커버리지).
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
