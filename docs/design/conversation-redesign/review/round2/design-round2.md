# Conversation 리더 — 디자인 라운드2 리뷰 (디자인 전문가 관점)

작성: jaden / 2026-06-21
범위: `Lupen/UI/Dashboard/Conversation/` + `Lupen/Domain/Conversation/Story/`
비교 대상: `work_3`(최상 평가 세션)
**중요: 본 문서는 개선안/버그 목록일 뿐, 코드 수정은 하지 않는다. 메인 세션이 사용자 승인 후 적용.**

관점: 타이포 · 간격 · 색/대비 · 카드 표면 · 코드/표/diff 시각 · 아이콘 일관성 · 다크모드.
핵심 목표: **"내 프롬프트 · 모델 최종 답변"이 시각적으로 도드라지게** 하고, 남은 시각 버그(겹침/정렬/잘림) 제거.

---

## 0. 현재 구조 요약 (근거)

- 스택: `ConversationDetailView`(scrollView + flipped documentView + 수직 stack) → 블록별 `CardContainerView` → 본문(텍스트/마크다운/디스클로저).
- 카드 표면/색: `CardContainerView.surfaceColor / accentColor` (역할별 분기, layer 직접 칠).
- 본문 텍스트: `ConversationBodyTextView`(selectable NSTextView, intrinsic height).
- 마크다운: `ConversationMarkdownView`가 `MarkdownParser` 노드별 뷰 생성(문단/헤딩/리스트/코드블록/표/인용).
- 헤더 아이콘: `ConversationInlineText.symbolPrefixed`로 SF Symbol(👍 이모지 아님).
- 빌더: `ConversationStoryBuilder`가 Turn → `[ConversationBlock]` 큐레이션, highlight stepUuid로 강조.

---

## 🔴 필수 수정 (Critical)

### C1. 카드 본문 폰트가 역할별로 들쭉날쭉 — 줄간격(line-height) 전무

근거:
- `UserPromptCardRenderer`: 본문 `systemFont(ofSize: 13)`.
- `AssistantTextCardRenderer` → `ConversationMarkdownView.bodyFont = systemFont(ofSize: 13)`.
- `PlainTextBlockRenderer`(폴백): `systemFont(ofSize: 12)`.
- `StatusBannerRenderer`: `systemFont(ofSize: 12)`.
- `ToolGroupCardRenderer` 본문: 11pt 모노/12pt 혼재.

문제:
1. 같은 "본문"인데 폴백(12)·정식(13)이 1pt 차이로 어긋나 카드 간 리듬이 깨진다.
2. **줄간격(lineHeightMultiple)이 어디에도 없다.** 모든 본문이 시스템 기본 줄간격(약 1.0)으로 붙어 "평면적으로 읽히는" 핵심 원인. `work_3`는 `DetailStyles.conversationLineHeightMultiple`(본문)·1.2(헤딩)·1.35(코드)를 일관 적용한다(`ConversationTextBuilder.bodyAttributes` 등). 메모리에도 "리더 줄간격 1.45" 정석 기록.

수정 방향(코드 X, 방침):
- 본문 폰트/줄간격을 한 곳(예: `ConversationTextStyle` 또는 기존 `DetailStyles`)에 토큰화:
  - body 13pt / lineHeightMultiple ≈ 1.4
  - secondary(thinking/tool) 12pt
  - code 12pt mono / lineHeightMultiple ≈ 1.3
- `ConversationBodyTextView.setBody`에 들어오는 attributed에 `.paragraphStyle`(lineHeightMultiple) 부여. 현재 `ConversationInlineText.body/markdownInline`은 paragraphStyle을 전혀 안 붙임 → 여기에 추가.
- 폴백 12 → 13으로 통일(정식 본문과 동일 리듬).

기대 효과: 본문이 숨쉬는 간격을 얻어 "벽 텍스트" 인상 해소. 가독성 개선의 1순위.

---

### C2. 내 프롬프트/최종 답변이 도드라지지 않음 — Tier에 따른 시각 위계 부재

