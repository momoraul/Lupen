# Conversation 탭 재설계 — 통합 청사진 (Single Recommended Blueprint)

> 5개 제안서(현재구현 / 경쟁벤치마크 / 가독성UX / 렌더링기술 / 콘텐츠큐레이션)를 통합한 **단일 추천안**.
> 작성: jaden / 일자: 2026-06-21
> 사용자 핵심 요구: "지난 turn의 내 프롬프트 + LLM 응답을 전용 Claude Code/Codex/Cursor 앱 수준으로, **중요한 내용만 추려서** 가독성 좋고 rich하게."

---

## 0. 한 문단 결론

5개 제안서는 진단·방향에서 **완전히 수렴**한다: 데이터 모델은 이미 충분히 rich하고(`Step`/`Turn`/`ToolUseInfo`/`ToolResultInfo`/`SubAgentGraftIndex`), 막혀 있는 것은 오직 **표현 레이어**다. 현재 Conversation 탭은 단일 `NSTextView`에 평문 두 덩어리(`humanPrompt`+`assistantContent`)를 붙이고, Turn 선택 시 `assistantContent: nil`을 넘겨 항상 `(no response available)`만 띄운다 — **코드로 확인 완료** (`DetailViewController.swift:728`, `:1579`, `:1585`). 통합안의 골자: **(1) 순수 헬퍼 `ConversationStoryBuilder`로 Turn을 `[ConversationBlock]`으로 큐레이션(3-Tier 점진 공개), (2) 렌더는 `NSStackView` 카드 스택 + 본문만 selectable `NSTextView`로 처리하는 하이브리드, (3) 마크다운은 Foundation `AttributedString(markdown:)`(인라인) + 코드펜스/리스트 자체 보강(의존성 0)으로 시작.** 가장 시급한 건 데이터 결선 버그(`(no response available)`) 제거다.

---

## 1. 합의된 사실 토대 (5개 안 공통 + 코드 검증)

이 분석에서 직접 코드로 확인한 항목:

| 주장 | 검증 결과 | 근거 |
|---|---|---|
| Turn 선택 시 `assistantContent: nil` 전달 → 답변 항상 빔 | **사실** | `DetailViewController.swift:728` |
| 단일 `NSTextView`에 평문 통째 set, 마크다운 미해석 | **사실** | `:1585` `textView.textStorage?.setAttributedString(attributed)`, `:1576` 평문 append |
| `(no response available)` 하드코딩 빈 상태 | **사실** | `:1579` |
| Tokens 탭에 flipped documentView + NSStackView 검증 패턴 존재 | **사실** | `TokensFlippedDocumentView`(`:1039`), `outerStack`(`:1076`), 위→아래 스택 셋업(`:1094-1126`) |
| 마크다운 렌더 코드베이스 전체 0건 | **사실** | `grep "AttributedString(markdown" Lupen` → 0 hits |
| SwiftUI `NSHostingView` 임베드가 사내 표준 | **사실** | 8개 파일 사용(Preferences/Reports/Diagnostics/Log/LaunchProgress/**TurnOutline**/IndexingStatus/FilterPopover), `import SwiftUI` 16개 파일 |
| macOS 26 / Swift 6.2 전용 (구버전 호환 불요) | **사실** | `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.2` |

**중요한 발견**: 상단 아웃라인(`TurnOutlineViewController`)이 **이미 `NSHostingView`(SwiftUI)** 를 쓴다. 즉 대시보드의 상·하단 두 surface 중 위쪽은 이미 SwiftUI다 — 렌더링 기술 선택에 직접 영향(§4).

데이터가 100% 준비됐다는 증거(5개 안 공통, 코드 라인 인용 일치):
- 7종 분류 `StepKind`(`StepKind.swift:5-22`) + 1급/종속 색 정책 `StepKindStyle.textColor`(`:70-80`)
- thinking 분리 저장 `Step.thinkingText`, 도구별 semantic 요약 `ToolUseInfo.abbreviatedInput()`/`semanticInputSummary`, 결과 요약+에러 `ToolResultInfo.abbreviatedContent()`/`isError`
- 상태 판정 `Turn.wasCompactedAway`/`endedWithApiError`/`isInterrupted`/`isComplete`/`isOrphan`, `Step.isSyntheticApiError`
- 서브에이전트 조인 `SubAgentGraftIndex`(`linksByStepUuid` + `subAgentTurnsByAgentId`)

---

