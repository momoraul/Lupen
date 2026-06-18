# 세션 비용 사이드바 노출 — 설계 문서

- **날짜**: 2026-06-19
- **브랜치**: `feature/session-pricing`
- **목업**: `docs/superpowers/mockups/session-pricing-sidebar.html`

## 1. 문제 정의

세션 사이드바 행은 3줄 스택(제목 / 브랜치 / 메타)으로 렌더된다. 세션 총비용은 셋째 줄(메타 라인)에
`프로젝트 · 시각 · 비용 · N req` 형태로 다른 메타데이터와 한 줄에 묶여 있다 — `SessionListViewController.swift:2449-2455`.

이 메타 라인은 `lineBreakMode = .byTruncatingTail`(`:2274`)이라, 사이드바 폭이 좁아지면 **오른쪽 끝의 비용
세그먼트부터 잘려 사라진다**. 비용은 이 앱의 핵심 지표인데, 시각·req 수와 동급으로 묶여 가장 먼저 희생된다.
대조적으로 오른쪽 메인 패널(턴 아웃라인)은 비용에 **전용 Cost 컬럼**을 줘 항상 또렷하다 — 이 비대칭이 문제의 본질이다.

## 2. 핵심 발견 — 데이터는 이미 완성돼 있다

세션 총비용은 이미 계산·캐시·전달되고 있다. 이 작업은 **순수 UI 표시 레이어**만 건드린다.

- 비용 값: `StoreSessionListAggregate.costUSD`, SQL `SUM(COALESCE(final_cost_usd, provisional_cost_usd, 0)) GROUP BY session_id`로 집계 — `ProviderStore.sessionListAggregates()` (`ProviderStore.swift:1477-1487`), DTO는 `StoreDTO.swift:486-490`.
- 캐시: `AppStateStore.sessionListAggregates` (`AppStateStore.swift:357`).
- 이미 `sessionCell(for:)`이 `aggregate?.costUSD ?? 0`을 읽어 `cell.configure(totalCost:costConfidence:)`로 전달 중 — `SessionListViewController.swift:1620-1664`.

→ **Data / Domain / Store 레이어 변경 0줄.** `configure(...)` 시그니처도 불변(이미 `totalCost`, `costConfidence`를 받음). 바뀌는 것은 **그 값을 어디에 어떻게 그리느냐**뿐.

## 3. 설계

### 3.1 채택안 — 전용 우측 비용 라벨

비용을 메타 라인의 텍스트 세그먼트에서 **떼어내**, 제목 줄 우측에 고정된 독립 `NSTextField`로 만든다.

```
[ 넓을 때 320pt ]                       [ 좁을 때 188pt ]
● Fix coupon total + review  $10.02     ● Fix coupon to…   $10.02
  ⎇ feature/coupon-fix                    ⎇ feature/coup…
  04/14 11:52 · 71 req  👥3               04/14 11:52 · 71 req  👥3
```

비용 라벨은 절대 안 잘리고, 제목이 먼저 `…`로 잘린다.

### 3.2 컴포넌트 — `SessionCellView` (`SessionListViewController.swift`)

- 새 멤버: `private let costLabel = NSTextField(labelWithString: "")`.
- 폰트: `NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)` — 턴 행 `.cost` 셀과 동일.
- `setupSubviews()`의 뷰 배열(`:2295-2296`)에 추가.
- 메타 라인(`metaParts`, `:2449-2454`)에서 `cost` 세그먼트 **제거** → `[projectLabel, startTime, "N req"]`만 남김.

### 3.3 레이아웃 (Auto Layout 우선순위 — "비용 우선, 제목 먼저 잘림")

- **비용 라벨**: `setContentCompressionResistancePriority(.required, for: .horizontal)` + `setContentHuggingPriority(.required, for: .horizontal)` → 절대 안 잘리고 폭도 안 늘어남.
- **제목 라벨**: compression resistance를 `.defaultLow`로 낮춰 폭 부족 시 먼저 `…`로 잘림(이미 `byTruncatingTail`).
- 제약:
  - `costLabel.trailingAnchor == trailingAnchor - 8`
  - `costLabel.firstBaselineAnchor == titleLabel.firstBaselineAnchor`
  - `titleLabel.trailingAnchor ≤ costLabel.leadingAnchor - 8` (기존 `titleLabel.trailing ≤ trailing - 8`을 대체, `:2350`)
- 서브에이전트 인디케이터(`person.2.fill` + 수)는 **현재 그대로** 메타 줄 우측에 유지(`:2368-2375`). 비용은 제목 줄, 서브에이전트는 메타 줄 — 다른 줄이라 충돌 없음.

### 3.4 색상 / 포맷 — 턴 행 색 체계 재사용

숫자 포맷은 기존 `CostFormatter.compact`(이미 사이드바·턴 공유)를 그대로 쓴다. 색 틴팅은 턴 행
`TurnOutlineViewController.prefixedCostAttr`(`:3224-3280`)의 규칙을 재사용한다:

