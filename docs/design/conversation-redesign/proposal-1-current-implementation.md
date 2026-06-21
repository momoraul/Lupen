# 제안서 1 — 현재 구현 심층 분석 (Conversation 탭)

> 관점: **현재 구현 심층 분석**. Lupen이 지금 Conversation 탭에서 데이터를 어떻게 조립하고 무엇을 렌더링하는지 코드베이스를 깊이 읽어 사실 기반으로 정리한다. 이 문서는 나머지 4개 안의 "사실 토대"가 되므로 모든 코드 주장은 `파일경로:라인`으로 근거를 남긴다.

---

## 0. TL;DR (핵심 한 문단)

지금 Conversation 탭은 **단일 `NSTextView` 한 개에 평문 두 덩어리(`humanPrompt` + `assistantContent`)를 붙여 넣는 구조**다 (`DetailViewController.swift:1465-1587`). 표시 단위가 "한 Turn 전체"가 아니라 **선택된 단일 Step(또는 Step 하나로 환원된 Turn)**이라서, Turn 헤더를 선택하면 `assistantContent: nil`이 들어가 화면에 그 악명 높은 **"(no response available)"**가 뜬다 (`DetailViewController.swift:726-730`, `1577-1583`). 반면 도메인 모델(`Step`, `Turn`, `ToolUseInfo`, `ToolResultInfo`)에는 전용 앱 수준 대화 뷰를 만들 **풍부한 신호가 이미 다 들어와 있다** — thinking 텍스트 분리, tool 입력 semantic 요약, tool 결과/에러 플래그, 첨부 manifest, stop/interruption 사유, 모델/토큰/비용까지. 즉 **데이터는 충분하고, 막혀 있는 건 오직 "표현 레이어"**다. 가장 큰 구조적 장벽은 (1) Turn 전체를 순회해 렌더링하는 경로가 아예 없다는 점과 (2) 마크다운 렌더링이 코드베이스 어디에도 없다는 점이다 (`grep` 결과 0건).

---

## 1. Conversation 탭 렌더링 경로 (있는 그대로)

### 1.1 호스트 — `DetailViewController`

- 하단 상세 패널은 5개 탭을 `NSSegmentedControl`로 전환한다: `Conversation / Attachments / Tokens / Usage / Raw` (`DetailViewController.swift:150-154`). Conversation이 0번, 즉 기본 랜딩 탭이다 (`:147-149`).
- 탭 뷰 배열 순서: `[conversationView, attachmentsView, tokensView, usageView, rawView]` (`:112-114`). 한 컨테이너에 다섯 뷰를 겹쳐 두고 `isHidden`만 토글한다 (`:875-888`).
- 선택 진입점은 3개:
  - `showRequest(_:)` — 레거시 `ParsedRequest` 경로. Conversation은 **항상 빈값**(`humanPrompt: nil, assistantContent: nil`)으로 호출된다 (`:511-514`).
  - `showStep(_:)` — **단일 Step**을 표시. Conversation 표현 로직의 핵심 (`:537-661`).
  - `showTurn(_:displayCost:displayTokens:)` — Turn 헤더 선택. **prompt 텍스트만** 넣고 `assistantContent: nil` (`:709-730`).
  - `showSkillGroup(...)` — Skill 그룹. label + 한 줄짜리 step 요약 리스트를 텍스트로 넣음 (`:765-806`, `:989-994`).

### 1.2 `showStep` 의 "대화로 환원" 로직 — 여기가 표현의 전부

`Step.kind`에 따라 `humanPrompt`/`assistantContent` 두 문자열을 만든다 (`:563-628`):