## 2. 충돌 지점과 통합 결정 (트레이드오프 명시)

다섯 안이 갈라지는 지점은 단 두 곳이다. 각각 하나를 골랐다.

### 충돌 A — 렌더링 기술: NSStackView(안1·2·3·5) vs SwiftUI 하이브리드(안4)

- **안 1/2/3/5**: `NSScrollView` + flipped documentView + `NSStackView` 카드 스택. 근거 = Tokens 탭에 **검증된 사내 패턴**이 이미 있음, 의존성 0, "검증된 패턴의 확장".
- **안 4**: SwiftUI(`NSHostingView`) 채팅 셸 + 본문만 `NSViewRepresentable(NSTextView)`. 근거 = `List` 가상화로 긴 대화 성능, 선언형 카드 조립, 사내 임베드 표준.

**통합 결정 → 안1/2/3/5의 NSStackView 카드 스택을 채택하되, 안4의 핵심 통찰("본문 텍스트는 NSTextView로 선택/복사 보존") 흡수.**

근거:
1. **검증된 패턴이 더 강한 안전판**이다. Tokens 탭이 정확히 동일한 flipped-stack 구조를 이미 쓰고 있어(`:1039-1126`) "새 기술 도입"이 아니라 복제다. 회귀·학습 비용 최소.
2. **가상화 필요성은 과대평가**다 — Conversation 탭은 **Turn 1개**(보통 수~수십 step)를 그린다. 세션 전체가 아니다. `List` 가상화의 이점이 작고, NSStackView도 Tier2/3 기본 접힘으로 초기 서브뷰 수를 억제하면 충분하다(안2·5 공통 완화책).
3. 안4가 지적한 SwiftUI의 약점("블록 경계 넘는 선택 불가")은 실재하고, 안4 자신도 본문을 NSTextView로 우회한다. 그렇다면 바깥 셸까지 SwiftUI일 이유가 약하다 — 셸도 NSStackView면 선택/복사·다크모드·접근성이 전부 네이티브로 일관된다.
4. **단, 안4의 결정적 기여를 가져온다**: 각 카드의 본문(프롬프트·답변·코드·도구 출력)은 **selectable `NSTextView`**(또는 selectable label)로 둔다. 이게 "카드화하면 전체 선택·복사를 잃는다"(안1·2·3·5 공통 리스크)는 문제를 정확히 막는다.

> 트레이드오프: SwiftUI 셸을 포기하면 선언형 코드의 간결함을 잃는다. 그러나 Lupen은 "네이티브 데이터 표면"을 지향(`DetailStyles` 주석)하고, 카드 종류가 6~8종으로 한정되며, 공통 `CardContainerView`로 추상화하면(안2 §6) AppKit 보일러플레이트는 감당 가능하다.

### 충돌 B — 마크다운 렌더러: 자체 경량 파서(안1·3) vs Apple swift-markdown+Splash(안4) vs AttributedString(markdown:)(안1·4 언급)

- **안 3**: 자체 경량 파서(코드펜스/리스트/inline code/링크 4종), 의존성 0, 제로 네트워크 철학 부합.
- **안 4**: Foundation `AttributedString(markdown:)`(인라인, 의존성 0) → 블록은 Apple `swift-markdown` AST 매핑, 코드 하이라이트는 Splash. MarkdownUI/Textual는 비권장(유지보수 불안정).

**통합 결정 → 단계적: (P3) Foundation `AttributedString(markdown:)`(인라인, 의존성 0)으로 출발 + 코드펜스/리스트/헤더만 자체 attribute 보강. (후속, 선택) 표·체크리스트 정확도가 필요해지면 Apple `swift-markdown` AST 도입. 코드 신택스 하이라이트는 최후순위(Splash 또는 단색 모노).**

근거:
1. 현재 의존성은 GRDB/Sparkle/argument-parser **3개뿐**(안4 확인). 새 의존성 추가는 신중해야 하므로 **의존성 0으로 시작**이 양 안의 공통분모.
2. `AttributedString(markdown:)`은 인라인(굵게/이탤릭/링크/inline code)을 공짜로 처리한다 — 자체 파서로 이걸 다시 짜는 건 낭비. 블록(코드펜스 배경·리스트·헤더)만 보강하면 LLM 답변의 95%를 커버.
3. swift-markdown(Apple 공식, GFM)은 "표/체크리스트가 실제로 문제가 됐을 때" 들이는 정직한 확장 경로. MarkdownUI/Textual는 양 안 모두 비권장 — 채택 안 함.

