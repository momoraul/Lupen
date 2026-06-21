# Plan: Conversation 탭 → "Turn 대화 리더" (확장 가능 카드 스택)

작성자: jaden
연관 리서치: [synthesis.md](synthesis.md) · [extensibility-architecture.md](extensibility-architecture.md) · [proposal-0~5](.) · [HTML 제안서](conversation-redesign-proposal.html)
브랜치: `feature/conversation-rich-reader` (이미 생성됨, main 기반)

---

## 0. 이 문서를 읽는 새 세션에게 — 자율 실행 가이드

> 이 plan은 **사전 승인된 확정 계획**이다. 맥락이 전혀 없는 새 세션이 이 문서 하나로 프로젝트를 파악하고 **구현을 완료까지 자율 진행**하도록 작성되었다. 별도 승인을 기다리지 말고 0.5의 **페이즈 실행 프로토콜**을 따라 진행하라. 핵심 원칙: **안정적으로(회귀 0), 성능 이슈 없이, 좋은 설계로.** 각 페이즈는 **피드백 루프로 이슈가 0이 될 때까지 반복**한 뒤에만 커밋하고 다음 페이즈로 넘어간다.

### 0.1 무엇을 만드는가 (한 문단)
Lupen의 Conversation 탭(하단 상세 패널의 첫 번째 탭)은 현재 단일 `NSTextView`에 "USER 평문 / ASSISTANT 평문" 두 덩어리만 그린다. 특히 Turn을 선택하면 응답이 통째로 비어 `"(no response available)"`가 뜬다. 이를 **전용 앱(Claude Code/Codex/Cursor) 수준의 "Turn 대화 리더"** 로 바꾼다: 한 Turn의 흐름(내 프롬프트 → 사고 → 도구 → 최종 답변)을 **한눈에 훑을 수 있게**, 표시 대상별로 **rich하게**(마크다운·테이블·코드·diff·도구 묶음) 보여주고, **새 표시 대상 추가가 쉽도록** 블록 + 렌더러 레지스트리 골격 위에 올린다. 도메인 모델은 바꾸지 않는다(데이터는 이미 충분). 표현 레이어만 교체한다.

### 0.2 시작 절차 (이 순서로 읽어라)
1. **이 plan 전체** (특히 0, 2, 3, 4, 5, 6).
2. 같은 폴더의 리서치 — 깊은 근거가 필요할 때: [synthesis.md](synthesis.md)(통합 청사진) → [extensibility-architecture.md](extensibility-architecture.md)(확장 골격) → 필요 시 proposal-1(현재 구현)·proposal-5(콘텐츠 설계).
3. 루트 [README.md](../../../README.md) — Lupen이 무엇인지 1분 파악.
4. 핵심 코드(아래 0.3의 경로) — **라인 번호는 변동될 수 있으니 Grep/Read로 현재 위치를 반드시 재확인**하고 진행하라.

### 0.3 프로젝트 1분 파악 (Lupen)
- **무엇**: Claude Code / Codex의 로컬 세션 로그를 읽어 AI 코딩 비용을 항목별로 분해·검증하는 **macOS 메뉴바 앱**. 제로 네트워크(로컬 파일만 읽음).
- **스택**: Swift 6.2 (strict concurrency `complete`), macOS 26+, **AppKit**(NSOutlineView/NSSplitView), GRDB(SQLite), Sparkle. 외부 의존성 3개뿐 — **추가 지양**.
- **레이어**: `Lupen/Data`(JSONL 파싱) → `Lupen/Store`(프로바이더별 SQLite 인덱스) → `Lupen/Domain`(대화 조립·비용·프로바이더 추상화) → `Lupen/UI`(AppKit). 중앙 상태는 `@Observable AppStateStore`(메인 액터에서만 변경).
- **이 작업의 무대**:
  - `Lupen/UI/Dashboard/DetailViewController.swift` — 상단 아웃라인 아래의 상세 패널. **Conversation/Attachments/Tokens/Usage/Raw 탭**을 형제 NSView로 두고 `isHidden`으로 전환. `ConversationDetailView`(교체 대상)·`TokensDetailView`(참고할 검증된 스택 패턴)가 같은 파일에 들어있다.
  - `Lupen/Domain/Conversation/` — `Turn`, `Step`, `StepKind`, `ToolUseInfo`, `ToolResultInfo`, `SkillGroupBuilder` 등 대화 도메인. **이미 rich한 데이터**(사고·도구·모델·비용·서브에이전트)를 들고 있다.
  - `Lupen/UI/Dashboard/SubAgentGraftIndex.swift` — 서브에이전트 부모-자식 연결.
  - `Lupen/UI/Support/StepKindStyle.swift` — 역할별 아이콘/색 토큰(재사용).
