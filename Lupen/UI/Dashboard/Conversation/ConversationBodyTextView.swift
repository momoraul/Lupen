//
//  ConversationBodyTextView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 카드 본문용 selectable NSTextView. NSStackView 안에서 콘텐츠 높이에 맞춰
/// 자동으로 세로 크기를 정한다(intrinsicContentSize). 본문 선택·복사·검색을
/// 네이티브로 보존하고(데이터 표면 요구), `[Image source:]`/`[Image #N]`
/// 마커의 `file://` 링크 클릭 → Finder reveal을 처리한다(기존 Conversation
/// 탭 동작 이식 — 회귀 금지).
@MainActor
final class ConversationBodyTextView: NSTextView, NSTextViewDelegate {

    var onRevealFile: ((URL) -> Void)?

    static func make() -> ConversationBodyTextView {
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let view = ConversationBodyTextView(frame: .zero, textContainer: container)
        view.configure()
        return view
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = .zero
        autoresizingMask = [.width]
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .cursor: NSCursor.pointingHand,
        ]
        translatesAutoresizingMaskIntoConstraints = false
        delegate = self
        // 가로로 콘텐츠 크기를 유지하려는 NSTextView 성향이 카드/스크롤 폭을
        // 밀어내 detail pane 리사이즈를 막지 않도록, 가로 hugging/compression을
        // 낮춰 항상 부모 폭에 양보하고 줄바꿈하도록 한다.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func setBody(_ attributed: NSAttributedString) {
        textStorage?.setAttributedString(attributed)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 스택 레이아웃이 폭을 정하면 줄바꿈이 바뀌므로 높이를 다시 계산.
        invalidateIntrinsicContentSize()
    }

    func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let fileURL = link as? URL {
            url = fileURL
        } else if let string = link as? String {
            url = URL(fileURLWithPath: string)
        } else {
            url = nil
        }
        guard let resolved = url else { return false }
        onRevealFile?(resolved)
        return true
    }
}