---

## 3. 큐레이션 규칙 (3-Tier 점진 공개) — source of truth

안5의 3-Tier 매핑을 골격으로, 안3의 가독성 토큰과 안1·2의 빈 상태 배너를 합쳤다. **핵심 = `ConversationStoryBuilder`라는 순수 헬퍼가 Turn을 `[ConversationBlock]`으로 변환.** 도구 호출+결과를 `toolUseId`로 병합하는 것이 가장 중요한 신규 로직.

### 3.1 Tier 정의

| Tier | 내용 | 기본 상태 | 사용자 제어 |
|---|---|---|---|
| **Tier 1 — 대화** | 내 프롬프트 · 모델 산문/thinking 텍스트 · 최종 답변 · 오류/중단/압축 신호 · 서브에이전트 결과 요약 | **항상 펼침** | 없음 |
| **Tier 2 — 실행** | 도구 호출+결과 한 줄 칩 · reply의 thinking · 서브에이전트 카드 · 첨부 묶음 | **접힘(한 줄 요약)** | 칩 클릭 펼침 + 헤더 "도구 펼치기" 일괄 토글 |
| **Tier 3 — 원본** | 전체 도구 입출력 JSON · system-injected 메타 · compact 원문 | **숨김** | 토글 "원본/메타 보기" + **Raw 탭 escape** |

### 3.2 Step → ConversationBlock 매핑 표

| Step / 상황 | 추출 소스 (기존 메서드 재사용) | Tier | 기본 | 렌더 형태 |
|---|---|---|---|---|
| `.prompt` 일반 | `step.text` + `step.images.count` + `step.attachments` | 1 | 펼침 | User 카드(좌측 accent 바 + 옅은 음영, 인라인 🖼) |
| `.prompt` (`isCompactSummary`) | `step.text` | 3 | 접힘 | 막간 라인 "↻ Compact resume", 펼치면 원문 |
| `.thought`/`.toolCall`의 텍스트 | `step.text` | 1 | 펼침 | Assistant 산문(마크다운) |
| `.thought`/`.toolCall`의 `toolCalls` | `ToolUseInfo.abbreviatedInput(80)` + 도구명 | 2 | 접힘 | 도구 칩 한 줄(§3.3) |
| `.toolResult` | `ToolResultInfo.abbreviatedContent()`, `isError` | 2 | 접힘 | **직전 도구 칩에 결과 병합**(toolUseId 매칭) |
| `.reply`의 `thinkingText` | `step.thinkingText` | 2 | 접힘 | "💭 Thinking · N lines" 디스클로저 |
| `.reply`의 `text` | `step.text` | 1 | 펼침 | **Assistant 최종 답변 카드(최강조, 풀 마크다운, 모델·비용 배지)** |
| `.stop` (`isSyntheticApiError`) | `step.text` | 1 | 펼침 | ⚠ 오류 배너(주황 좌측바) |
| `.stop` 일반 | `step.stopReason` | 1 | 펼침 | "■ 중단됨: max_tokens" 배너 |
| `.interruption` | — | 1 | 펼침 | "✋ 사용자가 요청을 취소함" 배너(빨강) |
| `isSystemInjected` | — | 3 | 숨김(토글) | 토글 시 회색 칩 |
| 서브에이전트(sidechain) | `SubAgentGraftIndex` + 서브Turn `aggregateCost` | 2 | 접힘 | 부모 Agent 도구 칩 자리에 "🤖 Agent" 카드, 펼치면 `build()` 재귀(깊이 1) |

### 3.3 도구 칩 (접힘/펼침)

```
접힘(기본):
  ● Read   src/Step.swift                          ↪ 526 lines
  ● Bash   swift build                              ✗ exit 1     (빨강)
  ● Grep   /showTurn/ in Lupen/UI                   ↪ 3 matches

펼침(클릭):
  ▼ Read   src/Step.swift
    input:  { file_path: "/Users/.../Step.swift" }   ← ToolInputFormatter(기존)
    output: 1  import Foundation …                    ← ToolResultInfo.content
            (2KB 초과 truncation 시 "Raw 탭에서 전체 보기")
```
- 좌측 글리프 = `StepKindStyle.roleSymbol(.toolCall)`, 색 `secondaryLabelColor`
- 결과 배지: 성공 `↪`(회색) / 실패 `✗`(빨강, `ToolResultInfo.isError`)
- **병합 실패 fallback**(안5 리스크): toolUseId 매칭 실패 시 독립 "↪ orphan result" 칩(데이터 손실 0)

