# Conversation 탭 재설계 — 제안서 5: 콘텐츠 추출 & 정보 설계

> 관점: **무엇을 보여줄 것인가 (큐레이션)**.
> "turn 안의 원시 이벤트(Step) 더미에서 무엇을 1급 대화로 올리고, 무엇을 노이즈로 걷어낼지"를 데이터 기반으로 정의한다.
> 작성: jaden / 일자: 2026-06-21

---

## 0. TL;DR

현재 Conversation 탭은 선택된 한 단위(Turn / Step / SkillGroup)를 **`USER` 평문 + `ASSISTANT` 평문** 두 블록으로만 보여준다(`DetailViewController.swift:1513` `ConversationDetailView.configure(humanPrompt:assistantContent:)`). Turn을 선택하면 `assistantContent`에 `nil`이 들어가기 때문에(`DetailViewController.swift:726-730`) 화면에는 거의 항상 **"(no response available)"**(`:1579`)만 남는다. 즉 Turn 단위에서는 대화가 사실상 비어 보인다.

이 제안은 데이터 모델(`Step`/`StepKind`/`ToolUseInfo`/`ToolResultInfo`/`SkillGroup`/`SubAgentGraftIndex`)을 그대로 활용해, **한 Turn을 "읽을 수 있는 스토리"로 재구성하는 큐레이션 규칙**을 정의한다. 핵심은 3-tier 점진적 공개(progressive disclosure):

- **Tier 1 (항상 표시)**: 내 프롬프트, 모델 최종 답변, 모델의 사고/설명 텍스트, 오류·중단 상태, 서브에이전트 결과 요약.
- **Tier 2 (기본 접힘, 한 줄 요약만)**: 도구 호출/결과(파일 읽기·Bash·Grep 등), thinking 블록, 첨부 묶음.
- **Tier 3 (옵션 토글 / Raw 탭으로 escape)**: 전체 도구 입출력 JSON, system-injected 메타, 압축(compact) 원문.

---

## 1. 핵심 발견 (코드 근거)

### 1.1 Step은 이미 "7종 분류 + 의미 필드"로 완전히 정규화되어 있다

`StepKind`(`StepKind.swift:5-22`)는 모든 JSONL 행을 정확히 하나로 분류한다:

| StepKind | 의미 | 핵심 필드 | 역할 |
|---|---|---|---|
| `.prompt` | 사용자 입력 (텍스트 1+, tool_result 없음). **Turn 시작** | `text`, `images`, `attachments` | 1급 |
| `.reply` | assistant + `end_turn`, 텍스트 有. **Turn 종료** | `text`, `thinkingText` | 1급 |
| `.thought` | assistant + `tool_use`, 텍스트 有 ("X 할게요" + 도구) | `text`, `toolCalls` | 텍스트=1급 / 도구=2급 |
| `.toolCall` | assistant + `tool_use`, 텍스트 없음. 순수 도구 호출 | `toolCalls` | 2급 |
| `.toolResult` | user role, tool_result만. 도구 응답 자동 주입 | `toolResult` | 2급 |
| `.stop` | assistant + `end_turn` 이외(max_tokens, refusal, API 오류…) | `text`, `stopReason` | 1급(신호) |
| `.interruption` | 사용자 Esc 중단 (`[Request interrupted by user]`) | — | 1급(신호) |

→ 큐레이션을 위한 분류기를 새로 만들 필요가 **없다**. `StepKind` + 기존 헬퍼(`StepKindStyle.textColor(for:)` 등 `StepKindStyle.swift:70-80`)가 이미 "1급 vs 종속" 구분(`labelColor` vs `secondaryLabelColor`)을 색으로 표현하고 있어, 이 분류 철학을 Conversation 탭에 그대로 이식하면 된다.

### 1.2 의미 요약은 이미 풍부하게 추출되어 있고 — 단지 버려지고 있다

