# Conversation 리더 — 라운드2 통합 실행안 (승인용)

작성: jaden / 2026-06-21
범위: `Lupen/UI/Dashboard/Conversation/` + `Lupen/Domain/Conversation/Story/`
입력: `ux-round2.md`(UX 관점) + `design-round2.md`(디자인 관점) + 본 통합 세션의 코드 정독·교차검증.
비교 기준: `work_3`(최상 평가 세션).

**중요: 이 문서는 버그/개선 목록일 뿐, 코드는 수정하지 않았다. 메인 세션이 사용자 승인 후 적용.**

코드 정독으로 두 리뷰의 주장을 모두 교차검증했고, 추가로 자체 발견한 버그(아래 A* 신규 항목)를 더했다.
중복 항목은 한 줄로 병합하고, 두 리뷰가 어긋나는 지점은 "판정"으로 결론을 냈다.

---

## A. 버그 수정 목록 (즉시 적용 후보 — 시각/로직 명백)

> 이 섹션은 "명백한 결함/회귀 위험"이라 비교적 저위험으로 바로 고칠 수 있는 후보다.
> 단, B1·B-scroll처럼 `CardContainerView`/`configure`를 함께 손대는 것은 B섹션(위계) 작업과
> 묶는 것이 효율적이므로 적용 순서에서 조정.

### A-P0

**A1. configure() 카드 제약 누수 — 빠른 Turn 전환 시 dangling constraint 누적**
- 무엇: `ConversationDetailView.configure`(라인 107–119)는 매 호출마다 새 카드에
  `view.leadingAnchor/trailingAnchor.constraint(...).isActive = true`를 건다(라인 116–117).
  이전 카드는 `removeFromSuperview()`로 빠지지만, **stack을 first item으로 가진 이 제약들은
  명시적으로 deactivate되지 않는다.**
- 왜: NSStackView `arrangedSubviews` 경유 제약의 정리 타이밍이 보장되지 않아, 스트리밍·트리 연타로
  Turn을 빠르게 바꾸면 제약이 쌓여 `Unable to simultaneously satisfy constraints` 경고 +
  폭 계산 흔들림(방금 잡은 "너비 고정 버그" 재발 벡터). 간헐적이라 회귀 테스트로도 안 잡힌다.
- 어떻게: 추가한 제약을 `private var cardConstraints: [NSLayoutConstraint]`로 보관 →
  다음 configure 진입 시 `NSLayoutConstraint.deactivate(cardConstraints); cardConstraints.removeAll()`.
  (work_3는 `clearArrangedSubviews`에서 상태를 한 지점에서 리셋해 구조적으로 회피.)
- 교차검증: 코드 라인 116–117 직접 확인. 정확.

**A2. 본문 줄간격(lineHeightMultiple) 전무 — 모든 카드가 "벽 텍스트"**
- 무엇: `ConversationInlineText.body`/`markdownInline`/`symbolPrefixed` 어디에도 `.paragraphStyle`을
  안 붙인다(라인 26, 87–101 확인). 코드블록·thinking·tool 본문도 동일. 즉 전 본문이 시스템 기본
  줄간격(≈1.0)으로 붙는다.
- 왜: 사용자가 말한 "카드가 평면적으로 읽힘"의 1순위 원인. work_3는 `conversationLineHeightMultiple`
  (본문)·1.2(헤딩)·1.35(코드)를 일관 적용. 메모리에도 "리더 줄간격 1.4~1.45" 정석.
- 어떻게: 본문 attributed 생성 시 `NSMutableParagraphStyle.lineHeightMultiple ≈ 1.4`(코드 ≈ 1.3,
  헤딩 ≈ 1.2)를 전 범위에 부여. 토큰을 한 곳(예 `ConversationTextStyle` 신규 또는 기존 `DetailStyles`)에
  모아 중복 방지. **A3 폰트 통일과 같은 지점에서 처리.**