| kind | humanPrompt | assistantContent |
|---|---|---|
| `.prompt` | `step.text` | nil |
| `.toolResult` | `"↪ \(name) result\n\n\(content)"` | nil |
| `.toolCall` / `.thought` | nil | 텍스트 + 각 toolCall을 `"→ \(name)\n\(input)"`로 join (`ToolInputFormatter.format(call:limit:400)`) |
| `.reply` | nil | `"— thinking —\n…"` + `"— reply —\n…"` (있을 때만) |
| `.stop` | nil | synthetic API 에러면 `"⚠ \(body)"`, 아니면 `"(stopped: reason)"` |
| `.interruption` | `"✋ User cancelled this request"` | nil |

→ 즉 **`USER`/`ASSISTANT` 둘 중 하나만** 채워지는 경우가 대부분이다. 한 Step은 한쪽 역할만 갖기 때문. 결과적으로 Conversation 탭은 "대화"가 아니라 **"선택한 단일 항목의 평문 덤프"**다.

### 1.3 실제 그리기 — `ConversationDetailView.configure`

(`:1513-1587`)

- `NSMutableAttributedString`에 다음을 차례로 붙인다:
  1. `"USER\n"` (헤더, 11pt semibold secondaryLabel — `DetailStyles.sectionHeaderFont`)
  2. prompt 본문 (12pt systemFont labelColor). 비어있으면 `"(no prompt available)"` tertiaryLabel.
  3. `"\n\n"`
  4. `"ASSISTANT\n"` 헤더
  5. response 본문. 비어있으면 **`"(no response available)"`** tertiaryLabel (`:1579`).
- 본문은 `buildBodyWithImageLinks(...)`로 `[Image source: /path]` / `[Image #N]` 마커를 SF Symbol `photo` 첨부 글리프로 치환하고, 경로 마커는 `file://` 링크로 만들어 Finder reveal을 건다 (`:1589-1649`, `:1653-1678`).
- 텍스트는 selectable(`isSelectable=true`), non-editable, rich text. **마크다운 파싱·코드블록·테이블·리스트 처리는 전혀 없음** — `\n`만 살아있는 순수 plain attributed string.

### 1.4 폭/높이/스타일

- 좌우 inset 16pt(`DetailStyles.horizontalInset`), 상하 12pt (`:1486`).
- 단일 `NSScrollView` + `NSTextView`. 카드/구분선/배경 버블 없음. USER/ASSISTANT는 그냥 굵은 헤더 한 줄.

---

## 2. 이미 가진 풍부한 신호 (데이터는 충분하다)

전용 앱 수준 뷰를 만들 재료가 도메인 모델에 **이미** 다 있다. 현재 표현이 이걸 거의 다 버린다.

### 2.1 `Step` (`Step.swift:35-205`)

- `kind: StepKind` — 7종 분류 (`prompt/toolResult/toolCall/thought/reply/stop/interruption`) (`StepKind.swift:5-22`). 역할/아이콘/색을 이미 매핑하는 `StepKindStyle`까지 존재 (`StepKindStyle.swift`).
- `text` (thinking 제외 본문) **와** `thinkingText` (확장 사고 블록)가 **분리 저장**됨 (`Step.swift:76-79`). → "사고 과정"을 접을 수 있는 별도 블록으로 렌더 가능.
- `images`, `imageSourcePaths`, `mentionedFilePaths`, `attachments`(통합 manifest) (`:80-106`). → 첨부를 인라인으로 그릴 수 있음.
- `toolCalls: [ToolUseInfo]`, `toolResult: ToolResultInfo?` (`:107-110`).
- `model`, `tokens`, `cost`, `speed`, `requestId(s)`, `messageId` (`:112-129`). → 각 reply/Step 옆에 모델 배지·비용을 붙일 수 있음.
- `stopReason` / `stopReasonKind`, `isSyntheticApiError`(`:377-379`), `isCompactSummary`(`:70`), `isSidechain`/`agentId`(`:56-61`).
- `oneLineSummary(...)` — 코드 펜스/구분선 스킵, 첫 비공백 줄 추출, 이미지 프리픽스(`🖼`) 등 **이미 큐레이션 휴리스틱이 구현돼 있음** (`:394-524`). 지금은 아웃라인 행에만 쓰이고 Conversation 탭은 안 씀.

