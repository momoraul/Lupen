# 제안 3 — Conversation 탭 가독성 & 정보 큐레이션 UX

> 관점: **가독성 / 큐레이션 UX**
> 목표: 지난 Turn의 "내 프롬프트 + LLM 답변"을 Claude Code / Codex / Cursor 같은 전용 앱 수준으로
> 가독성 좋고 rich하게, **중요한 내용만 추려서** 보여준다. 노이즈(장황한 tool I/O, 시스템 메시지,
> 반복)는 접거나 요약하고, 사용자가 실제로 확인하고 싶어하는 화면으로 큐레이션한다.
> 작성자: jaden

---

## 0. 한 줄 요약

현재 Conversation 탭은 단일 `NSTextView`에 `USER` / `ASSISTANT` 평문 두 덩어리만 그린다.
이걸 **"카드형 대화 transcript"** 로 바꾼다 — 화자별 시각 위계, 적정 읽기폭(reading measure),
점진적 공개(thinking/tool I/O는 접힘), Markdown/코드블록 렌더링, 그리고 핵심 답변 강조.
가장 시급한 건 기능 결함 하나: **Turn을 선택하면 답변이 아예 안 보인다(`(no response available)`)** — 이건 UX 이전에 데이터 결선 버그다.

---

## 1. 핵심 발견 (현 상태 진단)

### 1.1 Conversation 탭은 "평문 두 덩어리"가 전부다

`ConversationDetailView`는 하나의 `NSTextView`에 다음만 그린다 (DetailViewController.swift:1465-1587):

- `USER\n` (11pt semibold, secondaryLabel) + 프롬프트 본문(12pt, labelColor)
- 빈 줄 두 개
- `ASSISTANT\n` + 답변 본문(12pt, labelColor)

즉 **화자 구분은 11pt 회색 헤더 텍스트 한 줄뿐**이고, 카드/배경/구분선/아바타가 전혀 없다.
Markdown은 해석하지 않는다 — 코드블록, 리스트, 헤딩, 인라인 코드가 전부 평문으로 흐른다.
유일한 rich 처리는 `[Image source:]`/`[Image #N]` 마커를 SF Symbol로 치환하는 것뿐이다
(`buildBodyWithImageLinks`, DetailViewController.swift:1599-1649).

### 1.2 `(no response available)`의 정체 — 데이터 결선 버그

스크린샷의 `(no response available)`는 빈 답변이 아니라 **Conversation 탭이 답변을 받지 못한 것**이다.
경로별로 무엇을 넘기는지 확인했다:

- **Turn 선택** (`showTurn`, DetailViewController.swift:709-763):
  ```swift
  conversationView.configure(
      humanPrompt: promptText,
      assistantContent: nil,          // ← 답변을 아예 안 넘긴다
      promptInlineImageCount: ...)
  ```
  `assistantContent`가 `nil`이라 `ASSISTANT` 헤더 아래 `(no response available)`가 찍힌다
  (DetailViewController.swift:1577-1583). Turn 안에 `.reply` Step이 분명히 있는데도.

- **Step 선택** (`showStep`, DetailViewController.swift:537-628): 단일 Step만 보여준다.
  `.prompt`이면 프롬프트만, `.reply`이면 답변만. 한 화면에서 "내 질문 → 답변" 쌍을 볼 수 없다.

- **SkillGroup 선택**: `assistantContent`로 `• Reply: …` 식의 한 줄 요약 목록을 넣는다
  (DetailViewController.swift:765-806, `skillGroupConversationSummary`).

**결론**: Turn 단위로 "프롬프트 + thinking + tool 사용 + 최종 답변"을 한 화면에 모아 보여주는
조립 로직 자체가 없다. `Turn.steps`에 모든 데이터(프롬프트/thinking/toolCall/toolResult/reply)가
다 있는데(Step.swift, Turn.swift), Conversation 탭은 그걸 큐레이션해서 합치지 않는다.

