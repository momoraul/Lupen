# Conversation 탭 재설계 — 통합 개선 로드맵 (Synthesis)

작성: 2026-06-21
입력: `review/ux-review.md`(읽기 경험·인터랙션) + `review/design-review.md`(시각·타이포·레이아웃) + 현재(main) 코드 실측
대상: 현재(main) 구현을 6개(main, work_1~5) 중 최상으로 끌어올리는 단일 로드맵
표기: 출처 = [차용:work_N] / [독자] / [유지:main]

---

## 0. 현재 코드 실측 결과 (리뷰 요약과의 차이 — 먼저 교정)

두 리뷰는 작성 시점 스냅샷 기준이라, 그 사이 main 코드가 일부 변경됐다. 로드맵은 **현재 실제 코드**를 기준으로 한다.

- **버그2(스크롤)는 "완전 미구현"이 아니라 "불완전 구현"이다.** `ConversationDetailView.configure(blocks:)` L95-100은 이미 `highlightedView`를 찾아 `documentView.scrollToVisible(rect.insetBy(dx:0, dy:-12))`를 호출한다. 그러나 (a) `insetBy(dy:-12)`는 위·아래를 동시에 넓혀 "상단 12pt 여백 오프셋"이 아니다, (b) `scrollToVisible`은 이미 보이면 스크롤하지 않아 "재선택 시 같은 카드로 재정렬"이 안 된다, (c) maxY over-scroll 클램프가 없다, (d) `.top/.highlighted/.preserve` 분기가 없다. → **work_3 수준의 명시적 분기 + minY-12 + 클램프로 교체**가 여전히 필요.
- **버그1(너비)는 리뷰 그대로 유효.** `documentView.width == contentView.width`만 있고(L67) 스택에 읽기폭 상한·선호폭·centerX가 없다. `RenderContext.readingWidth = 620`은 선언만 돼 있고 어디서도 안 쓰인다(데드 상수). `CardContainerView`에 압축저항 하향이 없다. 다만 `MarkdownTableView` 셀과 `DisclosureCardView` 요약 라벨은 이미 `.defaultLow` 압축저항을 가진다(부분 방어).
- **필터/모드 토글 자체가 main엔 없다.** 따라서 "토글 시 top 튐"은 현재 발생하지 않지만, 토글 바를 새로 도입할 때(R 단계) 반드시 `.preserve`를 함께 넣어야 회귀를 막는다.
- **같은 Step 재바인드 skip은 컨트롤러가 처리**(`DetailViewController.showStep` L536-542 `currentSelection == identity` early-return). 즉 스트리밍 갱신 시 top 튐은 이미 방지됨[유지:main]. 단, **Turn↔Step 전환·다른 Step 선택 시**엔 매번 full rebuild라 펼침 상태·스크롤이 초기화된다(P2 대상).
- **이모지 헤더는 실측 확인.** `AssistantTextCardRenderer`("✦ Assistant"), `ToolGroupCardRenderer`("🔧"), `ThinkingBlock.plainTextFallback`("💭"), `StatusKind.message`(✋⚠■✂)가 전부 이모지·기호 문자. SF Symbol 0개.
- **줄간격 미설정 확인.** `ConversationMarkdownView.bodyFont = .systemFont(ofSize:13)`만 있고 `paragraphStyle.lineHeightMultiple`이 없다. 코드블록도 동일.
- **카드 표면 부재 확인.** `CardContainerView`는 highlighted일 때만 배경(`selectedContentBackgroundColor α0.18`), 평상시 배경·보더 0. 거터는 2pt 단색·role 4색(user=teal, assistant=clear, system=orange, subAgent=purple). tier 구분 없음.
- **SubAgent/Diff/Attachment 블록·렌더러 전무.** `ConversationBlock.swift`에 `SubAgentBlock`/`DiffBlock`/`AttachmentBlock` 타입이 없고, `ConversationStoryBuilder`도 생성하지 않는다(Phase D 미착수).

---

## P0 — 버그·안정성·접근성 (반드시, 회귀 직결)

