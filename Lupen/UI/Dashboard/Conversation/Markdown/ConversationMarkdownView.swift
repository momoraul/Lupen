//
//  ConversationMarkdownView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 마크다운 본문을 블록 노드별 전용 뷰로 렌더하는 수직 스택.
///
/// `MarkdownParser.parse`로 블록을 분리한 뒤 노드 종류마다 뷰를 만든다
/// (테이블=NSGridView, 코드블록=모노+Copy, 리스트/헤딩/인용/문단). 새 노드
/// 종류가 생기면 `view(for:)`에 case를 더하고, 미지원 노드는 문단으로 폴백한다.
@MainActor
final class ConversationMarkdownView: NSStackView {

    private let onRevealFile: ((URL) -> Void)?

    init(markdown: String, onRevealFile: ((URL) -> Void)?) {
        self.onRevealFile = onRevealFile
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        for node in MarkdownParser.parse(markdown) {
            let view = makeView(for: node)
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeView(for node: MarkdownNode) -> NSView {
        switch node {
        case .paragraph(let text):
            return paragraphView(text, font: Self.bodyFont)

        case .heading(let level, let text):
            return paragraphView(text, font: Self.headingFont(level: level))

        case .bulletList(let items):
            return listView(items.map { "•  \($0)" })

        case .orderedList(let items):
            return listView(items.enumerated().map { "\($0.offset + 1).  \($0.element)" })

        case .codeBlock(_, let code):
            return CodeBlockView(code: code)

        case .table(let headers, let rows):
            return MarkdownTableView(headers: headers, rows: rows)

        case .quote(let lines):
            return quoteView(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Node views

    private func paragraphView(_ text: String, font: NSFont) -> NSView {
        let body = ConversationBodyTextView.make()
        body.onRevealFile = onRevealFile
        body.setBody(ConversationInlineText.markdownInline(text, font: font, color: .labelColor))
        return body
    }

    private func listView(_ lines: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for line in lines {
            let item = ConversationBodyTextView.make()
            item.onRevealFile = onRevealFile
            item.setBody(ConversationInlineText.markdownInline(line, font: Self.bodyFont, color: .labelColor))
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func quoteView(_ text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.separatorColor.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        let body = ConversationBodyTextView.make()
        body.onRevealFile = onRevealFile
        body.setBody(ConversationInlineText.markdownInline(text, font: Self.bodyFont, color: .secondaryLabelColor))
        container.addSubview(body)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            body.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - Fonts

    static let bodyFont: NSFont = .systemFont(ofSize: 13)

    static func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = 18
        case 2: size = 16
        case 3: size = 15
        default: size = 14
        }
        return .systemFont(ofSize: size, weight: .semibold)
    }
}

/// 코드블록 — 모노 텍스트 + 옅은 배경 + 좌측 accent 바 + 우상단 Copy 버튼.
/// 신택스 하이라이팅은 범위 밖(Q3, 단색); 노드 렌더 인터페이스만 열어둔다.
@MainActor
final class CodeBlockView: NSView {

    private let code: String

    init(code: String) {
        self.code = code
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        let text = ConversationBodyTextView.make()
        text.setBody(NSAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        addSubview(text)

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyCode))
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.controlSize = .mini
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

/// 마크다운 표 — NSGridView로 헤더(강조) + 데이터 행을 격자로 그린다.
@MainActor
final class MarkdownTableView: NSView {

    init(headers: [String], rows: [[String]]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup(headers: headers, rows: rows)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup(headers: [String], rows: [[String]]) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return }

        func cell(_ text: String, bold: Bool) -> NSView {
            DetailStyles.makeSelectableValueLabel(
                text,
                font: .systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
                color: bold ? .labelColor : .secondaryLabelColor,
                alignment: .left
            )
        }

        var gridRows: [[NSView]] = []
        gridRows.append((0..<columnCount).map { cell($0 < headers.count ? headers[$0] : "", bold: true) })
        for row in rows {
            gridRows.append((0..<columnCount).map { cell($0 < row.count ? row[$0] : "", bold: false) })
        }

        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 6
        grid.columnSpacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }
}