**A3. 본문 폰트 사이즈가 역할/렌더러별로 들쭉날쭉(11/12/13 혼재)**
- 무엇: UserPrompt 본문 13(라인 21), AssistantMarkdown `bodyFont` 13(라인 114), 폴백
  `PlainTextBlockRenderer` 12(라인 73), StatusBanner 12(라인 18), ToolGroup detail 11(라인 49),
  Thinking 펼침 본문 12(라인 18). 같은 "본문"인데 1~2pt씩 어긋나 카드 간 리듬이 깨진다.
- 왜: 위계는 "primary 13 / secondary 12 / code mono 12"로 의도해야 하는데, 폴백 12와 정식 13이
  뒤섞여 리듬 신호가 노이즈가 됨.
- 어떻게: 토큰화 — primary body 13, secondary body 12, code mono 12. 폴백을 12→tier 기반으로
  (primary면 13). A2와 한 PR.

### A-P1

**A4. 코드블록 Copy 버튼이 본문 상단 1줄을 항상 강제 점유**
- 무엇: `CodeBlockView.setup`(라인 168–176)이 `text.top = copyButton.bottom + 2`,
  `copyButton.top = top + 6`으로 묶어, **모든** 코드블록이 버튼 높이만큼 상단 빈 줄을 갖는다.
  겹침은 해소됐으나 한 줄짜리 코드도 위에 빈 버튼 줄이 떠 어색.
- 왜: 짧은 코드에서 버튼이 코드보다 커 보임 + 수직 공간 낭비.
- 어떻게(P1 범위): 최소안 = 버튼을 우상단 오버레이로 되돌리되 본문 trailing에 버튼폭+여백만큼
  inset을 줘 겹침 방지(본문은 top부터 시작). 권장안(N-급) = hover 시에만 표시(NSTrackingArea).
  더 나아가 코드블록 헤더 바(언어 라벨 + Copy)로 분리하면 지금 안 쓰는 `codeBlock(language:)`도 활용.

**A5. 도메인 모델에 이모지 하드코딩 + 본문 이모지 의존(다크/색맹/VoiceOver 취약)**
- 무엇: `StatusKind.message`(ConversationBlock.swift 라인 137–151)에 `✋ ⚠ ■ ✂` 하드코딩.
  `UserPromptBlock.plainTextFallback`/렌더러의 `↻ Compact resume`, `ThinkingBlock` `💭`,
  `ToolGroupCardRenderer.detail`의 `✗`/`↪`(라인 54).
- 왜: 이모지는 시스템 틴트를 안 받아 다크모드에서 색이 따로 놀고, 색/모양만으로 상태 구분 →
  색맹·저시력·VoiceOver 취약. 도메인(StatusKind)에 표현 기호가 섞여 UI/도메인 경계도 위반.
  work엔 이미 `symbolPrefixed`(SF Symbol) 인프라가 있어 비용 적음.
- 어떻게: 도메인 문자열에서 이모지 제거(순수 텍스트) → 렌더러가 `symbolPrefixed`로 SF Symbol +
  색을 붙임. 매핑: interrupted=`hand.raised.fill`, apiError=`exclamationmark.triangle.fill`,
  stopped=`stop.fill`, compacted=`scissors`, orphan=`questionmark.circle`,
  tool 성공=`arrow.turn.down.right`, 오류=`xmark.octagon.fill`, compact resume=`arrow.clockwise`.

**A6. 하이라이트 스크롤이 빗나감(scrollToVisible 한계 + 좌표/타이밍)**
- 무엇: `configure`(라인 123–128) `documentView.scrollToVisible(rect.insetBy(dx:0,dy:-12))`.
- 왜: `scrollToVisible`는 "이미 일부 보이면 스크롤 안 함"이라 선택 step을 상단 근처로 못 올림.
  또 NSStackView 내부 텍스트뷰 intrinsic height가 늦게 확정돼 rect가 부정확할 수 있음.
