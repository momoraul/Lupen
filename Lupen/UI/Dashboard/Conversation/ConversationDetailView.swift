//
//  ConversationDetailView.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// Conversation 탭의 본문 — Turn을 큐레이션한 `[ConversationBlock]`을 카드
/// 스택으로 그린다. 검증된 Tokens 탭 패턴(NSScrollView + flipped
/// documentView + 수직 NSStackView)을 복제하고, 블록→뷰 매핑은
/// `BlockRendererRegistry`에 위임한다(미등록 블록은 평문 폴백).
@MainActor
final class ConversationDetailView: NSView {

    private let scrollView = NSScrollView()
    private let documentView = ConversationFlippedDocumentView()
    private let stack = NSStackView()
    private let registry = BlockRendererRegistry()
    private let renderContext = RenderContext()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerRenderers()
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 전용 렌더러 등록. 여기에 `register(_:)` 한 줄을 더하면 새 표시
    /// 대상이 추가된다(확장 포인트). 미등록 블록(ToolGroup/Thinking 등
    /// Phase D 이전)은 `PlainTextBlockRenderer`로 안전하게 폴백된다.
    private func registerRenderers() {
        registry.register(UserPromptCardRenderer())
        registry.register(AssistantTextCardRenderer())
        registry.register(StatusBannerRenderer())
        registry.register(ToolGroupCardRenderer())
        registry.register(ThinkingCardRenderer())
    }

    private func setup() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 16, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // 문서 뷰는 스크롤 뷰포트 폭을 따라가 본문이 pane-wide가 된다.
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    /// 큐레이션된 블록들로 카드 스택을 다시 그린다. (선택 스킵은 상위
    /// `DetailViewController`가 동일 Step 재바인드에서 처리하므로 — 회귀
    /// 유지 — 여기서는 매 호출 재구성한다.)
    func configure(blocks: [ConversationBlock]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for block in blocks {
            let view = registry.view(for: block, context: renderContext)
            stack.addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        // flipped 문서 뷰라 (0,0)이 좌상단 — 새 선택은 맨 위에서 시작.
        layoutSubtreeIfNeeded()
        documentView.scroll(.zero)
    }
}

/// `isFlipped = true` 문서 뷰 — `scroll(.zero)`가 맨 위로 가도록(아니면
/// NSStackView 기본 좌표계가 (0,0)을 바닥에 둬 매 바인드 끝으로 스크롤됨).
private final class ConversationFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