근거:
- `CardContainerView.surfaceColor`는 **highlight(선택) 여부**로만 강하게 분기하고, 평소엔 역할별 6% 틴트로 거의 동일한 약한 표면.
- user 표면 `systemTeal 0.06`, assistant `textBackgroundColor 0.35`(반투명 흰/검) — 둘 다 매우 옅어 primary(프롬프트·답변)와 secondary(thinking·tool 디스클로저)의 **표면 강도가 사실상 같다**.
- 보더도 `borderWidth = highlighted ? 1.5 : 0.5`로 tier 무관.
- 헤더 폰트도 항상 11pt semibold(역할 무관).

대조 — `work_3`의 위계 장치(차용 권장):
- `backgroundColor(role:tier:highlighted:)`가 **tier별로 알파를 분기**: user primary 0.085 / secondary 0.035, assistant primary 0.050 / secondary 0.020.
- `borderWidth = isHighlighted ? 1.5 : (tier == .primary ? 0.75 : 0.4)` — primary가 더 또렷한 테두리.
- gutter 폭도 tier별 `primary ? 4 : 3`.
- contentStack spacing도 `primary ? 9 : 7`, 헤더 폰트 `primary ? 12 : 11`, title 색 `secondary는 secondaryLabelColor`.

문제: 현재 `ConversationBlock.tier`(primary/secondary/hidden)가 **빌더엔 있는데 카드 렌더에 전혀 반영 안 됨.** `CardContainerView.init`은 `role`, `highlighted`만 받고 `tier`를 안 받는다. 위계의 핵심 신호가 버려진 상태.

수정 방향:
- `CardContainerView`에 `tier` 인자 추가 → 표면 알파·borderWidth·gutter 폭·헤더 폰트/색을 tier로 분기(work_3 매핑 차용).
- primary(프롬프트·답변·상태)는 또렷하게, secondary(thinking·tool)는 한 단계 가라앉게.
- 모든 렌더러가 `CardContainerView(role:tier:highlighted:)`로 `block.tier` 전달.

기대 효과: 사용자가 요청한 "중요 대화가 눈에 띄게"의 직접 해법. 스캔 시 프롬프트/답변이 먼저 들어온다.

---

### C3. assistant 표면색이 다크/라이트에서 반대로 작동 (대비 역전 위험)

근거: `surfaceColor(role:.assistant)` = `NSColor.textBackgroundColor.withAlphaComponent(0.35)`.
- `textBackgroundColor`는 라이트=흰색, 다크=거의 검정.
- 카드는 윈도우 배경 위에 놓인다. 다크모드에서 "검정 35%"를 어두운 배경에 얹으면 거의 안 보이거나 카드가 배경보다 **더 어두워** 함몰돼 보인다. 라이트에선 흰 35%라 살짝 떠 보임 — **방향이 외관마다 뒤집힌다.**

대조: `work_3`는 `NSColor.textColor.withAlphaComponent(...)`(전경색 기반 오버레이)를 써서 라이트=검정 살짝, 다크=흰 살짝 → **항상 "배경보다 약간 밝은/대비되는" 일관 방향**.

수정 방향: assistant(및 모든 역할 비강조 표면)을 `textColor` 또는 `labelColor` 저알파 오버레이 기반으로 통일. `textBackgroundColor` 기반 표면 폐기.

기대 효과: 다크모드 카드 함몰/대비 역전 제거. 메모리의 "cgColor 정적 → 외관전환 재계산" 패턴은 이미 `applyColors`로 처리됨(양호).

---

### C4. system 역할 강조색 `systemOrange` 표면 + 본문색 충돌

근거:
- `CardContainerView.accentColor(.system) = .systemOrange`, 표면 `systemOrange 0.06`, gutter orange.
- 그런데 `StatusBannerRenderer.color(for:)`는 본문 텍스트를 kind별로 `systemRed`(interrupted) / `systemOrange`(apiError, orphan) / `secondaryLabel`(stopped, compacted)로 칠한다.
- 결과: orange 거터·orange 표면 위에 **red 본문**(interrupted) → red/orange 인접 = 메모리 기록한 "systemPink vs systemRed 11° 혼동" 류의 적색 인접 문제. interrupted(사용자 중단)는 사실 "오류"가 아닌데 가장 강한 red로 외친다.

