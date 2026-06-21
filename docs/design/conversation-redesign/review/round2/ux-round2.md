# Conversation 탭 2차 리뷰 — UX 관점 (코드 미수정, 개선안/버그 목록)

리뷰어 관점: 상호작용 · 정보위계 · 스캔성 · 역선택(카드↔트리) · 스크롤 · 접근성
대상 코드: `/Users/user/_work/_lupen/work/Lupen/UI/Dashboard/Conversation/` + `Lupen/Domain/Conversation/Story/`
비교 기준(최상 평가 세션): `/Users/user/_work/_lupen/work_3/Lupen/UI/Dashboard/Conversation/`

**중요: 이 문서는 분석/제안만 담습니다. 코드는 수정하지 않았습니다. 메인 세션이 승인 후 적용.**

---

## 0. 한눈에 보기 (우선순위)

| # | 종류 | 우선순위 | 항목 |
|---|------|----------|------|
| B1 | 버그 | 🔴 | 카드 재구성 시 제약(leading/trailing) 미해제 → 레이아웃 누수/충돌 |
| F1 | 미구현 | 🔴 | 역선택(카드 클릭 → 트리 step 선택+스크롤) 전무 |
| D1 | 개선 | 🔴 | 중요 대화(내 프롬프트·최종 답변) 위계가 평면적 — 강조 부족 |
| B2 | 버그 | 🟡 | Disclosure 카드 펼침 시 카드 본문 텍스트 선택과 클릭 토글 충돌 |
| B3 | 버그 | 🟡 | `documentView.scrollToVisible` 하이라이트 스크롤이 빗나감(좌표/타이밍) |
| B4 | 버그 | 🟡 | CardContainerView 거터가 본문보다 짧을 때 시각적으로 끊김 |
| B5 | 버그 | 🟡 | 코드블록 `Copy` 버튼이 항상 본문 1줄 위 공간을 차지(짧은 코드에서 어색) |
| F2 | 미구현 | 🟡 | 표시 필터(Tools/Thinking/System) + Compact/Full 모드 없음 |
| B6 | 버그 | 🟢 | 빈 블록 배열일 때 "no content" 안내 카드 없음(빈 화면) |
| D2 | 개선 | 🟢 | 헤더 메타(model·cost) 단조 — 비용/모델 시각 구분 약함 |
| A1 | 접근성 | 🟡 | 카드에 accessibility role/label 없음(work_3 대비 회귀) |
| A2 | 접근성 | 🟢 | 상태 배너가 이모지에 의존(✋⚠■✂) — VoiceOver/색맹 |

---

## 1. 🔴 필수 버그

### B1. 카드 재구성 시 제약 미해제 → 제약 누수/충돌
**위치:** `ConversationDetailView.configure(blocks:)` (라인 107–119)

```swift
for view in stack.arrangedSubviews {
    stack.removeArrangedSubview(view)
    view.removeFromSuperview()
}
...
view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
```

**문제:** 매 `configure` 호출마다 새 카드를 `stack`에 leading/trailing 제약으로 묶는다. 이전 카드는 `removeFromSuperview()`로 빠지지만, **그 카드에 걸렸던 제약은 명시적으로 deactivate되지 않는다.** `removeFromSuperview()`는 superview와 직접 연결된 제약은 정리하지만, NSStackView의 `arrangedSubviews` 경유로 추가한 제약과 stack 자신을 first item으로 가진 제약의 정리 타이밍은 보장되지 않는다. Turn을 빠르게 전환(스트리밍·트리 클릭 연타)하면 dangling constraint가 쌓여 Auto Layout 경고(`Unable to simultaneously satisfy constraints`)와 폭 계산 흔들림(과거 "너비 고정 버그"와 같은 증상 재발 위험)을 부른다.

**왜 문제인지:** 사용자가 방금 잡은 "너비 고정 버그"의 재발 벡터다. 제약 누수는 간헐적이라 회귀 테스트로도 잘 안 잡힌다.

**수정 방법:** 카드를 추가하면서 만든 제약을 배열로 보관했다가 다음 재구성 때 일괄 deactivate. work_3는 이 문제를 `clearArrangedSubviews()`에서 구조적으로 회피한다(아래).