### 3.4 빈/오류 상태 — `(no response available)` 삭제

| 상황 | 판정 | 표시 |
|---|---|---|
| compact 소실 | `Turn.wasCompactedAway(nextTurnInSession:)` | "✂ 이 Turn의 답변은 다음 Turn으로 압축됨(자동 compact)" |
| API 오류 종료 | `Turn.endedWithApiError` | "⚠ API 오류로 종료됨" + `step.text` |
| 사용자 중단 | `Turn.isInterrupted` | "✋ 사용자가 이 Turn을 중단함" |
| 진행 중 | `!Turn.isComplete` | "⏳ 진행 중 — 아직 답변 미도착" |
| 고아 Turn | `Turn.isOrphan` | "프롬프트 없이 시작된 Turn(불완전 데이터)" |
| 도구만 있고 텍스트 응답 없음 | reply 텍스트 부재 | "ⓘ 이 Turn은 도구 N회 실행, 텍스트 응답 없음"(안4) |

> `wasCompactedAway`는 `nextTurnInSession`을 요구 → `showTurn` 호출부(`DashboardSplitViewController`)가 세션 이웃 Turn을 넘기도록 시그니처 추가 필요(안5 §5.3).

### 3.5 가독성 토큰 (안3, `DetailStyles`에 추가 — 전부 semantic 동적 색)

```swift
static let convBodyFont       = NSFont.systemFont(ofSize: 13, weight: .regular)
static let convQuietColor     = NSColor.secondaryLabelColor          // thinking/tool
static let convLineHeightMul: CGFloat = 1.45                         // NSParagraphStyle
static let convReadingWidth:  CGFloat = 620                          // 읽기 컬럼 max (CJK 실측 미세조정)
static let convCodeFont       = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
// 카드 fill/border는 기존 sectionBoxFillColor / sectionBoxBorderColor 재사용
```
- 색·아이콘은 **신규 정의 금지** — `StepKindStyle` 토큰 재사용(중복·표류 방지, 안2·3 공통)
- 읽기 컬럼: 카드 width를 `min(패널폭-여백, 620)`로 클램프, centerX 정렬. 코드/Raw는 컬럼 폭 초과 허용

---

## 4. 최종 레이아웃 청사진 (ASCII)

### 4.1 Turn 선택 시 (전체 흐름)

```
┌─ Conversation │ Attachments │ Tokens │ Usage │ Raw ────────── 📁 ─┐
│ [▸ 도구 펼치기]  [💭 thinking]  [⚙︎ 시스템]      1 turn · 14 steps │ ← 헤더 토글바(안5)
│ ─────────────────────────────────────────────────────────────── │
│                                                                  │
│   ◀── 좌우 여백 ──▶  ◀─ 읽기 컬럼 ~620pt ─▶  ◀─ 여백 ─▶          │
│                                                                  │
│  ▌◉ You                                                          │ ← 좌측 accent 바 + 옅은 음영
│  ▌ Conversation 탭에서 Turn 선택 시 답변이 안 보이는 버그 고쳐줘 │   본문 = selectable NSTextView
│  ▌ 🖼 screenshot.png                                             │
│                                                                  │
│  ✦ Assistant            claude-sonnet-4 · 1.2k→3.4k · $0.018    │ ← 메타 우측(tertiary 11pt)
│  원인을 찾기 위해 detail view controller를 먼저 읽을게요.        │   ← Tier1 산문(마크다운)
│                                                                  │
│  ● Read   DetailViewController.swift                ↪ 2130 lines │ ← Tier2 도구 칩(접힘)
│  ● Grep   /assistantContent/ in Lupen/UI           ↪ 4 matches  │
│  🤖 Agent · explore  "find render path"   8 steps · $0.21    ▶  │ ← 서브에이전트 카드(접힘)
│  ● Edit   DetailViewController.swift                ↪ ok        │
│                                                                  │
│  ▸ 💭 Thinking · 1.2k tokens                                    │ ← Tier2(접힘)
│                                                                  │
│  ✅ Reply                                            [Copy as MD]│ ← Tier1 최종 답변(최강조)
│  showTurn이 assistantContent에 nil을 넘기고 있었습니다.          │   풀 마크다운 렌더
│  ```swift                                          [복사]        │ ← 코드블록: 모노+옅은 배경
│  conversationView.configure(blocks: builder.build(turn))        │   +좌측 악센트 바+Copy
│  ```                                                            │
└──────────────────────────────────────────────────────────────────┘
```

