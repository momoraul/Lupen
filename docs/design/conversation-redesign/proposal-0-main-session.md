# 제안 0 (메인세션): Conversation 탭을 "Turn 대화 리더"로 재설계

작성자: jaden (메인세션 직접 분석)
관점: 현재 코드베이스 정독 기반의 통합 설계 방향 제시

---

## 1. 한 줄 진단

Lupen의 데이터 레이어는 이미 전용 앱 수준의 rich 대화 렌더링에 필요한 신호를 **거의 다 보유**하고 있다.
병목은 순전히 **표현 레이어** — `ConversationDetailView`가 "평문 문자열 2개"만 받아 그리는 구조 — 에 있다.
따라서 이번 작업의 본질은 "데이터 확장"이 아니라 **"Turn 단위 대화 흐름을 묶어 큐레이션해 그리는 새 뷰"** 를 만드는 것이다.

---

## 2. 현재 구현의 사실관계 (코드 근거)

### 2.1 Conversation 탭은 평문 2개만 받는다
- `ConversationDetailView.configure(humanPrompt:assistantContent:promptInlineImageCount:)`
  [DetailViewController.swift:1513](../../../Lupen/UI/Dashboard/DetailViewController.swift)
- 단일 `NSTextView`(richText=true)에 `"USER\n" + prompt` → `"\n\n"` → `"ASSISTANT\n" + response` 를 `NSAttributedString`으로 찍는다. 본문은 **system font 12pt 평문**. 마크다운 파싱 없음 → 코드블록·헤딩·리스트·인라인코드·표가 전부 무시된다.
- 유일한 rich 처리는 `[Image source:]`/`[Image #N]` 마커를 SF Symbol(📎)로 치환하고 `file://` 링크를 거는 것뿐 ([DetailViewController.swift:1599](../../../Lupen/UI/Dashboard/DetailViewController.swift)).

### 2.2 Turn 선택 시 응답이 통째로 사라진다 (현재 가장 큰 결함)
- `showTurn(...)`은 `conversationView.configure(humanPrompt: promptText, assistantContent: nil, ...)`
  [DetailViewController.swift:726](../../../Lupen/UI/Dashboard/DetailViewController.swift)
- 즉 Turn을 고르면 **사용자 프롬프트만** 보이고 모델 응답/사고/도구사용/최종답변은 전부 빠진다 → "(no response available)" ([DetailViewController.swift:1579](../../../Lupen/UI/Dashboard/DetailViewController.swift)).
- 사용자는 응답을 보려면 Turn을 펼쳐 개별 Step(reply 등)을 하나하나 클릭해야 한다. 전용 앱처럼 "한 턴 = 읽을 수 있는 한 편의 대화"로 보이지 않는다.

### 2.3 Step 선택 시도 kind별 평문 조립에 그친다
- `showStep(...)`이 `step.kind`에 따라 문자열을 조립한다 ([DetailViewController.swift:537](../../../Lupen/UI/Dashboard/DetailViewController.swift)):
  - `.reply`: `"— thinking —\n…\n\n— reply —\n…"` 처럼 텍스트 라벨로 사고/응답 구분
  - `.toolCall/.thought`: `"→ 도구명\n입력(400자 제한)"`
  - `.toolResult`: `"↪ 도구명 result\n\n내용"`
  - `.stop`: `"(stopped: reason)"` 또는 API 에러 본문
- 모두 한 덩어리 평문으로 합쳐 `assistantContent`에 넣는다. 시각적 위계가 없다.

### 2.4 데이터는 이미 충분히 풍부하다 — 이게 핵심
`Step`( [Step.swift](../../../Lupen/Domain/Conversation/Step.swift) )이 보유한 신호:
- 분류: `kind`(prompt/toolResult/toolCall/thought/reply/stop/interruption), `isSystemInjected`, `isSidechain`(서브에이전트), `agentId`, `isCompactSummary`
- 내용: `text`, **`thinkingText`(확장 사고 별도 보관)**, `images`, `attachments`(통합 매니페스트), `toolCalls: [ToolUseInfo]`, `toolResult: ToolResultInfo`
- 메트릭: `tokens`, `cost`, `model`, `requestId`, `stopReason`/`stopReasonKind`
- 헬퍼: `oneLineSummary(...)`(이미 노이즈/마크업 제거 로직 보유), `isSyntheticApiError`
- `Turn`은 `steps: [Step]`, `promptStep`, `allAttachments`를 제공.

→ **"무엇을 보여줄지"의 원재료는 전부 메모리에 있다.** 마크다운 본문, 도구 입력/출력, 사고 과정, 첨부, 비용까지. 새 파이프라인을 만들 필요 없이 표현만 바꾸면 된다.