- 어떻게(work_3 `scroll(to:)` 차용): 3단계 `layoutSubtreeIfNeeded`(self/document/stack) 후
  `targetY = clamp(rect.minY - 12, 0, docH - visibleH)` → `contentView.scroll(to:)` +
  `reflectScrolledClipView`. 항상 상단 12pt 여백 보장 + 스크롤러 위치 동기화.
- 판정: F1(역선택) 적용 시 sourceStepUUID 매칭과 함께 정리하면 자연스러움. 단독 적용도 가능.

### A-P2 (자체 발견 — 두 리뷰 미포함 신규)

**A7. [신규] StatusBlock 거터/표면이 항상 system(orange)인데 본문색은 kind별 → 적색 인접 충돌**
- 무엇: 모든 StatusBlock이 `role == .system`이라 거터·표면이 항상 systemOrange(0.06)인데,
  `StatusBannerRenderer.color(for:)`는 interrupted를 `systemRed`로 칠한다(라인 31). 결과:
  orange 거터/표면 위에 red 본문이 인접.
- 왜: interrupted(사용자 중단)는 사실 "오류"가 아닌데 가장 강한 red로 외치고, orange/red 인접은
  메모리의 "systemPink vs systemRed 색조 혼동" 류 문제. 강조가 과하다.
- 어떻게: 상태 카드의 거터/표면을 kind 기준으로(중단=중립 회색, apiError=주황, 진짜 위험만 빨강),
  본문색은 거기 종속. (CardContainerView가 role만 받는 현 구조론 어려우니 B1 tier/role 확장과 함께.)

**A8. [신규] AssistantTextBlock 본문 비었을 때 빈 마크다운 카드 생성 가능**
- 무엇: `ConversationMarkdownView.init`은 `MarkdownParser.parse("")`가 빈 노드 배열을 주면
  arrangedSubview가 0개인 빈 스택을 만든다. 빌더는 `text.isEmpty` reply는 블록을 안 만들지만(라인
  104·111 OK), 마크다운이 공백문자/개행만 있는 경우(`"   \n"`)는 `!text.isEmpty` 통과 후 파서가
  빈 결과를 줄 수 있다 → "Assistant · model · cost" 헤더만 있고 본문 0줄인 카드.
- 왜: 비용 분석 앱에서 "헤더만 있는 빈 답변 카드"는 혼란. 흔치 않지만 usage-only/공백 reply에서 발생.
- 어떻게: `ConversationMarkdownView`가 노드 0개면 최소 1줄 placeholder를 두거나, 렌더러가
  `markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`면 StatusBlock류로 대체.

**A9. [신규] ToolGroup detail이 NSGridView 아닌 단일 라벨 + 모노 11pt — 폭 압박 시 wrap 깨짐**
- 무엇: `ToolGroupCardRenderer.detail`(라인 47–69)은 호출별로 `"• input  ↪ result"`를 한 라벨에
  `byWordWrapping`으로 그린다. inputSummary가 긴 경로면 모노 11pt가 좁은 패널에서 단어 단위 줄바꿈돼
  들여쓰기·정렬이 무너진다.
- 왜: tool 묶음은 "스캔"이 목적인데 wrap된 경로 텍스트가 오히려 노이즈. (마크다운 표는 NSGridView로
  잘 처리하면서 tool detail만 평라벨이라 일관성도 깨짐.)
- 어떻게(P2): input/result를 2열 grid 또는 input 한 줄(말줄임) + result 보조줄로 구조화. 범위 크면 라운드3.

**A10. [신규] DisclosureCardView 토글이 chevron 텍스트만 바꿔 — VoiceOver에 펼침 상태 미노출**
- 무엇: `DisclosureCardView`(라인 14–97)는 `▸`/`▾` 텍스트 NSTextField로 상태를 표시하고
  `NSClickGestureRecognizer`로 토글. `setAccessibilityRole(.disclosureTriangle)`이나 expanded
  상태 a11y 통지가 없다.