### 4.2 단일 Step 선택 시 (예: toolResult)

기존 반쪽 빈 플레이스홀더 대신, 같은 카드 규칙으로 그 Step 한 장만 풀폭 카드로:

```
┌─ ↪ Result · Read · 30 lines ─────────────────────────────────┐
│  (에러면 좌측 빨강 바 + "Error" 배지)                         │
│   1  import AppKit                                            │ ← selectable
│   2  final class SidebarCell: NSTableCellView {              │
└────────────────────────────────────────────────────────────────┘
```

### 4.3 오류 종료 Turn

```
│  ● Bash   swift build                               ✗ exit 1  │
│  ⚠ 이 Turn은 API 오류로 종료되었습니다                        │
│    API Error: 529 Overloaded — please retry                  │
```

---

## 5. 렌더 아키텍처 (구현 형태)

```
ConversationDetailView (NSView)
└─ headerToggleBar (NSStackView 수평: 도구펼치기/thinking/시스템 + 요약 메타)   ← P-C
└─ NSScrollView
   └─ ConversationFlippedDocumentView (isFlipped=true)   ← Tokens 탭 패턴 복제(:1039)
      └─ outerStack (NSStackView 수직, spacing 12, width clamp 620 centerX)
         ├─ UserPromptCard      (selectable NSTextView 본문)
         ├─ AssistantProseCard  (마크다운, 모델·비용 배지)
         ├─ ToolChipView × N    (접힘 헤더만 / 펼칠 때 본문 lazy 생성)
         ├─ SubAgentCardView    (접힘 / 펼치면 build() 재귀, 깊이 1)
         ├─ ThinkingDisclosure  (접힘)
         ├─ AssistantReplyCard  (최강조, 풀 마크다운, CodeBlockView)
         └─ StatusBanner        (compact/error/interrupt)
```

공통 추상화: `CardContainerView`(좌측 바 + 헤더 슬롯 + 본문 슬롯)로 카드 6~8종의 표면적 최소화(안2 §6).

**반드시 지킬 기존 제약(코드 검증):**
- flipped documentView 필수 — 아니면 매 바인드마다 끝으로 스크롤(`:1033-1041` 주석 명시)
- 동일 선택 재바인드 시 re-render 스킵 가드 유지(`showStep` `:537-545`) → 스크롤 튐 방지
- 인라인 이미지 글리프 + `file://` Finder reveal 링크(`buildBodyWithImageLinks` `:1599`, `clickedOnLink` `:1653`)를 새 카드 본문 렌더러로 **반드시 이식**(누락 시 기능 후퇴)
- truncated 도구 본문 전체 보기는 `store.rawJSON(for:)` lazy 로드 경유(클릭당 I/O — 비동기/캐시)

---

## 6. 최종 권장 렌더링 기술 (1개)

**NSStackView 카드 스택(Tokens 탭 flipped-document 패턴 복제) + 카드 본문만 selectable NSTextView 하이브리드.** 마크다운은 Foundation `AttributedString(markdown:)`(의존성 0) + 코드펜스/리스트/헤더 자체 보강.

배제한 대안:
- **WKWebView**: 제로 네트워크 원칙 위반(외부 CDN), 네이티브 톤 불일치 — 안4도 배제.
- **SwiftUI 풀 셸**: 가상화 이점이 작고(Turn 1개 렌더), 블록 넘는 선택 불가가 "복사 가능한 데이터 표면" 가치와 충돌. 단 "본문=NSTextView" 통찰은 흡수.
- **MarkdownUI/Textual**: 유지보수 불안정 — 안4 비권장, 채택 안 함.

---

## 7. 우선순위 로드맵 (P0 → P5)

다섯 안의 단계론을 통합. **Phase A(빌더+단위테스트, UI 무변경)를 먼저 머지**하는 안5의 안전 분리를 채택.

