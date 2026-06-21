# Conversation 탭 재설계 — UX/상호작용/정보설계 리뷰

관점: **읽기 경험(스캔성·위계·인터랙션·레이아웃 안정성)**
대상: 현재(main) + work_1~work_5 (총 6개 독립 구현)
작성: 2026-06-21

---

## 0. 한 줄 결론

**정보설계·인터랙션 완성도는 work_3 가 6개 중 최상**(카드 헤더 위계, LazyDisclosure, 카드→아웃라인 클릭 동기화, ScrollTarget 분기, 서브에이전트 재귀, diff before/after). 현재(main) 구현은 **Phase A/B/C까지만** 와서 위계·스캔성이 약하고, 보고된 버그 2건(너비·스크롤)이 그대로 살아 있다. **권장 베이스라인 = work_3 의 인터랙션 골격 + work_5 의 마크다운 폭 안정화 + 6개 어디에도 없는 독자 개선(턴 네비게이션·검색 점프·펼침 상태 기억·Copy as Markdown)을 얹는 것**.

---

## 1. 보고된 버그 2건 — 원인과 6개 비교

### 버그 1) 너비 고정 — detail pane 리사이즈 불가

**현재(main) 원인 (`ConversationDetailView.swift`)**
- `documentView.widthAnchor == scrollView.contentView.widthAnchor` 자체는 정상(뷰포트 추종). 진짜 문제는 두 가지가 겹친 것:
  1. **읽기 폭(reading width) 클램프가 없다.** 본문이 pane 전체 폭으로 흘러 와이드 화면에서 한 줄이 과도하게 길어진다(가독성 저하). `RenderContext.readingWidth = 620`은 선언만 돼 있고 **레이아웃에 연결돼 있지 않다**.
  2. **카드 본문의 가로 압축 저항이 통제되지 않는다.** `ConversationMarkdownView`의 `CodeBlockView`/`MarkdownTableView`(NSGridView)와 `DetailStyles.makeSelectableValueLabel`은 내재 폭(intrinsic width)이 커서, 코드/표/긴 토큰이 있으면 스택의 fitting width가 뷰포트보다 커진다. `documentView.width == contentView.width`가 있어도 내부 콘텐츠가 우선순위로 버티면 **pane을 줄여도 콘텐츠가 안 줄어드는 것처럼** 보인다(가로 스크롤/잘림).

**6개 비교**

| 구현 | 읽기 폭 클램프 | 폭 우선순위 처리 | 평가 |
|---|---|---|---|
| **main** | ❌ 없음(상수만 존재) | ❌ 카드 압축 저항 미설정 | 🔴 풀폭 흐름 + 코드/표가 폭을 밀어냄 |
| work_1 | △ `clampToReadingWidth` 플래그는 있으나 `addArranged`가 실제로 max-width 제약을 **안 건다**(`readingWidthConstraints` 항상 빈 배열) | ❌ | 🟡 의도만 있고 미구현(데드코드) |
| work_2 | ✅ 마크다운 노드별 `lessThanOrEqual readingWidth` | △ 노드 단위라 일관성 흔들림 | 🟡 |
| **work_3** | ✅ `stackView.width ≤ readingWidth` + 카드 `setContentCompressionResistancePriority(.defaultLow)` + `Hugging .defaultLow` | ✅ 카드가 폭 양보 | 🟢 **가장 견고** |
| work_4 | △ 노드별 `shouldClampReadingWidth`(문단만 클램프, 코드/표 제외) | △ | 🟡 선택적 클램프 — 표가 넘칠 수 있음 |
| **work_5** | ✅ `outerStack.width ≤ readingWidth` + `defaultHigh` preferred(= width − inset*2) | △ 카드 압축 저항 명시 없음 | 🟢 센터드 컬럼 안정 |

**최선:** **work_3** (max-width 클램프 + 카드의 압축 저항/허깅을 `.defaultLow`로 낮춰 "콘텐츠가 절대 pane을 못 밀게" 한 것이 핵심). work_5의 `defaultHigh` preferred-width 패턴은 센터드 정렬과 함께 쓰면 더 안정적.

**현재 구현 권장 수정 (최소 diff)**