```swift
// Before: 제약을 즉석에서 .isActive로만 켬 (해제 추적 없음)
view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true

// After: 추적 후 일괄 해제
private var cardConstraints: [NSLayoutConstraint] = []

func configure(blocks: [ConversationBlock]) {
    NSLayoutConstraint.deactivate(cardConstraints)
    cardConstraints.removeAll()
    for view in stack.arrangedSubviews {
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
    }
    ...
    let c = [
        view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
    ]
    NSLayoutConstraint.activate(c)
    cardConstraints.append(contentsOf: c)
}
```

> work_3 차용점: work_3 `ConversationDetailView.addArrangedCard`는 leading/trailing만 stackView에 거는 동일 패턴이지만, `clearArrangedSubviews`에서 `renderedContainers`까지 함께 비워 상태를 한 곳에서 리셋한다. 같은 정리 지점을 두는 것이 핵심.

---

### F1. 역선택 전무 — 카드 클릭 시 트리 step 선택+스크롤 안 됨
**위치:** 현재 work에는 관련 코드가 **존재하지 않음.** `ConversationDetailView`에 `onSourceStepSelected` 콜백 없음, `CardContainerView`에 `mouseDown`/`hitTest`/`configureSource` 없음, `DetailViewController`에 `onConversationSourceStepSelected` 없음.

**문제:** 사용자가 카드(예: 모델 최종 답변)를 클릭해도 상단 Turn 아웃라인에서 해당 step이 선택/스크롤되지 않는다. 단방향(트리→카드)만 동작. 사용자가 명시적으로 요청한 핵심 인터랙션.

**work_3 전체 체인 (차용 청사진):**

1. **블록에 sourceStepUUID 노출** — work는 각 구체 블록(`UserPromptBlock.stepUuid` 등)에 이미 `stepUuid`가 있다. 다만 `ConversationBlock` 프로토콜에는 노출되지 않음. work_3처럼 `var sourceStepUUIDs: [String] { get }`를 프로토콜에 추가하면 ToolGroup(여러 step 묶음)도 일관 처리 가능.
   - ToolGroup은 `calls.map(\.stepUuid)`의 첫 유효값 또는 anchor uuid를 쓰면 됨.

2. **CardContainerView에 선택 전달 기계** (work_3 `CardContainerView` 라인 36–155 차용):
```swift
private(set) var sourceStepUUIDs: [String] = []
private var onSelectSourceStep: (([String]) -> Void)?

func configureSource(blockID: String, sourceStepUUIDs: [String],
                     onSelectSourceStep: (([String]) -> Void)?) {
    self.sourceStepUUIDs = sourceStepUUIDs
    self.onSelectSourceStep = onSelectSourceStep
    if onSelectSourceStep != nil, !sourceStepUUIDs.isEmpty {
        toolTip = "이 step을 위 목록에서 선택"
        setAccessibilityHelp("대화 목록에서 해당 step 선택")
    }
    if let body = bodyContainer.subviews.first { installSelectionForwarding(in: body) }
}

override func mouseDown(with event: NSEvent) {
    selectSourceStep(); super.mouseDown(with: event)
}

// 텍스트 선택(드래그) vs 카드 선택(클릭) 분리:
override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    guard onSelectSourceStep != nil, !sourceStepUUIDs.isEmpty else { return hit }
    // 빈 영역/거터/헤더 라벨 클릭은 카드 선택으로, 본문 텍스트는 텍스트뷰가 처리
    if hit === self || hit === gutter || hit is NSTextField { return self }
    return hit
}
```
   - **핵심:** NSTextView는 드래그 선택을 보존해야 하므로 `installSelectionForwarding`로 `ConversationBodyTextView.onMouseDown` 콜백을 심어 "클릭 즉시 선택, 드래그는 텍스트 선택"이 자연스럽게 공존한다(work_3 `installSelectionForwarding` 라인 146–155). work의 `ConversationBodyTextView`에는 현재 `onMouseDown`이 없으니 work_3 `ConversationTextView`의 `mouseDown` 오버라이드(라인 44–47)를 이식해야 한다.

3. **ConversationDetailView에 콜백 노출** (work_3 라인 26, 140–143):
```swift
var onSourceStepSelected: (([String]) -> Void)?
// 카드 생성 시:
(view as? CardContainerView)?.configureSource(
    blockID: block.id,
    sourceStepUUIDs: block.sourceStepUUIDs,
    onSelectSourceStep: { [weak self] in self?.onSourceStepSelected?($0) }
)
```