- **테스트 문화**: `LupenTests/`에 순수 로직 단위 테스트가 매우 촘촘하다(도메인 위주). 성능/메모리 예산 테스트도 존재: `SQLiteSelectionLatencyTests`, `ImporterMemoryBoundTests`, `CodexOversizedPieceMemoryTests`, `Support/RefactorBudgets`. → **이 작업도 같은 수준으로 테스트한다.**

### 0.4 빌드 / 테스트 / 커버리지 명령 (CI ground truth — 이 작업에 한해 자율 실행 허용)
```bash
# 빌드 (경고 신규 발생 0 목표)
xcodebuild build -project Lupen.xcodeproj -scheme Lupen \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO 2>&1 | tail -n 40

# 전체 테스트 + 커버리지 수집
xcodebuild test -project Lupen.xcodeproj -scheme Lupen \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO \
  -enableCodeCoverage YES -resultBundlePath /tmp/Lupen.xcresult 2>&1 | tail -n 60

# 특정 테스트만 (피드백 루프 중 빠르게)
xcodebuild test ... -only-testing:LupenTests/ConversationStoryBuilderTests

# 커버리지 리포트 — 새로 추가한 파일이 ~100%인지 확인
xcrun xccov view --report --files-for-target Lupen /tmp/Lupen.xcresult \
  | grep -E "Conversation|Markdown|Extractor|Renderer"
```
- 테스트 타깃 `LupenTests`. 신규 테스트 파일은 이 타깃 멤버십으로 .xcodeproj에 추가.
- SwiftLint 전용 게이트 없음(루트 `.swiftlint.yml` 없음). CI는 build + test만 검사.

### 0.5 페이즈 실행 프로토콜 (★ 모든 페이즈가 이 루프를 따른다)
각 페이즈는 다음 7단계로 진행한다. **5단계(피드백 루프)에서 이슈가 0이 될 때까지 반복**한 뒤에만 6단계(커밋)로 간다.

```
[1] SCOPE    해당 페이즈 task를 세부 단계로 쪼개고, 건드릴 파일·영향 범위를 Grep/Read로 현재 코드 기준 재확인.
             기존 패턴(참조 구현: TokensDetailView)을 먼저 찾아 그대로 따를지 결정.
[2] DESIGN   확장 골격(블록/렌더러 레지스트리/폴백)에 맞는지, 단일 책임·최소 표면인지 1차 점검.
[3] BUILD    구현. 기존 코드 컨벤션·주석 밀도에 맞춤. 새 로직은 순수 함수로 빼서 테스트 가능하게.
[4] TEST     이 페이즈가 만든 모든 로직에 단위 테스트 작성(0.7 커버리지 목표). 엣지/실패 경로 포함.
[5] FEEDBACK LOOP — 아래를 돌려 이슈가 "0"이 될 때까지 반복(고치고 다시 처음부터):
     5a 빌드 통과 + 신규 경고 0
     5b 전체 테스트 통과(신규 + 기존 회귀 0)
     5c 커버리지 측정 → 이 페이즈 산출 파일이 목표 미달이면 테스트 보강(→ 5로 복귀)
     5d 성능 게이트 통과(0.6의 성능 기준; 해당 페이즈에 한함)
     5e 회귀 체크리스트 통과(0.6 회귀 금지 항목 수동/테스트 확인)
     5f 설계 셀프리뷰 통과(0.6 설계 기준) — 미달이면 리팩터 후 5로 복귀
     ── 위 6개가 모두 클린일 때만 다음 단계 ──
[6] COMMIT   클린 상태에서만 페이즈 단위 커밋(메시지 규약 0.6). 체크박스 [x] 갱신. 결정 로그 한 줄.
[7] NEXT     다음 페이즈로. 모든 페이즈 완료 + 0.7 DoD 충족까지 멈추지 않는다.
```
- **push / PR 생성은 하지 않는다**(사용자가 별도 지시할 때만).
- **막힘 처리**: 설계 선택지가 생기면 합리적 기본값을 택해 진행하고 맨 끝 "결정 로그"에 한 줄 남긴다. **중단하고 물을 때는** 데이터 파괴·되돌리기 어려운 변경·외부 영향(네트워크/푸시)·도메인 모델 스키마 변경이 필요할 때뿐이다.
- 2의 확정 결정(Q1~Q4)을 절대 뒤집지 말 것.