```swift
// ConversationDetailView.setup() — documentView.width == contentView.width 는 유지하고,
// 스택에 "최대 읽기 폭 + 약한 선호 폭 + 센터" 3종을 추가한다.
let preferred = stack.widthAnchor.constraint(
    equalTo: documentView.widthAnchor, constant: -DetailStyles.horizontalInset * 2)
preferred.priority = .defaultHigh
NSLayoutConstraint.activate([
    stack.topAnchor.constraint(equalTo: documentView.topAnchor),
    stack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
    stack.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor,
                                   constant: DetailStyles.horizontalInset),
    stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor,
                                    constant: -DetailStyles.horizontalInset),
    stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620),   // Q4 읽기 폭
    preferred,
    stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
])
```
```swift
// CardContainerView.setup() 끝에 — 콘텐츠가 pane을 밀지 못하게.
setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
setContentHuggingPriority(.defaultLow, for: .horizontal)
```
> 코드블록/표는 자체적으로 가로 스크롤(NSScrollView 래핑) 또는 `lineBreakMode = .byTruncatingTail` + 펼치면 전체로 두는 게 정석. 표(NSGridView)는 `grid.column(at:).width` 대신 셀에 `maximumNumberOfLines`/wrapping을 줘서 폭 폭주를 막는다.

---

### 버그 2) Step 선택 시 항상 top — 해당 카드로 스크롤 안 됨

**현재(main) 원인**
- 블록은 `isHighlighted`를 들고 있지만, `configure(blocks:)` 끝에서 **무조건 `documentView.scroll(.zero)`** 만 한다. 강조 카드의 위치를 계산해 스크롤하는 코드가 없다. (`DetailViewController.showStep` → `build(turn:highlight:)` 로 강조 정보는 들어오나 뷰가 무시.)

**6개 비교**

| 구현 | 강조 카드 스크롤 | 분기 처리 | 동일선택 재바인드 보존 | 평가 |
|---|---|---|---|---|
| **main** | ❌ 항상 top | ❌ | 상위 컨트롤러가 skip(부분만) | 🔴 버그 재현 |
| **work_1** | ✅ `scrollToInitialPosition`→`scroll(to:)` (rect.minY−12, maxY 클램프) | △ top/highlight 2분기 | ❌ 토글 시 top 복귀 | 🟢 |
| work_2 | ❌ 스크롤 코드 없음 | ❌ | ❌ | 🔴 main과 동일 결함 |
| **work_3** | ✅ `scrollToHighlightedCard()`: ① `sourceStepUUIDs.contains(uuid)` ② `isBlockHighlighted` ③ top 폴백 | ✅ **`.top/.highlighted/.preserve` 3분기** (필터 토글 시 `.preserve`로 위치 유지) | ✅ `.preserve` | 🟢 **최상** |
| work_4 | ❌ 항상 `scroll(.zero)` (`configure`가 `highlightStepUUID`를 받지만 무시) | ❌ | ❌ | 🔴 |
| work_5 | ❌ 항상 `scroll(.zero)` | ❌ | ❌ | 🔴 |

**최선:** **work_3.** 특히 ① stepUUID 직접 매칭 → ② isHighlighted → ③ top 의 **3단 폴백**과, **필터/모드 토글 시 `.preserve`** 로 사용자의 스크롤 위치를 안 건드리는 점이 UX적으로 결정적이다(main/4/5는 토글만 해도 top으로 튐 → 매우 거슬림).

**현재 구현 권장 수정**

```swift
// CardContainerView: 강조 여부와 step 매칭을 노출.
private(set) var isHighlighted = false
private(set) var stepUuids: [String] = []   // 블록의 stepUuid(들)

// ConversationDetailView: scroll(.zero) 자리 교체.
private enum ScrollTarget { case top, highlighted, preserve }

func configure(blocks: [ConversationBlock]) {
    rebuild(blocks)
    let target: ScrollTarget = blocks.contains(where: \.isHighlighted) ? .highlighted : .top
    apply(target)
}

private func apply(_ target: ScrollTarget) {
    layoutSubtreeIfNeeded()
    switch target {
    case .top: documentView.scroll(.zero)
    case .preserve: break
    case .highlighted:
        guard let card = cards.first(where: \.isHighlighted) else { documentView.scroll(.zero); return }
        let rect = card.convert(card.bounds, to: documentView)
        let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        let y = min(max(0, rect.minY - 12), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
```
> 핵심 디테일 2개: **(a)** 스크롤 전 반드시 `layoutSubtreeIfNeeded()`(flipped 문서뷰는 레이아웃 전 frame이 0이라 위치 계산이 틀림). **(b)** maxY 클램프(문서가 짧으면 over-scroll로 빈 영역 노출). work_1/3 모두 이 둘을 지켰다 — 현재 구현에 그대로 이식.