- 왜: VoiceOver가 "오른쪽 삼각형" 글리프로 읽거나 무시 → 펼침 가능/현재 상태 전달 실패.
  (A5의 이모지 문제와 같은 계열.)
- 어떻게: chevron을 SF Symbol(`chevron.right`/`chevron.down`)로 + 헤더에
  `setAccessibilityRole(.disclosureTriangle)` 또는 버튼화. N3와 묶음.

---

## B. UX·디자인 개선 (사용자 승인 필요)

### B-P0

**B1. tier 기반 시각 위계 도입 — "내 프롬프트·최종 답변"을 도드라지게 (사용자 핵심 요청)**
- 무엇: `ConversationBlock.tier`(primary/secondary/hidden)가 **빌더엔 있는데 카드 렌더에 전혀 안 쓰임.**
  `CardContainerView.init(role:highlighted:)`이 `tier`를 안 받는다(라인 24). 그래서 표면 틴트(0.06
  고정)·보더(0.5 고정)·거터폭(3 고정)·헤더(11pt semibold 고정)가 primary/secondary 동일.
- 왜: Conversation 탭의 목적은 "내가 뭘 물었고 모델이 뭐라 답했나"의 빠른 스캔인데, 도구 호출 한 줄과
  모델 최종 답변이 같은 시각 무게라 눈이 닻 내릴 지점이 없다. 사용자가 명시한 가독성 문제의 직접 원인.
- 어떻게(work_3 `CardContainerView` 차용, 라인 92·111·128·204–242):
  - `CardContainerView.init(role:tier:highlighted:)`로 tier 인자 추가, 전 렌더러가 `block.tier` 전달.
  - 보더 `highlighted ? 1.5 : (tier == .primary ? 0.75 : 0.4)`.
  - 거터폭 `tier == .primary ? 4 : 3`, 거터 `heightAnchor >= 20`(B5 흡수).
  - 헤더 폰트 `tier == .primary ? 12 : 11` semibold, 제목색 primary `.labelColor`/secondary `.secondaryLabelColor`.
  - 카드 내부 stack spacing `tier == .primary ? 9 : 7`(현재 일률 4 → 헤더-본문 밀착 해소, B-R2 흡수).
  - 표면 알파 tier 분기(아래 B2와 한 메서드에서).
- 판정(리뷰 충돌 해소): UX·디자인 둘 다 동일 결론. A1(제약 누수)·B5(거터)와 `CardContainerView`를 함께
  손대므로 **한 작업으로 묶는다.**

**B2. 비강조 표면색을 전경색 기반 오버레이로 — 다크모드 대비 역전/함몰 제거**
- 무엇: `surfaceColor(.assistant) = textBackgroundColor.withAlphaComponent(0.35)`(라인 107).
  `textBackgroundColor`는 라이트=흰/다크=거의 검정이라, 다크모드에서 "검정 35%"를 어두운 배경에 얹으면
  카드가 배경보다 더 어두워 함몰. 라이트에선 흰 35%라 떠 보임 → 방향이 외관마다 뒤집힌다.
- 왜: 다크모드에서 답변 카드가 안 보이거나 함몰. user/system/subAgent는 systemColor 0.06이라 그나마
  덜하지만 assistant만 기준이 다름.
- 어떻게: 전 비강조 표면을 `NSColor.textColor`/`labelColor` 저알파 오버레이로 통일(work_3 패턴 —
  user `controlAccent` α 0.085/0.035, assistant `textColor` α 0.05/0.02). `textBackgroundColor`
  기반 표면 폐기. 항상 "배경보다 약간 대비되는" 일관 방향.
- 판정: 메모리 `nscolor-darkmode-values` 일치. B1과 같은 `surfaceColor` 메서드에서 처리(한 PR).
- 주의(차용 시 조정): work_3는 system에 `systemYellow`를 쓰는데 메모리상 systemYellow는 다크 대비
  최악 → **work의 systemOrange 유지**(work가 더 나음). user accent도 work는 systemTeal, work_3는
  controlAccent — work의 systemTeal 유지하되 cost 강조색은 별색(B-D2)으로 분리.