### P0-1. 강조 카드 스크롤을 ScrollTarget 3분기로 교체 [차용:work_3 + work_1]
**무엇:** `configure(blocks:)`의 `scrollToVisible(insetBy(dy:-12))`를 명시적 타깃 분기로 교체.
**왜:** 현재 (a) 12pt 상단 오프셋이 실제로는 위·아래 동시 확장이라 정렬이 어긋나고, (b) 이미 보이면 안 움직여 "다른 Step 선택→해당 카드로 점프"가 일관되지 않으며, (c) over-scroll 클램프가 없어 짧은 문서에서 빈 영역이 노출될 수 있다.
**어떻게(현재 코드 기준):**
- `CardContainerView`에 `private(set) var isHighlighted: Bool`와 `stepUuids: [String]`를 노출(렌더러가 블록에서 채움). 현재 컨테이너는 highlighted를 init에서만 쓰고 버린다 — 저장 필요.
- `ConversationDetailView`에 `private enum ScrollTarget { case top, highlighted, preserve }` 추가, 카드 배열 `private var cards: [CardContainerView]` 보관.
- `configure`는 rebuild 후 `let target: ScrollTarget = blocks.contains(where: \.isHighlighted) ? .highlighted : .top` 로 호출.
- `apply(_:)`에서 `.highlighted`는 `layoutSubtreeIfNeeded()` → `card.convert(card.bounds, to: documentView).minY` → `let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)` → `let y = min(max(0, minY - 12), maxY)` → `scrollView.contentView.scroll(to: .init(x:0,y:y))` + `reflectScrolledClipView`. (work_1의 `minY-12` + maxY 클램프, work_3의 3단 폴백 stepUUID→isHighlighted→top.)
**리스크:** 낮음. `scrollToVisible` 1줄을 함수로 대체. flipped 문서뷰라 minY 계산 좌표계는 그대로.

### P0-2. 읽기폭 클램프 + 센터드 컬럼 + 카드 압축저항 하향 [차용:work_5 폭, work_3 카드]
**무엇:** detail pane 리사이즈가 콘텐츠에 막히지 않게 하고, 와이드 모니터에서 한 줄 65~75자를 지킨다.
**왜:** 현재 본문이 pane 풀폭으로 흘러 와이드에서 "벽"이 되고, 코드/표/긴 토큰이 fitting width를 키워 pane 축소가 안 먹히는 것처럼 보인다. `readingWidth=620`은 선언만 돼 데드코드.
**어떻게(현재 코드 기준):** `ConversationDetailView.setup()`의 stack 제약을 교체 —
```
let preferred = stack.widthAnchor.constraint(
    equalTo: documentView.widthAnchor, constant: -DetailStyles.horizontalInset * 2)
preferred.priority = .defaultHigh   // 좁히면 따라 줄고
NSLayoutConstraint.activate([
  stack.topAnchor.constraint(equalTo: documentView.topAnchor),
  stack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
  stack.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: DetailStyles.horizontalInset),
  stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -DetailStyles.horizontalInset),
  stack.widthAnchor.constraint(lessThanOrEqualToConstant: renderContext.readingWidth), // 620 상한
  preferred,
  stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
])
```
그리고 `CardContainerView.setup()` 끝에 `setContentCompressionResistancePriority(.defaultLow, for: .horizontal)` + `setContentHuggingPriority(.defaultLow, for: .horizontal)`. (work_3 핵심: 콘텐츠가 절대 pane을 못 밀게.)
**리스크:** 중. 현재 `documentView.width == contentView.width`는 유지(가로 스크롤바 방지). stack의 leading/trailing `equalTo`(L70-71)를 `greaterThan/lessThan`+centerX로 바꾸는 게 핵심 변경. 코드블록 긴 한 줄은 P1-5(가로 스크롤)에서 별도 처리.