4. **DetailViewController → Split → Outline 전달** (work_3 `DetailViewController` 569–570, `DashboardSplitViewController` 209–210):
```swift
// DetailVC.showStep/showTurn 안에서 turn을 캡처:
conversationView.onSourceStepSelected = { [weak self, turn] uuids in
    self?.onConversationSourceStepSelected?(turn, uuids)
}
// Split:
detailVC.onConversationSourceStepSelected = { [weak self] turn, uuids in
    self?.turnOutlineVC.selectSourceStepUUIDs(uuids, in: turn)
}
```
   - **주의(회귀 방지):** `showStep`의 "동일 Step 재바인드 스킵"(work `DetailViewController` 라인 536–542) 때문에, 역선택으로 트리가 같은 step을 다시 통지하면 카드가 재렌더되지 않는다. 이는 **의도된 동작**(스크롤 점프 방지)이지만, 트리 선택 변경 → 카드 하이라이트 갱신이 안 되는 부작용이 생긴다. work_3는 outline이 `notifySelection`으로 step을 다시 통지하고(라인 1794), 같은 step이면 `configure`가 스킵되어도 트리 쪽 선택/스크롤은 이미 끝나 있으므로 일관적이다. work에서도 "트리 선택+스크롤"은 outline이 책임지고, 카드 하이라이트는 동일 step이면 그대로 두는 정책이 맞다.

5. **Outline 측 step 선택+스크롤** (work_3 `TurnOutlineViewController.selectSourceStepUUIDs` 라인 1741–1794): `identityKey(forStepUUID:)`로 행을 찾아 `selectRowIndexes` + `scrollRowToVisible`. work의 outline 컨트롤러에 동등 메서드가 있는지 확인 필요(없으면 신규). uuid→row 매핑이 핵심.

**기대 효과:** 양방향 동기화 — 긴 답변 카드를 보다가 클릭 한 번으로 트리 위치를 잡고, 거기서 Tokens/Raw 탭으로 점프하는 흐름이 완성된다. OK JSON·Xcode 디버거의 "양쪽 패널 연동" 표준 패턴.

---

### D1. 중요 대화 위계가 평면적 — 강조 부족 (가독성 핵심)
**위치:** `CardContainerView.surfaceColor`/`accentColor` (라인 93–111), `ConversationCardHeader.make` (라인 132–145)

**현재 상태 분석:**
- 모든 카드가 동일한 `cornerRadius 8`, 동일한 본문 폰트 size 13, 동일한 패딩(top/bottom 8, body 13pt)을 쓴다.
- primary(프롬프트·답변)와 secondary(도구·사고)의 시각 차이가 **표면 틴트 alpha(0.06)와 보더 두께(0.5)뿐**이라 스크롤하면 카드들이 한 덩어리로 읽힌다.
- 헤더는 11pt semibold 한 줄로 모든 역할이 동일 — "You"와 "Assistant"가 같은 무게.

**왜 문제인지:** Conversation 탭의 목적은 "내가 뭘 물었고 모델이 뭐라 답했나"를 빠르게 훑는 것이다. 현재는 도구 호출 한 줄과 모델 최종 답변이 같은 시각 무게라 눈이 닻을 내릴 지점이 없다(스캔성 실패).

**수정 방법 — tier 기반 위계 강화 (work_3 패턴 차용):**

work_3 `CardContainerView`는 **tier를 1급 시민으로** 다룬다:
- 보더 두께: `isHighlighted ? 1.5 : (tier == .primary ? 0.75 : 0.4)` (라인 92)
- 거터 폭: `tier == .primary ? 4 : 3` (라인 128)
- contentStack 내부 간격: `tier == .primary ? 9 : 7` (라인 111)
- 표면 alpha를 tier로 분기: user primary 0.085 / secondary 0.035 (라인 211–220)
- 제목 색을 tier로: primary `.labelColor`, secondary `.secondaryLabelColor`, hidden `.tertiaryLabelColor` (라인 223–232)

work에 이식할 구체안:

```swift
// CardContainerView가 tier도 받도록 확장
init(role: BlockRole, tier: BlockTier, highlighted: Bool)

// 1) 보더/거터/표면을 tier로 분기
layer?.borderWidth = highlighted ? 1.5 : (tier == .primary ? 0.75 : 0.4)
gutter.widthAnchor.constraint(equalToConstant: tier == .primary ? 4 : 3)

static func surfaceColor(role:tier:highlighted:) -> NSColor {
    if highlighted { return accentColor(for: role).withAlphaComponent(0.12) }
    let a: CGFloat = tier == .primary ? 0.085 : 0.030
    switch role { ... withAlphaComponent(a) }
}
```

