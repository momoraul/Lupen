//
//  ConversationBodyTextView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 카드 본문 — selectable `NSTextView`(여러 줄 드래그 선택·복사가 자연스럽고,
/// 선택 시 레이아웃이 흔들리지 않음. NSTextField는 field editor 특성상 여러 줄
/// 선택이 불가하고 선택 시 레이아웃이 변해 부적합했다).
///
/// 과거 NSTextView가 가로 폭을 밀어내 패널 리사이즈를 막았던 문제는, 컨테이너를
/// 뷰포트에 단방향 `==`로 고정(ConversationDetailView)해 근본 해결했다. 본 뷰는
/// 추가 안전장치로 intrinsic 가로 크기를 없애고(width = noIntrinsicMetric) 가로
/// hugging/compression을 낮춰, 어떤 경우에도 컨테이너 폭을 위로 밀어내지 않는다.
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
        // 컨테이너 폭을 위로 밀어내지 않도록(단방향 전파 보장) 가로 우선순위를 낮춘다.
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
        // 가로는 intrinsic 없음(컨테이너 폭을 따름), 세로만 콘텐츠 높이.
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 폭이 바뀌면 줄바꿈이 달라지므로 높이를 다시 계산.
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