### 0.6 품질 게이트 정의 (피드백 루프의 합격 기준)
**회귀 게이트** — 매 루프 전체 테스트 통과(기존 테스트 회귀 0). 다음 기존 동작을 새 렌더러로 **반드시 이식**(가능하면 테스트로 고정):
- 인라인 이미지 글리프 치환 + `[Image source:]`의 `file://` 링크 클릭 → Finder reveal.
- 동일 선택 재바인드 시 re-render 스킵(스트리밍 중 스크롤 점프 방지).
- Codex / Claude 프로바이더 분기, 본문 드래그 선택·복사.
- 다른 탭(Attachments/Tokens/Usage/Raw)과 빈 상태 동작 불변.

**성능 게이트** — 긴 Turn(수십~수백 step)에서:
- 접힌 블록은 펼치기 전 본문 뷰를 **생성하지 않음**(lazy). 큰 toolResult/이미지/diff는 펼칠 때만 로드.
- 선택 전환 시 동일선택 재바인드 스킵 유지.
- 렌더/스크롤이 체감 끊김 없을 것. 가능하면 `RefactorBudgets` 패턴으로 빌드 시간·렌더 항목 예산 테스트 추가, 메모리는 `ImporterMemoryBoundTests` 패턴 참고.

**설계 게이트(셀프리뷰)**:
- 새 표시 대상이 "타입 1개 + 렌더러 등록"으로 추가되는가(레지스트리 + 폴백 불변식). 미등록 블록/노드는 평문 폴백 → 크래시/빈 화면 없음.
- 순수 로직(Builder/Parser/Extractors)과 뷰(Renderer)가 분리됐는가. 순수부는 UI 의존 0.
- 불필요한 복잡도/추상화 없음. 단일 책임. 기존 패턴과 일관.

**빌드 게이트** — 빌드 통과 + 이 작업으로 **새로 생긴 경고 0**(기존 경고는 건드리지 않음).

**컨벤션**:
- 파일 헤더 author는 `jaden`. AI/Claude 이름 금지. 불필요한 주석/과도한 추상화 금지.
- 커밋 메시지: `feat:`/`refactor:`/`test:` 등 + 한국어 본문 가능. 끝에:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

### 0.7 완료 정의 (Definition of Done)
- [ ] Phase A~E의 모든 task 체크 완료.
- [ ] `xcodebuild build`·`xcodebuild test` 통과. 기존 테스트 회귀 0. 신규 경고 0.
- [ ] **테스트 커버리지**: 순수 로직 파일(`ConversationStoryBuilder`, `MarkdownParser`, 모든 `Extractor`)은 라인+브랜치 **~100%**. 렌더러는 로직부(폴백 선택·요약·하이라이트 판정 등)를 테스트로 커버, 순수 뷰 생성은 스모크 수준 이상.
- [ ] Turn 선택 시 전체 대화 흐름이 보이고 `"(no response available)"`가 사라짐.
- [ ] Step 선택 시 Turn 전체 + 해당 Step 하이라이트(Q1).
- [ ] 본문 마크다운(헤더/리스트/링크) + 테이블(NSGridView) + 코드블록(단색 모노+Copy) 렌더.
- [ ] 도구 묶음("읽기 파일 N개 ›") 접기/펼치기, 사고·서브에이전트·diff·문서 카드, 빈 상태 배너 동작.
- [ ] 0.6 회귀·성능·설계 게이트 전부 충족.

---

## 1. 목표

Conversation 탭을 "평문 출력기"에서 **Turn 단위 대화 리더**로 재설계한다. 한 Turn의 흐름을 한눈에 훑게, 표시 대상별로 rich하게 보여주고, 새 표시 대상 추가가 쉽도록 확장 골격(블록 + 렌더러 레지스트리) 위에 올린다.

## 2. 확정된 결정 (변경 금지)