### P0-3. Disclosure 헤더를 NSButton(role=.disclosureTriangle)로 교체 [차용:work_3/work_5]
**무엇:** `DisclosureCardView`의 `NSClickGestureRecognizer`(L77) 토글을 NSButton 헤더로.
**왜:** 제스처는 키보드(Space/Enter)·VoiceOver로 펼칠 수 없는 접근성 위반. 도구·사고가 전부 secondary 접힘이라 키보드만으로 본문에 도달 불가.
**어떻게:** header NSStackView 대신 `NSButton(isBordered:false, alignment:.left)`, `setAccessibilityRole(.disclosureTriangle)`, `attributedTitle = chevron+summary`, `target/action = toggle`. `toggle()`에서 chevron(▸/▾) 갱신 + `setAccessibilityLabel(expanded ? "...,expanded" : "...,collapsed")`. lazy 본문 생성(L88-94)·`setExpandedForTesting`은 그대로 유지[유지:main].
**리스크:** 낮음. 토글 로직·lazy 빌드는 보존, 헤더 뷰만 교체.

### P0-4. 강조 표현에 accent 테두리 추가(배경 알파 단독 탈피) [차용:work_3]
**무엇:** 현재 highlighted는 `selectedContentBackgroundColor α0.18` 배경만(L33-37). accent 1.5pt 테두리를 더한다.
**왜:** 저시력·고대비 모드에서 α0.18 배경은 거의 안 보여 "선택된 Step"이 식별 불가. 접근성 + 스캔성.
**어떻게:** `CardContainerView.setup`의 highlighted 분기에 `layer?.borderWidth = 1.5; layer?.borderColor = NSColor.controlAccentColor.cgColor` 추가, 배경은 `controlAccentColor.withAlphaComponent(0.12)`로(work_3 톤). **다크↔라이트 재계산을 위해 `viewDidChangeEffectiveAppearance()`에서 layer 색 재설정**[차용:work_3] — 현재 cgColor를 init에서 굳혀 외관 전환 시 색이 안 따라오는 잠재 버그.
**리스크:** 낮음.

---

## P1 — 핵심 UX·시각 (네이티브 톤·스캔성·정보 위계)

### P1-1. 이모지 헤더 → SF Symbol + semantic tint [차용:work_1/work_2 / design-review C3]
**무엇:** ✦/🔧/💭 및 StatusKind ✋⚠■✂↻를 SF Symbol로.
**왜:** 이모지는 시스템 틴트 미적용·다크모드 대비 붕괴·VoiceOver "망치 이모지" 낭독·SF와 광학 정렬 불일치. main만 이모지 사용(나머지 5개 전부 SF).
**어떻게:** assistant=`sparkles`, tool=`wrench.adjustable`, thinking=`brain`(또는 `bubble.left`), status=interrupted `hand.raised`, apiError `exclamationmark.triangle`, stopped `stop.fill`, compacted `arrow.triangle.merge`, orphan `questionmark.circle`. `NSImage(systemSymbolName:)` + `contentTintColor`(semantic/role 색). 헤더 빌더(`ConversationCardHeader.make`)에 symbol 슬롯 추가.
**리스크:** 낮음. `StatusKind.message`의 기호는 a11y/표시 분리(아이콘은 뷰, 텍스트는 순수 문구)로.

### P1-2. 본문/코드 줄간격 + 카드 표면(role×tier) [차용:work_3/work_4 타이포, work_3 표면]
**무엇:** (a) 본문 `lineHeightMultiple 1.45`, 코드 1.30. (b) 카드에 평상시에도 role(+tier)별 미묘한 배경 틴트 + 0.5pt 보더 + cornerRadius 8.
**왜:** 현재 줄간격 시스템 기본이라 장문이 빡빡하고, 카드 표면이 없어 user/assistant/tool이 한 덩어리로 읽힌다(거터 색 바 1개에만 의존, assistant는 거터마저 clear).
**어떻게:**
- `ConversationMarkdownView.paragraphView`/`listView`/`quoteView`의 attributed string에 `NSMutableParagraphStyle().lineHeightMultiple = 1.45` 주입. `CodeBlockView` 본문은 `minimumLineHeight = maximumLineHeight = ceil(12*1.30)`[차용:work_5 고정형 — 이모지/한글 혼용 줄높이 들쭉 방지].
- `CardContainerView`에 `tier: BlockTier` 인자 추가, role×tier 매트릭스로 배경(`NSColor(name:dynamicProvider:)` 동적[차용:work_4])·거터 굵기(primary 4pt / secondary 3pt)·보더·타이틀 무게 분기. primary(user/assistant/status)는 보더+옅은 배경, secondary(tool/thinking)는 거터만+더 옅게.
**리스크:** 중. `CardContainerView` init 시그니처 변경 → 5개 렌더러 호출부 수정. 회귀 테스트로 카드 표면 가드.