---

## 2. 정보 위계·스캔성 — 6개 비교

| 항목 | main | work_1 | work_2 | work_3 | work_4 | work_5 |
|---|---|---|---|---|---|---|
| 카드 헤더(역할 라벨 + 부제) | △ "You"만, assistant·tool 헤더 약함 | ✅ tier별 거터 굵기 | ✅ 디스클로저+아이콘 | ✅ **title+subtitle+거터+배경 4중 위계** | ✅ | ✅ |
| tier 시각 구분(primary/secondary) | △ 텍스트 색만 | ✅ 거터 4/3pt | ✅ | ✅ **거터+테두리+배경+제목색 다층** | ✅ | ✅ |
| 역할 색(거터) | teal/clear/orange/purple | accent/… | — | accent/secondary/yellow/teal | — | — |
| 도구 묶음 한 줄 요약 | ✅ "🔧 Read · 3개 + 첫 입력" | ✅ | ✅ | ✅ "title + N items / N failed" | ✅ | ✅ |
| **실패 카운트 강조** | ❌ | △ | △ | ✅ **"N failed" 부제** | △ | △ |
| 빈/오류 상태 | △ 폴백 평문 | ✅ emptyTurnBlock | ✅ | ✅ noTextResponse 카드 | ✅ empty 카드 | ✅ orphan 카드 |
| 강조(선택 Step) 표현 | 옅은 배경(0.18) | 거터/테두리 | 테두리 | **accent 테두리 1.5pt + accent 배경 0.12** | 배경 | 배경 |

**스캔성 최선: work_3.** 한 화면을 훑었을 때 "프롬프트 / 답변 / 도구(접힘) / 사고(접힘)"가 거터색·배경 농도·제목 무게로 즉시 분리되고, **실패한 도구는 "N failed" 부제로 빨간 신호**가 뜬다(HIG Clarity). main은 assistant 답변과 도구 카드가 같은 평면으로 읽혀 위계가 약하다.

**차용 포인트(현재 구현에):**
- 카드 헤더를 `title + subtitle` 2-슬롯으로(현재 "You" 단독 → "You" / "Assistant · model" / "Read · 3 items" / "Bash · **2 failed**").
- 강조를 배경 알파만이 아니라 **accent 테두리**까지(저시력·고대비 모드에서 배경 알파는 거의 안 보임 — 현재 0.18 + selectedContentBackgroundColor 조합은 대비 부족).

---

## 3. 접기/펼치기 인터랙션

| 항목 | main `DisclosureCardView` | work_3 `LazyDisclosureView` | work_5 `DisclosureCardBodyView` |
|---|---|---|---|
| Lazy 본문 생성 | ✅ | ✅ | ✅ |
| 클릭 타깃 | 헤더 NSStackView + GestureRecognizer | **NSButton(role=.disclosureTriangle)** | NSButton |
| 접근성 role | ❌ (제스처라 VoiceOver가 토글로 안 읽음) | ✅ `.disclosureTriangle` + "expanded/collapsed" 라벨 | ✅ |
| 키보드 토글(Space/Enter) | ❌ 제스처는 키보드 불가 | ✅ NSButton이라 기본 키 지원 | ✅ |
| 부제(요약) | ✅ 한 줄 truncate | ✅ title+subtitle | ✅ |

**최선: work_3 / work_5 (NSButton + disclosureTriangle).** **현재의 `NSClickGestureRecognizer` 방식은 키보드·VoiceOver로 펼칠 수 없는 접근성 결함** — HIG/접근성 위반이다. NSButton(`isBordered=false`, `role=.disclosureTriangle`)으로 바꾸면 클릭·Space·Enter·VoiceOver가 공짜로 따라온다.

```swift
// main DisclosureCardView 개선: chevron+label 대신 NSButton 헤더.
let header = NSButton()
header.isBordered = false
header.alignment = .left
header.target = self; header.action = #selector(toggle)
header.setAccessibilityRole(.disclosureTriangle)
header.attributedTitle = summaryWithChevron  // "▸ 🔧 Read · 3개"
// toggle()에서 chevron(▸/▾) 갱신 + accessibilityLabel "..., collapsed/expanded"
```