수정 방향:
- 상태 카드의 **거터/표면색을 kind 기준으로** 정하고(중단=중립 회색, apiError=주황, 진짜 위험만 빨강), 본문은 거기에 종속. 이모지(✋⚠■✂)는 SF Symbol로 교체(아래 C6 참조).
- 메모리 가이드: 경고 틴트는 "전부 강조 = 강조 없음" 안티패턴 주의. 상태별로 1개 강조색만.

---

### C5. 코드블록 Copy 버튼이 본문 위 공간을 항상 점유 — 짧은 코드에서 레이아웃 낭비 + 우측 잘림 잠재

근거(`ConversationMarkdownView.CodeBlockView`):
- 겹침은 고쳤으나(버튼 아래에서 본문 시작), 이제 **모든 코드블록이 버튼 1줄 높이를 상단에 강제 확보**. 한 줄짜리 인라인성 코드블록도 위에 빈 버튼 줄이 떠 어색하다.
- 코드 본문은 `ConversationBodyTextView`(width-tracking, 줄바꿈)인데 **긴 코드 라인은 줄바꿈돼 버린다.** 코드는 가로 스크롤(`NSScrollView`) 또는 최소한 의도적 처리가 표준인데, 지금은 본문처럼 wrap → 인덴트 깨지고 읽기 나쁨.
- Copy 버튼 위치가 `trailing -8`인데 documentView 우측 끝과 카드 inset(12) + body inset(10)이 누적돼, 좁은 패널에서 버튼이 코드 우측과 시각적으로 붙거나 살짝 넘칠 수 있음.

수정 방향(우선순위):
1. Copy 버튼을 **본문과 같은 행의 우상단 오버레이**로 되돌리되(공간 안 먹게), 호버 시에만 표시(아래 N1 hover) + 본문에 우측 패딩 확보해 겹침 방지. 또는 버튼을 코드블록 **헤더 바**(언어 라벨 + Copy)로 분리 — 언어 태그(`MarkdownNode.codeBlock(language:)`)를 지금 안 쓰는데, 헤더에 노출하면 일석이조.
2. 코드 라인 줄바꿈 정책 결정: 최소한 `lineBreakMode`를 명시하고, 긴 줄은 가로 스크롤 컨테이너로 감싸는 안을 검토(범위 크면 라운드3).

---

### C6. 이모지 글리프가 도메인·상태 텍스트에 직접 박혀 있음 (다크/색맹/VoiceOver 취약)

근거:
- `StatusKind.message`: `"✋ ..."`, `"⚠ ..."`, `"■ ..."`, `"✂ ..."` — **도메인 모델 문자열에 이모지/기호 하드코딩**.
- `UserPromptBlock.plainTextFallback` / 렌더러: `"↻ Compact resume"`, `ThinkingBlock`: `"💭 ..."`.
- `ToolGroupCardRenderer.detail`: 결과에 `"✗"` / `"↪"` 텍스트 글리프.

문제(메모리의 "이모지 단독 상태 전달 실패"와 동일):
- 이모지는 시스템 틴트를 안 받아 다크모드에서 색이 따로 논다.
- 색/모양만으로 상태 구분(✋ vs ⚠ vs ■) → 색맹·저시력 취약.
- VoiceOver가 "흰색 손바닥 이모지"식으로 읽어 의미 전달 실패.
- 도메인(`StatusKind`)에 표현 기호가 섞여 UI/도메인 경계 위반.

수정 방향:
- 상태/역할 기호를 전부 **SF Symbol**로(이미 `symbolPrefixed` 인프라 존재). 매핑 예: interrupted=`hand.raised.fill`, apiError=`exclamationmark.triangle.fill`, stopped=`stop.fill`, compacted=`scissors`, orphan=`questionmark.circle`. tool 결과 성공=`arrow.turn.down.right`, 오류=`xmark.octagon.fill`.
- `StatusKind.message`에서 이모지 제거(순수 텍스트), 렌더러가 symbol을 붙이게 분리.
- 모든 카드 헤더/상태에 `accessibilityLabel` 부여(work_3는 `CardContainerView`가 `setAccessibilityLabel(title+subtitle)` 함 — 차용 권장).