---

## 3. 목표 화면 정의 (사용자 요구의 구체화)

> "지난 turn을 전용 Claude Code/Codex/Cursor 앱처럼, 내 프롬프트 + LLM 응답을 가독성 좋고 rich하게, 중요한 것만 추려서."

이를 다음 3원칙으로 환원한다.

1. **Turn = 한 편의 읽을 수 있는 대화.** Turn을 선택하면 그 안의 흐름(내 프롬프트 → (사고) → 도구 사용/결과 → 최종 답변)이 시간순으로 한 화면에 이어진다.
2. **Rich 렌더링.** 마크다운(헤딩/리스트/표/인용/링크), 코드블록 신택스 하이라이팅, 인라인 코드, 도구 입력은 코드로, diff는 diff로.
3. **노이즈 큐레이션.** 1급 콘텐츠(내 프롬프트, 모델 최종 답변)는 항상 펼침. 부가(사고, 장황한 도구 I/O, 시스템/메타)는 **접힌 채 한 줄 요약 + 펼치기**.

---

## 4. 설계 방향

### 4.1 Turn 단위 "대화 트랜스크립트" 뷰 신설
`ConversationDetailView`를 "평문 2문자열" 인터페이스에서, **Step 배열을 받아 메시지 블록 스트림으로 그리는** 뷰로 승격한다.