| # | 결정 | 영향 |
|---|---|---|
| **Q1** | **Turn 전체 렌더 + 선택 Step 하이라이트** | `showStep`도 Turn 전체를 그리고 해당 Step 카드를 강조·스크롤. Step 단독 평문 표시 폐기. |
| **Q2** | **중간 단계(P1) 생략, 최종 스펙 직행** | 단색 TextView 개선 단계 없이 카드 스택 최종 구조로. (안전 머지를 위해 *내부 순서*는 빌더→레지스트리→카드→리치로 점진) |
| **Q3** | **코드블록 단색 모노 폴백** | `Splash` 등 신택스 하이라이팅 의존성 미추가. 노드 렌더러 인터페이스만 열어 추후 교체 가능. |
| **Q4** | **읽기폭 ~620pt 권장값** | 본문 컬럼 clamp 620pt 시작, 코드/표/diff는 초과 허용. CJK 실측은 구현 중 미세조정. |

추가 확정(synthesis):
- 렌더 기술 = **NSStackView 카드 스택 + 카드 본문 selectable NSTextView** 하이브리드.
- 마크다운 = Foundation **`AttributedString(markdown:)`**(인라인) + 블록(테이블/코드/리스트) 자체 노드 렌더러. 외부 의존성 0.
- `ConversationStoryBuilder`는 **순수 함수**(UI 무관, 단위 테스트 대상). 도메인 모델 변경 없음.

## 3. 아키텍처 (확장 골격)

2단계 파이프라인 (상세: [extensibility-architecture.md](extensibility-architecture.md)).

```
Turn(steps[]) ─► ConversationStoryBuilder ─► [ConversationBlock] ─► BlockRendererRegistry ─► NSStackView 카드들
   (+SubAgentGraftIndex, 이웃 Turn)        (extractor 체인, 큐레이션)     (타입별 렌더러 + 폴백)
                                                                            └ 본문 텍스트 ─► Markdown 노드 렌더러(테이블=NSGridView)
```

확장 포인트(모두 "등록만"): `BlockExtractor`(Step 해석) · `BlockRenderer`(블록→뷰) · `MarkdownNodeRenderer`(노드→뷰).
폴백 불변식: 미등록 블록/노드는 평문으로라도 표시 → 크래시/빈 화면 없음.

## 4. 파일 / 타입 배치

기존 `DetailViewController.swift`는 모든 detail view를 한 파일에 담지만, 카드 스택은 규모가 커 **별도 디렉토리로 승격**한다(근거: 단일 파일 비대 방지, 렌더러 다수).

```
Lupen/Domain/Conversation/Story/
  ConversationBlock.swift          # protocol ConversationBlock + Tier/Role enum + 구체 블록 타입들
  ConversationStoryBuilder.swift   # 순수: Turn → [ConversationBlock] (extractor 체인 구동)
  Extractors/
    PromptReplyExtractor.swift     # .prompt → UserPromptBlock, .reply → AssistantTextBlock
    ToolGroupExtractor.swift       # 연속 동종 toolCall+result 병합 → ToolGroupBlock ("읽기 파일 3개")
    DiffExtractor.swift            # Edit/Write/MultiEdit/patch → DiffBlock (Phase D)
    ThinkingExtractor.swift        # thinkingText/.thought → ThinkingBlock
    SubAgentExtractor.swift        # SubAgentGraftIndex → SubAgentBlock
    StatusExtractor.swift          # 중단/API오류/compact → StatusBlock
  Markdown/
    MarkdownNode.swift             # paragraph/heading/list/table/codeBlock/quote
    MarkdownParser.swift           # AttributedString(markdown:) + 블록 분리(테이블/펜스)
Lupen/UI/Dashboard/Conversation/
  ConversationDetailView.swift     # 카드 스택 호스트(NSScrollView+flipped+NSStackView). 기존 동명 클래스 대체
  CardContainerView.swift          # 공통 카드 셸(좌측 거터 + 헤더 + 본문 슬롯 + 펼침 상태)
  BlockRendererRegistry.swift      # 등록소 + PlainText 폴백
  Renderers/
    UserPromptCardRenderer.swift / AssistantTextCardRenderer.swift
    ToolGroupCardRenderer.swift / ThinkingCardRenderer.swift / SubAgentCardRenderer.swift
    DiffCardRenderer.swift / AttachmentCardRenderer.swift / StatusBannerRenderer.swift
  Markdown/
    TableNodeRenderer.swift           # NSGridView
    CodeBlockNodeRenderer.swift       # 단색 모노 + Copy (Q3)
    ListNodeRenderer.swift / QuoteNodeRenderer.swift
  DetailStyles+Conversation.swift     # convBodyFont 13, lineHeight 1.45, readingWidth 620 (Q4)
```