---

## 🟡 권장 개선 (Recommended)

### R1. [기능+UX] 역선택(카드 클릭 → 아웃라인 step 선택/스크롤) 미구현

근거: `work`에는 `onSourceStepSelected / sourceStepUUIDs / onSelectSourceStep`가 **전혀 없음**(grep 결과 NONE). `CardContainerView`에 클릭 핸들링·blockID·sourceStepUUIDs 개념 부재. 본문 선택용 NSTextView가 카드 전체 클릭을 먹어 역선택을 더 어렵게 한다.

대조 — `work_3` 차용 패턴(검증됨):
- `CardContainerView`가 `blockID`, `sourceStepUUIDs`, `onSelectSourceStep` 보유.
- `hitTest`로 "본문 빈 영역·라벨·거터" 클릭은 카드로 흡수하되, 인터랙티브 하위(버튼/링크)는 통과.
- `installSelectionForwarding`로 `ConversationTextView.onMouseDown`을 카드 선택으로 포워딩(텍스트 선택과 공존).
- `ConversationDetailView.onSourceStepSelected` → 상위가 아웃라인 `selectRowIndexes + scrollRowToVisible` 호출.

연결점 확인: `TurnOutlineViewController`에 이미 stepUuid 인덱스(주석 "(turnId, stepUuid) → node")와 `selectRowIndexes`/`scrollRowToVisible` 인프라가 있어 **수신 측은 거의 준비됨**. `ConversationBlock`이 stepUuid를 갖고 있으므로(UserPrompt/AssistantText/Thinking/ToolGroup의 calls[].stepUuid) sourceStepUUIDs 산출 가능. ToolGroup은 다중 stepUuid라 work_3처럼 배열(`sourceStepUUIDs: [String]`)이 맞다.

수정 방향(라운드3 구현 항목): work_3의 3계층(CardContainerView 클릭/hitTest → DetailView 콜백 → 상위가 outline 선택) 그대로 이식. 본 라운드는 설계 차용점만 명시.

---

### R2. [간격] 카드 내부 패딩/스택 spacing이 work_3보다 빡빡 + 비대칭

근거(`CardContainerView.setup`):
- top/bottom 8, leading(gutter) 10, gutter→body 10, trailing 12 → **상하(8)와 좌우(10~12) 비대칭**, work_3는 사방 12 + gutter→content 10으로 더 여유롭고 균형.
- 카드 스택 `spacing = 10`(work는 10, work_3도 10) OK.
- `UserPromptCardRenderer`/`AssistantTextCardRenderer`의 내부 stack `spacing = 4`(헤더↔본문) — work_3는 `primary ? 9 : 7`로 더 넓어 헤더가 본문에 안 붙는다. 현재 4는 헤더-본문이 붙어 답답.

수정 방향: 카드 패딩 사방 12로 통일(top/bottom 8 → 12), 헤더↔본문 spacing 4 → 8~9(primary)/7(secondary). DisclosureCard 내부 spacing(6/4)도 동반 점검.

---

### R3. [표] MarkdownTableView 셀 전부 말줄임 + 헤더 구분선/스트라이프 없음

근거(`MarkdownTableView`):
- 모든 셀 `lineBreakMode = .byTruncatingTail` + `compression .defaultLow` → 좁아지면 **모든 셀이 …로 잘려 표가 무의미**해질 수 있음(특히 다열).
- 헤더는 bold만 다르고 **헤더와 본문 사이 구분선/배경 없음** → 표 구조가 약하게 읽힘. 메모리 "NSTableView 우측 컬럼 잘림" 류 위험과 동일 계열(컬럼합 vs 가용폭).
- gridView columnSpacing 16 고정 — 좁은 패널에서 가로 압박.

