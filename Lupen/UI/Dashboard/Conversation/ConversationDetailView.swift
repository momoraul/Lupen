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
    /// 현재 렌더된 카드들의 leading/trailing 제약 — 재구성 시 일괄 비활성(A1).
    /// 추적 없이 매번 activate만 하면 빠른 Turn 전환 때 dangling 제약이 쌓여
    /// 레이아웃이 꼬인다.
    private var cardConstraints: [NSLayoutConstraint] = []

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

            // 문서 뷰는 스크롤 뷰포트 폭을 따라간다(세로 스크롤) — TokensDetailView와
            // 동일한 검증된 패턴. 너비 고정의 진짜 원인은 이 제약이 아니라 본문
            // NSTextView의 가로 밀어냄이었으므로, 본문을 NSTextField로 교체해 해결한다.
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            // 읽기 컬럼(Q4): 좁으면 패널 폭(좌우 inset)을 따라가고, 넓으면 620pt에서
            // 멈춰 가운데 정렬 — 와이드 모니터에서 본문이 '읽히지 않는 벽'이 되는 것 방지.
            stack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: documentView.leadingAnchor,
                constant: DetailStyles.horizontalInset
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: documentView.trailingAnchor,
                constant: -DetailStyles.horizontalInset
            ),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxReadingWidth),
        ])
        // 좁을 때 패널 폭(−좌우 inset)을 선호하되, 위 `<= 620`이 우선이라
        // 넓어지면 620에서 멈춘다.
        let preferredWidth = stack.widthAnchor.constraint(
            equalTo: documentView.widthAnchor,
            constant: -DetailStyles.horizontalInset * 2
        )
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
    }

    /// 읽기 컬럼 최대 폭(Q4). 본문은 이 폭 안에서 줄바꿈/말줄임한다.
    private static let maxReadingWidth: CGFloat = 620

    /// 큐레이션된 블록들로 카드 스택을 다시 그린다. (선택 스킵은 상위
    /// `DetailViewController`가 동일 Step 재바인드에서 처리하므로 — 회귀
    /// 유지 — 여기서는 매 호출 재구성한다.)
    func configure(blocks: [ConversationBlock]) {
        // 카드 제약을 명시적으로 비활성·정리(A1): 누적 dangling 제약 방지.
        NSLayoutConstraint.deactivate(cardConstraints)
        cardConstraints.removeAll()
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var highlightedView: NSView?
        for block in blocks {
            let view = registry.view(for: block, context: renderContext)
            stack.addArrangedSubview(view)
            let leading = view.leadingAnchor.constraint(equalTo: stack.leadingAnchor)
            let trailing = view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            cardConstraints.append(contentsOf: [leading, trailing])
            NSLayoutConstraint.activate([leading, trailing])
            if block.isHighlighted, highlightedView == nil { highlightedView = view }
        }
        layoutSubtreeIfNeeded()
        // 선택한 Step(하이라이트)이 있으면 그 카드가 보이도록 스크롤하고,
        // 없으면(Turn/SkillGroup 선택) 맨 위로. flipped 문서 뷰라 (0,0)이 좌상단.
        if let highlightedView {
            let rect = highlightedView.convert(highlightedView.bounds, to: documentView)
            documentView.scrollToVisible(rect.insetBy(dx: 0, dy: -12))
        } else {
            documentView.scroll(.zero)
        }
    }
}

/// `isFlipped = true` 문서 뷰 — `scroll(.zero)`가 맨 위로 가도록(아니면
/// NSStackView 기본 좌표계가 (0,0)을 바닥에 둬 매 바인드 끝으로 스크롤됨).
private final class ConversationFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