### P1-3. 카드 헤더 title+subtitle 2슬롯 + 도구 "N failed" 부제 [차용:work_3]
**무엇:** 헤더를 제목+부제 2슬롯으로. ToolGroup은 "Read · 3 items" / 실패 시 "Bash · 2 failed"(빨강). assistant는 "Assistant" / "model · cost".
**왜:** 현재 ToolGroup 요약은 "🔧 Read · 3개  첫 입력" 한 줄이라 실패가 안 드러난다. 분석 도구에서 "어느 도구가 실패했나"는 1순위 스캔 신호.
**어떻게:** `ConversationCardHeader`에 subtitle 슬롯 추가. `ToolGroupBlock`은 이미 `calls[].isError` 보유 → `let failed = block.calls.filter(\.isError).count`로 부제 분기(`systemRed`). `ToolGroupCardRenderer.summary`의 inputSummary는 부제 2번째 줄 또는 펼침 본문으로.
**리스크:** 낮음.

### P1-4. 답변 카드 비용 배지(우측 정렬 monospaced + CostColor) [독자 / design-review 4-5]
**무엇:** assistant 헤더의 cost를 "✦ Assistant · model · $0.37" 텍스트 이어붙이기가 아니라, **우측 끝 monospacedDigit + `CostColor.accent` 틴트 배지**로.
**왜:** Lupen 고유 가치("어느 답변이 비쌌나"를 스캔으로). 사이드바/아웃라인 비용 색(`Lupen/UI/Support/CostColor.swift` 단일 소스)과 시각 일관. 6개 중 cost 전용 틴트한 구현 없음.
**어떻게:** `AssistantTextCardRenderer.headerText`에서 cost를 분리, 헤더 row를 `[모델 라벨 — spacer — costBadge]` 가로 스택으로. `DetailCostFormatter.format` 재사용, 색은 `CostColor.accent`(다크/라이트 동적). 0 또는 nil이면 배지 생략.
**리스크:** 낮음. 헤더 레이아웃만.

### P1-5. 코드블록: SF doc.on.doc Copy + 언어 라벨 헤더 + 긴 줄 가로 스크롤 [차용:work_2/work_3 헤더, work_5 스크롤]
**무엇:** `CodeBlockView`의 "Copy" 텍스트 버튼(L162)을 SF `doc.on.doc` 아이콘으로, 상단에 언어 라벨 헤더 추가, 긴 한 줄은 강제 래핑 대신 가로 스크롤.
**왜:** 텍스트 "Copy" 버튼은 무겁고 번역 이슈. 네이티브(Xcode/Notes)는 전부 doc.on.doc. 현재 긴 코드 한 줄은 강제 래핑돼 깨짐(P0-2 폭 클램프와 충돌). `MarkdownNode.codeBlock(lang, code)`의 lang이 현재 버려짐.
**어떻게:** Copy를 `NSButton(image: NSImage(systemSymbolName:"doc.on.doc"))` `.accessoryBar` + toolTip "Copy". 헤더 row에 `node.codeBlock`의 언어 라벨(mono 11). 본문을 `NSScrollView`(hasHorizontalScroller, 본문 NSTextView `isHorizontallyResizable`)로 감싸 긴 줄 가로 스크롤[차용:work_5]. `ConversationMarkdownView.makeView`에서 `.codeBlock(let lang, let code)` 언어 전달.
**리스크:** 중. NSTextView 가로 스크롤은 컨테이너 설정이 까다로움 — work_5 구현을 정확히 이식.

