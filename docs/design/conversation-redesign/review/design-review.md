# Conversation 탭 재설계 — 시각 디자인 리뷰

관점: **시각 디자인 / 타이포 / 레이아웃 미학**
대상: 현재(work) + work_1~work_5, 6개 독립 구현
작성자: macOS UX/UI 디자이너 (jaden)
근거: 각 구현의 Conversation UI 코드를 실제 Read로 비교 (파일 경로 명시)

---

## 0. 한 줄 결론

시각 완성도 순위는 **work_3 ≳ work_4 > work_5 > work_2 > work_1 > work(현재)** 다.
현재 구현(work)은 "버블 없는 좌측 거터 + 풀폭" 기본 골격은 잡았지만,
**카드 표면이 없고(거터 색 바 1개뿐), 읽기폭 제한이 없으며, 폰트/줄간격이 시스템 기본값**이라
"리치한 대화 리더"가 아니라 "긴 텍스트 덤프"로 읽힌다. 반면 work_3/4는 카드 표면·계층(tier)·
읽기폭·줄간격·코드블록 헤더까지 갖춘 **네이티브 인스펙터 톤**에 가장 근접했다.

---

## 1. 핵심 비교표

### 1-1. 카드/거터/표면 표현

| 항목 | work(현재) | work_1 | work_2 | work_3 | work_4 | work_5 |
|---|---|---|---|---|---|---|
| 카드 배경 표면 | ❌ 없음(강조 시만) | △ | ⭕ role별 | ⭕ **role×tier** | ⭕ role×tier | ⭕ role |
| 카드 테두리 | ❌ | △ | 0.5pt | **tier별 0.4/0.75/1.5** | 0.5/1.5 | 0.5/1.5 |
| cornerRadius | 6(강조만) | - | 6 | **8** | 8 | 8 |
| 좌측 거터 | 2pt, 1색 | 거터 | 거터 | **3/4pt tier별, r1.5** | 3pt | 4pt, r2 |
| 강조(선택) | 배경 α0.18 | 보더 | 보더 | **배경α0.12 + 보더1.5 accent** | 배경α0.10+보더 | 보더1.5 |
| 다크모드 대응 | semantic만 | - | semantic | **viewDidChangeEffectiveAppearance 재계산** | cgColor 1회 | cgColor 1회 |

**가장 나음: work_3.** `CardContainerView.swift`에서 role(user/assistant/system/subAgent) ×
tier(primary/secondary/hidden) 2축으로 배경·거터·보더·타이틀색을 모두 분기하고,
`viewDidChangeEffectiveAppearance()`로 다크↔라이트 전환 시 layer 색을 다시 계산한다(L60-63).
나머지는 cgColor를 init에서 1회만 굳혀, 외관 전환 시 색이 안 따라온다(잠재 버그).

### 1-2. 타이포 / 읽기폭 / 줄간격

| 항목 | work | work_1 | work_2 | work_3 | work_4 | work_5 |
|---|---|---|---|---|---|---|
| 본문 폰트 | 13 | 13 | 13 | 13 | 13 | 13 |
| 줄간격(lineHeight) | ❌ 기본 | △ | **1.45** | **1.45** | **1.45** | 1.45(min/max) |
| 읽기폭 제한 | ❌ 풀폭 | readingWidth | 620/760 | **620 clamp** | 620/720 | 620 |
| 헤더 위계 | 11 semibold 1단 | - | 15/13 | tier 12/11 | sectionHeaderFont | sectionHeaderFont |
| 코드 줄간격 | ❌ | - | 1.25 | 1.35 | 1.25 | min/max |

**가장 나음: work_3/work_4 공동.** 본문 `lineHeightMultiple = 1.45`(`ConversationTextBuilder.bodyAttributes`,
work_4 `DetailStyles+Conversation.conversationParagraphStyle`)로 한국어/영문 혼용 본문의 가독성을 확보했고,
`conversationReadingWidth = 620`으로 **한 줄 65~75자**라는 타이포 정석을 지킨다.
현재(work)는 **줄간격·읽기폭 둘 다 없음** — 와이드 모니터에서 한 줄이 150자까지 늘어나
"읽히지 않는 벽"이 된다. 이게 현재 구현 최대의 시각 약점.

> 메모: work_5 `conversationParagraphStyle`은 `minimumLineHeight=maximumLineHeight=ceil(pt*1.45)`로
> 줄높이를 **고정**한다. 한글+이모지 혼용 줄에서 줄높이가 들쭉날쭉해지는 걸 막는 더 견고한 방식이라,
> 이 패턴은 차용 가치가 있다(아래 4-3).