**B3. 역선택(카드 클릭 → 상단 아웃라인 step 선택+스크롤) — 미구현, 사용자 핵심 요청**
- 무엇: work엔 `onSourceStepSelected`/`sourceStepUUIDs`/`configureSource`/카드 `mouseDown`/`hitTest`가
  **전무**(grep NONE 확인). 단방향(트리→카드)만 동작.
- 왜: 사용자가 긴 답변 카드를 보다 클릭 한 번으로 트리 위치를 잡고 Tokens/Raw로 점프하는 흐름이 막혀 있음.
  Xcode 디버거·JSON 에디터의 양쪽 패널 연동 표준.
- 어떻게(work_3 3계층 체인 차용 — `CardContainerView` 라인 36–155, `ConversationDetailView`,
  `DetailViewController`/Split/Outline):
  1. `ConversationBlock` 프로토콜에 `var sourceStepUUIDs: [String] { get }` 추가. UserPrompt/Assistant/
     Thinking=`[stepUuid]`, ToolGroup=`calls.map(\.stepUuid)`, StatusBlock=`[stepUuid]`(있으면).
  2. `CardContainerView`에 `configureSource(blockID:sourceStepUUIDs:onSelectSourceStep:)` +
     `mouseDown`(즉시 selectSourceStep, `super.mouseDown` 유지) + `hitTest`(빈 영역/거터/NSTextField는
     카드 흡수, 인터랙티브 하위는 통과).
  3. **본문 텍스트 선택 공존**: `ConversationBodyTextView`에 `var onMouseDown: (() -> Void)?` +
     `mouseDown` 오버라이드 추가(work엔 현재 없음). `installSelectionForwarding`로 심어 "클릭=카드선택,
     드래그=텍스트선택" 공존.
  4. `ConversationDetailView.onSourceStepSelected: (([String]) -> Void)?` 추가, 카드 생성 시 configureSource 연결.
  5. `DetailViewController.showStep/showTurn`에서 turn 캡처해 `onConversationSourceStepSelected?(turn, uuids)`,
     Split이 받아 `turnOutlineVC.selectSourceStepUUIDs(uuids, in: turn)` 호출.
  6. **Outline 수신 측 — 거의 준비됨(검증 완료)**: `TurnOutlineViewController`에 이미
     `stepNodes: [String: TurnOutlineNode]`((turnId, stepUuid) 키, 라인 81)와 `rowForIdentityKey`(1685)
     + `selectRowIndexes`/`scrollRowToVisible`(3986–3988)가 있다. **신규 public 메서드
     `selectSourceStepUUIDs(_:in:)` 하나만 추가**해 stepUuid→node.identityKey→row 매핑 후 선택+스크롤.
- 주의(회귀): `showStep`의 "동일 Step 재바인드 스킵"(DetailViewController 라인 536–542 확인)이
  의도된 동작(스크롤 점프 방지)이라, 역선택으로 같은 step을 다시 통지해도 카드 재렌더는 안 됨. 이때
  "트리 선택+스크롤"은 outline이 책임지고 카드 하이라이트는 그대로 두는 정책이 일관적(work_3와 동일).
- 판정: 가장 큰 작업. A1·B1 이후 라운드3 단위. UX·디자인 둘 다 동일 청사진.

### B-P1

**B4. Disclosure 펼침 본문 텍스트선택 vs 카드선택 충돌(B3 적용 시 발현)**
- 무엇: Thinking/Tool 펼침 본문은 selectable `ConversationBodyTextView`. B3의 카드 mouseDown 선택을
  붙이면 드래그 선택과 카드 선택이 경합.