### 2.2 `Turn` (`Turn.swift:8-284`)

- `steps: [Step]` 전체 보유 (`:15`). **Turn 전체를 순회할 재료가 이미 손안에 있다.**
- `promptStep`(`:37-40`), `isComplete`(`:43-46`), `isInterrupted`(`:18`), `endedWithApiError`(`:54-56`), `isOrphan`(`:60`), `wasCompactedAway(...)`(`:82-87`).
- `aggregateTokens`/`aggregateCost`(`:102-152`), 서브에이전트 포함 롤업까지 (`:173-214`).
- `allAttachments` — Turn 전체 첨부 dedup manifest (`:259-283`).

### 2.3 `ToolUseInfo` (`ToolUseInfo.swift:19-461`)

- `name`, `inputJSON`(스냅샷에서 ~1KB로 truncate), `skillName`, `displayInputSummary`.
- **semantic 요약기가 도구별로 이미 구현돼 있음**: Read/Write/Edit→경로, Bash→명령, Grep→`/pattern/ in path`, WebSearch→query, Agent→타입+설명, Skill→스킬명+args (`:66-212`). → tool-call 카드의 1줄 제목을 공짜로 얻음.
- `abbreviatedInput(limit:)`(`:50-56`).

### 2.4 `ToolResultInfo` (`ToolResultInfo.swift:19-79`)

- `content`(~2KB truncate), `isError`(`:24`), `toolUseId`(parent toolCall 매칭용), `abbreviatedContent(limit:)`.
- → 결과를 접힘 카드로, 에러는 빨간 배지로 그릴 수 있음.

### 2.5 표현 헬퍼 (이미 존재)

- `StepKindStyle.roleSymbol/roleTint/textColor/displayName(forToolName:)` (`StepKindStyle.swift:13-101`) — 역할별 SF Symbol·틴트·도구명 정규화가 다 준비됨.
- `ToolInputFormatter`, `JSONPrettyFormatter`, `InlineImageSymbol`, `ImageSourceFormatter`, `DetailCostFormatter`, `ModelDisplay` 등.

---

## 3. 현재 표현의 한계 (왜 "빈약"한가)

1. **표시 단위가 단일 Step**이라 "프롬프트 → 사고 → 도구 사용 → 결과 → 답변"의 **흐름 자체가 안 보인다.** Conversation 탭은 본질적으로 한 항목만 보여준다.
2. **Turn 헤더 = "(no response available)"** — `showTurn`이 `assistantContent: nil`을 넘김 (`:728`). 사용자가 가장 자연스럽게 누르는 Turn 행이 가장 빈약한 화면을 띄운다. **스크린샷의 빈 상태가 바로 이것.**
3. **마크다운 미렌더** — LLM 답변은 거의 항상 마크다운(제목/리스트/코드블록/표/굵게)인데, 전부 raw 텍스트로 평면화된다. 코드블록이 본문과 시각적으로 구분되지 않는다 (`grep markdown` 0건).
4. **정보 위계 없음** — thinking·toolCall·toolResult·reply가 전부 같은 12pt 본문. `thinkingText`를 분리 저장하는데도 화면에선 `"— thinking —"` 라벨 한 줄로 뭉뚱그린다 (`:591-597`).
5. **도구 사용이 텍스트 한 줄** — `"→ Bash\n{json}"` 식 (`:581-586`). `ToolUseInfo`의 semantic 요약/에러 플래그/결과 매칭을 안 쓴다. 전용 앱들은 도구 호출을 접이식 카드로 보여준다.
6. **노이즈 제거 큐레이션 없음** — `isSystemInjected`(meta), 빈 reply("Usage update"), compact 마커 등을 Conversation 탭 수준에서 추리지 않는다. (`oneLineSummary`엔 휴리스틱이 있지만 탭은 미사용.)
7. **메타데이터 부재** — 각 답변의 모델/토큰/시각/비용이 Conversation 탭엔 안 붙는다(전부 Tokens 탭으로 분리). 전용 앱은 메시지 옆에 모델 배지를 단다.
8. **상태 텍스트가 투박** — `"(stopped: stop_sequence)"`, `"↪ tool result"` 같은 내부 용어 노출.