### 1-3. 코드블록 시각 스타일

| 항목 | work | work_2 | work_3 | work_4 | work_5 |
|---|---|---|---|---|---|
| 언어 라벨 헤더 | ❌ | ⭕ mono 11 | ⭕ 11 semibold | (텍스트 prefix) | ⭕ caption |
| Copy 버튼 | "Copy" 텍스트 mini | **SF doc.on.doc 아이콘** | **SF doc.on.doc** | - | **SF doc.on.doc** |
| 가로 스크롤(긴 줄) | ❌ 래핑 | ❌ | ❌ | ❌ | **⭕ NSScrollView 수평** |
| 배경 | textBg α0.5 | textBg α0.55 | textColor α0.035 | - | textBg α0.72 |

**가장 나음: 헤더+아이콘은 work_2/work_3, 긴 코드 줄 처리는 work_5.**
현재(work) `CodeBlockView`는 우상단에 **"Copy"라는 텍스트 버튼**을 쓴다 —
macOS 네이티브(Xcode/Notes 코드 필드)는 전부 `doc.on.doc` 심볼 아이콘이다. 텍스트 버튼은 무겁고
번역 이슈도 생긴다. work_5만 긴 코드 한 줄을 가로 스크롤로 처리(나머지는 강제 래핑되어 깨짐).

### 1-4. 테이블 / diff / 도구칩

| 항목 | work | work_2 | work_3 | work_4 | work_5 |
|---|---|---|---|---|---|
| 테이블 | NSGridView, 격자선❌ | **셀 박스+헤더틴트** | **셀별 border+헤더틴트** | grid | grid |
| diff | ❌ 없음 | ❌ | before/after 2열 | **before/after + ±배지** | **before/after + 라벨 pill** |
| diff 라인 하이라이트 | - | work_1: **+/− 줄 배경틴트** | - | - | - |
| 도구칩 헤더 아이콘 | 🔧 이모지 | **SF wrench.adjustable** | (텍스트) | (텍스트) | (텍스트) |
| 사고 마커 | 💭 이모지 | (텍스트) | (텍스트) | (텍스트) | (텍스트) |

**가장 나음: 테이블 work_3, diff 시각은 work_1(라인 틴트) + work_4(±배지).**
work_1 `BlockRenderers+PhaseD.DiffLineView`는 추가/삭제 줄에 `systemGreen/systemRed α0.12`
배경을 깔아 **GitHub/Xcode diff 톤**을 낸다(가장 "diff처럼" 보인다). work_4는 파일 헤더에
`+N`/`-N` 컬러 배지를 붙인다. 둘을 합치면 이상적.

### 1-5. 아이콘(SF Symbols) 일관성 — HIG deference

| 구현 | 아이콘 정책 | 평가 |
|---|---|---|
| work(현재) | 🔧/💭/✦ **이모지** 헤더 | 🔴 비네이티브. 다크모드/대비/접근성 모두 약함 |
| work_1 | SF `wrench.adjustable`, `chevron`, `photo` | 🟢 일관 |
| work_2 | SF `wrench.adjustable.fill`, `doc.on.doc` | 🟢 일관 |
| work_3 | SF `doc.on.doc` (코드), disclosure triangle | 🟢 |
| work_4 | SF `chevron.down/right`, `doc.on.doc` | 🟢 |
| work_5 | SF `doc.on.doc` | 🟢 |

**현재 구현만 이모지(🔧💭✦🖼)를 헤더 글리프로 쓴다.** 이건 시각적으로 가장 큰 "비네이티브 신호"다.
이모지는 (1) 시스템 틴트색을 못 받고(항상 컬러 이모지로 렌더), (2) 다크모드에서 대비가 무너지며,
(3) VoiceOver가 "망치 이모지"로 읽고, (4) 굵기/광학 정렬이 SF Symbol과 안 맞는다.
**반드시 SF Symbol + `contentTintColor`(semantic)로 교체**해야 한다.

### 1-6. 상호작용 시각 피드백