| 조건 | 색 | 예시 |
|---|---|---|
| 일반 (`> $0.1`, exact) | `labelColor` | `$10.02` |
| 소액 (`≤ $0.1`) | `tertiaryLabelColor` (흐림) | `$0.087` |
| 추정 (partial) | `systemOrange`, `≈` 접두 | `≈$2.10` |
| 불가 (unavailable) | `systemOrange` | `N/A` |
| 0 / 미산정 | `quaternaryLabelColor` | `—` |

**세션 단위에는 이상치(outlier) 임계값이 없으므로 턴 행의 주황 이상치 하이라이트는 생략**한다 —
신뢰도 색(추정/불가)과 소액 흐림만 적용.

#### 색 로직 추출 (작업 중 코드 개선)

현재 색 결정 로직은 `TurnOutlineViewController`의 `private static func prefixedCostAttr`에 갇혀 있어
사이드바에서 재사용할 수 없다. 두 곳이 같은 색 규칙을 공유하도록, 색 결정 함수
(`cost + confidence + warningThreshold → NSColor`)를 **새 `CostColor.swift`(`UI/Support/`)** 로 추출한다.
별도 파일로 두는 이유: 기존 `CostFormatter.swift`는 `import Foundation`만 하는 순수 포맷 모듈인데, 색은
`AppKit`(`NSColor`) 의존이 필요하므로 관심사를 분리한다.

- 추출 후 턴 행은 동작 불변(같은 함수 호출), 사이드바는 색 획득.
- 사이드바 호출 시 `warningThreshold`는 `.infinity`로 넘겨(이상치 비활성) `exactColor`는 nil.
- 추출 함수는 순수 함수로 단위 테스트 가능하게 한다.

## 4. 엣지 케이스 / 테스트

### 4.1 렌더 스킵 가드

`SessionFingerprint`는 현재 cost를 추적하지 않는다(id/endTime/title/isCustomTitle/isPinned/isActive만).
cost 변경은 `endTime`/aggregate 관찰(`startObserving()`에서 `sessionListAggregates` 관찰 armed, `:747`)을 통해 갱신된다.
비용이 더 두드러지는 표시가 되므로, **cost-only 백필(엔드타임 불변)이 확실히 다시 그려지도록 `SessionFingerprint`에
cost를 포함**한다.

### 4.2 선택 행 대비

선택된 행(파란 하이라이트) 위에서 `tertiaryLabelColor`(소액 흐림)가 묻힐 수 있다. 선택 상태에서는 흐림 색을 한
단계 밝게 보정한다(예: `selectedControlTextColor` 계열 또는 보정 알파).

### 4.3 비용 폰트

비용 라벨은 12pt semibold(턴 행 `.cost` 셀과 동일). 제목(13pt semibold)과 같은 줄에서 `firstBaselineAnchor`로 정렬.

### 4.4 테스트

- 색 추출 함수 단위 테스트(`CostFormatterTests` 패턴): 일반/소액/추정/불가/0 각 케이스의 색 매핑.
- 셀 구성 테스트(`SessionListLoadingStateTests` 패턴): `costLabel`이 올바른 문자열·색으로 설정되는지.
- 레이아웃 회귀: 좁은 폭에서 제목이 먼저 잘리고 비용 라벨 폭이 유지되는지(compression resistance 검증).

## 5. 변경 파일 요약

| 파일 | 변경 |
|---|---|
| `Lupen/UI/Support/CostColor.swift` | 색 결정 함수 추출(신규 파일) |
| `Lupen/UI/Dashboard/TurnOutlineViewController.swift` | `prefixedCostAttr` 색 결정부를 추출 함수 호출로 교체(동작 불변) |
| `Lupen/UI/Dashboard/SessionListViewController.swift` | `costLabel` 뷰 추가, 레이아웃 제약, `metaParts`에서 cost 제거, `SessionFingerprint`에 cost 추가 |
| `LupenTests/UI/Support/CostFormatterTests.swift` 등 | 색 함수 + 셀 구성 + 레이아웃 테스트 |

Data / Domain / Store: **변경 없음**.

## 6. 비채택안 (참고)

- **제목 줄 우측 비용 배치(제목과 동일 줄, 비용이 가장 먼저 닿음)**: 시선은 빠르나 제목 가용 폭을 더 잠식.
- **메타 라인 비용 순서만 앞으로**: 변경 최소이나 여전히 한 줄에 묶여 시각/req가 잘릴 수 있음.
- **비용 전용 4번째 줄 분리**: 항상 보이나 모든 행이 높아져 한 화면 세션 수 감소.
- **저장된 세션 총비용 컬럼 추가**: 읽기 시점 SQL fold가 이미 정답값을 만들므로 불필요(스키마 마이그레이션·finalizer write·staleness 처리 부담만 추가).