---

## 4. "Rich하게" — 바로 가능 vs 새로 필요

### 4.1 새 데이터 없이 **바로 가능** (재료가 이미 있음)

- **Turn 전체 대화 렌더**: `turn.steps`를 순회하며 prompt→thought→toolCall→toolResult→reply를 순서대로 그림. 데이터 100% 보유. `showTurn`이 step 배열을 넘기게만 바꾸면 됨.
- **역할별 카드/버블 + 아이콘/틴트**: `StepKindStyle` 그대로 사용.
- **thinking 접이식 블록**: `step.thinkingText` 이미 분리 저장.
- **tool-call 카드 (도구명 + semantic 요약 + 결과 미리보기)**: `ToolUseInfo.displayInputSummary`/`abbreviatedInput`, `ToolResultInfo.content`/`isError`/`abbreviatedContent`.
- **첨부 인라인 칩**: `step.attachments` / `turn.allAttachments` + 기존 `InlineImageSymbol`·inline image provider.
- **메시지별 모델/비용 배지**: `step.model`/`step.cost`/`step.tokens` + `ModelDisplay`/`DetailCostFormatter`.
- **노이즈 필터**: `isSystemInjected`, 빈 reply, compact 마커 등으로 step 솎아내기 — 모두 기존 플래그.
- **stop/interruption/synthetic-error 친화 표현**: `isSyntheticApiError`, `stopReasonKind` 보유.

### 4.2 **새로 필요한 것** (구현 추가)

- **마크다운 → attributed string 렌더러** (또는 코드블록만이라도 분리). 현재 0건. macOS 12+ `AttributedString(markdown:)`은 인라인만 지원하고 코드블록/리스트 블록 레이아웃은 약함 — 코드블록·리스트·표는 자체 파서 또는 경량 렌더 필요.
- **다중 뷰 레이아웃 컨테이너**: 단일 `NSTextView`로는 "카드 N개 + 코드블록 배경 + 접기" 표현 한계. `NSStackView` 기반 메시지 리스트 또는 `NSTableView`/`NSCollectionView` 대화 뷰로 전환 필요. (Tokens 탭이 이미 flipped documentView + NSStackView 패턴을 쓰고 있어 참고 구현 존재 — `:1039-1291`.)
- **truncate된 tool 입출력의 on-demand 펼치기**: 스냅샷이 inputJSON 1KB / content 2KB로 자르므로(`ToolUseInfo.swift:413-426`, `ToolResultInfo.swift:41-54`), 전체 보기는 `store.rawJSON(for:)` lazy 로드 경유 필요 (Raw 탭이 쓰는 그 경로).
- **코드블록 신택스 하이라이트**(선택): 있으면 전용 앱 느낌↑, 없어도 무방.

---

## 5. 권고 — 어떤 화면을 어떻게

### 5.1 핵심 전환: "단일 Step 덤프" → "Turn 전체 대화 타임라인"

Conversation 탭을 **선택된 Turn의 전체 대화 흐름**을 위→아래 타임라인으로 보여주는 뷰로 재정의한다. Step 단일 선택 시에는 해당 Step만(또는 해당 Step을 하이라이트한 Turn 전체) 보여준다.

- `showTurn`이 `turn.steps`를 통째로 넘기도록 변경 (현재 `assistantContent: nil` 한계 제거).
- 노이즈 필터를 거친 step만 렌더: meta-injected 제외, 빈 reply 접기, compact 마커는 `"↻ Compact resume"` 한 줄.

### 5.2 메시지 카드 위계 (3단)