- `ToolUseInfo.abbreviatedInput()`(`ToolUseInfo.swift:50-56`)와 `semanticInputSummary(...)`(`:66-119`)는 도구별로 사람이 읽을 수 있는 요약을 만든다: `Read`/`Write`→파일 경로, `Bash`→명령어, `Grep`→`/pattern/ in path`, `WebFetch`→URL, `Agent`→`타입: 설명`, `Skill`→`스킬명: args`.
- `ToolUseInfo.skillName`/`displayInputSummary`(`:28-31`)는 스냅샷 truncation에도 살아남도록 따로 보존된다.
- `ToolResultInfo.abbreviatedContent(limit:)`(`ToolResultInfo.swift:33-39`)는 첫 줄을 잘라 한 줄 요약을 준다. `isError`(`:24`) 플래그로 실패 여부도 안다.
- `Step.oneLineSummary(resolveToolName:)`(`Step.swift:394-458`)는 Turn 아웃라인 행에 쓰이는 한 줄 요약을 이미 kind별로 만들어 둔다.

→ **2급 콘텐츠의 "접힌 한 줄"은 새로 만들 필요 없이 위 메서드를 그대로 쓴다.** Conversation 탭은 이 자산을 전혀 활용하지 않고 `step.text` 평문만 이어붙이고 있다(`DetailViewController.swift:577-597`).

### 1.3 현재 Conversation 탭의 구체적 한계

1. **Turn 선택 시 답변이 빈다**: `showTurn`은 prompt 텍스트만 넘기고 `assistantContent: nil`(`:726-730`) → "(no response available)".
2. **단일 NSTextView 평문**: `ConversationDetailView`(`:1465-1466`)는 텍스트뷰 1개. 접기/펼치기·구조·인라인 도구 카드가 불가능.
3. **Step 선택 시 도구 표현이 빈약**: `→ 도구명 + input(400자)`을 평문으로 이어붙임(`:581-586`). 결과(`toolResult`)는 `↪ 이름 result\n\n내용`(`:575`).
4. **서브에이전트가 Conversation 탭에 전혀 안 보임**: 서브에이전트는 아웃라인에서 부모 Step 아래 graft되지만(`SubAgentGraftIndex.swift`), 그 내부 대화는 Conversation 탭 큐레이션에 포함되지 않는다.
5. **빈/오류 상태가 무의미**: 압축으로 사라진 Turn(`Turn.wasCompactedAway`, `Turn.swift:82-87`), API 오류(`Step.isSyntheticApiError`, `Step.swift:377-379`), 중단(`.interruption`)이 모두 "(no response available)" 같은 일반 빈 상태로 뭉개진다.

### 1.4 외부 베스트프랙티스

