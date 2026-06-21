# 확장성 아키텍처 — Conversation 렌더 파이프라인

작성자: jaden
관점: "표시 대상이 계속 늘어나도 기존 코드를 거의 건드리지 않고 추가"할 수 있는 구조 설계.
연관: [synthesis.md](synthesis.md), [proposal-5-content-curation.md](proposal-5-content-curation.md), [proposal-2-competitor-benchmark.md](proposal-2-competitor-benchmark.md)

---

## 0. 왜 확장성이 최우선 설계 가치인가

Conversation 탭이 "전용 앱 수준"이 되려면 **표시 대상의 종류가 계속 늘어난다**:

- 지금 당장: 텍스트(마크다운), 코드블록, 도구 호출/결과, 사고, 서브에이전트, 첨부, 상태 배너
- 곧: **테이블**, 파일 편집 **diff 카드**, 도구 액션 **묶음 접기**("읽기 파일 3개 ›"), 문서 카드("다음에서 열기")
- 미래: 이미지 그리드, mermaid/그래프, 웹 미리보기, todo 체크리스트, 인용 블록, 수식…

이때 **새 표시 대상 하나를 추가할 때 손대야 할 코드가 적어야** 한다. 표시 대상마다 거대한 `switch`를 여기저기 수정해야 한다면 금방 무너진다.
→ 설계 목표: **새 표시 대상 = 작은 타입 1개 + 렌더러 1개 등록.** 그 외 코드는 불변.

---

## 1. 2단계 렌더 파이프라인

표시 대상은 두 층위에 존재한다. 이를 명확히 분리하는 것이 확장성의 핵심.

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │  Level 1 — 대화 구조 (누가/무엇을 했나)                                  │
 │                                                                       │
 │   Turn(steps[])  ──►  [BlockExtractor]  ──►  [ConversationBlock]       │
 │                       (Step 해석 규칙)        (큐레이션된 블록 시퀀스)    │
 └─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼  각 블록을 뷰로
 ┌─────────────────────────────────────────────────────────────────────┐
 │  Level 2 — 콘텐츠 리치 (텍스트 안의 표/코드/리스트)                       │
 │                                                                       │
 │   AssistantTextBlock.markdown ──► [MarkdownNode] ──► [NodeRenderer]    │
 │     (paragraph/heading/list/table/codeBlock/quote/...)                │
 └─────────────────────────────────────────────────────────────────────┘
```

- **Level 1**은 "대화의 뼈대" — 화자, 도구 사용, 사고, 서브에이전트. 큐레이션(3-Tier 접기)이 여기서 일어난다.
- **Level 2**는 "한 텍스트 블록 내부의 리치 콘텐츠" — 마크다운 본문 안의 **테이블**, 코드펜스, 리스트, 인용. 표시 대상별 리치 렌더가 여기서 일어난다.

두 층을 섞으면(예: 한 거대 함수에서 Step과 마크다운을 동시에 처리) 확장이 막힌다. 분리하면 각 층에 독립적으로 새 타입을 꽂을 수 있다.

---

## 2. 확장 포인트 3개 (모두 "등록만 하면 됨")

### 2.1 BlockExtractor — Turn 해석 규칙 추가
Step들을 보고 `ConversationBlock`을 만들어내는 규칙. 새 "대화 구조 패턴"이 생기면 extractor를 추가한다.

```swift
/// Turn의 Step 스트림을 ConversationBlock으로 변환하는 규칙 하나.
/// 여러 extractor가 체인으로 동작하며, 각자 자기가 아는 패턴만 소비한다.
protocol BlockExtractor {
    /// `cursor` 위치의 Step(들)을 소비해 블록을 만들면 (블록, 소비한 Step 수)를 반환.
    /// 못 만들면 nil → 다음 extractor에게 양보.
    func extract(_ steps: [Step], at cursor: Int, context: StoryContext) -> ExtractResult?
}

struct ExtractResult { let blocks: [ConversationBlock]; let consumed: Int }
```

예) `ToolGroupExtractor`: 연속된 동종 도구 호출(Read×3)을 하나의 `ToolGroupBlock`으로 묶음("읽기 파일 3개 ›"). `DiffExtractor`: `Edit`/`Write`/`MultiEdit` 도구를 `DiffBlock`으로 승격. `SubAgentExtractor`: `SubAgentGraftIndex`를 보고 `SubAgentBlock` 삽입.

### 2.2 BlockRenderer — 블록을 뷰로 (레지스트리)
`ConversationBlock` → `NSView` 매핑. 블록 타입별 렌더러를 레지스트리에 등록한다.

```swift
protocol BlockRenderer {
    associatedtype Block: ConversationBlock
    func makeView(for block: Block, context: RenderContext) -> NSView
}