`DetailViewController.swift`는 `conversationView`를 새 `ConversationDetailView`로 교체하고 호출부만 수정. 형제 `isHidden` 토글 구조는 불변 → 다른 탭 영향 격리.
> 새 .swift 파일은 모두 `Lupen` 앱 타깃, 새 테스트는 `LupenTests` 타깃 멤버십으로 .xcodeproj에 추가해야 빌드/테스트에 잡힌다.

## 5. 핵심 인터페이스 (스케치, 구현 중 확정)

```swift
protocol ConversationBlock { var id: String { get }; var tier: Tier { get }; var role: Role { get } }
enum Tier { case primary, secondary, hidden }
enum Role { case user, assistant, system, subAgent }

protocol BlockExtractor {
    func extract(_ steps: [Step], at i: Int, ctx: StoryContext) -> ExtractResult?
}
final class ConversationStoryBuilder {  // 순수
    static func build(turn: Turn, graft: SubAgentGraftIndex?, neighbor: Turn?,
                      highlight stepUuid: String?) -> [ConversationBlock]
}
protocol BlockRenderer { associatedtype B: ConversationBlock
    func makeView(for b: B, ctx: RenderContext) -> NSView }
final class BlockRendererRegistry {
    func register<R: BlockRenderer>(_ r: R)
    func view(for b: any ConversationBlock, ctx: RenderContext) -> NSView  // 미등록 → 폴백
}
```

`ConversationDetailView.configure(blocks:highlight:)` — 평문 2개 인터페이스(`humanPrompt:assistantContent:`) 폐기.
`DetailViewController.showTurn/showStep`은 `ConversationStoryBuilder.build(...)` 호출로 변경(Q1: showStep은 `highlight: step.uuid`).

## 6. Task Breakdown + 페이즈별 진행 방식

> 모든 페이즈는 0.5의 7단계 루프를 따른다. 아래 "진행 방식"은 그 페이즈에서 특히 중요한 게이트를 짚는다. **체크박스는 진행하며 `[x]`로 갱신.**

### Phase A — 빌더 + 모델 + 테스트 (UI 무변경, 안전 머지)
**진행 방식**: 순수 로직만. UI를 건드리지 않으므로 회귀 위험이 가장 낮다 → 여기서 **커버리지 ~100%를 확보**해 이후 페이즈의 토대를 굳힌다. 도메인 모델 변경 없음(기존 `Step`/`Turn` 읽기만).
- [x] A1. `ConversationBlock` protocol + `Tier`/`Role` enum + 구체 블록 타입 정의.
- [x] A2. `MarkdownNode` + `MarkdownParser`(블록 분리: 테이블/코드펜스/리스트/인용/헤딩).
- [x] A3. `ConversationStoryBuilder.build(turn:neighbor:highlight:)` 단일 패스(Prompt/Reply, ToolGroup 병합·동종 묶음, Thinking, Status). SubAgent/Diff는 Phase D.
- [x] A4. 단위 테스트(LupenTests/Domain/Conversation/Story): 36 케이스 + 엣지. **Builder/Parser/Block 커버리지 100% 측정 확인.**
- [x] A5. 피드백 루프 클린 → 커밋.
**게이트**: 커버리지 100%(달성), 설계 분리(순수/뷰), 신규 경고 0.