| 항목 | work | work_3 | work_4 | work_5 | work_1 |
|---|---|---|---|---|---|
| disclosure 토글 | ▸/▾ 텍스트 | "▾ title sub" 버튼 | **SF chevron 버튼** | summary | **SF chevron** |
| 카드→step 선택 | ❌ | **⭕ hitTest+tooltip** | ❌ | ⭕ | ⭕ |
| 표시 토글 바(Tools/Thinking) | ❌ | ⭕ checkbox+seg | ⭕ **toolTip+a11y** | ⭕ | ⭕ seg |
| 빈 상태(empty) | "(빈 프롬프트)" | ⭕ StatusBlock | ⭕ | ⭕ | ⭕ |

**가장 나음: work_4(컨트롤바 a11y 완비) + work_3(카드 클릭→step 동기화).**
현재(work)는 **표시 토글 바 자체가 없어** 도구/사고 노이즈를 끌 수 없다 — 정보 밀도 조절 불가.

---

## 2. 현재 구현(work)의 시각 이슈 — 우선순위

### 🔴 Critical

**C1. 읽기폭 무제한 → 본문이 "벽"이 됨.**
`ConversationDetailView.swift` L67은 `documentView.widthAnchor == contentView.widthAnchor`만 걸고,
스택에 `lessThanOrEqualToConstant` 읽기폭 제한이 없다. detail pane을 넓히면 한 줄이 무한정 길어진다.
(보고된 "너비 고정" 버그와도 연결 — 아래 5장.)

**C2. 카드 표면 부재 → 역할 구분이 거터 색 바 1개에만 의존.**
`CardContainerView.swift`는 평소 배경/보더가 전혀 없고, 강조 시에만 옅은 배경이 뜬다. 결과적으로
user/assistant/tool 카드가 시각적으로 안 나뉘고 한 덩어리로 읽힌다. work_3처럼 role(+tier)별
미묘한 배경 틴트 + 0.5pt 보더 + r8을 줘야 "카드 스택"으로 읽힌다.

**C3. 이모지 헤더(🔧💭✦🖼) → 비네이티브.** (1-5 참조)

**C4. 본문 줄간격 미설정.** 시스템 기본 줄간격은 장문 읽기에 빡빡하다. `lineHeightMultiple 1.45`
적용 필요(work_2/3/4/5 전부 적용함).

### 🟡 Recommended

**R1. 코드블록 Copy 텍스트버튼 → SF `doc.on.doc` 아이콘 버튼.** (1-3)
**R2. 표시 토글 바(Tools/Thinking/System + Compact/Full) 추가.** 정보 밀도 조절·노이즈 제거.
**R3. 코드블록 언어 라벨 헤더 추가**(work_2/3/5). 어떤 언어인지 + Copy 위치 명확.
**R4. 다크↔라이트 전환 시 layer 색 재계산**(work_3 `viewDidChangeEffectiveAppearance`).
현재 강조 배경/거터를 cgColor로 굳히면 외관 전환 시 색이 안 바뀐다.

### 🟢 Nice to Have

**N1. diff 라인 틴트(+초록/−빨강 배경)** — work_1 패턴. Xcode/GitHub 톤.
**N2. tier(primary/secondary) 위계** — 도구/사고는 약하게, 답변은 강하게(work_3/4).
**N3. 테이블 셀 헤더 틴트 + 격자선** — 현재 NSGridView는 선이 없어 "표"로 안 읽힌다(work_2/3).

---

## 3. 다른 세션에서 차용할 시각 패턴 (Borrow)

1. **읽기폭 클램프 + 중앙 정렬**(work_3 `ConversationDetailView` L90-94):
   `centerXAnchor` + `widthAnchor <= 620` + `defaultHigh`로 늘어남 방지, 와이드에서 가운데 정렬.
2. **role × tier 2축 색 시스템 + 외관 재계산**(work_3 `CardContainerView`).
3. **본문 1.45 줄간격 / 코드 1.25~1.35**(work_2/3/4 `bodyAttributes`).
4. **줄높이 고정형 paragraphStyle**(work_5 `conversationParagraphStyle`, min=max) — 이모지 혼용 안정.
5. **코드블록 헤더(언어 라벨 + SF Copy 아이콘)**(work_2/3) + **긴 줄 가로 스크롤**(work_5).
6. **diff 라인 배경 틴트**(work_1 `DiffLineView`) + **±컬러 배지**(work_4).
7. **표시 토글 바 + toolTip/accessibilityLabel 완비**(work_4 `setupControlBar`).
8. **카드 클릭 → 아웃라인 step 동기화 + tooltip "Select corresponding step"**(work_3 `hitTest`/`configureSource`).
9. **테이블 셀별 0.5pt border + 헤더 틴트**(work_2/3 `TableCellView`).
10. **SF chevron disclosure 버튼 + a11y "Expand/Collapse"**(work_4 `CardContainerView`).

