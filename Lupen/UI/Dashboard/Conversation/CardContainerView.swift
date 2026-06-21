//
//  CardContainerView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 모든 대화 카드의 공통 셸: 좌측 역할 거터 + 본문 슬롯 + (선택)하이라이트 배경.
///
/// 6~8종 렌더러가 이 컨테이너를 재사용해 거터/패딩/하이라이트를 한 곳에서
/// 일관되게 처리한다(벤치마크 원칙: 버블 금지·풀폭 + 좌측 거터). 본문은
/// `setBody(_:)`로 꽂는다.
@MainActor
final class CardContainerView: NSView {

    private let gutter = NSView()
    private let bodyContainer = NSView()

    init(role: BlockRole, highlighted: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setup(role: role, highlighted: highlighted)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup(role: BlockRole, highlighted: Bool) {
        // 선택된 Step에 해당하는 카드는 옅은 강조 배경(Q1).
        if highlighted {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor
                .withAlphaComponent(0.18).cgColor
            layer?.cornerRadius = 6
        }

        // 좌측 거터 — 역할 색 바. assistant는 풀폭이라 거터를 투명하게 둬
        // 정렬만 맞추고, user/system/subAgent는 색으로 구분한다.
        gutter.wantsLayer = true
        gutter.layer?.backgroundColor = Self.gutterColor(for: role).cgColor
        gutter.layer?.cornerRadius = 1
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyContainer)

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DetailStyles.horizontalInset),
            gutter.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            gutter.widthAnchor.constraint(equalToConstant: 2),

            bodyContainer.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 10),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DetailStyles.horizontalInset),
            bodyContainer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    /// 본문 뷰를 슬롯에 채운다(기존 본문은 교체).
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

    /// 역할별 거터 색. assistant는 본문이 풀폭으로 읽히도록 거터를 투명하게.
    static func gutterColor(for role: BlockRole) -> NSColor {
        switch role {
        case .user:     return .systemTeal
        case .assistant: return .clear
        case .system:   return .systemOrange
        case .subAgent: return .systemPurple
        }
    }
}