### P1-6. 표시 토글 바(Tools/Thinking + Compact/Full) + 숨김 카운트 칩 [차용:work_4 a11y, 독자 카운트]
**무엇:** ConversationDetailView 상단에 도구/사고 표시 토글 + Compact/Full 세그먼트. 옆에 "N개 숨김" 카운트 칩[독자].
**왜:** 현재 정보 밀도 조절 수단이 0 — 도구·사고 노이즈를 끌 수 없다. 토글 시 과접힘으로 정보 손실을 인지시키는 카운트 칩은 6개 어디에도 없음.
**어떻게:** `StoryBuilder.build`에 표시 옵션 파라미터 추가(또는 빌드 후 필터링). 컨트롤바는 `NSSegmentedControl`+체크박스, 각 항목 `toolTip`/`accessibilityLabel` 완비[차용:work_4]. **재바인드 시 `ScrollTarget.preserve`로 스크롤·강조 보존**(P0-1 분기 재사용) — 토글마다 top 튐 방지.
**리스크:** 중. 토글 상태 보관 위치(뷰모델/Defaults), preserve 연동.

---

## P2 — 고도화 (큐레이션 깊이·파워유저·차별화)

### P2-1. SubAgent / Diff / Attachment 렌더러(Phase D) [차용:work_3]
**무엇:** `SubAgentBlock`(재귀 트랜스크립트), `DiffBlock`(before/after 2열 + "+N −N"), `AttachmentBlock`을 블록 모델·StoryBuilder·렌더러에 추가.
**왜:** Claude Code/Codex 세션 분석 도구의 핵심 가치 = 위임·파일변경 추적. main엔 전무(Phase D 갭).
**어떻게:** SubAgent는 **같은 `ConversationStoryBuilder`로 재귀 빌드 + depth 가드**[차용:work_3] — 카드 안에서 위임 트랜스크립트를 펼침. Diff 라인은 `systemGreen/systemRed α0.12` 배경 틴트[차용:work_1 DiffLineView] + 헤더 ±컬러 배지[차용:work_4]. ToolGroup 펼침에 Input/Output 섹션 + raw JSON pretty-print[차용:work_3], `rawJSONForStepUUID` 주입.
**우선순위:** SubAgent > Diff > Attachment.
**리스크:** 높음. 새 블록 타입·빌더 분기·재귀 가드. 폴백 불변식(미등록=평문)이 안전망.

### P2-2. 펼침 상태 기억(per-step persistence) [독자 / 6개 공통 약점]
**무엇:** 어떤 disclosure를 펼쳐뒀는지 Step 전환 후 복원.
**왜:** 6개 전부 재바인드 시 disclosure가 초기화 — 도구 펼쳐 보다 다른 Step 갔다 오면 다 접힘.
**어떻게:** `DisclosureCardView`에 `persistenceKey`(= blockID, 안정적 — `ToolGroupBlock.id = "tg:anchor:name"`) 부여, `Set<String> expandedKeys`를 뷰모델 또는 Defaults에 저장, 빌드 시 복원.
**리스크:** 중. 키 안정성(StoryBuilder id가 결정적이어야 함 — 현재 anchor uuid 기반이라 OK).

### P2-3. Copy as Markdown (Turn 전체) [독자 / plan line 283 명시·6개 미구현]
**무엇:** Turn → 마크다운 직렬화를 우클릭 메뉴/⌘C(빈 선택 시)로.
**왜:** plan이 "블록 통선택 대신 Copy as Markdown"으로 못박았으나 6개 다 미구현.
**어떻게:** `StoryBuilder` 결과를 마크다운으로 직렬화(프롬프트 `> `, 답변 원문, 도구 `<details>`)하는 순수 함수 추가(테스트 용이) → `menu(for:)` + ⌘C. **보이는 것 = 복사되는 것**(현재 표시 토글 필터 반영).
**리스크:** 낮음~중.

