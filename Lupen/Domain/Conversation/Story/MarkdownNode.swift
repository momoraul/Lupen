//
//  MarkdownNode.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import Foundation

/// 한 텍스트 블록을 마크다운 파싱한 결과의 블록 레벨 노드.
///
/// Level 2 렌더링의 단위(extensibility-architecture.md): 노드 종류별로
/// 전용 렌더러(테이블=NSGridView, 코드=카드 등)를 꽂을 수 있고, 미지원
/// 노드는 평문으로 폴백한다. 인라인 마크다운(굵게/링크 등)은 파싱하지
/// 않고 원문 문자열로 보존해 렌더러가 `AttributedString(markdown:)`로 처리.
enum MarkdownNode: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case orderedList([String])
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case quote([String])
}