### 1.3 데이터는 이미 충분히 rich하다 — 표현만 빈약하다

`Step` 모델은 큐레이션에 필요한 모든 필드를 갖고 있다 (Step.swift):

- `kind`: prompt / toolCall / toolResult / thought / reply / stop / interruption (StepKind.swift)
- `text`, `thinkingText`(extended thinking 별도 저장), `images`
- `toolCalls`(ToolUseInfo), `toolResult`(ToolResultInfo)
- `isSystemInjected`, `isCompactSummary`, `isSidechain`
- `tokens` / `cost` / `model`(assistant Step만)

그리고 `StepKindStyle`에는 이미 **화자/역할별 시각 언어가 정의돼 있다** (StepKindStyle.swift):

- 역할 아이콘: prompt=`bubble.left.fill`, reply=`checkmark.bubble.fill`, thought=`brain`,
  toolCall=`wrench.adjustable.fill`, toolResult=`arrow.turn.down.right`
- 색 정책: prompt/reply는 강조(label/green), thought/tool은 quiet(secondary/tertiary),
  stop/interruption만 경고색(orange/red) — **"monochrome-first, 색은 의미 신호에만"** 원칙

→ 이 시각 언어는 상단 아웃라인(TurnOutline)에만 쓰이고, **Conversation 탭은 이 자산을 전혀 활용하지 않는다.**
   같은 디자인 토큰을 Conversation 탭으로 끌어오면 일관성과 rich함을 공짜로 얻는다.

### 1.4 가독성 기본기 부재 — 측정폭 / 줄간격 / Markdown

