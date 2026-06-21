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
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 24, right: 0)
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

            // 컨테이너(documentView)는 뷰포트(clipView)를 단방향으로 따라간다.
            // 4변을 clipView에 ==로 고정해, 하위 카드/텍스트의 intrinsic 폭이 위로
            // 전파돼 컨테이너(=패널/윈도우) 폭을 제약하는 것을 원천 차단한다.
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            // stack은 documentView 폭을 그대로(==) 따른다. 읽기폭 클램프·centerX·
            // min/max 없음 — 카드는 스스로 폭 제약을 갖지 않고 컨테이너를 따른다.
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Self.contentHorizontalInset),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -Self.contentHorizontalInset),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    /// Conversation 콘텐츠 좌우 여백 — 카드가 패널 가장자리에 붙어 답답해 보이지
    /// 않도록 공용 inset(16)보다 넉넉히 준다.
    private static let contentHorizontalInset: CGFloat = 24

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
        var previous: (view: NSView, tier: BlockTier)?
        for block in blocks {
            let view = registry.view(for: block, context: renderContext)
            stack.addArrangedSubview(view)
            let leading = view.leadingAnchor.constraint(equalTo: stack.leadingAnchor)
            let trailing = view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            cardConstraints.append(contentsOf: [leading, trailing])
            NSLayoutConstraint.activate([leading, trailing])
            if let previous {
                // 곁가지(사고·도구)끼리는 촘촘히 묶고, 본문 카드가 끼면 넉넉히 띄워
                // '대화 단위'로 끊어 읽히게 한다(간격 그룹핑).
                let bothSecondary = previous.tier == .secondary && block.tier == .secondary
                stack.setCustomSpacing(bothSecondary ? 2 : 14, after: previous.view)
            }
            previous = (view, block.tier)
            if block.isHighlighted, highlightedView == nil { highlightedView = view }
        }
        // 정확한 좌표를 위해 3단계 레이아웃 강제 후 스크롤.
        layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        if let highlightedView {
            // 선택 카드를 상단 근처(−12)로 올린다(이미 일부 보여도). maxY 클램프로
            // 과스크롤 방지. scrollToVisible는 '이미 보이면 안 움직임'이라 부적합.
            let rect = highlightedView.convert(highlightedView.bounds, to: documentView)
            let visibleHeight = scrollView.contentView.bounds.height
            let documentHeight = max(documentView.bounds.height, stack.fittingSize.height)
            let maxY = max(0, documentHeight - visibleHeight)
            let targetY = min(max(0, rect.minY - 12), maxY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        } else {
            scrollView.contentView.scroll(to: .zero)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// `isFlipped = true` 문서 뷰 — `scroll(.zero)`가 맨 위로 가도록(아니면
/// NSStackView 기본 좌표계가 (0,0)을 바닥에 둬 매 바인드 끝으로 스크롤됨).
private final class ConversationFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