> 펼침 애니메이션: 6개 모두 즉시 토글(애니메이션 없음). **Reduce Motion 존중 차원에선 OK**지만, 가능하면 `NSAnimationContext`로 높이 페이드(120ms)를 주되 `accessibilityDisplayShouldReduceMotion`이면 생략하는 게 Notes/Xxcode 수준. (선택)

---

## 4. 도구 묶음·사고·서브에이전트·diff 표현 (큐레이션 깊이)

| 표시 대상 | main | work_3 | work_4 | work_5 |
|---|---|---|---|---|
| ToolGroup 입력/출력 상세 | △ inputSummary + result 한 줄 | ✅ **Input/Output 섹션 + raw JSON pretty-print** | ✅ | ✅ |
| Thinking | ✅ secondary 한 줄 | ✅ | ✅ | ✅ |
| **SubAgent (재귀 트랜스크립트)** | ❌ 없음 | ✅ **재귀 빌드 + depth 가드** | ✅ | ✅ |
| **Diff (before/after)** | ❌ 없음 | ✅ **2열 비교 + +N/−N 부제** | ✅ | ✅ |
| Attachment 카드 | ❌ | ✅ | ✅ | ✅ |
| Raw JSON 폴백(toolUseId 매칭) | ❌ | ✅ `rawJSONForStepUUID` 주입 | △ | △ |

**최선: work_3.** 서브에이전트를 **같은 StoryBuilder로 재귀 렌더**(depth 가드로 무한루프 차단)하는 설계가 탁월하다 — 사용자가 "오케스트레이터가 무엇을 위임했나"를 카드 안에서 펼쳐 본다. Diff는 before/after 2열 + `+N −N` 부제로 코드 변경을 한눈에. main은 이 셋(SubAgent/Diff/Attachment)이 전부 없어 Phase D 갭이 크다.

**차용 우선순위:** SubAgent > Diff > Attachment (Claude Code/Codex 세션 분석 도구의 핵심 가치가 "위임·파일변경 추적"이므로).

---

## 5. plan 너머 — 6개 어디에도 없는 독자 개선

> 6개 전부 미구현. 비용 분석 + 대화 리더라는 Lupen 정체성에 맞춰 제안.

### (A) Turn/Step 네비게이션 — ⌘↑/⌘↓ 또는 J/K
긴 세션에서 카드 스택만으로는 "다음 프롬프트로" 이동이 느리다. **primary 카드(프롬프트·답변·상태) 사이를 키보드로 점프**하고, 점프 시 해당 카드를 강조+스크롤(버그2 수정분 재사용).
```swift
override func keyDown(with e: NSEvent) {
    switch e.charactersIgnoringModifiers {
    case "j": focusNextPrimaryCard()
    case "k": focusPrevPrimaryCard()
    default: super.keyDown(with: e)
    }
}
// focus = 강조 테두리 이동 + apply(.highlighted) 재사용
```

### (B) 인-컨버세이션 검색 + 점프 (⌘F)
NSScrollView 상단에 NSSearchField 오버레이 → 매칭 카드 강조 + 다음/이전(↩/⇧↩) 점프 + 매칭 수 표시. 접힌 도구/사고 카드 안에 매치가 있으면 **자동 펼침 후 점프**(핵심 차별점 — "검색 내 점프"). 데이터는 이미 카드별 `plainTextFallback`/blockID가 있어 인덱싱이 쉽다.

### (C) 펼침 상태 기억 (per-step persistence)
work_3가 `.preserve`로 스크롤은 보존하지만, **어떤 disclosure를 펼쳐뒀는지**는 6개 모두 재바인드 시 초기화된다. Step 전환 후 돌아오면 다시 다 접힌다 → 거슬림.
- `DisclosureCardView`에 `persistenceKey`(= blockID) 부여, `Set<String> expandedKeys`를 뷰모델/Defaults에 저장, 빌드 시 복원.