추가로 **본문 폰트로 위계 한 단계 더** (work의 강점인 마크다운 렌더와 결합):
- 모델 최종 답변(AssistantText) primary 본문: 13pt 유지하되 줄간격을 `paragraphStyle.lineHeightMultiple = 1.4`로 넉넉히 → 긴 답변 가독성↑ (현재 줄간격 기본값이라 빽빽함; 메모리의 "읽기폭620/줄간격1.45" 정석과도 일치).
- 도구/사고 secondary: 12pt + secondaryLabel (이미 일부 적용).

**프롬프트 카드 추가 강조:** "You" 헤더가 모델 답변과 같은 무게라 내 발화가 묻힌다. user 역할 거터를 4pt + accent(teal)로, 표면 alpha를 0.085로 올리면 스크롤 중 "내 질문 위치"가 닻 역할을 한다. (단, 메모리 노트: systemTeal vs accent 혼용 주의 — 아래 D2 참고.)

**기대 효과:** 스크롤 시 프롬프트→답변→프롬프트 리듬이 시각적으로 잡혀, 도구/사고는 배경으로 가라앉는다. 정보위계 명확화(HIG Clarity).

---

## 2. 🟡 권장 버그/개선

### B2. Disclosure 펼침 본문의 텍스트 선택 vs 토글 클릭 충돌
**위치:** `DisclosureCardView` (라인 77 header 제스처) + `ThinkingCardRenderer`/`ToolGroupCardRenderer`의 본문이 `ConversationBodyTextView`(selectable)

**문제:** Thinking 카드를 펼치면 본문이 `ConversationBodyTextView`(isSelectable=true). 그런데 F1을 적용해 `CardContainerView`에 `mouseDown` 선택 전달을 붙이면, 펼친 본문 텍스트를 드래그 선택하려는 동작이 카드 선택(역선택)과 경합한다. 현재도 header 클릭 영역과 본문 클릭 영역의 경계가 모호(둘 다 같은 카드 안).

**수정 방법:** F1의 `hitTest`에서 NSTextView는 `return hit`(텍스트뷰가 처리)로 두고, `installSelectionForwarding`의 `onMouseDown`은 "클릭만, 드래그 아님"을 구분하지 않으므로 — work_3처럼 mouseDown 즉시 콜백을 호출하되 텍스트 선택을 막지 않는(`super.mouseDown` 호출 유지) 방식이 안전하다. 단 Disclosure 토글 영역(chevron+summary)과 본문 영역의 z-order를 명확히 분리할 것.

### B3. 하이라이트 스크롤이 빗나감
**위치:** `ConversationDetailView.configure` 라인 123–128

```swift
let rect = highlightedView.convert(highlightedView.bounds, to: documentView)
documentView.scrollToVisible(rect.insetBy(dx: 0, dy: -12))
```

**문제 1 (좌표):** `scrollToVisible`는 "보이면 스크롤 안 함"이라 카드가 일부만 보여도 상단 정렬이 안 된다. 사용자가 기대하는 "선택 step을 상단 근처로" 동작이 아니다.
**문제 2 (타이밍):** `layoutSubtreeIfNeeded()` 직후라도 NSStackView 내부 텍스트뷰의 intrinsic height가 비동기로 확정되는 경우 rect가 부정확.

**수정 방법(work_3 `scroll(to:)` 차용 — 라인 280–292):** `scrollToVisible` 대신 명시적 offset 계산.
```swift
layoutSubtreeIfNeeded()
documentView.layoutSubtreeIfNeeded()
stack.layoutSubtreeIfNeeded()
let rect = highlightedView.convert(highlightedView.bounds, to: documentView)
let visibleH = scrollView.contentView.bounds.height
let docH = max(documentView.bounds.height, stack.fittingSize.height)
let targetY = min(max(0, rect.minY - 12), max(0, docH - visibleH))
scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
scrollView.reflectScrolledClipView(scrollView.contentView)
```
work_3는 3단계 layout 강제 + clamped targetY로 "항상 상단 12pt 여백"을 보장한다. 또한 work_3는 `documentView.scroll(.zero)` 대신 `scrollView.contentView.scroll(to:)` + `reflectScrolledClipView`를 쓴다 — 스크롤러 위치까지 동기화되어 더 안정적.