```
┌─ Conversation ────────────────────────────────────────────┐
│                                                            │
│  🧑 You                                    11:25 · turn 시작 │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ 현재 프로젝트에 큰 기능추가를 해야하는데 먼저 …          │ │   ← 내 프롬프트 (강조 버블)
│  └──────────────────────────────────────────────────────┘ │
│                                                            │
│  ✦ Assistant · opus-4-8                       $0.37 · 2.3k │
│                                                            │
│   ▸ 사고 3문단 (접힘)                                       │   ← thinkingText: 기본 접힘
│                                                            │
│   ▸ 🔧 Read  Lupen/Domain/.../Session.swift   ✓ 192 lines │   ← toolCall+result 1줄, 접힘
│   ▸ 🔧 Bash  "find Lupen -type f -name *.swift"  ✓        │
│                                                            │
│   ## 아키텍처 (레이어별)                                    │   ← 최종 답변: 마크다운 렌더
│   Lupen은 … 입니다.                                         │
│   ```swift                                                 │
│   struct Session { … }            ← 신택스 하이라이트       │
│   ```                                                      │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

핵심:
- 화자(You / Assistant) 헤더 + 모델/비용/토큰 메타를 대화와 함께 표시(이미 `step.cost`/`step.tokens`/`step.model` 보유).
- 내 프롬프트는 살짝 들어간 배경 버블로 시각 강조, 모델 답변은 본문 폭 전체.
- 사고/도구는 **디스클로저(▸)** 로 접힘. 펼치면 사고 본문 / 도구 입력(코드) / 도구 결과(코드, 길면 잘림+더보기).

### 4.2 큐레이션 매핑 (StepKind → 표시 정책)
| StepKind / 신호 | 기본 표시 | 형태 |
|---|---|---|
| `.prompt` (내 프롬프트) | **항상 펼침 (1급)** | 강조 버블 + 마크다운 + 첨부 칩 |
| `.reply` 최종 텍스트 | **항상 펼침 (1급)** | 본문 마크다운 + 코드 하이라이트 |
| `.reply`의 `thinkingText` | **접힘** | 디스클로저 "▸ 사고 N문단" |
| `.thought` (중간 사고) | **접힘** | 디스클로저 |
| `.toolCall` + 짝 `.toolResult` | **접힘(한 줄)** | "🔧 도구명 · 핵심인자 · ✓/✗" → 펼치면 입력/출력 코드 |
| `.toolResult` 단독 | 부모 toolCall에 병합 | — |
| `.stop`(정상 end_turn) | 숨김 | — |
| `.stop`(API 에러, `isSyntheticApiError`) | **표시(경고)** | ⚠ 에러 배너 |
| `.interruption` | 표시 | "✋ 사용자가 취소" 배지 |
| `isSystemInjected` / 메타 | 기본 숨김(옵션 토글) | — |
| `isSidechain`(서브에이전트) | 부모 turn에 **인라인 요약** | "🤖 sub-agent ×N · 펼치기" |

상단에 **밀도 토글**(Compact ↔ Full)을 두어, 기본은 큐레이션(접힘 위주), Full은 모든 Step 펼침을 제공한다.

### 4.3 서브에이전트 표현
- Turn이 서브에이전트를 띄우면(`isSidechain`/`agentId`) 부모 답변 흐름 안에 "🤖 sub-agent: <목적> · $비용 · 펼치기" 카드로 인라인 삽입. 펼치면 그 에이전트의 미니 트랜스크립트(같은 렌더러 재귀).
- 이미 `SubAgentLinker`/`SubAgentGraftIndex`가 부모-자식 연결을 갖고 있어 그래프트는 기존 로직 재사용 가능.

---

## 5. 렌더링 기술 권고 (메인세션 1차 의견 — 워크플로우 안 4와 교차검증 예정)

후보: (A) `NSTextView`+`NSAttributedString`(TextKit2), (B) `WKWebView`(마크다운→HTML/CSS), (C) SwiftUI(`NSHostingView`), (D) NSStackView/CollectionView 블록 조립.

메인세션 1차 권고: **(D) 블록 단위 뷰 조립 + 각 블록 내부 텍스트는 마크다운→NSAttributedString**.
- 이유: "메시지 블록 / 접을 수 있는 도구 카드 / 코드 카드"라는 구조는 본질적으로 **이질적 블록의 세로 스택**이다. 디스클로저·복사버튼·비용배지 같은 인터랙티브 요소를 블록마다 붙이려면 단일 TextView보다 블록 컴포넌트가 자연스럽다.
- 코드블록 신택스 하이라이팅과 마크다운은 블록 내부에서 처리(예: `swift-markdown` 파싱 + 자체 attributed 변환, 또는 경량 하이라이터). 외부 의존성 추가 여부는 워크플로우 안 4의 라이브러리 비교 결과로 확정.
- WKWebView(B)는 마크다운/하이라이팅이 가장 쉽지만, 제로 네트워크 원칙·선택/복사·네이티브 룩·메모리(긴 대화) 측면에서 신중해야 함 → 워크플로우 결과로 trade-off 확정.

성능: 긴 대화는 블록 lazy 구성/가상화 필요. 현재도 Step 선택 시 `setRawUsageContent`로 지연 로딩 패턴을 쓰므로 같은 철학 적용.

---

## 6. 리스크 / 트레이드오프

- **범위 팽창 위험.** 마크다운+하이라이팅+diff+가상화를 한 번에 하면 큰 PR이 된다 → 7절처럼 단계 분할.
- **`showTurn`이 prompt Step만 참조하는 구조 변경** 필요(이제 `turn.steps` 전체를 렌더러에 넘김). `showStep`은 "그 Step만 강조 + 주변 맥락" 또는 기존 단일 표시 유지 중 택1 — 일관성 결정 필요.
- **스트리밍 중 스크롤 위치 보존.** 현재 `showStep`은 동일 선택 재바인드 시 re-render를 스킵해 스크롤을 지킨다([DetailViewController.swift:537](../../../Lupen/UI/Dashboard/DetailViewController.swift)). 블록 뷰에서도 diff 갱신/스크롤 앵커 보존 전략 필요.
- **마크다운 오판.** 로그/JSON 덩어리를 마크다운으로 잘못 렌더하면 깨져 보임 → 도구 출력은 마크다운 미적용(코드로), 답변 본문만 마크다운.
- **테스트.** 큐레이션 규칙(StepKind→표시정책)은 순수 함수로 추출해 단위테스트(이 레포의 강한 테스트 문화에 부합).

---

## 7. 단계적 실행안 (제안)

- **P0 (즉효, 작은 변경):** `showTurn`에서 Turn 전체를 하나의 읽기 흐름으로 합쳐 보여주기(프롬프트 + thinking + tool 요약 + 최종 reply). 지금의 단일 TextView로도 "(no response available)" 결함부터 제거. → 사용자가 가장 먼저 체감.
- **P1 (rich):** 마크다운 렌더 + 코드블록 하이라이팅 도입(답변 본문 한정).
- **P2 (구조):** 블록 기반 뷰로 전환 — 접을 수 있는 도구 카드 / 사고 디스클로저 / 화자 버블 / 비용 배지 / 밀도 토글.
- **P3 (심화):** diff 전용 렌더, 서브에이전트 인라인 재귀, 가상화/성능, 첨부 인라인.

---

## 8. 결론

데이터는 준비돼 있다. 해야 할 일은 **Conversation 탭을 "평문 출력기"에서 "Turn 대화 리더"로 바꾸는 표현 레이어 신설**이다.
가장 큰 즉효는 P0(Turn 선택 시 전체 흐름 표시) — 이것만으로도 "전용 앱 같다"는 인상의 절반을 가져온다. 나머지는 rich 렌더와 큐레이션으로 완성한다.
