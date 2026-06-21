//
//  MarkdownParser.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import Foundation

/// Pure parser that splits markdown text into an array of block-level
/// `MarkdownNode`s.
///
/// Inline syntax (bold/italic/link/inline-code) is **left untouched** — the
/// raw text is preserved as `paragraph` / list-item strings, and the renderer
/// draws it with `AttributedString(markdown:)`. This parser is only
/// responsible for "where do code blocks / tables / lists / headings / quotes
/// start and end". Unsupported/ambiguous input safely falls back to
/// `paragraph` (never throws).
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

            // Code fence: ``` ~ ``` (optional language tag)
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
                i += 1 // consume the closing fence (or EOF)
                nodes.append(.codeBlock(language: lang.isEmpty ? nil : lang,
                                        code: code.joined(separator: "\n")))
                continue
            }

            // Table: only when the line after the header row is a separator (|---|---|)
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

            // Heading: # ~ ######
            if let heading = parseHeading(line) {
                flushParagraph()
                nodes.append(heading)
                i += 1
                continue
            }

            // Bullet list
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

            // Ordered list
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

            // Quote
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

            // Blank line → paragraph boundary
            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Accumulate plain text (keep raw — preserve inline markdown)
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
        // Only "# text" counts as a heading ("#hashtag" is a normal paragraph).
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

    /// Whether this is a `|---|:--:|--:|`-style table separator. Every cell
    /// must consist only of `-`/`:` and contain at least one `-`.
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
