//
//  ConversationInlineText.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 카드 본문/헤더용 attributed 텍스트 빌더.
///
/// `[Image source: /path]` / `[Image #N]` 마커를 인라인 SF Symbol(photo)로
/// 치환하고, 경로 마커에는 `file://` 링크를 걸어 클릭 시 Finder reveal이
/// 되도록 한다(기존 `ConversationDetailView.buildBodyWithImageLinks` 이식 —
/// 회귀 금지). 인라인 마크다운 강조(볼드/코드/표 등)는 Phase C의 노드
/// 렌더러가 담당하므로 여기서는 다루지 않는다.
@MainActor
enum ConversationInlineText {

    /// 본문 텍스트 → 이미지 마커가 치환된 attributed 문자열.
    static func body(
        _ text: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sources = ImageSourceFormatter.extractSources(from: text)
        let refs = ImageSourceFormatter.extractRefs(from: text)

        struct Replacement: Comparable {
            let range: NSRange
            let fileURL: URL?
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.range.location < rhs.range.location }
        }

        var replacements: [Replacement] = sources.map {
            Replacement(range: $0.range, fileURL: URL(fileURLWithPath: $0.path))
        }
        for refRange in refs
        where !sources.contains(where: { NSIntersectionRange($0.range, refRange).length > 0 }) {
            replacements.append(Replacement(range: refRange, fileURL: nil))
        }

        guard !replacements.isEmpty else {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }

        let result = NSMutableAttributedString(string: text, attributes: baseAttrs)
        for rep in replacements.sorted().reversed() {
            let symbol = InlineImageSymbol.attachment(
                font: font,
                color: rep.fileURL != nil ? .systemBlue : color,
                linkURL: rep.fileURL
            )
            result.replaceCharacters(in: rep.range, with: symbol)
        }
        return result
    }

    /// 프롬프트에 인라인 이미지 블록이 있을 때 앞에 붙일 🖼 글리프들.
    /// (현재 Claude Code는 이미지를 base64 블록으로만 넣어 텍스트 마커가
    /// 없으므로, 첨부가 있었다는 시각 신호를 본문 앞에 표시한다.)
    static func imageGlyphPrefix(count: Int, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for index in 0..<max(0, count) {
            result.append(InlineImageSymbol.attachment(font: font, color: color))
            if index < count - 1 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
        }
        return result
    }

    /// 마크다운 인라인(볼드/기울임/인라인코드/링크)을 base 폰트에 반영한
    /// attributed 문자열. 블록 구조(테이블/코드블록/리스트)는 호출부가 이미
    /// `MarkdownParser`로 노드 분리했으므로 여기서는 인라인만 처리한다.
    /// 파싱 실패 시 평문(`body`)으로 폴백한다.
    static func markdownInline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return body(text, font: font, color: color)
        }
        let result = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: color, range: full)
        result.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            var resolved = font
            if let intent = value as? InlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .italicFontMask)
                }
                if intent.contains(.code) {
                    resolved = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                }
            }
            result.addAttribute(.font, value: resolved, range: range)
        }
        return result
    }
}

/// 카드 상단의 역할/메타 헤더("You", "✦ Assistant · opus-4-8 · $0.37").
@MainActor
enum ConversationCardHeader {
    static func make(_ text: String, color: NSColor) -> NSTextField {
        DetailStyles.makeChromeLabel(
            text,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: color,
            alignment: .left
        )
    }
}