### P2-4. Turn/Step 키보드 네비게이션(J/K 또는 ⌘↑↓) [독자]
**무엇:** primary 카드(프롬프트·답변·상태) 사이 키보드 점프 + 강조 + 스크롤.
**왜:** 긴 세션 동선 개선. P0-1 스크롤 분기를 그대로 재사용.
**어떻게:** `ConversationDetailView`를 `acceptsFirstResponder`, `keyDown`에서 j/k → `focusNext/PrevPrimaryCard()` → `apply(.highlighted)` 재사용.
**리스크:** 낮음.

### P2-5. 인-컨버세이션 검색 + 점프(⌘F, 접힌 카드 자동 펼침) [독자 / 6개 미구현]
**무엇:** NSSearchField 오버레이로 매칭 카드 강조 + ↩/⇧↩ 점프. **접힌 도구/사고 안 매치 시 자동 펼침 후 점프**(핵심 차별).
**왜:** 6개 어디에도 "검색 내 점프"가 없다. 카드별 `plainTextFallback`/blockID로 인덱싱 쉬움.
**어떻게:** 오버레이 + 매칭 인덱스, P2-1 펼침 API + P0-1 스크롤 재사용.
**리스크:** 중.

### P2-6. 긴 출력 maxHeight + 페이드 + "Show all (N lines)" [독자 / design-review 4-2]
**무엇:** 긴 도구/코드 출력에 `maxHeight ~320pt` + 하단 CAGradientLayer 페이드 + 전체 보기 링크.
**왜:** 펼친 본문이 화면을 잡아먹는 스크롤 폭주 방지 + "더 있음" 시각 신호. 어디에도 없음.
**리스크:** 중(정적 그래디언트라 Reduce Motion 무관).

### P2-7. 타임라인 연결 거터 + 강조 카드 NSVisualEffectView 머티리얼 [독자 / design-review 4-3·4-4]
**무엇:** 같은 turn의 assistant→tool→tool 거터를 세로선으로 연결(depth 표현). 강조 카드만 진짜 머티리얼 표면.
**왜:** HIG Depth 원칙. 6개 모두 단순 vertical stack·반투명 색 흉내. OK JSON 대비 차별.
**리스크:** 중~높음(거터 연결은 카드 간 좌표 계산). **강조 카드 한정** 머티리얼(성능).

---

## 종합 권고 (베이스라인)

1. **인터랙션 골격 = work_3** — ScrollTarget 3분기, 카드 `.defaultLow` 압축저항, title+subtitle+role×tier 위계, LazyDisclosure(NSButton·disclosureTriangle), 외관 재계산, SubAgent 재귀.
2. **읽기폭 = work_5** — `width ≤ 620` 상한 + `defaultHigh` 선호폭 + centerX 센터드 컬럼.
3. **시각 디테일** — 본문 1.45/코드 1.30 줄간격(work_2/3/4·고정형 work_5), 이모지→SF Symbol(work_1/2), 코드 doc.on.doc+언어 라벨(work_2/3)+긴 줄 가로 스크롤(work_5), diff 라인 틴트(work_1)+±배지(work_4), 컨트롤바 a11y(work_4).
4. **main에서 살릴 것**[유지] — `ConversationBodyTextView` intrinsic-height 자동 사이징, `MarkdownTableView`(NSGridView, 셀 압축저항 이미 적용), `StatusKind` 한국어 메시지, 컨트롤러의 same-step skip(스트리밍 top 튐 방지), **system 색 `systemOrange`(work_3/4의 systemYellow는 다크모드 대비 최악 — 채택 금지)**.
5. **6개 어디에도 없는 차별 7종**[독자] — 답변 비용 배지(P1-4), 숨김 카운트 칩(P1-6), 펼침 기억(P2-2), Copy as Markdown(P2-3), 검색 내 자동펼침 점프(P2-5), 출력 페이드 클램프(P2-6), 타임라인 연결 거터·머티리얼(P2-7).

## 권장 실행 순서

P0-1 → P0-2 → P0-3 → P0-4 (버그·접근성, 작은 diff·즉효) → P1-2 → P1-1 → P1-3 → P1-4 → P1-5 → P1-6 (네이티브 톤·위계) → P2-1(Phase D, 큰 가치) → P2-2 → P2-3 → P2-4/5/6/7(파워유저·차별).