- 어떻게: B3의 `hitTest`에서 NSTextView는 `return hit`(텍스트뷰 처리), `onMouseDown`은 클릭 시점에만
  콜백하되 `super.mouseDown` 호출 유지로 텍스트 선택 보존. Disclosure 토글 영역(chevron+summary)과
  본문 영역 z-order 분리. **B3 적용 직후 검증 항목.**

**B5. 카드 패딩 비대칭 + 거터 짧음**
- 무엇: `CardContainerView` top/bottom 8(라인 51–52,57–58) vs leading 10/trailing 12 → 상하 눌림.
  거터를 카드높이−16에 묶어 1줄 배너에선 거터가 8pt까지 줄어 점처럼 보임.
- 어떻게: 사방 패딩 12로 통일, 거터 `heightAnchor >= 20` + top 정렬. **B1과 한 작업(CardContainerView).**

**B6. 헤더 title/subtitle 2단 분리 + 비용 강조 분리**
- 무엇: `AssistantTextCardRenderer`가 "Assistant · model · $0.37" 전체를 `controlAccentColor`
  한 색으로 칠함(라인 24). model·cost는 부차 메타인데 제목과 동급 강조 → 위계 평평. Lupen은 비용 분석
  앱인데 대화 탭에서 비용이 묻힘.
- 어떻게(work_3 headerView 차용, 라인 182–202): `ConversationCardHeader`에 subtitle 슬롯 추가 →
  title(역할, 강조색) + subtitle(model, tertiary) + cost(monospacedDigit, 별색). 비용 강조색은
  systemTeal(user accent)와 혼동 없게 systemGreen 등 명백히 다른 색조. "You"도 동일 2단 패턴.

**B7. 표시 필터(Tools/Thinking/System) + Compact/Full 모드 부재**
- 무엇: work엔 `ConversationDisplayPreferences` 자체가 없음. 항상 전체 노출 → 도구 많은 Turn에서 노이즈.
- 어떻게(work_3 차용): `ConversationDisplayPreferences`(UserDefaults) + `shouldShow(_:)` 필터 +
  상단 controlsBar(체크 3개 + Compact/Full 세그먼트). Compact=프롬프트+답변만, Full=전부. detail 헤더
  높이 침범 않게 배치. 라운드3 도입 검토.

**B8. 카드 접근성 role/label 부재(work_3 대비 회귀)**
- 무엇: work `CardContainerView`에 NSAccessibility 호출 전무. work_3는 `setAccessibilityElement(true)`
  + `.group` role + title/subtitle 합성 label(라인 94–96).
- 어떻게: `setAccessibilityRole(.group)`, `setAccessibilityLabel("You: <요약>"/"Assistant, model, cost")`.
  B3 적용 시 `setAccessibilityHelp("해당 step 선택")`도. **B1/B6과 같은 지점.**

### B-P2

**B9. 마크다운 표 — 전 셀 truncation + 헤더 구분 약함 + 숫자열 정렬 없음**
- 무엇: `MarkdownTableView`(라인 215) 전 셀 `byTruncatingTail` + compression `.defaultLow` → 좁아지면
  모든 셀이 …로 잘려 표 무의미. 헤더는 bold만 다르고 구분선/배경 없음. columnSpacing 16 고정.
- 어떻게: 헤더 행 하단 구분선 또는 옅은 배경 틴트, 짝수 행 stripe(textColor 2~3%), 숫자열(비용/토큰)
  우측 정렬, 다열 표는 가로 스크롤 컨테이너 검토.

**B10. 인용(quote) 바·텍스트 동시 약화로 흐림**
- 무엇: `quoteView` 바=`separatorColor`(라인 92, 매우 옅음) + 본문=`secondaryLabelColor`(라인 97).
  둘 다 약해 흐릿한 회색 덩어리.
- 어떻게: 바를 역할 accent 저채도 또는 진한 톤, 본문은 `labelColor` + 좌측 들여쓰기 + 옅은 배경 틴트로
  구조 전달(색에만 의존 X).