1. **User 프롬프트** — 강조(labelColor, 살짝 채워진 배경 또는 좌측 강조선). 첨부는 인라인 칩.
2. **Assistant 답변(reply)** — 본문 강조 + 마크다운 렌더. 상단에 모델 배지 + 비용/토큰 메타.
3. **실행 트레이스(thought/toolCall/toolResult)** — **기본 접힘**, secondary 톤. 도구 카드 = `[아이콘] 도구명 — semantic 요약` + 펼치면 입력/결과/에러. (HIG "deference": 중간 과정은 가라앉히고 시작·끝(질문·답변)을 scan anchor로.)

### 5.3 ASCII 레이아웃 스케치

```
┌ Conversation ─────────────────────────────────────────────┐
│                                                            │
│  ● USER                                          14:32     │
│  ┃ 지난 turn을 Lupen에서 볼 때, 전용 앱처럼 대화를         │
│  ┃ rich하게 보여주고 싶어. 🖼 screenshot.png               │
│                                                            │
│  ⌄ 🧠 Thinking  (접힘 — 클릭하면 펼침)                     │
│                                                            │
│  ⌄ 🔧 Tool · Read   DetailViewController.swift            │
│  ⌄ 🔧 Tool · Grep   /assistantContent/  in Lupen/         │
│     ↳ ✓ 12 matches                                         │
│  ⌃ 🔧 Tool · Bash   swift build           ← 펼쳐진 카드    │
│     ┌───────────────────────────────────────────┐        │
│     │ $ swift build                              │        │
│     │ Compiling Lupen…                           │        │
│     │ Build complete! (3.4s)                     │  ✓     │
│     └───────────────────────────────────────────┘        │
│                                                            │
│  ✦ ASSISTANT          claude-opus-4 · $0.04 · 19,881 tok  │
│  현재 Conversation 탭은 다음 구조입니다:                   │
│                                                            │
│    1. 단일 NSTextView                                      │
│    2. humanPrompt + assistantContent                       │
│                                                            │
│  ```swift                              ← 코드블록 배경     │
│  conversationView.configure(humanPrompt: …)               │
│  ```                                                       │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### 5.4 도구 카드 마크업 예시 (개념)

```
[wrench.adjustable.fill]  Bash  ·  swift build && swift test
   └ (펼침) 입력:  { "command": "swift build && swift test" }
   └ (펼침) 결과:  Build complete! 142 tests passed.        [✓]
