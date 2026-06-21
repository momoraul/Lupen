# Conversation 탭 재설계 제안서 #2 — 전용 앱 벤치마크

작성자: jaden
관점: 경쟁/유사 앱(Cursor / Zed / Cline / Claude Code / Codex / ChatGPT·Claude 데스크톱) 벤치마크
대상 파일: `Lupen/UI/Dashboard/DetailViewController.swift`(현 Conversation 탭), `Lupen/Domain/Conversation/*`

---

## 0. 한 줄 요약

현 Conversation 탭은 `Turn`/`Step`이 들고 있는 **풍부한 구조(text / thinking / toolUse / toolResult / image 블록)** 를 전부 버리고
`humanPrompt`(평문) + `assistantContent`(평문)라는 **2개의 문자열**로 평탄화해 단일 `NSTextView`에 붙이고 있다.
전용 AI 코딩 앱들은 예외 없이 **"블록 단위 카드 + 역할 구분 + 접기/펼치기 + 코드/diff 전용 렌더 + 메타데이터 동행"** 으로 transcript를 보여준다.
이 제안서는 그 공통 패턴을 Lupen의 기존 데이터 모델 위에 얹는 방법을 구체화한다.

---

## 1. 현 구현의 사실 확인 (근거)

추측이 아니라 실제 코드로 확인한 현황:

- **렌더러는 단일 평문 `NSTextView` 하나다.**
  `ConversationDetailView`는 `scrollView` + `textView` 둘뿐이며, `configure(humanPrompt:assistantContent:promptInlineImageCount:)`로
  "USER\n…\n\nASSISTANT\n…" 형태의 `NSAttributedString` 하나를 만들어 통째로 붙인다.
  근거: `DetailViewController.swift:1465-1587`.

- **구조가 이미 호출부에서 평탄화되어 사라진다.**
  `showStep(_:)`은 `step.kind`별로 분기해서 `toolCalls`/`thinkingText`/`text`를
  `"→ \(name)\n\(input)"`, `"— thinking —\n…"`, `"— reply —\n…"` 같은 **문자열로 join**한 뒤 `assistantContent`에 넣는다.
  근거: `DetailViewController.swift:563-628`. 즉 toolUse/thinking/toolResult가 텍스트 접두어로만 구분되고, 코드/JSON/diff 구분이 없다.

- **모델은 이미 충분히 rich하다 — 안 쓰고 있을 뿐이다.**
  `RichContentBlock`은 `.text / .thinking / .toolUse(id,name,inputJSON) / .toolResult(toolUseId,content,isError) / .image(mediaType,path)`의 5종 합타입이다.
  근거: `RichEntry.swift:150-161`. `Step`은 `text` / `thinkingText` / `toolCalls` / `toolResult` / `images` / `imageSourcePaths`를 분리 보관한다.
  근거: `Step.swift` 주석 헤더(70-95행 부근).

- **"(no response available)" 빈약함의 출처.**
  `.toolCall`/`.thought`/`.toolResult`/`.stop` 같은 Step을 단독 선택하면 한쪽 슬롯이 항상 비어
  `(no prompt available)` / `(no response available)` 플레이스홀더가 뜬다. 근거: `DetailViewController.swift:1564-1583`.

- **역할/색 토큰은 이미 정의돼 있다.**
  `StepKindStyle.roleSymbol/roleTint/textColor`가 kind별 SF Symbol·색을 이미 제공한다(예: prompt=`bubble.left.fill`/labelColor, reply=`checkmark.bubble.fill`/green, toolCall=`wrench.adjustable.fill`).
  근거: `StepKindStyle.swift:14-70`. Conversation 탭만 이 토큰을 안 쓰고 있다.

요컨대 **데이터·스타일 토큰은 갖춰져 있고, Conversation 탭의 렌더 레이어만 1세대 평문에 머물러 있다.**

---

## 2. 핵심 발견 — 전용 앱들이 공유하는 transcript 렌더 패턴

웹 리서치로 확인한, 거의 모든 전용 앱이 수렴한 패턴들(출처는 §7):