/// 타입 → 렌더러 등록소. 미등록 타입은 PlainTextRenderer로 graceful fallback.
final class BlockRendererRegistry {
    func register<R: BlockRenderer>(_ renderer: R)
    func view(for block: any ConversationBlock, context: RenderContext) -> NSView
    // 미등록이면 fallbackRenderer.makeView(...) — 앱이 절대 안 깨진다.
}
```

### 2.3 MarkdownNodeRenderer — 마크다운 노드별 리치 렌더 (테이블 등)
텍스트 블록 내부를 마크다운 AST로 파싱한 뒤, 노드 종류별 렌더러를 등록한다. **테이블은 여기서 NSGridView로 렌더된다.**

```swift
protocol MarkdownNodeRenderer {
    func makeView(for node: MarkdownNode, context: RenderContext) -> NSView?
}
// TableNodeRenderer → NSGridView, CodeBlockNodeRenderer → 코드 카드,
// ListNodeRenderer, QuoteNodeRenderer, ... 미등록 노드는 attributed 텍스트로 폴백.
```

---

## 3. 블록 모델 — 닫힌 enum vs 열린 protocol

| 방식 | 장점 | 단점 |
|---|---|---|
| `enum ConversationBlock { case ... }` | Swift다움, exhaustive `switch`로 누락 컴파일 에러 | **새 case마다 모든 switch 수정** → 확장 비용 높음 |
| `protocol ConversationBlock` + 타입들 + 레지스트리 | **새 타입 = 타입+렌더러 등록만**, 기존 불변. 미등록 폴백 가능 | 컴파일 타임 exhaustive 보장 없음(런타임 폴백으로 보완) |

**권장 = 하이브리드.**
- `ConversationBlock`은 **프로토콜**(열린 확장). 렌더러 레지스트리로 매핑 → 새 표시 대상 추가가 싸다.
- 단, **빌더 내부의 큐레이션 Tier 판정**처럼 누락이 위험한 핵심 분기는 enum(`Tier`, `Role`)으로 두어 컴파일 안전성 확보.
- 미등록 블록/노드는 `PlainTextRenderer`로 자동 폴백 → 렌더러를 깜빡해도 "텍스트로라도" 보인다(안전한 확장).

```swift
protocol ConversationBlock {
    var id: String { get }
    var tier: Tier { get }          // .primary / .secondary / .hidden  (enum, 핵심)
    var role: Role { get }          // .user / .assistant / .system / .subAgent (enum)
}