- **점진적 공개(Progressive Disclosure)**: 복잡도를 한 번에 쏟지 않고 단계적으로 드러낸다 — Layer 1(인덱스: 제목·타입·토큰 수) → Layer 2(상세) → Layer 3(원본). AI 에이전트 트랜스크립트 가독성의 핵심 원칙으로 일관되게 권장됨([MindStudio](https://www.mindstudio.ai/blog/progressive-disclosure-ai-agents-context-management), [Agentic Design](https://agentic-design.ai/patterns/ui-ux-patterns/progressive-disclosure-patterns), [UXPin](https://www.uxpin.com/studio/blog/what-is-progressive-disclosure/)).
- **참고 앱 패턴**: Claude Code CLI / Cursor / Codex 앱은 도구 호출을 **기본 접힌 한 줄 칩**(`● Read foo.swift (12 lines)`)으로 보여주고, 클릭 시 펼친다. 모델의 산문 답변과 thinking은 펼친 채, 도구 실행 트레이스는 접힌 채 둔다 — 정확히 본 제안의 Tier 구분과 일치.

---

## 2. 정보 설계 — Turn → "읽을 수 있는 스토리" 변환 규칙

### 2.1 큐레이션 매핑 표 (source of truth)

각 Step을 아래 표에 따라 **블록(block)**으로 변환한다. 블록 = Conversation 탭이 그리는 최소 렌더 단위.

| Step / 상황 | 추출 소스 | Tier | 기본 상태 | 렌더 형태 |
|---|---|---|---|---|
| `.prompt` (일반) | `step.text` + `step.images.count` | **1** | 펼침 | 사용자 말풍선 (전체 텍스트, 인라인 🖼) |
| `.prompt` (`isCompactSummary`) | `"↻ Compact resume"` 라벨 + `step.text`(원문) | 3 | 접힘 | 시스템 칩 "↻ 이전 대화 압축됨", 펼치면 요약 원문 |
| `.thought` 의 텍스트 | `step.text` | **1** | 펼침 | assistant 산문 |
| `.thought`/`.toolCall` 의 `toolCalls` | `ToolUseInfo.abbreviatedInput()` + 도구명 | 2 | **접힘** | 도구 칩 한 줄 (아래 2.3) |
| `.toolResult` | `ToolResultInfo.abbreviatedContent()`, `isError` | 2 | **접힘** | 직전 도구 칩에 결과 병합 (성공=↪, 실패=✗ 빨강) |
| `.reply` 의 `thinkingText` | `step.thinkingText` | 2 | **접힘** | "💭 thinking" 칩, 펼치면 전문 |
| `.reply` 의 `text` | `step.text` | **1** | 펼침 | assistant 최종 답변 (강조, markdown) |
| `.stop` (`isSyntheticApiError`) | `step.text` (오류 본문) | **1** | 펼침 | ⚠ 오류 배너 (주황) |
| `.stop` (일반) | `step.stopReason` | **1** | 펼침 | "■ 중단됨: max_tokens" 배너 |
| `.interruption` | — | **1** | 펼침 | "✋ 사용자가 요청을 취소함" 배너 (빨강) |
| `isSystemInjected == true` | — | 3 | **숨김(옵션 토글)** | 기본 비표시; "시스템 메시지 보기" 토글 시 회색 칩 |
| 서브에이전트 (sidechain) Turn | `SubAgentGraftIndex` | 2 | **접힘** | 부모 도구 칩 자리에 "🤖 에이전트: N steps, $X" 요약, 펼치면 내부 스토리 (2.4) |

### 2.2 블록 시퀀스 빌더 (의사 코드)

새 순수 헬퍼 `ConversationStoryBuilder`를 둔다. 입력은 Turn(또는 Step/SkillGroup), 출력은 `[ConversationBlock]`. 도구 호출과 그 결과를 **하나의 칩으로 병합**하는 것이 핵심(현재는 toolCall과 toolResult가 별개 Step이라 따로 떠 있다).

```
func build(turn: Turn, graft: SubAgentGraftIndex) -> [ConversationBlock] {
    var blocks: [ConversationBlock] = []
    var pendingToolCalls: [String: ToolUseInfo] = [:]   // tool_use.id → call

    for step in turn.steps where !step.isSystemInjected || showSystem {
        switch step.kind {
        case .prompt:
            blocks.append(step.isCompactSummary
                ? .compactResume(step.text)
                : .userPrompt(text: step.text, imageCount: step.images.count,
                              attachments: step.attachments))

        case .thought, .toolCall:
            if let t = step.text, !t.isEmpty { blocks.append(.assistantProse(t)) }   // Tier 1
            for call in step.toolCalls {
                if let link = graft.linksByStepUuid[step.uuid]?.first(where { matches(call) }),
                   let sub = graft.turn(forAgentId: link.agentId) {
                    blocks.append(.subAgent(summary: subAgentSummary(sub),
                                            childBlocks: build(turn: sub, graft: graft)))  // 2.4
                } else {
                    pendingToolCalls[call.id] = call
                    blocks.append(.toolCall(id: call.id, name: call.name,
                                            summary: call.abbreviatedInput(), result: nil))
                }
            }

        case .toolResult:
            // 직전 toolCall 칩과 병합 — 새 블록을 만들지 않고 result만 채운다.
            if let tr = step.toolResult, let idx = blocks.lastIndex(matching: tr.toolUseId) {
                blocks[idx].attachResult(content: tr.abbreviatedContent(),
                                         isError: tr.isError, full: tr.content)
            }

        case .reply:
            if let th = step.thinkingText, !th.isEmpty { blocks.append(.thinking(th)) }   // Tier 2
            if let t = step.text, !t.isEmpty { blocks.append(.assistantReply(t)) }        // Tier 1

        case .stop:
            blocks.append(step.isSyntheticApiError
                ? .errorBanner(step.text ?? "API Error")
                : .stopBanner(step.stopReason ?? "unknown"))

        case .interruption:
            blocks.append(.interruption)
        }
    }
    if blocks.allSatisfy(\.isMeta) { return [emptyState(for: turn)] }   // 2.5
    return blocks
}
```

`ConversationBlock`은 enum (`.userPrompt`, `.assistantProse`, `.assistantReply`, `.thinking`, `.toolCall`, `.subAgent`, `.compactResume`, `.errorBanner`, `.stopBanner`, `.interruption`)으로 두고, 각 케이스가 자기 Tier·기본 접힘 상태·아이콘(`StepKindStyle.roleSymbol`)을 안다.

### 2.3 도구 칩(tool chip)의 접힌/펼친 형태

```
접힌 상태 (기본):
  ● Read   src/Step.swift                                   ↪ 526 lines
  ● Bash   swift build                                      ✗ exit 1
  ● Grep   /showTurn/ in Lupen/UI                           ↪ 3 matches

펼친 상태 (칩 클릭):
  ▼ Read   src/Step.swift
    ├ input:  { file_path: "/Users/.../Step.swift" }
    └ output: 1  import Foundation
              2  /// Domain model for a single JSONL entry...
              … (전체 결과, ToolResultInfo.content / Raw 탭으로 escape)
```

- 좌측 글리프: `StepKindStyle.roleSymbol(for: .toolCall)` = `wrench.adjustable.fill`, 색 `secondaryLabelColor`.
- 요약 텍스트: `ToolUseInfo.abbreviatedInput(limit: 80)`.
- 우측 결과 배지: 성공 `↪ <abbreviatedContent>` (회색), 실패 `✗` (빨강, `ToolResultInfo.isError`).
- 펼침 시 input은 `ToolInputFormatter`(기존), output은 `ToolResultInfo.content`. 2KB 초과 truncation 마커가 있으면 "전체는 Raw 탭에서" 링크를 붙인다 (`ToolResultInfo.truncationMarker`, `:54`).

### 2.4 서브에이전트(5개+메인)를 부모 Turn 안에서 표현하기

`SubAgentGraftIndex`(`SubAgentGraftIndex.swift`)가 이미 `linksByStepUuid`(부모 Step → 스폰된 에이전트 링크)와 `subAgentTurnsByAgentId`(agentId → 서브에이전트 Turn)를 준다. Conversation 탭은 이를 써서 `Agent` 도구 호출 자리를 **인라인 접힌 에이전트 카드**로 치환한다.

```
접힌 상태:
  🤖 Agent · code-review   "Review the diff for bugs"        12 steps · $0.34  ▶

펼친 상태 (카드 안에 들여쓰기된 미니 스토리 — 재귀적으로 build() 호출):
  🤖 Agent · code-review                                     12 steps · $0.34  ▼
  │  USER     Review the diff for bugs                       (= 서브에이전트 prompt)
  │  ● Read   DetailViewController.swift                     ↪ 2130 lines
  │  ● Grep   /assistantContent/                             ↪ 4 matches
  │  REPLY    Found 2 issues: (1) Turn shows no response…    (= 서브에이전트 최종 답변)
```

핵심 규칙:
- 메인 스토리 흐름은 **선형 유지**. 서브에이전트는 부모의 `Agent` 도구 칩 위치에 1개의 접힌 카드로 들어간다 (병렬 5개면 5개의 카드가 연달아).
- 카드 헤더 요약 = `Agent` 도구의 `abbreviatedInput()`(에이전트 타입+설명) + 서브Turn의 `billableStepCount`(`Turn.swift:217`) + `aggregateCost`(`Turn.swift:135`).
- 펼치면 서브Turn에 대해 동일한 `build()`를 재귀 호출하되 **Tier를 한 단계 더 보수적으로** (서브에이전트의 도구 칩은 더 강하게 접고, prompt/reply만 노출). 깊이 1단계까지만 (현 CC 데이터는 sub-sub-agent 파일을 만들지 않음 — `Turn.swift:166-172` 주석 근거).
- 토큰/비용은 `aggregateCostIncludingSubAgents`가 아니라 **서브Turn 자체의 `aggregateCost`** 를 카드에 표기 (중복 카운트 방지 — `Turn.swift:128-134` 주석).

### 2.5 빈/오류 상태 처리 (현재 "(no response available)" 대체)

선택 단위가 실제로 비었을 때만 의미 있는 빈 상태를 보여준다. 케이스별 메시지:

| 상황 | 판정 근거 | 표시 |
|---|---|---|
| 압축으로 답변 소실 | `Turn.wasCompactedAway(nextTurnInSession:)` (`Turn.swift:82`) | "✂ 이 Turn의 답변은 다음 Turn으로 압축되었습니다 (자동 compact)." |
| API 오류로 종료 | `Turn.endedWithApiError` (`Turn.swift:54`) | "⚠ API 오류로 종료됨" + `step.text` 본문 |
| 사용자 중단 | `Turn.isInterrupted` (`Turn.swift:17`) | "✋ 사용자가 이 Turn을 중단함" |
| 진행 중 (마지막 Step이 toolResult/toolCall) | `!Turn.isComplete` (`Turn.swift:43`) | "⏳ 진행 중 — 아직 답변이 도착하지 않음" |
| 고아 Turn | `Turn.isOrphan` (`Turn.swift:60`) | "이 Turn은 프롬프트 없이 시작됨 (불완전 데이터)" |

→ "(no response available)"는 **삭제**. 위 판정에 모두 안 걸리고 reply가 정말 없을 때만 마지막 fallback으로 둔다.

### 2.6 첨부/이미지 인라인 배치

- prompt의 인라인 이미지: 현재처럼 🖼 글리프(`InlineImageSymbol.attachment`, `:1540`)를 사용자 말풍선 안에 인라인. 클릭 시 기존 `inlineImageProvider`로 프리뷰.
- 도구가 만진 파일 경로(`Step.attachments` 중 `toolOutput`): 해당 도구 칩 우측에 "📎 3 files" 배지. 클릭하면 Attachments 탭으로 점프(또는 칩 펼침에 경로 목록).
- prompt에 드래그된 파일/`[Image source:]`: 사용자 말풍선 하단에 "📎 파일명" 칩. 기존 `buildBodyWithImageLinks`(`:1599`)의 file:// 링크 로직 재사용.
- **전체 첨부 매니페스트는 Attachments 탭에 위임** (`Turn.allAttachments`, `Turn.swift:259`). Conversation 탭은 "흐름 안에서 어디서 등장했는가"만 인라인으로 힌트.

---

## 3. 큐레이션 단계 — 3-Tier 점진 공개 + 토글

### 3.1 Tier 매핑 요약

| Tier | 정의 | 기본 | 사용자 제어 |
|---|---|---|---|
| **Tier 1 — 대화** | 내 프롬프트 / 모델 산문·thinking 텍스트 / 모델 최종 답변 / 오류·중단·압축 신호 | 항상 펼침 | (없음) |
| **Tier 2 — 실행** | 도구 호출+결과 한 줄 칩 / reply의 thinking / 서브에이전트 카드 / 첨부 묶음 | 접힘(한 줄) | 칩 클릭 펼침 + 헤더의 "도구 펼치기" 일괄 토글 |
| **Tier 3 — 원본** | 전체 도구 입출력 JSON / system-injected 메타 / compact 원문 | 숨김 | 토글 "원본/메타 보기" + Raw 탭 escape |

### 3.2 헤더 컨트롤 (Conversation 탭 상단에 얇은 필터 바 추가)

```
┌────────────────────────────────────────────────────────────────┐
│ [▸ 도구 펼치기]  [💭 thinking]  [⚙︎ 시스템 메시지]   3 turns · 28 steps │
└────────────────────────────────────────────────────────────────┘
```

- `▸ 도구 펼치기`: Tier 2 도구 칩을 전부 펼침/접음 (기본 접힘).
- `💭 thinking`: reply의 thinkingText 표시/숨김 (기본 숨김).
- `⚙︎ 시스템 메시지`: `isSystemInjected` Step 표시/숨김 (기본 숨김).
- 우측: 선택 단위의 요약 메타 (step/turn 수). 토글 상태는 `UserDefaults`로 영속.

---

## 4. ASCII 레이아웃 스케치 — Turn 선택 시 (Before / After)

### Before (현재)

```
┌─ Conversation ────────────────────────────────────────┐
│ USER                                                   │
│ DetailViewController에서 Turn 선택 시 답변이 안 보이는…  │
│                                                        │
│ ASSISTANT                                              │
│ (no response available)            ← 항상 이 모양       │
└────────────────────────────────────────────────────────┘
```

### After (제안)

```
┌─ Conversation ─────────────────────────────────────────────────┐
│ [▸ 도구 펼치기] [💭 thinking] [⚙︎ 시스템]      1 turn · 14 steps │
│ ───────────────────────────────────────────────────────────────│
│ 🗨  USER                                                         │
│    Conversation 탭에서 Turn 선택 시 답변이 안 보이는 버그 고쳐줘  │
│    📎 screenshot.png                                            │
│                                                                 │
│ ✨  ASSISTANT                                                    │
│    원인을 찾기 위해 detail view controller를 먼저 읽을게요.       │
│                                                                 │
│    ● Read   DetailViewController.swift              ↪ 2130 lines │
│    ● Grep   /assistantContent/ in Lupen/UI         ↪ 4 matches  │
│    🤖 Agent · explore  "find render path"   8 steps · $0.21  ▶  │
│    ● Edit   DetailViewController.swift              ↪ ok        │
│                                                                 │
│    💭 thinking (펼치려면 클릭)                              ▶    │
│                                                                 │
│ ✅ REPLY                                                         │
│    showTurn이 assistantContent에 nil을 넘기고 있었습니다.        │
│    빌더를 추가해 Turn 전체를 스토리로 렌더하도록 수정했습니다.    │
└─────────────────────────────────────────────────────────────────┘
```

오류로 끝난 Turn:

```
│ ✨ ASSISTANT                                                     │
│    ● Bash   swift build                              ✗ exit 1   │
│ ⚠ 이 Turn은 API 오류로 종료되었습니다                            │
│    API Error: 529 Overloaded — please retry                    │
```

---

## 5. Lupen 현 아키텍처에서의 적용 난이도

### 5.1 변경 범위

| 작업 | 파일 | 난이도 | 비고 |
|---|---|---|---|
| `ConversationBlock` enum + `ConversationStoryBuilder` 순수 헬퍼 신설 | `Lupen/Domain/Conversation/` 신규 | 중 | 순수 함수, 단위 테스트 용이. 기존 `Step`/`ToolUseInfo` 메서드 재사용 |
| `ConversationDetailView` 를 NSTextView 1개 → 블록 렌더러로 교체 | `DetailViewController.swift:1465` | **상** | NSStackView+collapsible 행 또는 NSOutlineView. 가장 큰 작업 |
| `showTurn`이 `build(turn:)` 호출하도록 시그니처 변경 | `DetailViewController.swift:709` | 중 | 현재 `humanPrompt/assistantContent` 2-string 인터페이스를 `blocks` 인터페이스로 |
| `showTurn`에 `SubAgentGraftIndex` 전달 | `DashboardSplitViewController.swift:189` | 중 | 호출부가 이미 graft index를 보유 (아웃라인 graft용) → 그대로 넘기면 됨 |
| 헤더 토글 바 + UserDefaults 영속 | `DetailViewController.swift` | 하 | |
| 빈/오류 상태 분기 | 신규 헬퍼 | 하 | 판정 메서드 전부 `Turn`에 이미 존재 (`wasCompactedAway`/`endedWithApiError`/`isInterrupted`/`isComplete`/`isOrphan`) |

### 5.2 유리한 점

- **데이터는 100% 준비됨**: 분류(`StepKind`), 의미 요약(`abbreviatedInput`/`abbreviatedContent`/`oneLineSummary`), 서브에이전트 조인(`SubAgentGraftIndex`), 상태 판정(`Turn` 확장)이 전부 존재. 이 제안은 **표현 레이어만 바꾸는 것**이며 도메인 모델 변경이 없다.
- **스냅샷 truncation 안전**: 2급/3급 본문은 스냅샷에서 잘릴 수 있으나(`ToolResultInfo:47`, `ToolUseInfo:416`) 1급 콘텐츠(prompt/reply 텍스트)는 `Step.text`에 온전. 잘린 도구 본문은 "Raw 탭에서 전체 보기"로 escape — 이미 Raw 탭이 lazy-load(`AppStateStore.rawJSON(for:)`) 지원.
- **성능**: `build()`는 Turn당 Step 수만큼의 O(n) 순회 1회. Turn 선택 시 1회 호출이라 비용 무시 가능. 다만 `showStep`의 "동일 Step 재바인드 시 skip"(`:537-545`) 패턴은 블록 렌더에도 유지해 스트리밍 중 스크롤 튐 방지 필요.

### 5.3 리스크 & 트레이드오프

1. **NSTextView → 구조화 뷰 전환 비용이 가장 큼.** 단일 텍스트뷰의 "전체 선택·복사" UX를 잃을 수 있음. → 완화: 각 블록을 selectable NSTextView로 두거나, "대화 전체 복사" 버튼을 헤더에 제공.
2. **도구 칩 병합(toolCall+toolResult)의 매칭 실패 케이스.** `toolUseId` 매칭이 어긋나면(병렬 호출·결과 누락) 결과가 붙지 않은 칩이 남음. → 완화: 매칭 실패 시 결과를 독립 칩 "↪ orphan result"로 fallback (데이터 손실 없음).
3. **서브에이전트 재귀 펼침의 깊이/성능.** 5개 병렬 에이전트를 모두 펼치면 화면이 길어짐. → 완화: 기본 접힘 강제 + "전부 펼치기"는 도구 토글과 분리, 깊이 1단계 제한.
4. **큐레이션이 정보를 숨긴다는 인식.** 사용자가 "이 도구는 왜 안 보이지?"라 느낄 수 있음. → 완화: Tier 2는 항상 한 줄 칩으로 **존재 자체는 표시**(완전 숨김 아님), Tier 3만 토글. 그리고 Raw 탭이 최종 escape hatch.
5. **compact/orphan 판정의 cross-Turn 의존.** `wasCompactedAway`는 `nextTurnInSession`을 요구(`Turn.swift:82`) → `showTurn` 호출부가 세션 Turn 배열에서 이웃을 넘겨줘야 함. 호출부(`DashboardSplitViewController`)가 세션 컨텍스트를 가지므로 가능하나 시그니처 추가 필요.

---

## 6. 단계적 도입 권고 (점진 마이그레이션)

기존 2-string 인터페이스를 한 번에 버리지 말고:

1. **Phase A** — `ConversationStoryBuilder`(순수) + 단위 테스트만 먼저 머지. UI 무변경. 빌더 출력의 정확성(병합·서브에이전트·상태)을 corpus로 검증.
2. **Phase B** — `ConversationDetailView`를 블록 렌더러로 교체하되 Tier 1만 (도구는 한 줄 칩, 펼침 없이). 즉시 "(no response available)" 박멸 + Turn 답변 노출이라는 최대 체감 개선 달성.
3. **Phase C** — 칩 펼침 / 서브에이전트 카드 / 헤더 토글 / thinking 추가.
4. **Phase D** — 인라인 첨부 배지, compact/orphan 정밀 상태.

이렇게 하면 Phase B만으로도 사용자 요청의 본질("Turn의 대화를 전용 앱처럼")을 충족하고, 이후는 점진 강화.

---

## 7. 참고

- 진행 단계적 공개 / 트랜스크립트 가독성:
  - [MindStudio — Progressive Disclosure in AI Agents](https://www.mindstudio.ai/blog/progressive-disclosure-ai-agents-context-management)
  - [Agentic Design — Progressive Disclosure UI Patterns](https://agentic-design.ai/patterns/ui-ux-patterns/progressive-disclosure-patterns)
  - [UXPin — What Is Progressive Disclosure in UX](https://www.uxpin.com/studio/blog/what-is-progressive-disclosure/)
- 참고 앱: Claude Code CLI / Cursor / Codex 데스크톱의 "접힌 도구 칩 + 산문 답변" 패턴 (도구 트레이스는 접고 대화는 펼침).
- 코드 근거 파일: `Step.swift`, `StepKind.swift`, `Turn.swift`, `ToolUseInfo.swift`, `ToolResultInfo.swift`, `SkillGroupBuilder.swift`, `SubAgentGraftIndex.swift`, `StepKindStyle.swift`, `TurnPreview.swift`, `DetailViewController.swift`.