1. **버블 금지, 풀폭(full-width) + 음영/정렬로 역할 구분.**
   진지한 AI 도구는 메신저식 말풍선을 쓰지 않는다. user는 옅은 배경 음영 또는 좌측 강조선, assistant는 풀폭 리치 마크다운으로 구분한다. (Setproduct, IntuitionLabs)

2. **reasoning(사고과정)은 답변 위에 "기본 접힘" 섹션으로.**
   라벨은 정직하게 "Thinking"/"Reasoning". Claude Code 터미널은 thinking을 회색 이탤릭으로 보여주고 Ctrl+O로 토글, v2.0은 Tab으로 토글. (Setproduct, Claude Code issue #36006)

3. **코드 블록 = 모노스페이스 + 문법 강조 + 필수 Copy 버튼 + 접기.**
   긴 코드/출력은 "Show more/less"로 접고, 각 블록에 1-클릭 복사(체크마크 피드백). (OpenAI/Anthropic community, ChatGPT 패턴)

4. **tool call은 "카드"로, 결과는 접힌 채로 붙인다.**
   Cline은 모든 tool 사용을 카드로 보여주고, 파일 편집은 **side-by-side diff**로, 각 tool 뒤에 북마크형 "Checkpoint" 인디케이터(점선 + Compare/Restore)를 단다. (Cline docs)

5. **tool 결과 출력은 분리 캐시 + 접힘.**
   Cursor는 큰 tool 출력을 transcript 본문에서 떼어 별도 보관(본문 비대화 방지). (Cursor 역공학 분석)

6. **메타데이터(모델/토큰/비용/시각)는 메시지에 "조용히" 동행.**
   모델명은 매 assistant 메시지에 표시(파워유저용 토큰/비용은 옵션, 기본은 거슬리지 않게). (Setproduct)

7. **레이아웃: 좌측 히스토리 / 중앙 메시지 스트림 / (조건부) 우측 아티팩트 패널.**
   Claude의 Artifacts·Gemini의 듀얼페인처럼 코드/긴 산출물은 본문에서 떼어내 옆 패널로. (IntuitionLabs)

8. **turn 단위 묶음 + 상태 표시.**
   Zed의 thread는 메시지 묶음을 하나의 reviewable flow로, 각 메시지에 코드 블록·파일 참조·slash 출력·tool 인디케이터를 인라인. 완료/중단/에러/재생성 상태를 명시. (Zed docs, Setproduct)

Lupen에 특히 잘 맞는 통찰: **Lupen은 "사후(post-hoc) 리뷰어"** 다. 실시간 채팅이 아니라 끝난 turn을 되돌아본다.
→ 스트리밍 캐럿/자동스크롤 같은 건 불필요하고, 대신 **(a) 큐레이션(노이즈 접기) (b) 비용·토큰 동행 (c) 빠른 스캔(역할 거터)** 에 집중하면 전용 앱보다 오히려 깔끔할 수 있다.

---

## 3. 구체적 권고 — "무엇을 어떻게 만들지"

### 3.1 렌더 모델 전환: 평문 1장 → "블록 카드 스택"

`configure(humanPrompt:assistantContent:)`를 폐기하고, **Turn(또는 Step) 전체를 입력으로 받아 블록 배열을 그리는** API로 바꾼다.

```swift
// 새 진입점 (개념)
func configure(turn: Turn)        // Turn 선택 시: prompt → 실행 트레이스 → reply 전체를 한 흐름으로
func configure(step: Step)        // Step 선택 시: 해당 Step 1개를 같은 카드 규칙으로
```

내부적으로 `Step`/`RichContentBlock`을 **렌더 노드(ConversationBlock)** 배열로 매핑한다:

```swift
enum ConversationBlock {
    case userPrompt(text: String, images: [ImageRef])     // 옅은 음영 + 좌측 강조선
    case assistantText(markdown: String)                   // 풀폭 마크다운
    case thinking(text: String)                            // 기본 접힘, 회색 이탤릭
    case toolCall(name: String, input: ToolInputRender)    // 카드: 헤더(아이콘+이름) + 본문
    case toolResult(name: String, content: String, isError: Bool, lineCount: Int)  // 카드, 기본 접힘
    case codeBlock(language: String?, code: String)        // 모노 + Copy
    case fileDiff(path: String, hunks: [DiffHunk])         // +녹/−적 거터 (Edit tool 입력에서 파생)
    case stopNotice(reason: String, isApiError: Bool)      // 경고 배너
}
```

매핑 규칙(이미 `showStep`이 하던 분기를 문자열 join 대신 **블록 생성**으로 치환):
- `.prompt` → `userPrompt` (+ `imageSourcePaths`/`images`는 썸네일/칩으로)
- `.thought` → `thinking` + (있으면) `assistantText`
- `.toolCall` → `toolCall` 카드들
- `.toolResult` → `toolResult` 카드 (Edit/Write 결과면 `fileDiff`로 승격)
- `.reply` → `thinking`(접힘) + `assistantText`(마크다운)
- `.stop` → `stopNotice` (현 `isSyntheticApiError`/`step.text` 로직 그대로 활용, `DetailViewController.swift:598-614`)

### 3.2 역할 구분 — "버블 대신 거터(gutter) + 음영"

전용 앱 합의(버블 금지)를 따르되, macOS 네이티브 톤 유지:

- **User 블록**: 좌측 3pt 강조선(accent) + 셀 전체에 `controlBackgroundColor` 옅은 음영, 좌상단에 `bubble.left.fill` + "You". `StepKindStyle.roleSymbol(.prompt)` 재사용.
- **Assistant 블록**: 배경 없음(풀폭), 좌상단에 `checkmark.bubble.fill`(reply) / `sparkle`(thought) + 모델명 칩.
- 색·아이콘은 **신규 정의 금지 — `StepKindStyle` 토큰 재사용**(중복·표류 방지). 근거: 이미 `roleTint`/`textColor`가 "prompt/reply는 강조, 중간 트레이스는 흐리게"라는 정책을 가지고 있다(`StepKindStyle.swift:33-70`).

### 3.3 사고과정(thinking) — 기본 접힘 디스클로저

`thinking` 블록은 `NSButton`(disclosure triangle) 헤더 + 접힘 본문.
- 헤더: "▸ Thinking · {N줄}" (회색). 펼치면 회색 이탤릭 본문.
- Claude Code 터미널 UX와 동일한 멘탈모델(기본 접힘, 클릭 토글). 근거: Claude Code issue #36006, ClaudeLog.

### 3.4 tool call / result — 접히는 카드 + diff 승격

- **toolCall 카드**: 헤더 `[wrench] Edit · src/Foo.swift`(아이콘=`StepKindStyle.roleSymbol(.toolCall)`), 본문은 `ToolInputFormatter`로 정형화된 입력(이미 존재, `DetailViewController.swift:583`에서 사용 중).
- **toolResult 카드**: **기본 접힘**(전용 앱들이 큰 출력을 접거나 분리 캐시하는 이유와 동일 — Cursor). 헤더에 "Result · {N줄}" + 에러면 빨강 배지(`isError` 플래그가 이미 모델에 있음, `RichEntry.swift:158`).
- **diff 승격**: tool 이름이 `Edit`/`Write`/`MultiEdit`(또는 Codex `patch_apply`)이면, 입력 JSON의 old/new에서 **간이 diff 거터**(+녹/−적 라인)를 그린다. Cline의 핵심 셀링포인트가 "본문 안의 시각 diff". 근거: Cline docs.
  - 1차 구현은 풀 LCS diff 대신 "old 블록 / new 블록 나란히" 수준이어도 충분히 전용 앱급 가독성을 낸다.

### 3.5 코드 블록 — 모노 + Copy + 접기

assistant 마크다운 안의 펜스 코드(```` ``` ````)는 별도 코드뷰로:
- 배경 `textBackgroundColor` 약간 어둡게 + 모노스페이스 + 우상단 Copy 버튼(클릭 시 체크마크 0.8초).
- 길면(예: >40줄) "Show more" 페이드. 근거: OpenAI/Anthropic community 요청, ChatGPT 패턴.
- 기존 `JSONPrettyFormatter`/`ToolInputFormatter`를 JSON/입력 정형화에 재사용.

### 3.6 메타데이터 동행 (Lupen의 차별점)

Lupen은 비용 분석 앱이다 — 전용 앱들이 "옵션"으로 숨기는 토큰/비용을 **오히려 1급 시민**으로:
- 각 assistant Step 카드 우측에 작은 메타 라인: `claude-sonnet-4 · 1.2k→3.4k tok · $0.018`.
- 데이터는 이미 Step에 있음(`tokens`/`cost`/`model`, `Step.swift` 헤더). Tokens 탭과 동일 소스라 정합성 유지.
- 단, 본문 가독성을 해치지 않게 `tertiaryLabelColor`·11pt로 "조용히". 근거: Setproduct("토큰/비용은 파워유저용, 기본은 거슬리지 않게").

### 3.7 Stop / API 에러 / 중단 — 인라인 배너

현 로직(`isSyntheticApiError`면 `⚠ {body}`, 아니면 `(stopped: …)`)을 **배너 카드**로 승격.
주황/빨강 좌측 바 + 아이콘(`StepKindStyle.roleSymbol(.stop)`=`exclamationmark.octagon.fill`). 근거 로직: `DetailViewController.swift:598-617`.

---

## 4. ASCII 레이아웃 스케치

### 4.1 Turn 선택 시 (전체 흐름)

```
┌────────────────────────────────────────────────────────────────┐
│ Conversation │ Attachments │ Tokens │ Usage │ Raw   [Reveal] [▾] │  ← 기존 탭바
├────────────────────────────────────────────────────────────────┤
│▌ ◉ You                                                          │  ← 좌측 accent 바 + 옅은 음영
│▌  사이드바 비용 색을 주황으로 바꾸고 N/A는 슬레이트로…             │
│▌  🖼 screenshot.png                                              │
│                                                                  │
│  ✦ Assistant            claude-sonnet-4 · 1.2k→3.4k · $0.018    │  ← 메타 우측 정렬
│  ▸ Thinking · 6 lines                                           │  ← 기본 접힘
│  먼저 SidebarCell의 cost 라벨 색 토큰을 확인하겠습니다.          │  ← 풀폭 마크다운
│                                                                  │
│  ┌─ 🔧 Read · SidebarCell.swift ───────────────────────────┐    │  ← tool 카드
│  │  offset 40, limit 30                                     │    │
│  └──────────────────────────────────────────────────────────┘    │
│  ┌─ ↪ Result · 30 lines ──────────────────────── [expand ▸]┐    │  ← 결과 접힘
│  └──────────────────────────────────────────────────────────┘    │
│  ┌─ ✏️ Edit · SidebarCell.swift ───────────────────────────┐    │  ← diff 승격
│  │  - costLabel.textColor = .systemBlue                     │    │  (−적)
│  │  + costLabel.textColor = .systemOrange                   │    │  (+녹)
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ✓ Reply                                                        │
│  주황색으로 변경했습니다. ```swift … ``` [Copy]                  │  ← 코드블록+Copy
└────────────────────────────────────────────────────────────────┘
```

### 4.2 단일 Step 선택 시 (예: toolResult)

기존엔 `(no prompt available)` / `(no response available)`로 반쪽이 비었지만,
같은 카드 규칙으로 **그 Step 한 장**만 풀폭 카드로:

```
┌─ ↪ Result · Read · 30 lines ──────────────────────────────────┐
│  (에러면 좌측 빨강 바 + "Error" 배지)                          │
│   1  import AppKit                                              │
│   2  final class SidebarCell: NSTableCellView {                │
│   …                                                            │
└────────────────────────────────────────────────────────────────┘
```

---

## 5. Lupen 현 아키텍처에서의 적용 — 구현 단계 & 난이도

### 5.1 권장 구현체: NSStackView 기반 카드 스택 (NOT 단일 NSTextView)

현 `NSTextView` 1장으로는 블록별 접기/Copy 버튼/diff 거터를 줄 수 없다.
→ **Tokens 탭이 이미 쓰는 패턴**을 그대로 차용: `NSScrollView` + flipped document view + `NSStackView`에 카드 서브뷰를 쌓는다.
근거: `TokensDetailView`가 `TokensFlippedDocumentView`(`isFlipped=true`) + `outerStack`(`NSStackView`)로 정확히 이 구조다(`DetailViewController.swift:1039-1127`). **즉 사내에 검증된 레퍼런스 구현이 존재** → 새 패턴 도입 아님, 기존 패턴 확장.

각 카드는 `NSView` 서브클래스(예: `ToolCallCardView`, `ThinkingDisclosureView`, `CodeBlockView`, `DiffView`, `RoleHeaderView`).

### 5.2 단계별 (점진적, 각 단계가 독립 출시 가능)

| 단계 | 내용 | 난이도 | 비고 |
|---|---|---|---|
| **P0** | `configure(humanPrompt:assistantContent:)` 호출부를 `Turn`/`Step` 직접 전달로 교체. 블록 매핑 함수 신설. | 중 | `showStep`/`showTurn`/`showSkillGroup` 3곳 수정(`DetailViewController.swift:537,709,765`). |
| **P1** | NSTextView → NSStackView 카드 스택 골격(Tokens 탭 패턴 복제). 역할 헤더 + user 음영/거터. | 중 | `StepKindStyle` 토큰 재사용. |
| **P2** | thinking 디스클로저(기본 접힘) + toolResult 카드 접힘. | 하 | 상태(접힘 여부)는 카드뷰 로컬. |
| **P3** | 코드블록 뷰(모노+Copy) + 마크다운 인라인 렌더(헤더/리스트/`code`). | 중상 | 경량 마크다운만; 풀 CommonMark 불요. |
| **P4** | Edit/Write/patch → diff 거터 승격. | 상 | 1차는 old/new 병치, 추후 LCS. |
| **P5** | 메타 라인(모델·토큰·비용) 카드 동행. | 하 | Step에 이미 데이터 존재. |

### 5.3 주의해야 할 기존 제약(실측)

- **스크롤 위치 보존**: `showStep`은 같은 Step 재바인드 시 re-render를 스킵해 스크롤 점프를 막는다(`DetailViewController.swift:537-545`). 카드 스택에서도 이 가드 유지 필요(특히 라이브 스트리밍 업데이트).
- **flipped 문서뷰 필수**: 안 그러면 (0,0)이 바닥이라 매 바인드마다 끝으로 스크롤된다(Tokens 탭 주석이 명시, `DetailViewController.swift:1033-1041`).
- **이미지 인라인**: 현 `InlineImageSymbol`/`buildBodyWithImageLinks`(`:1599-1649`)와 Attachments 탭의 `inlineImageProvider`(`:642-648`) 흐름을 카드로 옮길 때 재사용. 새 디코더 만들 필요 없음.
- **lazy 탭 로딩**: Conversation은 lazy 대상이 아님(Raw/Usage만, `:673`). 즉 Conversation은 매 선택마다 즉시 렌더되므로 카드 생성 비용을 가볍게 유지(긴 Step은 본문 접힘으로 초기 뷰 수 최소화).

---

## 6. 트레이드오프와 리스크

- **성능 (가장 큰 리스크).** 수백 줄 toolResult가 많은 Turn을 전부 카드로 펼치면 NSStackView 서브뷰가 폭증한다.
  → 완화책: (a) toolResult/코드 **기본 접힘**으로 초기 뷰 수 최소화, (b) 접힌 카드는 헤더만 생성하고 펼칠 때 본문 lazy 생성, (c) 매우 긴 결과는 "Show more". (Cursor가 큰 출력을 분리 캐시하는 것과 같은 동기.)
- **마크다운 렌더 범위.** 풀 CommonMark + 문법 강조는 과투자. 1차는 문단/리스트/헤더/inline code/펜스 코드만. assistant 텍스트 대부분은 이 범위로 충분.
- **diff 정확도.** Edit 입력의 old/new는 "문자열 치환"이라 진짜 diff가 아니다 — 라인 단위 병치로 과장 없이 보여주고, 라벨을 "before/after"로 정직하게.
- **단일 NSTextView의 장점 상실.** 평문 1장은 "전체 선택→복사"가 공짜였다. 카드화하면 텍스트 선택이 카드 경계에서 끊긴다.
  → 완화: 각 코드/결과 카드에 Copy 버튼, 그리고 헤더에 "Copy as Markdown"(전체 Turn을 마크다운으로 — Zed의 "Open Thread as Markdown"과 동일 발상, 출처 §7).
- **유지보수 면적 증가.** 카드 뷰가 6~8종 늘어난다. → 공통 `CardContainerView`(좌측 바+헤더+본문 슬롯)로 추상화해 표면적 최소화.
- **접근성/다크모드.** 음영·거터 색을 하드코딩하지 말고 시맨틱 컬러(`controlBackgroundColor`, `separatorColor`, `StepKindStyle` 토큰)만 사용.

---

## 7. 참고한 앱·기법과 출처

- 전용 AI 채팅 UI 해부(버블 금지·풀폭·reasoning 접힘·코드 Copy·메타데이터 정책):
  Setproduct, "Designing AI chat interfaces" — https://www.setproduct.com/blog/ai-chat-interface-ui-design
- Cursor transcript/툴콜 구조(큰 tool 출력 분리 캐시, user=Type1/assistant=Type2):
  DEV, "I Reverse-Engineered Cursor's AI Agent" — https://dev.to/vikram_ray/i-reverse-engineered-cursors-ai-agent-heres-everything-it-does-behind-the-scenes-3d0a
  Cursor Docs (Agent overview) — https://cursor.com/docs/agent/overview
- Zed Agent Panel(thread = 코드블록·파일참조·slash 출력·tool 인디케이터 인라인, "Open Thread as Markdown"):
  Zed Docs — https://zed.dev/docs/ai/agent-panel
- Cline(모든 tool=카드, side-by-side diff, 북마크형 Checkpoint + Compare/Restore):
  Cline Docs (Checkpoints) — https://docs.cline.bot/core-workflows/checkpoints
- Claude Code thinking 토글(기본 접힘, Ctrl+O / Tab):
  GitHub issue #36006 — https://github.com/anthropics/claude-code/issues/36006
  ClaudeLog — https://claudelog.com/faqs/how-to-toggle-thinking-in-claude-code/
- 코드블록 접기/Copy 요구:
  OpenAI community — https://community.openai.com/t/feature-request-collapsible-code-blocks-in-chat/1358142
  Claude Code issue #51624 — https://github.com/anthropics/claude-code/issues/51624
- 앱별 비교(코드블록·reasoning·메타데이터·아티팩트 듀얼페인):
  IntuitionLabs, "Comparing Conversational AI Tool UIs 2025" — https://intuitionlabs.ai/articles/conversational-ai-ui-comparison-2025

---

## 8. 결론 — Lupen이 가져갈 "전용 앱급" 최소 세트

전부 다 할 필요는 없다. **가성비 순서**로 P0~P2(블록 카드화 + 역할 거터 + thinking/result 접힘)만 해도
현 "(no response available)" 평문에서 **전용 앱 수준의 큐레이션된 transcript**로 도약한다.
P3(코드+Copy)·P5(메타 동행)는 Lupen의 정체성(비용 분석)과 직결되는 차별 포인트라 우선순위가 높다.
P4(diff)는 임팩트가 크지만 비용도 커서 마지막. 모든 단계가 **기존 Tokens 탭의 NSStackView 패턴과 `StepKindStyle` 토큰을 재사용** 하므로
"새 패턴 도입"이 아니라 "검증된 패턴의 확장"이라는 점이 핵심 안전판이다.
