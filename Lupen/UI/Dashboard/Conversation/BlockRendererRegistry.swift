//
//  BlockRendererRegistry.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import AppKit

/// 렌더링 시 블록들이 공유하는 의존성(스타일/콜백). 확장 가능 — 새 렌더러가
/// 필요로 하는 값이 생기면 여기에 추가한다.
@MainActor
struct RenderContext {
    /// 본문 읽기 컬럼 최대 폭(Q4). Phase C의 노드 렌더가 사용.
    var readingWidth: CGFloat = 620
    /// 파일 경로(이미지/첨부) 클릭 시 Finder reveal. 회귀 이식용.
    var revealInFinder: (URL) -> Void = { url in
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-R", path])
        } else {
            let parent = url.deletingLastPathComponent().path
            if FileManager.default.fileExists(atPath: parent) {
                Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [parent])
            }
        }
    }
}

/// 한 블록 타입을 NSView로 그리는 렌더러. 타입별로 구현해 레지스트리에 등록.
@MainActor
protocol BlockRenderer {
    associatedtype Block: ConversationBlock
    func makeView(for block: Block, context: RenderContext) -> NSView
}

/// 블록 타입 → 렌더러 매핑. 미등록 타입은 `PlainTextBlockRenderer`로 폴백한다.
///
/// 확장성의 핵심: 새 표시 대상을 추가하려면 `BlockRenderer`를 구현해
/// `register(_:)`만 호출하면 된다 — 기존 코드 수정 0. 렌더러를 깜빡 등록하지
/// 않아도 폴백이 평문으로 그려 빈 화면/크래시가 나지 않는다(폴백 불변식).
@MainActor
final class BlockRendererRegistry {
    private var makers: [ObjectIdentifier: (any ConversationBlock, RenderContext) -> NSView?] = [:]
    private let fallback = PlainTextBlockRenderer()

    func register<R: BlockRenderer>(_ renderer: R) {
        let key = ObjectIdentifier(R.Block.self)
        makers[key] = { block, context in
            guard let typed = block as? R.Block else { return nil }
            return renderer.makeView(for: typed, context: context)
        }
    }

    func view(for block: any ConversationBlock, context: RenderContext) -> NSView {
        let key = ObjectIdentifier(type(of: block))
        if let maker = makers[key], let view = maker(block, context) {
            return view
        }
        return fallback.makeView(for: block, context: context)
    }
}

/// 폴백 렌더러: 어떤 블록이든 `plainTextFallback`을 selectable 평문 카드로
/// 그린다. 전용 렌더러가 아직 없는 블록(Phase B 시점의 ToolGroup/Thinking 등)도
/// 최소한 읽을 수 있게 보장한다.
@MainActor
struct PlainTextBlockRenderer {
    func makeView(for block: any ConversationBlock, context: RenderContext) -> NSView {
        let isSecondary = block.tier != .primary
        let label = DetailStyles.makeSelectableValueLabel(
            block.plainTextFallback,
            font: .systemFont(ofSize: 12),
            color: isSecondary ? .secondaryLabelColor : .labelColor,
            alignment: .left
        )
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        let card = CardContainerView(role: block.role, tier: block.tier, highlighted: block.isHighlighted)
        card.setBody(label)
        return card
    }
}