수정 방향:
- 헤더 행에 하단 구분선(separator) 또는 옅은 배경 틴트 추가, 짝수 행 stripe(`textColor` 2~3% 오버레이) 검토.
- 셀 말줄임은 **첫 열은 유지·나머지는 wrap** 또는 표 전체를 가로 스크롤로 감싸는 안 중 택1(읽기폭 620 안에서 다열 표는 결국 가로 스크롤이 정답).
- 숫자열(비용/토큰 등) 우측 정렬 옵션(구분선 정렬 정석).

---

### R4. [인용] quoteView 바 색이 너무 약함 + 텍스트가 secondary라 이중 약화

근거(`ConversationMarkdownView.quoteView`): 바 `separatorColor`(매우 옅음) + 본문 `secondaryLabelColor`. 둘 다 약해 인용이 "흐릿한 회색 덩어리"로 보임.

수정 방향: 인용 바를 역할 accent의 저채도 버전 또는 `tertiaryLabelColor`보다 진한 톤으로, 본문은 `labelColor` 유지하되 좌측 들여쓰기 + 옅은 배경 틴트로 "인용 블록"임을 구조로 전달(색에만 의존 X).

---

### R5. [헤더 메타] Assistant 헤더의 model·cost가 본문 강조색(controlAccent)과 동일 톤

근거: `AssistantTextCardRenderer`가 헤더 전체("Assistant · model · $0.37")를 `controlAccentColor`로 칠함. 모델/비용은 부차 메타인데 제목과 같은 강조색이라 위계가 평평.

대조: work_3는 title=accent/label, subtitle(메타)=`tertiaryLabelColor`로 분리.

수정 방향: 헤더를 title(역할, 강조색) + subtitle(model·cost, tertiary)로 2단 분리(`ConversationCardHeader`에 subtitle 슬롯 추가). UserPrompt "You"도 동일 패턴.

---

### R6. [아이콘 일관성] 헤더 심볼 무게·정렬 산발

근거:
- `symbolPrefixed`는 `weight: .medium` 고정, baseline `y = descender + 1`(경험적). 헤더 폰트는 11pt semibold인데 심볼은 medium → 굵기 미스매치.
- User=`bubble.left.fill`(teal), Assistant=`sparkles`(accent), Thinking=`brain`, Tool=`wrench.adjustable.fill`. sparkles만 fill 아님 → 채움/외곽선 혼재.

수정 방향: 헤더 심볼 weight를 헤더 폰트 weight(semibold)에 맞추고, fill/outline 정책 통일(역할 아이콘은 fill 계열로). baseline 정렬은 `symbolPrefixed`의 매직넘버 대신 `NSTextAttachment` + 폰트 메트릭 기반으로 견고화.

---

## 🟢 선택 개선 (Nice to Have)

### N1. 코드블록/카드 Copy·액션의 hover 노출 (NSTrackingArea)
- 메모리/HIG: 마우스 환경은 hover 상태 필수. Copy 버튼을 평소 숨기고 카드/코드블록 hover 시 페이드인(Finder·Xcode 패턴). Reduce Motion 시 즉시 표시.

### N2. 선택 카드 강조에 미세 모션
- highlight 전환 시 표면/보더 0.15s 페이드(`NSAnimationContext`). `accessibilityDisplayShouldReduceMotion` 존중. 역선택(R1)과 결합 시 "어디로 점프했는지" 인지 향상.

### N3. 디스클로저 chevron을 SF Symbol로 (▸/▾ 텍스트 → chevron.right/down)
- 현재 `▸`/`▾` 유니코드 텍스트. SF Symbol `chevron.right`/`chevron.down`이 시스템 정렬·다크모드·VoiceOver 일관(Finder 디스클로저 표준). 회전 애니메이션도 자연스러움.

### N4. 빈/특수 상태 일러스트 없음
- work_3는 빈 선택 시 `StatusBlock(.noTextResponse, title:..., message:...)` 카드를 명시 렌더. work는 빈 blocks면 그냥 빈 스택(스크롤만). 최소한 "표시할 대화 없음" 안내 카드 필요(메모리: empty state는 가이드 제공).