### Phase B — 카드 스택 렌더러 골격 (Tier1 우선, 최종 구조)
**진행 방식**: 표현 레이어를 처음 바꾸는 페이즈 → **회귀 게이트가 최우선.** 기존 `ConversationDetailView`를 교체하기 전에 이식할 동작(0.6 회귀 목록)을 테스트/체크리스트로 고정한 뒤 교체한다. 교체 후 **앱 실행 육안 확인** 필수.
- [ ] B1. `ConversationDetailView`를 NSScrollView+flipped+NSStackView로 재작성. `configure(blocks:highlight:)`.
- [ ] B2. `BlockRendererRegistry` + `PlainText` 폴백 + `CardContainerView`(거터/헤더/본문/펼침).
- [ ] B3. 렌더러: UserPrompt, AssistantText(본문 selectable NSTextView + Markdown 노드뷰), StatusBanner.
- [ ] B4. `DetailViewController.showTurn/showStep` → builder 호출로 교체 (Q1 하이라이트, Q2 최종 스펙).
- [ ] B5. 회귀 이식: 인라인 이미지 글리프 + `file://` Finder reveal, 동일선택 re-render 스킵, Codex/Claude 분기. (가능한 것은 테스트로 고정)
- [ ] B6. 빈 상태 배너(✋ 중단 / ⚠ API 오류 / ✂ compact)로 "(no response available)" 박멸.
- [ ] B7. 레지스트리/폴백/하이라이트 판정 로직 테스트. 피드백 루프 클린 + **앱 실행 육안 확인** → 커밋.
**게이트**: 회귀 0(이식 동작 보존), 폴백 불변식, 동일선택 스킵 유지.

### Phase C — 리치 콘텐츠 노드 렌더러
**진행 방식**: 표시 대상별 렌더러를 레지스트리에 "등록만"으로 추가 — 확장 골격이 실제로 동작하는지 검증되는 페이즈. 마크다운 오판(로그/JSON을 표로) 방지: 도구 출력엔 마크다운 미적용.
- [ ] C1. `TableNodeRenderer`(NSGridView) — 본문 테이블.
- [ ] C2. `CodeBlockNodeRenderer` — 단색 모노 + Copy 버튼 (Q3, 신택스는 인터페이스만).
- [ ] C3. List/Quote 노드 렌더러. 미지원 노드는 평문 폴백.
- [ ] C4. 읽기폭 620pt clamp + 줄간격 1.45 토큰(`DetailStyles+Conversation`).
- [ ] C5. 파서/노드 매핑 테스트(테이블 셀 파싱, 펜스, 미지원 폴백) → 피드백 루프 클린 → 커밋.
**게이트**: 파서 커버리지, 폴백 동작, 마크다운 오판 없음.

### Phase D — 도구/구조 카드 + 큐레이션 컨트롤
**진행 방식**: 가장 복잡 → **성능 게이트 중점.** 도구/서브에이전트/diff 본문은 펼칠 때만 생성(lazy)·로드. 재귀(서브에이전트)는 깊이 1로 제한.
- [ ] D1. `ToolGroupCardRenderer` — "읽기 파일 N개 ›" 접힘 → 펼치면 개별(입력/출력 lazy 로드 via `store.rawJSON`).
- [ ] D2. `ThinkingCardRenderer` — 접힘 디스클로저.
- [ ] D3. `SubAgentExtractor`/`SubAgentCardRenderer` — 인라인 카드, 펼치면 build() 재귀(깊이 1), 비용=서브Turn aggregate.
- [ ] D4. `DiffExtractor`/`DiffCardRenderer` — 파일명 + +N/−M 배지 + hunk 병치(스샷 패턴).
- [ ] D5. `AttachmentCardRenderer` — 문서/첨부 카드("다음에서 열기").
- [ ] D6. 헤더 전역 토글 바(도구·thinking·시스템) + Compact↔Full, UserDefaults 영속.
- [ ] D7. 병합/그룹핑/diff 추출 로직 테스트 + 긴 Turn 성능 확인 → 피드백 루프 클린 → 커밋.
**게이트**: 도구 병합 로직 커버리지, lazy 로드 검증, 재귀 깊이 1, 긴 Turn 성능.

### Phase E — 마감
**진행 방식**: 전체 회귀·성능·접근성 최종 점검. 0.7 DoD 전수 점검.
- [ ] E1. 비용/모델/토큰 메타 라인 동행(assistant 카드, Lupen 차별점).
- [ ] E2. 성능: 접힌 블록 본문 lazy 생성 확인, 긴 Turn 측정, 필요 시 뷰 풀링. (가능하면 예산 테스트 추가)
- [ ] E3. 접근성(VoiceOver 역할/라벨), 다크모드 semantic 컬러 확인.
- [ ] E4. 최종 빌드+전체 테스트+커버리지 점검, 0.7 DoD 전수 통과 → 커밋.
**게이트**: 전체 회귀 0, 성능, 접근성, DoD 전수.

## 7. 단위 테스트 (커버리지 ~100% 목표)