### B4. 거터가 본문보다 짧을 때 시각적 끊김
**위치:** `CardContainerView` 라인 50–53. 거터 top/bottom을 카드 top+8 / bottom-8에 고정.

**문제:** 거터를 카드 전체 높이(−16)에 묶는데, work_3는 `gutter.heightAnchor >= 20`만 두고 top 정렬한다. 짧은 카드(1줄 상태 배너)에서 현재 방식은 거터가 8pt까지 줄어 점처럼 보인다. 역할 색 띠로서의 식별 기능이 약해진다.

**수정 방법:** 거터 최소 높이 보장(`heightAnchor >= 20`) + top 정렬, 또는 현재 full-height 유지하되 최소높이 추가.

### B5. 코드블록 Copy 버튼이 항상 한 줄 위 공간 점유
**위치:** `ConversationMarkdownView.CodeBlockView.setup` 라인 168–176

```swift
text.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 2)
copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 6)
```

**문제:** 겹침은 해결됐지만(사용자 확인), 이제 모든 코드블록이 본문 위에 Copy 버튼 높이만큼 빈 공간을 갖는다. 한 줄짜리 코드에선 버튼이 코드보다 커 보여 어색.

**수정 방법(권장):** Copy 버튼을 우상단 **오버레이**로 띄우되, 기본 숨김 → 카드 hover 시 페이드인(NSTrackingArea). 본문은 top부터 시작. macOS의 Xcode/Notes 코드블록, GitHub 코드 패널이 쓰는 표준. 본문과 겹치지 않게 본문 trailing에 버튼 폭(+여백)만큼 inset을 주거나, 버튼이 짧은 첫 줄을 가리지 않도록 우상단 16pt 안전영역만 확보.

### F2. 표시 필터(Tools/Thinking/System) + Compact/Full 모드 없음
**위치:** work에는 `ConversationDisplayPreferences` 자체가 없음. work_3는 `ConversationDetailView` 상단에 controlsBar(체크박스 3개 + Compact/Full 세그먼트)를 둔다(라인 99–121).

**문제:** 현재 work는 빌더가 secondary를 항상 접힌 한 줄로 내보내지만, 사용자가 "도구 다 숨기고 대화만" 또는 "전부 펼쳐" 같은 모드 전환을 못 한다. 긴 세션에서 도구 노이즈를 끄는 건 스캔성의 핵심.

**수정 방법:** work_3 `ConversationDisplayPreferences`(UserDefaults 백업) + `shouldShow(_:)` 필터 그대로 이식. Compact = 프롬프트+답변만, Full = 전부. 상단 controlsBar는 Conversation 탭 안에 두되 detail 헤더 높이를 침범하지 않게 배치.

**기대 효과:** "대화만 빠르게 읽기"(Compact)와 "전체 추적"(Full) 두 모드. 메모리의 "role×tier 표면" 정석을 사용자가 직접 제어.

---

## 3. 🟢 선택 개선

### B6. 빈 블록 배열 → 빈 화면
**위치:** `ConversationDetailView.configure` — `blocks`가 비면 stack이 텅 빈다. `showRequest`는 `configure(blocks: [])`를 명시 호출(work `DetailViewController` 라인 511).

**문제:** 레거시 request 선택 시 Conversation 탭이 완전 백지. "(no response available) 박멸"이 목표였는데 빈 화면은 그보다 나쁘다.
**수정 방법(work_3 차용 — 라인 149–158):** blocks가 비면 `StatusBlock`(예: "이 선택에는 표시할 대화가 없습니다") 안내 카드를 1개 렌더.

### D2. 헤더 메타(model·cost) 단조 — 비용 시각 구분
**위치:** `AssistantTextCardRenderer.headerText` 라인 35–45. `"Assistant · opus-4-8 · $0.37"`를 한 색(controlAccentColor)으로 연결.

**문제:** model과 cost가 같은 색·무게라 비용이 눈에 안 띈다. Lupen은 "비용 분석" 앱인데 대화 탭에서 비용이 묻힘.
**수정 방법:** "Assistant"는 accent, model은 secondaryLabel, cost는 monospacedDigit + 약한 강조색. work_3 headerView가 title(semibold) / subtitle(tertiaryLabel) 2단으로 나눈 패턴(라인 182–202)을 참고하되, cost만 별도 틴트.