**B11. 빈 블록 배열 → 완전 백지(안내 카드 없음)**
- 무엇: `configure(blocks: [])`(DetailViewController 라인 511, 레거시 request 선택)면 stack이 텅 빔.
- 어떻게(work_3 차용): blocks 비면 "이 선택에는 표시할 대화가 없습니다" StatusBlock 1개 렌더.

**B12. 헤더 심볼 무게/채움 정책 불일치 + baseline 매직넘버**
- 무엇: `symbolPrefixed` weight `.medium` 고정인데 헤더 폰트는 11pt semibold → 굵기 미스매치.
  User `bubble.left.fill`/Assistant `sparkles`(fill 아님)/Thinking `brain`/Tool `wrench.adjustable.fill`
  → fill/outline 혼재. baseline `y = descender + 1` 경험적 매직넘버(라인 119).
- 어떻게: 심볼 weight를 헤더 폰트 weight(semibold)에 맞추고 fill/outline 통일, baseline은
  `NSTextAttachment` + 폰트 메트릭 기반으로 견고화.

**B13. 디스클로저 chevron SF Symbol화(A10과 묶음)** — `▸`/`▾` 텍스트 → `chevron.right`/`chevron.down`,
  회전 애니메이션 + a11y(A10).

**B14. hover 노출 / 미세 모션(Nice to Have)** — Copy·카드 액션 평소 숨김→hover 페이드인(NSTrackingArea),
  highlight 전환 0.15s 페이드. 둘 다 `accessibilityDisplayShouldReduceMotion` 존중.

---

## work_3에서 차용 / 차용 금지 (결론)

차용:
1. tier 기반 위계(`backgroundColor/borderWidth/gutter/spacing` tier 분기) → B1.
2. 전경색 기반 표면 오버레이 → B2.
3. 역선택 3계층(CardContainerView hitTest/mouseDown → DetailView 콜백 → outline select) → B3.
4. `scroll(to:)` 정밀화(3단계 layout + clamped targetY + reflectScrolledClipView) → A6.
5. 헤더 title/subtitle 2단 분리 → B6. 6. 카드 a11y 라벨 → B8. 7. 빈 상태 카드 → B11.
8. 표시 옵션 바 → B7. 9. 거터 `heightAnchor >= 20` → B5.

차용 금지(work가 우수 — 유지):
1. 마크다운 노드별 전용 뷰 렌더(표=NSGridView, 코드블록=Copy 버튼) — work_3의 attributed 단일 빌드보다
   표/코드 구조 표현이 강함. **절대 attributed 단일 빌드로 회귀 금지.**
2. system 역할색: work의 systemOrange 유지(work_3 systemYellow는 다크 대비 최악).
3. 렌더러 레지스트리 + 폴백 불변식(빈화면/크래시 방지) — 안전한 설계, 유지.
4. lazy disclosure(펼칠 때만 본문 생성) — 성능 게이트 양호, 유지.

---

## 권장 적용 순서 (의존성 고려)

1. **A1**(제약 누수) + **A2/A3**(줄간격·폰트 토큰) — 저위험·고체감. 가장 적은 변경으로 가독성 최대.
2. **B1**(tier 위계) + **B2**(표면 색) + **B5**(거터/패딩) + **B6/B8**(헤더·a11y) — `CardContainerView`
   동시 개편(한 PR). "중요 대화 도드라짐" 사용자 요청 직접 해결.
3. **A5**(이모지→SF Symbol) + **A7**(상태 색) + **A10/B13**(chevron) — 다크/접근성 부채 청산.
4. **A4**(코드블록 Copy) + **B9/B10**(표·인용) — 시각 디테일.
5. **B3**(역선택) + **A6**(스크롤) + **B4**(선택 충돌 검증) — 별도 기능 단위 라운드3, 가장 큰 작업.
6. **B7**(필터) + **B11**(빈 상태) + **A8/A9**(빈 답변·tool detail) — 독립 마감.
