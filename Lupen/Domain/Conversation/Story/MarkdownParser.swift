//
//  MarkdownParser.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import Foundation

/// 마크다운 텍스트를 블록 레벨 `MarkdownNode` 배열로 분리하는 순수 파서.
///
/// 인라인 문법(굵게/기울임/링크/인라인코드)은 **건드리지 않고** 원문을
/// `paragraph`/리스트 항목 문자열로 보존한다 — 렌더러가 그 문자열을
/// `AttributedString(markdown:)`로 그린다. 이 파서는 "어디서 코드블록·표·
/// 리스트·헤딩·인용이 시작/끝나는가"만 책임진다. 미지원/모호 입력은
/// `paragraph`로 안전 폴백한다(절대 throw하지 않음).
enum MarkdownParser {

    static func parse(_ text: String) -> [MarkdownNode] {
        var nodes: [MarkdownNode] = []
        let lines = text.components(separatedBy: "\n")
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { nodes.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 코드펜스: ``` ~ ``` (언어 태그 선택)
            if line.hasPrefix("```") {
                flushParagraph()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // 닫는 펜스(또는 EOF) 소비
                nodes.append(.codeBlock(language: lang.isEmpty ? nil : lang,
                                        code: code.joined(separator: "\n")))
                continue
            }

            // 테이블: 헤더 행 다음 줄이 구분선(|---|---|)일 때만
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = splitRow(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty, l.contains("|") else { break }
                    rows.append(splitRow(l))
                    i += 1
                }
                nodes.append(.table(headers: headers, rows: rows))
                continue
            }

            // 헤딩: # ~ ######
            if let heading = parseHeading(line) {
                flushParagraph()
                nodes.append(heading)
                i += 1
                continue
            }

            // 불릿 리스트
            if isBullet(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isBullet(l) else { break }
                    items.append(bulletContent(l))
                    i += 1
                }
                nodes.append(.bulletList(items))
                continue
            }

            // 순서 리스트
            if isOrdered(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isOrdered(l) else { break }
                    items.append(orderedContent(l))
                    i += 1
                }
                nodes.append(.orderedList(items))
                continue
            }

            // 인용
            if line.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    quote.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                nodes.append(.quote(quote))
                continue
            }

            // 빈 줄 → 문단 경계
            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // 일반 텍스트 누적(원문 유지 — 인라인 마크다운 보존)
            paragraph.append(raw)
            i += 1
        }
        flushParagraph()
        return nodes
    }

    // MARK: - Helpers

    private static func parseHeading(_ s: String) -> MarkdownNode? {
        guard s.hasPrefix("#") else { return nil }
        var level = 0
        for ch in s {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = s.dropFirst(level)
        // "# text"만 헤딩으로 인정("#hashtag"는 일반 문단).
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func bulletContent(_ s: String) -> String {
        String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isOrdered(_ s: String) -> Bool {
        guard let dot = s.firstIndex(of: ".") else { return false }
        let num = s[s.startIndex..<dot]
        guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return false }
        let after = s.index(after: dot)
        return after < s.endIndex && s[after] == " "
    }

    private static func orderedContent(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        return String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }

    /// `|---|:--:|--:|` 형태의 표 구분선인지. 모든 셀이 `-`/`:`로만 구성되고
    /// 최소 한 개의 `-`를 포함해야 한다.
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        let cells = splitRow(t)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.contains("-") && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