// 구체 블록들 — 새로 추가해도 기존 코드 불변:
struct UserPromptBlock:   ConversationBlock { ... }
struct AssistantTextBlock:ConversationBlock { let markdown: String }
struct ToolGroupBlock:    ConversationBlock { let tool: String; let calls: [ToolCallSummary] }  // "읽기 파일 3개"
struct DiffBlock:         ConversationBlock { let file: String; let hunks: [DiffHunk] }          // 파일 편집 카드
struct ThinkingBlock:     ConversationBlock { let text: String }
struct SubAgentBlock:     ConversationBlock { let kind: String; let summary: String; let turn: Turn }
struct AttachmentBlock:   ConversationBlock { let refs: [AttachmentRef] }                        // 문서 카드
struct StatusBlock:       ConversationBlock { let kind: StatusKind }                             // 중단/오류/compact
// 미래: TableBlock(독립), ImageGridBlock, MermaidBlock, WebPreviewBlock ...
```

---

## 4. 스크린샷(Claude Code / Codex) 패턴 → 블록 매핑

사용자가 참고로 제시한 화면 요소들을 위 모델로 그대로 흡수한다.

| 스크린샷 요소 | 블록 / 렌더러 | 큐레이션 |
|---|---|---|
| "읽기 파일 3개 ›" / "실행됨 명령 2개 ›" | `ToolGroupBlock` + 디스클로저 렌더러 | Tier2, 기본 접힘·한 줄 |
| "파일 2개 편집함 · 변경 사항 검토" + 파일별 `+26 −23` | `DiffBlock`(파일별) + 그룹 헤더 | Tier2, 펼치면 hunk diff |
| 파일 카드("…plan.md · 문서·MD · 다음에서 열기 ⌄") | `AttachmentBlock`(문서 카드 렌더러) | Tier2, 액션 메뉴(Finder/열기) |
| 마크다운 본문(헤더·굵게·리스트) | `AssistantTextBlock` → Markdown Level 2 | Tier1, 항상 펼침 |
| **표/테이블** | Level 2 `TableNodeRenderer` → `NSGridView` | Tier1 본문 내 인라인 |
| 코드블록 | Level 2 `CodeBlockNodeRenderer` | 본문 내, Copy 버튼 |
| 사고("Thinking") | `ThinkingBlock` | Tier2, 접힘 |

핵심 차용 원칙(벤치마크 안과 일치): **버블 금지·풀폭 + 좌측 거터, 도구는 접히는 한 줄 요약, 한눈에 훑기 우선.** Lupen은 여기에 **비용/토큰 메타를 카드에 조용히 동행**(차별점).

---

## 5. "한눈에 훑기" 가독성 = 기본 압축 + 점진 공개

배치 우선순위(사용자 요구: 가독성·편집/배치가 가장 중요):

1. **스캔 라인 우선**: Tier2/3는 항상 "아이콘 + 한 줄 요약"으로 먼저 보여 전체 흐름을 5초에 훑게 한다.
2. **밀도 토글**: 헤더에 [도구][thinking][시스템] 토글(영속) + Compact↔Full. 기본 Compact.
3. **읽기 컬럼 clamp**: 본문 ~620pt(CJK 실측 조정), 코드/테이블/diff는 컬럼 초과 허용.
4. **그룹 헤더**: 연속 도구·파일편집을 묶어 "N개" 한 줄(스크린샷 패턴) → 노이즈를 구조로 흡수.

---

## 6. 렌더 성능 & 안전 (확장이 성능을 깨지 않도록)

- **본문 lazy 생성**: 접힌 블록은 펼칠 때만 뷰 생성(특히 거대 toolResult/diff). NSStackView 서브뷰 폭증 방지.
- **셀/뷰 재사용**: 같은 블록 타입 뷰 풀링 고려(매우 긴 Turn).
- **재바인드 가드 유지**: 동일 선택 re-render 스킵(DetailViewController:537-545) → 스크롤 점프 방지.
- **폴백 불변식**: 어떤 블록/노드도 렌더러가 없으면 평문으로라도 표시(절대 빈 화면/크래시 없음). 새 표시 대상을 실험적으로 추가해도 안전.

---

## 7. 확장 시나리오 — "5분 추가" 검증

> Q. 나중에 mermaid 다이어그램을 대화에 보여주고 싶다면?
> A. (1) `MermaidBlock` 타입 추가 → (2) `MermaidExtractor`(```mermaid 펜스 감지) 등록 → (3) `MermaidRenderer` 등록. **기존 블록/렌더러/빌더 코드 0줄 수정.** 폴백 덕분에 렌더러를 늦게 붙여도 그동안은 코드블록으로 보인다.

> Q. "테이블"을 리치하게?
> A. Level 2에 `TableNodeRenderer`(NSGridView) 등록. AssistantTextBlock은 그대로. 다른 코드 불변.

이 "추가 비용이 국소적"이라는 성질이 이번 설계의 합격 기준이다.

---

## 8. 파일/타입 배치 (제안)

```
Lupen/Domain/Conversation/Story/
  ConversationBlock.swift          // protocol + Tier/Role enum + 구체 블록들
  ConversationStoryBuilder.swift   // extractor 체인 구동 (순수, 테스트 대상)
  Extractors/                      // ToolGroupExtractor, DiffExtractor, SubAgentExtractor ...
Lupen/UI/Dashboard/Conversation/
  ConversationDetailView.swift     // 카드 스택 호스트 (NSScrollView+flipped+NSStackView)
  BlockRendererRegistry.swift      // 등록소 + 폴백
  Renderers/                       // UserPromptRenderer, ToolGroupRenderer, DiffRenderer ...
  Markdown/                        // MarkdownNode, NodeRenderers(Table=NSGridView, Code, List ...)
```

→ 새 표시 대상은 거의 항상 `Extractors/` + `Renderers/`(또는 `Markdown/`)에 **파일 1~2개 추가**로 끝난다.