**순수 로직(필수 ~100%)** — `ConversationStoryBuilder` / `MarkdownParser` / 각 `Extractor`:
- 프롬프트만/응답만/양쪽 있는 Turn → 블록 시퀀스 정확.
- toolCall+toolResult `toolUseId` 병합, 매칭 실패 시 orphan 폴백.
- 연속 동종 도구 묶음 카운트("3개"), 이종 도구 경계 분리.
- 빈/중단/API오류/compact → 올바른 StatusBlock(기존 Turn 플래그: `isInterrupted`/`endedWithApiError`/`wasCompactedAway`, `Step.isSyntheticApiError`).
- 큐레이션 Tier 매핑(prompt/reply=primary, tool/thinking=secondary, meta=hidden).
- Q1 하이라이트: 주어진 stepUuid가 해당 블록에 표시 플래그.
- 서브에이전트: graft 존재/부재, 재귀 깊이 1 경계.
- Markdown: 테이블(헤더/정렬/셀)·코드펜스·리스트·인용 노드 분리, 미지원 문법 평문 폴백, 빈/깨진 입력.

**렌더러 로직(테스트 가능부)** — 레지스트리 라우팅(등록/미등록→폴백), 하이라이트 적용, 도구 요약 문자열, lazy 로드 트리거 여부. 순수 뷰 생성은 "충돌 없이 NSView 반환" 스모크 수준 이상.

**회귀 고정** — 이미지 링크 URL 추출, 동일선택 재바인드 스킵 판정 등 0.6 회귀 항목 중 로직화 가능한 것은 테스트로 박제.

**측정** — 0.4의 `-enableCodeCoverage YES` + `xccov`로 신규 파일 커버리지 확인. 미달 라인/브랜치는 그 페이즈 피드백 루프에서 채운다.

## 8. 트레이드오프 / 범위 밖

- 신택스 하이라이팅: 범위 밖(Q3, 단색). 노드 렌더러 교체 지점만 확보.
- 진짜 라인 diff 알고리즘: Phase D는 Edit old/new 병치(정직하게 before/after 라벨). 정밀 LCS는 후속.
- 매우 긴 Turn 가상화: 1차는 lazy 본문으로 대응, 본격 가상화는 성능 측정 후.
- 블록 넘는 전체 통선택: 카드별 selectable + "Copy as Markdown"으로 대체.

## 9. 검증 계획

- 각 페이즈 종료 시 0.5의 피드백 루프(빌드/테스트/커버리지/성능/회귀/설계)를 게이트로 통과해야만 커밋.
- Phase B 후 앱 실행 육안 확인: Turn 선택 시 전체 흐름 표시, "(no response available)" 소멸, Step 선택 시 Turn+하이라이트, 기존 이미지 링크/검색/복사 회귀 없음.
- Phase C/D 후: 테이블/코드/도구묶음/diff/서브에이전트 렌더 및 토글 동작, Codex·Claude 양 provider 정상.
- 최종: 0.7 DoD 체크리스트 전부 충족.

---

## 결정 로그 (자율 진행 중 채택한 기본값을 여기 누적)

- _2026-06-21_: 초기 계획 확정(Q1~Q4 반영). 이후 구현 중 선택은 이 아래에 한 줄씩 추가.
- _Phase A_: 빌더는 `BlockExtractor` 프로토콜 체인 대신 **단일 패스 + 내부 헬퍼**로 구현(과도한 추상화 회피). 확장은 렌더러 레지스트리(Phase B) + Phase D extractor로 달성.
- _Phase A_: `build` 시그니처에서 서브에이전트 파라미터는 제외(`turn:neighbor:highlight:`만). 서브에이전트는 Phase D에서 파라미터·호출부 함께 도입.
- _Phase A_: `.thought`의 텍스트/`thinkingText`는 둘 다 `ThinkingBlock`(secondary)으로. 중간 설명을 1급 답변과 구분.
- _Phase A_: 커버리지 측정은 `xcrun xccov view --report <bundle>`(옵션 없이) 사용 — `--files-for-target`는 새 xcresult에서 빈 출력.
- _Phase A_: 무관한 pre-existing 실패 `SessionCostLabelTests.testNormalCostTextAndColor`(사이드바 색 재설계 #11 이후 미갱신) 1건을 현재 프로덕션 동작에 맞춰 별도 커밋으로 수정(사용자 승인). 전체 그린은 Phase E 최종에서 재검증.