> **메모리 주의(NSColor):** `CardContainerView.accentColor`가 user=systemTeal, assistant=controlAccentColor를 쓴다. 메모리 노트(`nscolor-darkmode-values`)대로 systemTeal/accent가 다크모드에서 인접 색조로 혼동될 수 있으니, user는 systemTeal 유지하되 cost 강조는 systemGreen 등 명백히 다른 색조로 분리 권장. 또 work_3는 system 역할에 systemYellow를 쓰는데, 메모리상 systemYellow는 다크 대비 최악이라 work의 systemOrange 선택이 더 낫다(work 유지 권장).

### A1. 카드 accessibility role/label 부재 (work_3 대비 회귀)
**위치:** work `CardContainerView`에 NSAccessibility 호출 전무. work_3는 `setAccessibilityElement(true)` + `.group` role + title/subtitle 합성 label(라인 94–96, 171–176).

**수정 방법:** 카드에 `setAccessibilityRole(.group)`, `setAccessibilityLabel("You: <프롬프트 요약>")` / `"Assistant, opus-4-8, $0.37"`. F1의 역선택을 붙이면 `setAccessibilityHelp("해당 step 선택")`도 함께.

### A2. 상태 배너가 이모지에 의존
**위치:** `StatusKind.message` (ConversationBlock.swift 라인 137–151) — ✋⚠■✂🔧💭 등 이모지 프리픽스.

**문제:** 메모리 노트(`emoji-status-accessibility`)대로 이모지 단독은 VoiceOver에서 "손 들기 이모지"처럼 읽히고 색맹/저시력에서 의미 전달 실패. work의 `ConversationInlineText.symbolPrefixed`는 이미 SF Symbol 경로가 있는데, StatusKind.message는 이모지를 쓴다(불일치).
**수정 방법:** StatusBannerRenderer에서 메시지 텍스트는 이모지 없이 두고, `symbolPrefixed`로 SF Symbol(예: interrupted=`hand.raised.fill`, apiError=`exclamationmark.triangle.fill`, compacted=`scissors`)을 색과 함께 붙인다. 이미 work에 헬퍼가 있어 비용 적음.

---

## 4. work_3 대비 work의 강점(유지할 것)

work가 더 나은 부분도 명시 — 무분별한 work_3 차용 금지.

1. **마크다운 블록 렌더**: work는 `ConversationMarkdownView`로 테이블(NSGridView)·코드블록·리스트·인용·헤딩을 노드별 전용 뷰로 그린다. work_3의 `ConversationTextBuilder`는 attributed string 단일 빌드라 표/코드블록 구조 표현이 약하다. **work의 마크다운 렌더가 우위 — 유지.**
2. **확장 가능한 렌더러 레지스트리 + 폴백 불변식**: `BlockRendererRegistry`의 ObjectIdentifier 매핑 + `PlainTextBlockRenderer` 폴백은 안전하고 깔끔. 빈 화면/크래시 방지 설계가 좋다.
3. **systemOrange(system 역할)**: work_3의 systemYellow보다 다크 대비가 낫다(메모리 일치).
4. **lazy disclosure**: `DisclosureCardView`가 펼칠 때만 본문 생성(성능 게이트) — work_3 `LazyDisclosureView`와 동급.

**결론:** work_3에서 가져올 것은 (1) 역선택 체인 전체(F1), (2) tier 기반 위계(D1), (3) scroll(to:) 정밀화(B3), (4) 표시 필터(F2), (5) accessibility(A1). work_3에서 **가져오지 말 것**: 마크다운을 attributed 단일 빌드로 되돌리는 것, system=systemYellow.

---

## 5. 적용 순서 제안 (의존성 고려)

1. **B1**(제약 누수) — 독립적, 즉시. 다른 작업의 토대.
2. **D1**(tier 위계) + **B4**(거터) — `CardContainerView`를 함께 손대므로 묶음. tier 파라미터 추가.
3. **F1**(역선택) — `CardContainerView`(mouseDown/hitTest) + `ConversationBodyTextView`(onMouseDown) + `ConversationDetailView`(콜백) + `DetailViewController`/Split/Outline. 가장 큰 작업, B1/D1 이후.
4. **B3**(스크롤) — F1의 sourceStepUUIDs 매칭과 함께 정리하면 자연스러움.
5. **B2**(선택 충돌) — F1 적용 직후 검증.
6. **F2**(필터) + **B6**(빈 상태) — 독립.
7. **A1/A2/D2/B5** — 마감 디테일.