| 단계 | 작업 | 난이도 | 체감 가치 | 비고 |
|---|---|---|---|---|
| **P0** | (응급 버그) `showTurn`이 `.reply` 텍스트를 조립해 `assistantContent`로 전달 → `(no response available)` 즉시 제거 | 매우 낮음 | 매우 높음 | 명백한 버그, 단순 수정 범주. `:726-730` |
| **P0.5** | `ConversationStoryBuilder`(순수) + `ConversationBlock` enum + **단위 테스트만**. UI 무변경 | 중 | (내부) | toolUseId 병합·서브에이전트·상태 판정을 corpus로 검증(안5 Phase A) |
| **P1** | (선택, 단일 TextView 유지) NSParagraphStyle 줄간격 1.45 + 읽기폭 클램프 | 낮음 | 중 | P2 전 임시 체감 개선. P2로 바로 가면 생략 가능 |
| **P2** | `ConversationDetailView`를 NSStackView 카드 스택으로 교체 (Tier1 우선: User/Assistant/도구 한 줄 칩/빈상태 배너). 본문 selectable. `showTurn`이 builder 호출하도록 시그니처 변경 + `SubAgentGraftIndex`·이웃 Turn 전달 | 상 | 매우 높음 | **핵심 도약**. Tokens 탭 패턴 복제. StepKindStyle 재사용 |
| **P3** | 마크다운 렌더(답변 카드): `AttributedString(markdown:)` + 코드펜스/리스트/헤더 보강 | 중상 | 높음 | 의존성 0. 미지원 문법 평문 폴백 |
| **P4** | 도구 칩 펼침 + thinking 디스클로저 + "N tools" 묶기 + 서브에이전트 카드 + 헤더 토글바(UserDefaults 영속) | 중 | 높음 | 접힘 본문 lazy 생성으로 성능 |
| **P5** | 코드블록 Copy 버튼 + "Copy as Markdown"(전체 Turn) + 메타 라인(모델·토큰·비용) + (선택)Edit diff 승격 + (선택)신택스 하이라이트 | 중~상 | 중 | 비용·diff는 Lupen 정체성 차별 포인트지만 비용 큼, 최후 |

> P0은 즉시. P0.5~P2가 "전용 앱 수준 큐레이션"의 본질을 충족하는 가성비 핵심 구간. P3~P5는 점진 강화.

---

## 8. 핵심 리스크와 완화 (통합)

| 리스크 | 완화 |
|---|---|
| 단일 TextView → 카드 스택 전환 비용(최대) | Tokens 탭 검증 패턴 복제, P0/P1로 리스크 분산, 공통 `CardContainerView` |
| 카드화로 "전체 선택·복사" 상실 | **본문 selectable NSTextView**(안4 통찰) + "Copy as Markdown" 헤더 버튼 |
| 성능(긴 toolResult 다수) | Tier2/3 기본 접힘, 접힐 때 본문 lazy 생성, "Show more". Turn 1개라 가상화 불요 |
| toolUseId 병합 실패(병렬/누락) | "↪ orphan result" 독립 칩 fallback(데이터 손실 0) |
| 마크다운 엣지케이스 | 인라인=Foundation, 블록=코드펜스/리스트/헤더로 범위 제한, 미지원 평문 폴백 |
| 큐레이션이 정보 은닉처럼 보임 | Tier2는 항상 한 줄 칩으로 존재 노출, Tier3만 토글, Raw 탭 최종 escape |
| cross-Turn 판정(`wasCompactedAway`) | `showTurn`에 `nextTurnInSession` 전달(호출부가 세션 컨텍스트 보유) |
| 기존 회귀(이미지 링크/Finder reveal) | `buildBodyWithImageLinks`/`clickedOnLink` 로직 새 렌더러로 이식 필수 |

---

## 9. 작업 시작점 요약

1. **즉시**: `DetailViewController.showTurn`(`:726-730`)의 `assistantContent: nil`을 reply 조립으로 교체 (P0).
2. **신규 파일**: `Lupen/Domain/Conversation/ConversationStoryBuilder.swift` + `ConversationBlock.swift` (순수, 단위테스트 동반).
3. **교체**: `ConversationDetailView`(`:1465`)를 NSStackView 카드 스택으로. `TokensDetailView`(`:1039-1126`)를 레퍼런스로 복제.
4. **시그니처 변경**: `showTurn`/`showStep`이 builder 출력(`[ConversationBlock]`)을 받도록. 호출부(`DashboardSplitViewController`)에서 `SubAgentGraftIndex` + 이웃 Turn 전달.
5. **재사용 자산**: `StepKindStyle`(아이콘/색), `ToolInputFormatter`/`JSONPrettyFormatter`, `InlineImageSymbol`, `ModelDisplay`/`DetailCostFormatter`, `DetailStyles` 카드 fill.