---

## 4. 6개 어디에도 없는 독자 시각 개선 (Own)

> 6개 모두 "카드 스택 + 거터 + tier"까지는 왔지만, 아래는 어디에도 없다.

### 4-1. 역할 헤더를 "캡슐 라벨"이 아니라 "거터 + 정렬 리듬"으로 (deference 강화)
현재 모든 구현이 `USER`/`ASSISTANT` 같은 헤더 텍스트를 카드마다 반복 출력한다. 사람/모델이
번갈아 나오는 대화에서 이 라벨은 노이즈다. **거터 색만으로 역할을 구분하고, 헤더 텍스트는
assistant의 model·cost 같은 "정보가 있을 때만" 노출**하면 화면이 훨씬 조용해진다(Apple Notes/
Messages가 발신자 라벨을 매 버블에 안 붙이는 것과 동일 원리).

### 4-2. 코드/도구 출력에 **고정폭 거터 라인 넘버 대신 "접힘 그라데이션"**
긴 도구 출력(수백 줄)을 펼치면 카드가 화면을 잡아먹는다. 어디에도 없는 개선:
펼친 본문에 `maxHeight`(예 320pt) + 하단 페이드 그라데이션(CAGradientLayer, 배경색→투명) +
"Show all (N lines)" 링크. 시각적으로 "더 있다"를 알리면서 스크롤 폭주를 막는다.

```swift
// 본문 호스트에 부착하는 페이드 마스크 (Reduce Motion 무관, 정적)
final class FadeClampView: NSView {
    private let gradient = CAGradientLayer()
    var maxContentHeight: CGFloat = 320
    override func layout() {
        super.layout()
        gradient.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 28)
        gradient.colors = [NSColor.clear.cgColor,
                           (NSColor.textBackgroundColor.withAlphaComponent(0.9)).cgColor]
        // 하단 28pt만 페이드
    }
}
```

### 4-3. **타임라인 거터(연속 카드 사이 세로 연결선)** — 대화 흐름의 depth 표현
6개 모두 카드를 단순 vertical stack으로 쌓는다. 같은 turn 안에서 assistant→tool→tool→assistant로
이어지는 흐름을, 좌측 거터들을 **세로 점선/실선으로 연결**(Xcode 콜스택, Linear activity feed 톤)하면
"하나의 사고 흐름"이라는 depth가 생긴다. HIG의 Depth 원칙에 정확히 부합하며 어디에도 없다.

### 4-4. **NSVisualEffectView 카드 표면(머티리얼)** — 진짜 네이티브 톤
현재 work_3/4/5는 `textColor.withAlphaComponent(0.05)` 같은 **반투명 색**으로 카드 표면을 흉내낸다.
하지만 macOS 26 네이티브 그룹 표면은 `NSVisualEffectView(.contentBackground / .sidebar)` 머티리얼이다.
강조 카드만이라도 머티리얼 배경을 쓰면 데스크탑/사이드바 뒤 비침과 어울려 "OK JSON보다 더 맥다운"
느낌이 난다. (단, 성능상 카드 수가 많으면 강조 카드 한정 권장.)

### 4-5. **assistant cost를 헤더 텍스트가 아니라 우측 정렬 monospaced 배지로**
현재(work) `AssistantTextCardRenderer.headerText`는 `✦ Assistant · opus-4-8 · $0.37`을 한 줄
텍스트로 이어 붙인다. cost는 숫자라 **우측 정렬 + monospacedDigit + CostColor 틴트**가 맞다
(`CostColor.accent`는 이미 사이드바/아웃라인에서 쓰는 단일 소스). 헤더 좌측엔 model, 우측 끝에
cost 배지를 띄우면 사이드바 비용 색과 시각적으로 묶여 일관성이 생긴다 — 6개 중 cost를 전용 색으로
틴트한 구현은 없다.

---

## 5. 보고된 버그 — 시각/레이아웃 관점 원인·해법 (vs _N)

