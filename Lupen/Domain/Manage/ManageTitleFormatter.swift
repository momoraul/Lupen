//
//  ManageTitleFormatter.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 세션 행의 1차 제목을 만든다. 첫 프롬프트를 식별자로 쓰되, 사용자가
/// 직접 붙인 이름(`/rename`)이 있으면 그게 가장 권위 있다(Session.swift 주석).
///
/// 우선순위: `customTitle`(사용자 지정) → `firstPrompt`(내용) →
/// `cachedTitle`(자동) → 폴백. (plan §2를 다듬음 — 식별력 우선.)
/// 표시 문자열은 개행·코드펜스·연속 공백을 한 줄로 정규화한다(research §B-4).
enum ManageTitleFormatter {

    static let emptyFallback = "(Untitled session)"

    static func sessionTitle(
        firstPrompt: String?,
        cachedTitle: String?,
        customTitle: String?,
        maxLength: Int = 80
    ) -> String {
        let chosen = nonEmpty(customTitle)
            ?? nonEmpty(firstPrompt)
            ?? nonEmpty(cachedTitle)
        guard let chosen else { return emptyFallback }
        let cleaned = clean(chosen)
        return cleaned.isEmpty ? emptyFallback : truncate(cleaned, maxLength: maxLength)
    }

    /// 개행/탭/코드펜스를 공백으로 접고 연속 공백을 하나로 만든다.
    static func clean(_ raw: String) -> String {
        let noFence = raw.replacingOccurrences(of: "```", with: " ")
        return noFence
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
    }

    /// `maxLength`를 넘으면 말줄임(…)으로 자른다.
    static func truncate(_ s: String, maxLength: Int = 80) -> String {
        guard maxLength > 1, s.count > maxLength else { return s }
        let head = s.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