```
- 제목 = `StepKindStyle.displayName(forToolName:)` + `ToolUseInfo.abbreviatedInput()`.
- 에러면 `ToolResultInfo.isError`로 카드 좌측선/배지 빨강.
- 전체 입출력은 truncate 한계 때문에 펼침 시 `store.rawJSON(for:step)` lazy 로드.

### 5.5 빈 상태 개선

- Turn에 reply가 없으면(`isInterrupted`/`endedWithApiError`/compacted) "(no response available)" 대신 **사유 배너**: `"✋ 사용자가 중단함"`, `"⚠ API 오류로 종료 (529 Overloaded)"`, `"✂ 이 답변은 다음 turn으로 요약됨(compact)"`. 모두 기존 플래그로 판정 가능 (`Turn.swift:54-87`, `Step.swift:377-379`).

---

## 6. 참고한 앱·기법과 출처

> 외부 베스트프랙티스는 코드베이스 내부 근거와 구분하여 표기. (이 분석 세션에서 웹 접근은 사용하지 않았고, 아래는 일반적으로 알려진 패턴/Apple HIG에 기반한 권고다. 확정 인용이 필요하면 후속 안에서 URL 확보 권장.)

- **Apple HIG — Deference / 정보 위계**: 중간 실행 트레이스를 가라앉히고 질문·답변을 강조하는 방침은 코드 주석에도 이미 인용돼 있음 (`StepKindStyle.swift:27-47`, `:63-80` — "Apple Mail subject bold + meta dim").
- **전용 LLM 앱 UI 패턴 (Claude Code / Codex / Cursor)**: tool 호출을 **접이식 카드**로, thinking을 **별도 접힘 블록**으로, 답변을 **마크다운 렌더**로, 메시지에 **모델/비용 배지**를 다는 것이 공통 관례. (사용자 요청의 레퍼런스 앱들.)
- **macOS `AttributedString(markdown:)`**: 인라인 마크다운은 표준 API로 가능하나 코드블록/리스트 블록 레이아웃은 제한적 — 자체 보강 필요. (Apple Foundation 공개 API; 정확한 한계는 후속 안에서 문서 URL 확인 권장.)
- **사내 참고 구현**: Tokens 탭의 flipped documentView + NSStackView 섹션 빌더가 "스크롤 가능한 카드 리스트" 패턴의 직접 참고 자료 (`DetailViewController.swift:1039-1291`).

---

## 7. 트레이드오프와 리스크

- **단일 NSTextView → 다중 뷰(NSStackView/NSTableView)** 전환은 가장 큰 변경. 스크롤 위치 보존(스트리밍 재바인드 시 점프 방지, 현재 `showStep`의 skip-rerender 로직 `:537-545`과 동일 고민), 셀 재사용, 대용량 Turn 성능을 새로 설계해야 함.
- **마크다운 렌더러**는 직접 만들면 엣지케이스(중첩 리스트, 표, 펜스 내 백틱)가 많고, 외부 의존성은 **제로 네트워크/경량** 원칙과 충돌 가능. 단계적(코드블록·굵게·리스트만 → 점진 확장) 접근 권장.
- **Truncated 데이터의 lazy 펼침**은 디스크 재스캔(`store.rawJSON(for:)`) — 클릭당 I/O. 캐시 활용/비동기 필요.
- **성능**: 매우 긴 Turn(수십~수백 step) 전체 렌더 비용. 가상화(보이는 카드만) 또는 step 페이지네이션 검토.
- **회귀 위험**: 현재 단일 Step 선택 UX, inline image Finder reveal 링크(`:1653-1678`), Codex/Claude 양 provider 분기를 깨지 않아야 함.
- **스코프 모호성**: "Step 선택 시 무엇을 보여줄지"(해당 Step만 vs Turn 전체+하이라이트) 결정 필요 — 현재는 Step 단독. 사용자 의도("turn 단위로 대화를")는 Turn 중심을 시사.

---

## 8. Lupen 현 아키텍처에서의 적용 난이도

| 작업 | 난이도 | 근거 |
|---|---|---|
| `showTurn`에 step 배열 전달(가장 시급) | 낮음 | 데이터 이미 보유, 1메서드 시그니처 변경 (`:709-730`) |
| 빈 상태 → 사유 배너 | 낮음 | 플래그 전부 존재 (`Turn`/`Step`) |
| 역할별 카드 + 아이콘/틴트 | 중간 | `StepKindStyle` 재사용, 레이아웃만 신규 |
| thinking/tool 접이식 카드 | 중간 | 데이터 보유, 접기 UI·상태관리 신규 |
| 단일 NSTextView → NSStackView 대화 뷰 | 높음 | 스크롤/재사용/성능 재설계, Tokens 탭 패턴 참고 가능 |
| 마크다운 렌더 | 중간~높음 | 신규 컴포넌트, 의존성·엣지케이스 부담 |
| truncated 입출력 lazy 펼침 | 중간 | `store.rawJSON(for:)` 경로 재사용, 비동기·캐시 |

**결론**: "rich한 대화 뷰"의 80%는 **이미 보유한 데이터를 표현 레이어에서 새로 조립**하는 일이다. 첫 마일스톤으로 (a) `showTurn`이 Turn 전체 step을 넘기고, (b) `ConversationDetailView`를 NSStackView 카드 리스트로 바꿔 역할별 위계 + 빈 상태 배너 + tool 카드를 그리는 것까지가 가성비 최고 구간이다. 마크다운/신택스 하이라이트/lazy 펼침은 그 위에 점진 추가한다.