### (D) Copy as Markdown (Turn 전체)
plan(line 283)이 "블록 통선택 대신 Copy as Markdown" 으로 못박았으나 **6개 다 미구현**. Turn → 마크다운 직렬화(프롬프트 `> `, 답변 그대로, 도구 `<details>`)를 ⌘C(빈 선택 시) 또는 우클릭 메뉴로.
```swift
override func menu(for event: NSEvent) -> NSMenu? {
    let m = NSMenu()
    m.addItem(withTitle: "Copy Turn as Markdown", action: #selector(copyTurnMarkdown), keyEquivalent: "")
    return m
}
```
StoryBuilder 결과를 그대로 직렬화하므로 큐레이션과 1:1로 맞는다(보이는 것 = 복사되는 것).

### (E) 비용 인레이(Lupen 고유 가치)
답변 카드 헤더 부제에 **이 Turn의 cost/tokens 미니 배지**(`AssistantTextBlock`이 이미 `cost`/`tokens` 보유). work_3가 SubAgent 부제에 `$cost`를 넣은 패턴을 답변 카드에도 일반화 → "어느 답변이 비쌌나"를 스캔으로 파악(메모리의 SessionCostLabel 색 규칙 재사용).

### (F) "도구만/사고 숨김" 프리셋의 시각 피드백
work_1/3/4/5는 Tools/Thinking/System 체크박스 + Compact/Full 세그먼트가 있다(main엔 없음). 추가로 **현재 N개 숨김** 같은 카운트 칩을 컨트롤바에 보이면 "내가 무엇을 가렸는지" 인지 가능(과접힘으로 인한 정보 상실 방지).

---

## 6. 우선순위 정리

| # | 항목 | 우선순위 | 근거 |
|---|---|---|---|
| 1 | **버그2: 강조 카드 스크롤(work_3 ScrollTarget 3분기 이식)** | 🔴 필수 | 보고된 버그·핵심 동선. main에 스크롤 로직 자체가 없음 |
| 2 | **버그1: 읽기폭 클램프 + 카드 압축저항 .defaultLow(work_3) + 센터 컬럼(work_5)** | 🔴 필수 | 보고된 버그. 가독성·리사이즈 안정성 |
| 3 | **재바인드 시 `.preserve`(필터/모드 토글이 스크롤·강조 안 건드림)** | 🔴 필수 | 토글마다 top 튐은 치명적 거슬림. work_3만 해결 |
| 4 | **Disclosure를 NSButton(disclosureTriangle)로 — 키보드·VoiceOver 토글** | 🔴 필수 | 현재 제스처 방식은 접근성 위반 |
| 5 | 카드 헤더 title+subtitle 2슬롯 + 실패 도구 "N failed" + accent 테두리 강조 | 🟡 권장 | 스캔성·위계(work_3) |
| 6 | SubAgent / Diff / Attachment 렌더러(Phase D, work_3 차용) | 🟡 권장 | 분석 도구 핵심 가치, main 부재 |
| 7 | 펼침 상태 기억(독자 C) | 🟡 권장 | 6개 공통 약점 |
| 8 | Copy as Markdown(독자 D, plan 명시 미구현) | 🟡 권장 | plan 요구·통선택 대체 |
| 9 | Turn 네비(J/K) + ⌘F 검색 점프(독자 A·B) | 🟢 선택 | 파워유저·긴 세션 |
| 10 | 답변 카드 비용 배지(독자 E) | 🟢 선택 | Lupen 고유 차별 |

---

## 7. 종합 권고 (구현 베이스라인)

1. **인터랙션 골격은 work_3을 채택** — `ScrollTarget{top,highlighted,preserve}`, `scrollToHighlightedCard()` 3단 폴백, 카드의 `.defaultLow` 압축저항/허깅, CardContainerView의 title+subtitle+거터+배경 다층 위계, LazyDisclosure(NSButton·disclosureTriangle), SubAgent 재귀.
2. **읽기 폭은 work_5 패턴 보강** — `outerStack.width ≤ 620` + `defaultHigh` preferred(width − inset*2) + `centerX`로 와이드 화면에서 센터드 컬럼, 좁힐 때 자연 수축.
3. **현재(main)에서 살릴 것** — `ConversationBodyTextView`의 intrinsic-height 자동 사이징(검증된 패턴), `MarkdownTableView`(NSGridView), `StatusKind` 한국어 메시지(사용자 친화적 오류 카피는 main이 가장 정돈됨).
4. **6개 어디에도 없는 차별 4종**(펼침 기억 / Copy as Markdown / 검색 내 자동펼침 점프 / 답변 비용 배지)을 Phase D 이후 단계로 로드맵에 추가.