- **측정폭(reading measure) 무제한**: `NSTextView`가 패널 폭 전체를 쓴다. 패널을 넓히면
  한 줄이 120자+로 늘어나 눈이 줄을 놓친다. 연구 합의는 **45~75자, 한국어 같은 CJK는 40자**
  ([Baymard](https://baymard.com/blog/line-length-readability),
  [UXPin](https://www.uxpin.com/studio/blog/optimal-line-length-for-readability/)).
- **줄간격(line-height) 기본값**: 본문 가독성 표준은 폰트의 ~1.5배
  ([Pimp my Type](https://pimpmytype.com/line-length-line-height/)). 현재 명시 설정 없음.
- **Markdown 미해석**: LLM 답변은 거의 항상 Markdown(헤딩/리스트/코드블록/`inline code`)인데
  평문으로 흐른다. 코드블록이 본문과 같은 폰트로 섞여 스캔이 안 된다.

---

## 2. 외부 베스트프랙티스 (근거 + 출처)

### 2.1 측정폭과 줄간격 — 읽기 피로의 1순위 변수

- 최적 줄 길이는 **50~75자(CPL), 66자가 황금값**. 라틴 문자는 WCAG가 80자 상한,
  **CJK(한·중·일)는 40자 상한**으로 더 좁게 권고한다.
  ([UXPin](https://www.uxpin.com/studio/blog/optimal-line-length-for-readability/),
  [Baymard](https://baymard.com/blog/line-length-readability))
- 본문 line-height는 **1.5배**가 안전한 출발점.
  ([Pimp my Type](https://pimpmytype.com/line-length-line-height/))

→ Lupen은 한국어 프롬프트가 많으므로 **읽기 컬럼에 max-width(약 70ch / ~620pt) 클램프**를 두고,
  넘치는 패널 폭은 좌우 여백으로 흘린다. line-height는 1.4~1.5.

### 2.2 점진적 공개(Progressive Disclosure) — 노이즈를 접어라

- "딱 필요한 만큼만 보여주고 나머지는 사용자가 원할 때까지 미룬다 — 인지 부하↓, 스캔성↑, 통제감↑."
  헤드라인/요약 먼저, 깊이는 옵션으로. 접힌 콘텐츠는 화살표/+/"펼치기"로 **발견 가능하게** 한다.
  ([IxDF](https://ixdf.org/literature/topics/progressive-disclosure),
  [UXPin](https://www.uxpin.com/studio/blog/what-is-progressive-disclosure/),
  [LogRocket](https://blog.logrocket.com/ux-design/progressive-disclosure-ux-types-use-cases/))

→ **이게 "중요한 내용만 추려서"의 핵심 메커니즘이다.** thinking 블록과 tool 입력/출력은
  기본 접힘(요약 1줄), 클릭 시 펼침.

### 2.3 전용 코딩 에이전트 앱들이 실제로 하는 방식

- Claude Code: thinking은 **접힌 블록**으로 표시, `Ctrl+O`로 전체 펼침/접힘. MCP 호출은
  `"Called slack 3 times"` 한 줄로 접힌다. tool 출력은 summary→truncated→full로 순환.
  ([Claude Code Docs](https://code.claude.com/docs/en/vs-code),
  [wmedia](https://wmedia.es/en/tips/claude-code-verbose-output-see-thinking))
- `claude-history` TUI: tool 호출 기본 **summary 모드**(입출력 숨김), `t`로 단계 순환,
  truncated 모드는 헤더 + 본문 앞 몇 줄 + `(N more lines…)`.
  ([claude-history](https://github.com/raine/claude-history))

→ Lupen Conversation 탭의 직접 모델: **tool은 1줄 요약 카드 + 펼치기, thinking은 접힘.**

### 2.4 화자 구분 — 색만으로 구분하지 말 것 / 풀폭 vs 버블

- 사용자 vs AI는 **색 하나에만 의존하지 말고** 라벨("You"/"Assistant")·정렬·아이콘을 병행한다
  (접근성/색맹 대응).
  ([aiuxdesign.guide](https://www.aiuxdesign.guide/patterns/conversational-ui))
- **풀폭(full-width)이 진지한 AI 도구의 현재 베스트프랙티스.** 버블은 "메신저" 느낌이라
  Claude.ai/ChatGPT/Cursor 같은 도구 프레이밍을 약화시킨다. 버블은 좁은 위젯에서만.
  ([aiuxdesign.guide](https://www.aiuxdesign.guide/patterns/conversational-ui))

→ Lupen은 분석 도구이므로 **풀폭 + 좌측 역할 거터(아이콘/라벨)** 패턴. 버블 채택 안 함.
  이미 `StepKindStyle`의 아이콘/색이 이 결정과 정확히 일치한다.

### 2.5 Markdown / 코드블록 렌더링

- 답변은 Markdown으로 렌더, 코드블록은 **monospace + (가능하면) 구문 강조 + 복사 버튼**.
  inline code는 본문에 섞이되 배경/폰트로 도드라지게.
  ([Markdown Visualizer](https://markdownvisualizer.com/blog/markdown-code-blocks))
- 주의: 일부 앱은 **사용자 입력은 평문, 어시스턴트 답변만 rich**하게 처리한다 — Lupen도
  사용자 프롬프트는 가볍게(코드 펜스 정도만), 답변은 풀 Markdown으로 가는 게 합리적.

### 2.6 macOS 네이티브 가독성

- macOS 시스템 폰트는 SF Pro. **19pt 이하 Text, 20pt 이상 Display** (macOS 11+는 광학 사이즈 자동).
  ([Apple HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography))
- macOS는 Dynamic Type 미지원 — 대신 `NSFont.systemFont` 동적 변형을 써서 시스템 컨트롤과 톤을 맞춘다.
- 다크모드: `NSTextView`에서 색을 직접 칠하면 다크모드에서 검은 글자가 검은 배경에 깔리는 함정.
  반드시 `.labelColor` / `.secondaryLabelColor` 같은 **동적(semantic) 색**만 사용.
  ([Apple Forums](https://developer.apple.com/forums/thread/114433))

→ Lupen은 이미 semantic 색을 쓰고 있어(DetailStyles) 안전하다. 이 원칙을 새 렌더러에도 유지.

---

## 3. 구체적 권고 — "어떤 화면을 어떻게"

### 3.1 핵심 전환: 단일 NSTextView → 카드형 대화 스트림

`ConversationDetailView`를 **수직 스택(NSStackView) 안의 역할별 카드 목록**으로 재구성한다.
각 카드는 한 화자/단계를 표현한다. Turn 선택 시 그 Turn의 Step들을 큐레이션해 카드 시퀀스로 만든다.

```
ConversationDetailView (NSScrollView)
└─ flippedDocumentView (isFlipped=true, 위→아래)
   └─ NSStackView(vertical, spacing=12, max-width 클램프된 읽기 컬럼)
      ├─ UserPromptCard
      ├─ ThinkingCard (접힘 기본)
      ├─ ToolCard (요약 1줄 + 펼치기)  × N
      ├─ ToolCard …
      └─ AssistantReplyCard (강조)
```

> 구현 메모: 상단 TokensDetailView가 이미 `TokensFlippedDocumentView`(isFlipped)로 위→아래
> 스택을 그린다(DetailViewController.swift:1039-1228). **그 패턴을 그대로 재사용**하면
> "위에서부터 쌓이고 맨 위로 스크롤" 동작을 공짜로 얻는다.

### 3.2 카드 유형별 스펙

#### (A) User Prompt Card — 내 프롬프트 (강조 대상 1)

```
┌─────────────────────────────────────────────┐
│ 💬  You                                       │  ← 역할 거터: bubble.left.fill, labelColor
│                                               │
│  Conversation 탭을 전용 앱 수준으로 rich하게   │  ← 13pt, labelColor, line-height 1.45
│  보여주고 싶어. 노이즈는 걷어내고...           │     읽기폭 클램프(~40 CJK자)
│  🖼 🖼                                          │  ← 첨부 이미지 글리프(기존 로직 재사용)
└─────────────────────────────────────────────┘
```

- 배경: 아주 옅은 fill(`DetailStyles.sectionBoxFillColor` 재사용 — 다크/라이트 동적).
- 사용자 입력은 **가벼운 Markdown**만(코드 펜스, 줄바꿈). 헤딩/리스트는 평문 유지해도 OK.
- 좌측 거터 24pt: 아이콘 + "You" 라벨(11pt semibold secondary).

#### (B) Assistant Reply Card — 최종 답변 (강조 대상 2, 가장 중요)

```
┌─────────────────────────────────────────────┐
│ ✅  Assistant · Opus 4.8                       │  ← checkmark.bubble.fill, 모델 배지
│                                               │
│  세 가지를 제안합니다.                         │  ← 풀 Markdown 렌더
│                                               │
│  1. 카드형 스트림으로 전환                     │  ← 리스트 들여쓰기
│  2. thinking/tool 접기                         │
│                                               │
│  ```swift                                     │  ← 코드블록: monospace, 옅은 배경,
│  let card = UserPromptCard()                  │     좌측 4pt 악센트 바, [복사] 버튼
│  ```                                          │
└─────────────────────────────────────────────┘
```

- **답변 카드는 시각적으로 가장 무게가 실려야 한다** — 약간 더 큰 본문(13pt), labelColor,
  넉넉한 상하 패딩. 모델명 배지(ModelDisplay 헬퍼 활용)로 "어떤 모델이 답했나"를 한눈에.
- 풀 Markdown: 헤딩(semibold), 리스트(• / 1.), `inline code`(monospace + 옅은 배경),
  코드블록(monospace 11pt + fill + 좌측 악센트 바 + 우상단 복사 버튼), 링크(systemBlue).

#### (C) Thinking Card — 추론 (기본 접힘)

```
▸ 🧠 Thinking · 1,240 tokens                      ← 한 줄, secondaryLabel, 클릭 시 펼침
```
펼치면:
```
▾ 🧠 Thinking · 1,240 tokens
   사용자는 가독성을 원한다. 측정폭을 먼저...     ← 12pt, secondaryLabel(quiet), italic 톤
```

- `step.thinkingText`를 소스로. 기본 접힘 — "중요한 내용만"의 핵심.
- 색은 quiet(secondaryLabel). 절대 답변보다 튀면 안 됨(StepKindStyle 원칙 일치).

#### (D) Tool Card — 도구 사용 (요약 1줄 + 펼치기)

```
▸ 🔧 Read  Lupen/UI/Dashboard/DetailViewController.swift          ← 요약: 도구명 + 핵심 인자 1개
```
펼치면 입력/출력 2단:
```
▾ 🔧 Read  DetailViewController.swift
   Input   { file_path: ".../DetailViewController.swift", limit: 200 }
   Output  ⤷ 200 lines · 8.2 KB                                   ← 큰 출력은 크기만, "전체 보기"
```

- 요약 1줄은 `ToolInputFormatter.format(call:limit:120)` (기존 헬퍼) 재사용.
- toolResult 본문이 길면(예: 파일 200줄) **앞 N줄 + `(N more lines…)`** truncated 모드
  → `claude-history`의 summary→truncated→full 순환을 차용.
- 연속된 tool 카드가 많으면(스킬 그룹) **"🔧 5 tools used"로 묶어 접기** — Claude Code의
  "Called slack 3 times" 패턴.

#### (E) System / Compact / Stop / Interruption — 메타 라인

```
─── ↻ Compact resume ───                          ← isCompactSummary
─── ⚠ API Error: 529 Overloaded ───               ← isSyntheticApiError (기존 텍스트 재사용)
─── ✋ User cancelled this request ───              ← interruption
```

- 시스템성/경고성은 **가느다란 구분선 + 중앙 라벨**로 흐름의 "막간"처럼. 카드 무게를 주지 않는다.
- 색: 일반 메타는 tertiaryLabel, stop=orange, interruption=red (StepKindStyle 그대로).

### 3.3 전체 레이아웃 스케치 (Turn 선택 시)

```
┌───────────────────────────────────────────────────────────────┐
│ [Conversation] Attachments  Tokens  Usage  Raw      📁  |  ▣    │ ← 기존 헤더(그대로)
├───────────────────────────────────────────────────────────────┤
│   ◀──── 좌우 여백 ────▶  ◀── 읽기 컬럼 ~620pt ──▶  ◀ 여백 ▶     │
│                                                                 │
│        ┌─────────────────────────────────────────┐             │
│        │ 💬 You                                    │             │
│        │   Conversation 탭을 rich하게...           │             │
│        └─────────────────────────────────────────┘             │
│                                                                 │
│        ▸ 🧠 Thinking · 1.2k tokens                              │
│        ▸ 🔧 Read DetailViewController.swift                     │
│        ▸ 🔧 5 tools used                                        │
│                                                                 │
│        ┌─────────────────────────────────────────┐             │
│        │ ✅ Assistant · Opus 4.8                    │             │
│        │   세 가지를 제안합니다.                    │             │
│        │   1. 카드형 스트림...                      │             │
│        │   ```swift … ```            [복사]         │             │
│        └─────────────────────────────────────────┘             │
└───────────────────────────────────────────────────────────────┘
```

### 3.4 큐레이션 규칙 — 무엇을 강조/접기/숨기기

| 콘텐츠            | 기본 표시            | 근거 |
|-------------------|----------------------|------|
| 내 프롬프트       | **카드, 강조**       | 사용자가 가장 먼저 찾는 닻 |
| 최종 답변(reply)  | **카드, 최강조**     | 핵심 산출물 |
| thinking          | 접힘(1줄 요약)       | 노이즈, 원할 때만 |
| toolCall/Result   | 접힘(1줄 요약)       | 장황한 I/O는 점진 공개 |
| 다수 tool 연속    | 묶어서 "N tools"     | 반복 압축 |
| systemInjected    | 숨김(또는 막간 라인) | 사용자 작성물 아님 |
| compact summary   | 막간 라인            | 흐름 표시만 |
| stop/interruption | 막간 라인(경고색)    | 의미 신호 |

토글: 헤더 우측에 **"Show details"** 작은 토글(또는 `⌥`-클릭으로 전체 펼침)을 두어
"깔끔히 보기 ↔ 전부 펼치기"를 한 번에. (Claude Code `Ctrl+O` 등가물)

### 3.5 타이포그래피 토큰 (DetailStyles에 추가)

```swift
// Conversation 전용 토큰
static let convBodyFont       = NSFont.systemFont(ofSize: 13, weight: .regular)   // 본문
static let convBodyColor      = NSColor.labelColor
static let convQuietColor     = NSColor.secondaryLabelColor                        // thinking/tool
static let convLineHeightMul: CGFloat = 1.45                                       // NSParagraphStyle
static let convReadingWidth:  CGFloat = 620                                        // 읽기 컬럼 max
static let convCodeFont       = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
static let convRoleLabelFont  = NSFont.systemFont(ofSize: 11, weight: .semibold)   // "You"/"Assistant"
static let convCardCornerRadius: CGFloat = 8
// 카드 fill/border는 기존 sectionBoxFillColor / sectionBoxBorderColor 재사용
```

- 모든 색은 **semantic(동적)** — 다크모드 함정 회피(2.6).
- 읽기 컬럼: 카드 스택의 widthAnchor를 `min(패널폭-여백, convReadingWidth)`로 클램프, centerX 정렬.

---

## 4. ASCII로 본 "전/후"

**Before (현재):**
```
USER
Conversation 탭을 rich하게 보여주고 싶어 노이즈는 걷어내고 사용자가 실제로 확인하고 싶은 화면으로 큐레이션...(패널 폭 끝까지 한 줄)

ASSISTANT
(no response available)            ← Turn 선택 시 항상 이렇게 나온다(버그)
```

**After (제안):**
```
        ┌────────────────────────────────┐
        │ 💬 You                          │
        │   Conversation 탭을 rich하게     │   ← 읽기폭 제한, 줄간격 1.45
        │   보여주고 싶어. 노이즈는...      │
        └────────────────────────────────┘

        ▸ 🧠 Thinking · 1.2k tokens
        ▸ 🔧 3 tools used

        ┌────────────────────────────────┐
        │ ✅ Assistant · Opus 4.8          │
        │   세 가지를 제안합니다.          │   ← 풀 Markdown, 강조
        │   1. ...                         │
        └────────────────────────────────┘
```

---

## 5. Lupen 현 아키텍처에서의 적용 난이도

### 5.1 단계별 (난이도 / 가치)

| 단계 | 작업 | 난이도 | 가치 | 비고 |
|------|------|--------|------|------|
| **P0** | `showTurn`에서 reply를 Conversation에 전달 | 매우 낮음 | 매우 높음 | `(no response available)` 버그 직결. 아래 5.2 |
| **P1** | 읽기폭 클램프 + 줄간격(NSParagraphStyle) | 낮음 | 높음 | 단일 NSTextView 유지한 채 즉시 개선 |
| **P2** | Turn 단위 Step 큐레이션 → 카드 스택 | 중간 | 매우 높음 | NSStackView 카드, TokensDetailView 패턴 복제 |
| **P3** | Markdown 렌더러(답변 카드) | 중간~높음 | 높음 | 5.3 참고 |
| **P4** | thinking/tool 접힘 + truncated, "N tools" 묶기 | 중간 | 높음 | NSDisclosure 패턴 / 커스텀 토글 |
| **P5** | 코드블록 복사 버튼 + (선택)구문 강조 | 중간 | 중간 | 구문 강조는 후순위 |

### 5.2 P0 — 지금 당장 가능한 1줄급 수정 (버그)

`showTurn`이 답변을 안 넘기는 게 원인이다. `.reply` Step의 텍스트를 조립해 넘기면 즉시 해결:

```swift
// DetailViewController.swift showTurn(...) 내부, 현재 assistantContent: nil 인 부분
let replyText = turn.steps
    .filter { $0.kind == .reply }
    .compactMap { $0.text }
    .joined(separator: "\n\n")
conversationView.configure(
    humanPrompt: promptText,
    assistantContent: replyText.isEmpty ? nil : replyText,
    promptInlineImageCount: promptStep?.images.count ?? 0
)
```
> 단, 이건 응급 패치다. 제대로 된 건 P2(카드 스택)에서 Turn 전체를 큐레이션하는 것.
> CLAUDE.md 규칙상 **이런 명백한 버그는 단순 수정 범주**지만, 큰 재설계는 plan 승인 후 진행.

### 5.3 적용 시 유리한 점 / 주의점

**유리한 점**
- 데이터는 이미 다 있다(Step/Turn). 새 파싱 불필요 — **순수 표현 레이어 작업**.
- 시각 언어(`StepKindStyle` 아이콘/색)와 카드 fill(`DetailStyles.sectionBoxFillColor`)이 이미 존재 → 재사용.
- flipped 위→아래 스택 패턴이 `TokensDetailView`에 검증돼 있어 복제 가능.
- semantic 색을 이미 쓰므로 다크모드 안전.

**주의점**
- **Markdown 렌더러 선택**: AppKit엔 기본 Markdown→attributed 변환이 빈약하다.
  - 옵션 A: `NSAttributedString(markdown:)`(Foundation) — inline 위주, 코드블록/리스트 약함.
  - 옵션 B: 자체 경량 파서(헤딩/리스트/코드펜스/inline code/링크만) — Lupen 톤에 맞춤, 의존성 0(제로 네트워크/경량 철학에 부합).
  - 권고: **B(자체 경량 파서)**. 코드펜스·리스트·inline code·링크 4종만 우선. `JSONPrettyFormatter`/`ToolInputFormatter` 같은 기존 포매터 패턴과 결이 같다.
- **성능/스크롤 안정성**: `showStep`의 "같은 선택이면 re-render 스킵"(DetailViewController.swift:539-545)
  로직을 카드 스택에도 유지해야 스트리밍 중 스크롤 튐 방지.
- **선택/복사**: 현재 NSTextView는 드래그 선택·복사가 된다(데이터 surface 요구). 카드로 가면
  각 카드 본문을 **selectable NSTextView/NSTextField**로 유지해야 한다(DetailStyles의 selectable 라벨 철학).
- **Step ↔ Turn 스코프 일관**: 상단 아웃라인에서 Step을 고르면 해당 카드로 스크롤/하이라이트하면
  상·하단이 연동된다(추가 가치, 선택).

---

## 6. 트레이드오프와 리스크

1. **복잡도 상승**: 단일 NSTextView(매우 단순) → 카드 스택 + 토글 상태 관리. 재렌더/스크롤
   안정성, 접힘 상태 보존 로직이 늘어난다. → P1/P0를 먼저 내고 점진 적용으로 리스크 분산.
2. **Markdown 파서 유지보수**: 자체 파서는 엣지케이스(중첩 리스트, 표) 부담. → 범위를 4종으로
   못 박고, 미지원 문법은 평문 폴백(안전).
3. **"너무 접어서 안 보인다" 리스크**: 과도한 접힘은 정보 은닉이 된다. → thinking/tool은 접되
   **항상 1줄 요약 + 명확한 펼침 어포던스(▸)**, 그리고 "Show details" 전역 토글로 통제감 부여
   (progressive disclosure 원칙 2.2).
4. **읽기폭 클램프의 위화감**: 넓은 패널에서 좌우 여백이 커지면 "휑하다"는 인상. → 카드 배경 fill로
   컬럼을 시각적으로 묶고, 코드블록/Raw는 컬럼 폭을 넘겨도 되게 예외 허용.
5. **CJK 측정폭**: 40자 권고는 한국어엔 빡빡할 수 있다. → 폰트 13pt 기준 ~600~640pt를
   실측 후 미세조정(고정값 맹신 금지).
6. **기존 동작 회귀**: 인라인 이미지 글리프/`file://` 링크 클릭→Finder(DetailViewController.swift:1653-1678)는
   반드시 카드 본문 렌더러로 이식해야 한다(누락 시 기능 후퇴).

---

## 7. 권장 실행 순서 (요약)

1. **P0**: `showTurn` reply 결선 → `(no response available)` 제거 (응급, 즉시).
2. **P1**: NSParagraphStyle(줄간격 1.45) + 읽기폭 클램프 — 단일 TextView 유지한 채 체감 개선.
3. **P2**: Turn 큐레이션 → 카드 스택(User/Assistant/Thinking/Tool/Meta). `StepKindStyle` 재사용.
4. **P3**: 답변 카드 경량 Markdown(코드펜스/리스트/inline code/링크).
5. **P4**: thinking/tool 접힘 + "N tools" 묶기 + "Show details" 전역 토글.
6. **P5**: 코드블록 복사 버튼, (선택) 구문 강조, Step↔카드 상하단 연동.

---

## 참고 출처

- 측정폭/줄간격: [Baymard](https://baymard.com/blog/line-length-readability) · [UXPin – Line Length](https://www.uxpin.com/studio/blog/optimal-line-length-for-readability/) · [Pimp my Type](https://pimpmytype.com/line-length-line-height/)
- 점진적 공개: [IxDF](https://ixdf.org/literature/topics/progressive-disclosure) · [UXPin – Progressive Disclosure](https://www.uxpin.com/studio/blog/what-is-progressive-disclosure/) · [LogRocket](https://blog.logrocket.com/ux-design/progressive-disclosure-ux-types-use-cases/)
- 화자 구분/풀폭: [AI UX Design – Conversational UI](https://www.aiuxdesign.guide/patterns/conversational-ui)
- 전용 앱 패턴: [Claude Code Docs](https://code.claude.com/docs/en/vs-code) · [wmedia – Show Thinking](https://wmedia.es/en/tips/claude-code-verbose-output-see-thinking) · [claude-history](https://github.com/raine/claude-history)
- Markdown/코드블록: [Markdown Visualizer](https://markdownvisualizer.com/blog/markdown-code-blocks)
- macOS 타이포그래피/다크모드: [Apple HIG – Typography](https://developer.apple.com/design/human-interface-guidelines/typography) · [Apple Forums – NSTextView dark mode](https://developer.apple.com/forums/thread/114433)

## 코드 근거 (파일:라인)

- 단일 NSTextView 평문 렌더: `Lupen/UI/Dashboard/DetailViewController.swift:1465-1587`
- `(no response available)` 출력 지점: `DetailViewController.swift:1577-1583`
- `showTurn`이 `assistantContent: nil` 전달(버그 원인): `DetailViewController.swift:726-730`
- `showStep` 단일 Step만 표현 + re-render 스킵: `DetailViewController.swift:537-545, 565-628`
- 인라인 이미지 글리프/링크 클릭 처리(이식 필요): `DetailViewController.swift:1599-1678`
- flipped 위→아래 스택 패턴(복제 대상): `DetailViewController.swift:1039-1228`
- 역할 아이콘/색 시각 언어(재사용): `Lupen/UI/Support/StepKindStyle.swift:13-80`
- 디자인 토큰/카드 fill/selectable 라벨(재사용): `Lupen/UI/Dashboard/DetailStyles.swift:30-209`
- 데이터 소스 필드: `Lupen/Domain/Conversation/Step.swift`, `Turn.swift`, `StepKind.swift`