### N5. 표시 옵션 컨트롤 바 부재
- work_3는 상단에 Tools/Thinking/System 체크 + Compact/Full 세그먼트(`ConversationDisplayPreferences`). work는 항상 전체 노출 → 도구 많은 Turn에서 노이즈. 라운드3에서 도입 검토(차용).

---

## 시각 버그 체크리스트 (겹침/정렬/잘림) — 정독 결과

| # | 위치 | 증상 | 심각도 |
|---|------|------|--------|
| V1 | `ConversationInlineText.body/markdownInline` | paragraphStyle(줄간격) 미부여 → 전 본문 줄 붙음 | 🔴 (C1) |
| V2 | `CardContainerView` | tier 미반영 → primary/secondary 표면 동일, 위계 없음 | 🔴 (C2) |
| V3 | `surfaceColor(.assistant)` | `textBackgroundColor 0.35` 다크모드 대비 역전/함몰 | 🔴 (C3) |
| V4 | `CodeBlockView` | Copy 버튼이 상단 1줄 강제 점유(짧은 코드 빈 줄) + 긴 코드 wrap | 🟡 (C5) |
| V5 | `MarkdownTableView` | 전 셀 truncation → 좁아지면 표 전멸, 헤더 구분 약함 | 🟡 (R3) |
| V6 | 헤더 stack spacing 4 | 헤더-본문 밀착(답답) | 🟡 (R2) |
| V7 | 카드 패딩 top/bottom 8 vs 좌우 10~12 | 상하 비대칭으로 카드가 위아래로 눌림 | 🟡 (R2) |
| V8 | quoteView | 바·텍스트 동시 약화로 인용 흐림 | 🟢 (R4) |
| V9 | `symbolPrefixed` baseline `descender+1` | 폰트 크기별 심볼 수직 미세 어긋남 | 🟢 (R6) |
| V10 | 이모지 글리프(✋⚠■✂💭↻✗) | 다크/색맹/VoiceOver 취약, 시스템 틴트 무시 | 🔴 (C6) |

---

## work_3에서 차용할 패턴 정리 (요약)

1. **tier 기반 위계**: `backgroundColor(role:tier:highlighted:)` 알파 분기 + `borderWidth`/gutter폭/spacing tier 분기. → C2 직접 해법.
2. **전경색 기반 표면 오버레이**(`textColor.withAlphaComponent`): 다크/라이트 일관 방향. → C3.
3. **`layerColor`(deviceRGB 변환) 헬퍼**: cgColor 외관 안정. (work도 `performAsCurrentDrawingAppearance`로 처리 중이라 동급, 둘 중 하나로 통일).
4. **역선택 3계층**(CardContainerView hitTest/mouseDown/onMouseDown 포워딩 → DetailView.onSourceStepSelected → 상위 outline select). → R1.
5. **줄간격 토큰**(`conversationLineHeightMultiple`, 헤딩 1.2, 코드 1.35). → C1.
6. **헤더 title/subtitle 2단 분리**(메타=tertiary). → R5.
7. **접근성 라벨**(`setAccessibilityLabel(title, subtitle)`, role=.group). → C6.
8. **빈 상태 카드**(`StatusBlock(.noTextResponse, title:, message:)`). → N4.
9. **표시 옵션 바**(`ConversationDisplayPreferences` + 체크/세그먼트). → N5.

주의: work는 블록을 노드별 NSView(NSGridView 표, Copy 버튼 코드블록)로 그려 work_3(단일 attributed 문자열)보다 **표/코드 인터랙션이 우수**하다. 이 강점은 유지하고, 위계·줄간격·색 일관성만 work_3에서 차용하는 것이 최선.

---

## 우선순위 적용 순서(권장)

1. C1(줄간격) + C3(표면 색 기반) — 가장 적은 변경으로 가독성 체감 최대.
2. C2(tier 위계) — "중요 대화 도드라짐" 사용자 요청 직접 해결.
3. C6(이모지 → SF Symbol + a11y) — 다크/접근성 부채 청산.
4. C4·C5(상태 색/코드블록) → R2·R5·R3(간격/헤더/표).
5. R1(역선택)은 별도 기능 단위로 라운드3에서.
