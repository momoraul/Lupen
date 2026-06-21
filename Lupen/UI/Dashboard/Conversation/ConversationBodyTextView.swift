//
//  ConversationBodyTextView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 카드 본문 라벨 — selectable·wrapping `NSTextField`.
///
/// 과거 `NSTextView`로 구현했으나, NSTextView는 NSStackView/Auto Layout에서
/// 가로 콘텐츠 크기를 유지하려 부모(카드→스크롤→detail pane)를 밀어내
/// **패널/윈도우 너비 리사이즈를 막는 고질 문제**가 있다(웹 자료 다수, 그리고
/// 같은 스크롤 패턴인 Tokens 탭은 NSTextField라서 무사했던 점이 결정적 단서).
/// NSTextField(wrapping)는 폭을 부모에 양보하고 줄바꿈하므로 너비가 안정적이다.
///
/// `setBody(_:)`로 attributed 본문을 채우고, 부모가 폭 제약을 주면 높이는
/// intrinsic으로 자동 산정된다.
@MainActor
final class ConversationBodyTextView: NSTextField {

    /// 본문 내 `file://` 링크 클릭 시 Finder reveal 콜백(이미지 마커 등).
    /// NSTextField는 selectable + 링크 속성으로 클릭 시 기본 열기를 지원하지만,
    /// reveal 동작이 필요한 경우를 위해 보관한다.
    var onRevealFile: ((URL) -> Void)?

    static func make() -> ConversationBodyTextView {
        let field = ConversationBodyTextView(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.translatesAutoresizingMaskIntoConstraints = false
        // 가로로 콘텐츠 크기를 유지해 부모를 밀어내지 않도록 — 항상 폭에 양보·줄바꿈.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func setBody(_ attributed: NSAttributedString) {
        attributedStringValue = attributed
    }
}
