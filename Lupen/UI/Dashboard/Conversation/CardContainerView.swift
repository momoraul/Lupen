//
//  CardContainerView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 모든 대화 카드의 공통 셸: 역할 거터 + 옅은 표면(배경 틴트 + 보더) + 본문 슬롯.
///
/// 역할(user/assistant/system/subAgent)별로 거터색·표면 틴트를 분기해 카드가
/// 한 덩어리로 뭉치지 않고 시각적으로 분리되게 한다(버블 금지·풀폭 + 좌측 거터).
/// 선택된 Step 카드는 accent 보더로 강조. 다크↔라이트 전환 시
/// `viewDidChangeEffectiveAppearance`로 layer 색을 재계산한다.
@MainActor
final class CardContainerView: NSView {

    private let gutter = NSView()
    private let bodyContainer = NSView()
    private let role: BlockRole
    private let highlighted: Bool

    init(role: BlockRole, highlighted: Bool) {
        self.role = role
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
        layer?.borderWidth = highlighted ? 1.5 : 0.5

        gutter.wantsLayer = true
        gutter.layer?.cornerRadius = 1.5
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyContainer)

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            gutter.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            gutter.widthAnchor.constraint(equalToConstant: 3),

            bodyContainer.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 10),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bodyContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// 현재 외관(다크/라이트) 기준으로 layer 색을 재계산. `cgColor`는 정적이라
    /// 외관 전환 시 자동 갱신되지 않으므로 명시적으로 다시 칠한다.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.surfaceColor(role: role, highlighted: highlighted).cgColor
            layer?.borderColor = (highlighted
                ? Self.accentColor(for: role).withAlphaComponent(0.7)
                : NSColor.separatorColor.withAlphaComponent(0.5)).cgColor
            gutter.layer?.backgroundColor = Self.accentColor(for: role).cgColor
        }
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

    /// 역할 강조색(거터 + 강조 보더). systemYellow는 다크 대비가 나빠 피한다.
    static func accentColor(for role: BlockRole) -> NSColor {
        switch role {
        case .user:     return .systemTeal
        case .assistant: return .controlAccentColor
        case .system:   return .systemOrange
        case .subAgent: return .systemPurple
        }
    }

    /// 역할별 옅은 표면 틴트. 선택 카드는 accent 틴트로 더 또렷하게.
    static func surfaceColor(role: BlockRole, highlighted: Bool) -> NSColor {
        if highlighted { return accentColor(for: role).withAlphaComponent(0.12) }
        switch role {
        case .user:      return NSColor.systemTeal.withAlphaComponent(0.06)
        case .assistant: return NSColor.textBackgroundColor.withAlphaComponent(0.35)
        case .system:    return NSColor.systemOrange.withAlphaComponent(0.06)
        case .subAgent:  return NSColor.systemPurple.withAlphaComponent(0.06)
        }
    }
}