### 버그1: detail pane 폭 조절 불가
**원인(work):** `ConversationDetailView.swift` L67에서 documentView 폭을 viewport에 묶고,
스택 항목은 `view.trailingAnchor == stack.trailingAnchor`(`UserPromptCardRenderer` L49 등)로
풀폭 고정. body NSTextView가 `widthAnchor == stack.widthAnchor`로 묶여 **고정 너비 제약 충돌**이
생기면 AutoLayout이 pane 리사이즈를 못 따라간다.
**해법(work_5 패턴이 가장 깔끔):** `outerStack.widthAnchor <= conversationReadingWidth`(상한)
+ `outerStack.widthAnchor == documentView.widthAnchor - inset*2 @defaultHigh`(선호) 조합.
상한+선호 우선순위로 두면 **좁힐 땐 따라 줄고, 넓힐 땐 620에서 멈춘다.** (work_3 L67-94 동일 전략.)

### 버그2: step 선택 시 항상 top으로 스크롤
**원인(work):** `configure(blocks:)` 끝에서 무조건 `documentView.scroll(.zero)`(L92). 강조 카드
위치를 계산하지 않는다.
**해법(work_3/work_1/work_5 공통):** 강조 카드의 `convert(bounds, to: documentView).minY - 12`로
타깃 Y를 구해 `contentView.scroll(to:)` + `reflectScrolledClipView`. work_3 `scroll(to:)`
(L280-292)이 maxY 클램프까지 포함해 가장 견고하다. 강조가 없을 때만 top.

---

## 6. 색 사용 주의 (다크모드 실측 메모 반영)

- **work_3/work_4가 system 카드에 `systemYellow`를 쓴다**(work_3 `CardContainerView` L217/239).
  systemYellow는 **다크모드 라벨/틴트로 대비가 가장 약한 색**이고, 라이트 배경에서도 흐리다.
  system/warning 카드는 `systemOrange`(또는 다크=Yellow/라이트=Orange 동적 전환)가 안전하다.
  현재(work)는 system을 `systemOrange`로 써서 이 점은 더 낫다 — 유지할 것.
- **cost 색은 신규로 만들지 말고 기존 `CostColor.accent`/`unavailable`을 재사용**(이미 다크/라이트
  동적 정의됨, `Lupen/UI/Support/CostColor.swift`). 4-5 배지에 그대로 연결.
- 카드 배경 반투명 틴트는 `textColor.withAlphaComponent`보다 work_4 `RowView`의
  `NSColor(name:dynamicProvider:)` 동적 정의가 외관 전환에 강하다.

---

## 7. 권장 최종 시각 스펙 (현재 구현을 끌어올리는 합본)

| 토큰 | 값 | 출처 |
|---|---|---|
| readingWidth | 620 (상한) + 중앙정렬 | work_3/5 |
| 본문 폰트 / 줄간격 | system 13 / lineHeight 1.45 | work_2/3/4 |
| 코드 폰트 / 줄간격 | mono 12 / 1.30 | work_3/5 |
| 카드 cornerRadius | 8 | work_3/4/5 |
| 거터 너비 / radius | primary 4 / secondary 3, r1.5 | work_3 |
| 카드 보더 | 0.5 (강조 1.5 accent) | work_3/4/5 |
| 카드 배경 | role×tier 동적 틴트(dynamicProvider) | work_3+work_4 |
| 강조 배경 | controlAccent α0.12 | work_3 |
| 코드 Copy | SF doc.on.doc 아이콘 버튼 | work_2/3/5 |
| disclosure | SF chevron.right/down + a11y | work_4 |
| diff 라인 | +초록/−빨강 α0.12 배경 + ±배지 | work_1+work_4 |
| 도구/사고 헤더 글리프 | SF wrench.adjustable / brain(또는 sparkles) | work_1/2 |
| system 색 | systemOrange (Yellow 금지) | work(현재) 유지 |
| cost | CostColor.accent monospaced 우측 배지 | 독자(4-5) |
| 독자 추가 | 타임라인 연결 거터(4-3), 출력 페이드 클램프(4-2) | 신규 |

---

## 8. 요약

현재 구현(work)은 골격은 맞지만 **시각 표면(카드/줄간격/읽기폭/아이콘)이 비어 있어** 6개 중 가장
"덤프"처럼 보인다. work_3를 시각 베이스라인으로 삼아 (a) 읽기폭+줄간격, (b) role×tier 카드 표면,
(c) 이모지→SF Symbol, (d) 코드블록 헤더+아이콘 Copy를 이식하고, work_1의 diff 라인 틴트와
work_4의 컨트롤바 a11y를 더하면 네이티브 인스펙터 수준에 도달한다. 그 위에 6개 어디에도 없는
**타임라인 연결 거터·출력 페이드 클램프·cost 전용 배지**를 얹으면 OK JSON을 시각적으로 앞선다.
