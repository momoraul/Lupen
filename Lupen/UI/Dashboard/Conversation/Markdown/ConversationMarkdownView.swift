//
//  ConversationMarkdownView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 마크다운 본문 렌더 — 연속된 텍스트 계열 노드(헤딩/문단/리스트/인용)는 하나의
/// attributed 문자열로 합쳐 **단일 `NSTextView`** 로 그린다. 노드마다 별도
/// NSTextView로 쪼개면 노드 경계를 넘는 드래그 선택이 불가했던 문제(한 step 안의
/// 여러 줄 선택 안 됨)를 해결한다. 테이블/코드블록만 전용 뷰(NSGridView / Copy
/// 버튼 코드 카드)로 분리해 리치 렌더를 유지한다.
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
        build(markdown: markdown)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build(markdown: String) {
        var run = NSMutableAttributedString()

        func flushRun() {
            guard run.length > 0 else { return }
            let textView = ConversationBodyTextView.make()
            textView.onRevealFile = onRevealFile
            textView.setBody(run)
            addArranged(textView)
            run = NSMutableAttributedString()
        }

        for node in MarkdownParser.parse(markdown) {
            switch node {
            case .codeBlock(_, let code):
                flushRun()
                addArranged(CodeBlockView(code: code))
            case .table(let headers, let rows):
                flushRun()
                addArranged(MarkdownTableView(headers: headers, rows: rows))
            default:
                // 텍스트 계열 노드는 누적해 하나의 NSTextView로 → 통째 드래그 선택.
                if run.length > 0 { run.append(NSAttributedString(string: "\n\n")) }
                run.append(Self.attributed(for: node))
            }
        }
        flushRun()
    }

    private func addArranged(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    // MARK: - 텍스트 노드 → attributed

    private static func attributed(for node: MarkdownNode) -> NSAttributedString {
        switch node {
        case .heading(let level, let text):
            return ConversationInlineText.markdownInline(text, font: headingFont(level: level), color: .labelColor)
        case .paragraph(let text):
            return ConversationInlineText.markdownInline(text, font: bodyFont, color: .labelColor)
        case .bulletList(let items):
            return list(items.map { (marker: "•  ", text: $0) })
        case .orderedList(let items):
            return list(items.enumerated().map { (marker: "\($0.offset + 1).  ", text: $0.element) })
        case .quote(let lines):
            return ConversationInlineText.markdownInline(
                lines.joined(separator: "\n"), font: bodyFont, color: .secondaryLabelColor
            )
        case .codeBlock, .table:
            return NSAttributedString() // 별도 뷰로 처리되어 여기 도달하지 않음
        }
    }

    private static func list(_ items: [(marker: String, text: String)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: item.marker, attributes: [
                .font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            result.append(ConversationInlineText.markdownInline(item.text, font: bodyFont, color: .labelColor))
        }
        return result
    }

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
            text.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
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
            let label = DetailStyles.makeSelectableValueLabel(
                text,
                font: .systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
                color: bold ? .labelColor : .secondaryLabelColor,
                alignment: .left
            )
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
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
