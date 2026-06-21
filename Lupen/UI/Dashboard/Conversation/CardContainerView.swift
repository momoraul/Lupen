//
//  CardContainerView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 모든 대화 카드의 공통 셸: 역할 거터 + tier별 표면(배경/보더/거터폭) + 본문 슬롯.
///
/// 역할(user/assistant/system/subAgent)로 색을, tier(primary/secondary)로 강도를
/// 나눠 중요한 대화(프롬프트·최종 답변=primary)가 보조(도구·사고=secondary)보다
/// 또렷하게 읽히도록 한다. 선택된 Step 카드는 accent 보더로 강조.
/// 표면색은 전경(labelColor 등) 저알파 오버레이라 다크/라이트 모두 배경보다 대비를
/// 유지한다(이전 textBackgroundColor 방식의 다크모드 함몰 수정).
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
        // 본문(primary)·선택 카드만 셸(배경/외곽선/거터)을 그린다. 곁가지(secondary
        // 사고·도구)는 셸 없이 들여쓴 한 줄로 렌더 → 화면 노이즈를 줄이고 본문을 부각.
        let showShell = tier == .primary || highlighted
        layer?.borderWidth = highlighted ? 1.5 : (showShell ? 0.75 : 0)

        gutter.wantsLayer = true
        gutter.layer?.cornerRadius = 2
        gutter.isHidden = !showShell
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyContainer)

        let verticalInset: CGFloat = showShell ? 12 : 4      // 곁가지는 납작하게
        let bodyLeadingInset: CGFloat = showShell ? 0 : 26   // 곁가지는 들여쓰기
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

    /// 현재 외관(다크/라이트) 기준으로 layer 색 재계산.
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

    /// 역할 강조색(거터 + 강조 보더). systemYellow는 다크 대비가 나빠 피한다.
    static func accentColor(for role: BlockRole) -> NSColor {
        switch role {
        case .user:      return .systemTeal
        case .assistant: return .controlAccentColor
        case .system:    return .systemOrange
        case .subAgent:  return .systemPurple
        }
    }

    /// 역할×tier 표면 틴트. 전경색 저알파 오버레이라 다크/라이트 모두 배경 대비 유지.
    /// primary(프롬프트·답변)는 진하게, secondary(도구·사고)는 옅게 → 위계.
    static func surfaceColor(role: BlockRole, tier: BlockTier, highlighted: Bool) -> NSColor {
        if highlighted { return accentColor(for: role).withAlphaComponent(0.12) }
        let base: NSColor
        switch role {
        case .user:      base = .systemTeal
        case .assistant: base = .labelColor   // 중립 전경 — 다크=흰 저알파, 라이트=검정 저알파
        case .system:    base = .systemOrange
        case .subAgent:  base = .systemPurple
        }
        return base.withAlphaComponent(tier == .primary ? 0.09 : 0.04)
    }
}
