# 세션 비용 사이드바 노출 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 세션 사이드바 행에서 비용을 제목 줄 우측 전용 라벨로 분리해, 폭이 좁아져도 비용이 잘리지 않고 항상 보이게 한다.

**Architecture:** 비용 값·신뢰도는 이미 `cell.configure(totalCost:costConfidence:)`로 전달되고 있으므로 데이터 레이어는 무변경. 턴 행의 비용 색/텍스트 결정 로직(`prefixedCostAttr`)을 순수 함수로 `CostColor.swift`에 추출해 턴 행과 사이드바가 공유한다. 사이드바 `SessionCellView`에 compression-resistant 비용 라벨을 추가하고, 메타 라인에서 비용 세그먼트를 제거한다.

**Tech Stack:** Swift 6, AppKit (`NSTableCellView`, Auto Layout), XCTest, Xcode 프로젝트(`Lupen.xcodeproj`).

## Global Constraints

- macOS 26+, Swift 6 — 기존 코드 스타일/동시성 모델 준수.
- 숫자 포맷은 항상 `CostFormatter.compact`를 통해서만 생성 (메인 패널과 byte 단위 일치).
- 색은 macOS 시맨틱 컬러만 사용: `labelColor` / `tertiaryLabelColor` / `quaternaryLabelColor` / `systemOrange`.
- Data / Domain / Store 레이어 변경 금지 — UI 레이어(`Lupen/UI/`)와 테스트만 수정.
- 턴 행(`TurnOutlineViewController`)의 비용 렌더 **동작은 불변**이어야 한다 (리팩터링만, 시각 변화 없음).
- TDD: 각 태스크는 실패하는 테스트 → 최소 구현 → 통과 → 커밋.
- 빌드/테스트는 Xcode MCP(`BuildProject` / `RunSomeTests`)로 수행하며, 워크스페이스 tabIdentifier는 실행 시점에 `XcodeListWindows`로 확인한다.

---

## File Structure

| 파일 | 책임 | 변경 |
|---|---|---|
| `Lupen/UI/Support/CostColor.swift` | 비용 → (표시 텍스트, NSColor) 순수 결정 로직. 턴/사이드바 공유 단일 소스. | **신규** |
| `Lupen/UI/Dashboard/TurnOutlineViewController.swift` | `prefixedCostAttr`의 텍스트/색 결정부를 `CostColor` 호출로 교체 (동작 불변). | 수정 |
| `Lupen/UI/Dashboard/SessionListViewController.swift` | `SessionCellView`에 전용 `costLabel` 추가, 레이아웃 제약, 메타에서 비용 제거, `SessionFingerprint`에 cost 반영. | 수정 |
| `LupenTests/UI/Support/CostColorTests.swift` | `CostColor` 결정 로직 단위 테스트. | **신규** |
| `LupenTests/UI/Dashboard/SessionCostLabelTests.swift` | `SessionCellView` 비용 라벨 구성/색/compression 우선순위 테스트. | **신규** |

각 파일을 Xcode 프로젝트 타깃에 추가해야 한다(아래 태스크에 포함). 신규 소스는 `Lupen` 타깃, 신규 테스트는 `LupenTests` 타깃.

---

## Task 1: `CostColor` — 비용 표시 텍스트/색 결정 추출

턴 행의 `prefixedCostAttr` 내부에 박혀 있던 "(prefix, cost, confidence, exactColor, warningThreshold) → (표시 문자열, NSColor)" 결정 로직을, AppKit 의존 순수 함수로 분리한다. 이게 턴/사이드바가 공유할 단일 소스다.

**Files:**
- Create: `Lupen/UI/Support/CostColor.swift`
- Test: `LupenTests/UI/Support/CostColorTests.swift`

**Interfaces:**
- Consumes: `CostFormatter.compact(_:)` (`Lupen/UI/Support/CostFormatter.swift:6`), `CostFormatter.emDash` (`:4`), `CostConfidence` enum (`.exact` / `.partial` / `.unavailable` / `.notBillable`).
- Produces:
  - `struct CostDisplay { let text: String; let color: NSColor }`
  - `enum CostColor { static func display(cost: Double, confidence: CostConfidence, prefix: String = "", exactColor: NSColor? = nil, warningThreshold: Double = .infinity) -> CostDisplay }`
  - 결정 규칙(턴 행 `prefixedCostAttr`와 byte 단위 동일):
    1. `confidence == .unavailable` → `("\(prefix)N/A", .systemOrange)`
    2. `cost <= 0` → `("\(prefix)\(CostFormatter.emDash)", .quaternaryLabelColor)`
    3. `confidence == .partial` → `("\(prefix)≈\(CostFormatter.compact(cost))", .systemOrange)`
    4. `cost >= warningThreshold` → `("\(prefix)\(CostFormatter.compact(cost))", .systemOrange)`
    5. `exactColor != nil` → `("\(prefix)\(CostFormatter.compact(cost))", exactColor!)`
    6. `cost <= 0.1` → `("\(prefix)\(CostFormatter.compact(cost))", .tertiaryLabelColor)`
    7. else → `("\(prefix)\(CostFormatter.compact(cost))", .labelColor)`

- [ ] **Step 1: Write the failing test**

`LupenTests/UI/Support/CostColorTests.swift`:

```swift
import XCTest
import AppKit
@testable import Lupen

final class CostColorTests: XCTestCase {
    func testUnavailableIsOrangeNA() {
        let d = CostColor.display(cost: 5.0, confidence: .unavailable)
        XCTAssertEqual(d.text, "N/A")
        XCTAssertEqual(d.color, .systemOrange)
    }

    func testZeroIsEmDashQuaternary() {
        let d = CostColor.display(cost: 0, confidence: .exact)
        XCTAssertEqual(d.text, CostFormatter.emDash)
        XCTAssertEqual(d.color, .quaternaryLabelColor)
    }

    func testPartialIsApproxOrange() {
        let d = CostColor.display(cost: 2.10, confidence: .partial)
        XCTAssertEqual(d.text, "≈$2.10")
        XCTAssertEqual(d.color, .systemOrange)
    }

    func testSmallAmountIsDim() {
        let d = CostColor.display(cost: 0.087, confidence: .exact)
        XCTAssertEqual(d.text, "$0.087")
        XCTAssertEqual(d.color, .tertiaryLabelColor)
    }

    func testNormalAmountIsLabelColor() {
        let d = CostColor.display(cost: 10.02, confidence: .exact)
        XCTAssertEqual(d.text, "$10.02")
        XCTAssertEqual(d.color, .labelColor)
    }

    func testWarningThresholdForcesOrange() {
        let d = CostColor.display(cost: 5.0, confidence: .exact, warningThreshold: 1.0)
        XCTAssertEqual(d.text, "$5.00")
        XCTAssertEqual(d.color, .systemOrange)
    }

    func testPrefixIsPrepended() {
        let d = CostColor.display(cost: 10.02, confidence: .exact, prefix: "Σ ")
        XCTAssertEqual(d.text, "Σ $10.02")
    }

    func testExactColorOverride() {
        let d = CostColor.display(cost: 5.0, confidence: .exact, exactColor: .systemBlue)
        XCTAssertEqual(d.color, .systemBlue)
    }
}
```

- [ ] **Step 2: Add both files to the Xcode project, run test to verify it fails**

먼저 `Lupen/UI/Support/CostColor.swift`를 빈 스텁(아래 내용 없이 `enum CostColor {}`만)으로 생성해 컴파일은 되되 심볼이 없어 실패하게 한다. 두 파일을 각각 `Lupen` / `LupenTests` 타깃에 추가.

Run: `RunSomeTests` (target `LupenTests`, `CostColorTests`)
Expected: FAIL — `CostColor.display` / `CostDisplay` 미정의 컴파일 오류.

- [ ] **Step 3: Write minimal implementation**

`Lupen/UI/Support/CostColor.swift`:

```swift
import AppKit

/// Decided text + color for a cost figure. Shared single source of truth
/// for the turn outline's Cost column and the sidebar session row, so the
/// two surfaces tint identical amounts identically.
struct CostDisplay {
    let text: String
    let color: NSColor
}

/// Maps (cost, confidence) to the displayed string and semantic color.
/// Rules mirror the historical `TurnOutlineViewController.prefixedCostAttr`
/// exactly — extracted here so the sidebar can reuse them without
/// duplicating the ladder. Pure function; no AppKit state beyond `NSColor`.
enum CostColor {
    static func display(
        cost: Double,
        confidence: CostConfidence,
        prefix: String = "",
        exactColor: NSColor? = nil,
        warningThreshold: Double = .infinity
    ) -> CostDisplay {
        if confidence == .unavailable {
            return CostDisplay(text: "\(prefix)N/A", color: .systemOrange)
        }
        guard cost > 0 else {
            return CostDisplay(text: "\(prefix)\(CostFormatter.emDash)", color: .quaternaryLabelColor)
        }
        let amount = CostFormatter.compact(cost)
        if confidence == .partial {
            return CostDisplay(text: "\(prefix)≈\(amount)", color: .systemOrange)
        } else if cost >= warningThreshold {
            return CostDisplay(text: "\(prefix)\(amount)", color: .systemOrange)
        } else if let exactColor {
            return CostDisplay(text: "\(prefix)\(amount)", color: exactColor)
        } else if cost <= 0.1 {
            return CostDisplay(text: "\(prefix)\(amount)", color: .tertiaryLabelColor)
        } else {
            return CostDisplay(text: "\(prefix)\(amount)", color: .labelColor)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `RunSomeTests` (target `LupenTests`, `CostColorTests`)
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Lupen/UI/Support/CostColor.swift LupenTests/UI/Support/CostColorTests.swift Lupen.xcodeproj/project.pbxproj
git commit -m "feat(ui): extract CostColor shared cost text/color decision"
```

---

## Task 2: 턴 행을 `CostColor`로 리팩터 (동작 불변)

`prefixedCostAttr`의 텍스트/색 결정 분기를 `CostColor.display(...)` 호출로 교체한다. 폰트·정렬(paragraphStyle)은 그대로 유지 — 시각 동작은 변하지 않아야 한다.

**Files:**
- Modify: `Lupen/UI/Dashboard/TurnOutlineViewController.swift:3224-3280`

**Interfaces:**
- Consumes: `CostColor.display(cost:confidence:prefix:exactColor:warningThreshold:)` (Task 1).
- Produces: 없음 (내부 리팩터). `costAttr` / `prefixedCostAttr` 시그니처 불변.

- [ ] **Step 1: Confirm existing turn-cost tests as the regression guard**

기존 색/포맷 회귀 테스트를 baseline으로 먼저 통과 확인한다. `costColorForTesting`(`TurnOutlineViewController.swift:4163`)을 거치는 테스트.

Run: `RunSomeTests` (target `LupenTests`, `TurnOutlineCostColorTests`)
Expected: PASS (리팩터 전 baseline).

- [ ] **Step 2: Replace the decision body with CostColor**

`Lupen/UI/Dashboard/TurnOutlineViewController.swift`의 `prefixedCostAttr` 본문(`:3232-3280`, `let font` 다음부터 `return NSAttributedString(...)` 전체)을 아래로 교체:

```swift
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        let display = CostColor.display(
            cost: cost,
            confidence: confidence,
            prefix: prefix,
            exactColor: exactColor,
            warningThreshold: warningThreshold
        )
        return NSAttributedString(
            string: display.text,
            attributes: [
                .font: font,
                .foregroundColor: display.color,
                .paragraphStyle: rightAlignedParagraph,
            ]
        )
```

- [ ] **Step 3: Run turn-cost regression tests to verify unchanged behavior**

Run: `RunSomeTests` (target `LupenTests`, `TurnOutlineCostColorTests`)
Expected: PASS — 리팩터 후에도 동일 결과.

- [ ] **Step 4: Build to confirm no orphaned symbols**

Run: `BuildProject`
Expected: BUILD SUCCEEDED, 경고 없음(미사용 변수 등).

- [ ] **Step 5: Commit**

```bash
git add Lupen/UI/Dashboard/TurnOutlineViewController.swift
git commit -m "refactor(ui): route turn cost rendering through CostColor"
```

---

## Task 3: `SessionCellView`에 전용 비용 라벨 추가 + 메타에서 비용 제거

제목 줄 우측에 compression-resistant 비용 라벨을 추가하고, 메타 라인(`metaParts`)에서 비용 세그먼트를 제거한다. 비용 라벨은 `CostColor`로 색을 입히고, 기존 Codex 신뢰도 툴팁을 비용 라벨로 옮긴다.

**Files:**
- Modify: `Lupen/UI/Dashboard/SessionListViewController.swift` — `SessionCellView` (멤버 선언 `:2179` 부근, `setupSubviews` `:2218-2377`, `configure` `:2379-2527`)
- Test: `LupenTests/UI/Dashboard/SessionCostLabelTests.swift`

**Interfaces:**
- Consumes: `CostColor.display(cost:confidence:)` (Task 1), `CostConfidence`, 기존 `configure(... totalCost:costConfidence:provider: ...)` 파라미터.
- Produces (테스트가 의존할 테스트 시드 — `SessionCellView`에 추가):
  - `func costDisplayForTesting(totalCost: Double, confidence: CostConfidence) -> (text: String, color: NSColor)` — 셀이 비용 라벨에 실제로 세팅하는 (문자열, 색)을 반환.
  - `var costLabelCompressionResistanceForTesting: Float` — 비용 라벨의 수평 compression resistance 우선순위.
  - `var titleLabelCompressionResistanceForTesting: Float` — 제목 라벨의 수평 compression resistance 우선순위.

- [ ] **Step 1: Write the failing test**

`LupenTests/UI/Dashboard/SessionCostLabelTests.swift`:

```swift
import XCTest
import AppKit
@testable import Lupen

final class SessionCostLabelTests: XCTestCase {
    private func makeCell() -> SessionListViewController.SessionCellView {
        SessionListViewController.SessionCellView(frame: .init(x: 0, y: 0, width: 300, height: 56))
    }

    func testNormalCostTextAndColor() {
        let cell = makeCell()
        let d = cell.costDisplayForTesting(totalCost: 10.02, confidence: .exact)
        XCTAssertEqual(d.text, "$10.02")
        XCTAssertEqual(d.color, .labelColor)
    }

    func testPartialCostIsApproxOrange() {
        let cell = makeCell()
        let d = cell.costDisplayForTesting(totalCost: 2.10, confidence: .partial)
        XCTAssertEqual(d.text, "≈$2.10")
        XCTAssertEqual(d.color, .systemOrange)
    }

    func testCostLabelResistsCompressionMoreThanTitle() {
        let cell = makeCell()
        XCTAssertGreaterThan(
            cell.costLabelCompressionResistanceForTesting,
            cell.titleLabelCompressionResistanceForTesting,
            "비용 라벨은 제목보다 늦게 잘려야 한다(제목 먼저 …)"
        )
    }
}
```

참고: `SessionCellView`가 현재 `private final class`(`SessionListViewController.swift:2153`)이므로, 테스트 접근을 위해 `final class SessionCellView`로 접근 수준을 올리고(같은 모듈 `@testable` 접근), `SessionListViewController` 안의 중첩 타입으로 노출한다. 메서드/프로퍼티 추가는 `internal`.

- [ ] **Step 2: Run test to verify it fails**

Run: `RunSomeTests` (target `LupenTests`, `SessionCostLabelTests`)
Expected: FAIL — `SessionCellView` 비공개 / `costDisplayForTesting` 미정의.

- [ ] **Step 3: Add the cost label member and setup**

`SessionListViewController.swift`에서:

(a) `private final class SessionCellView`를 `final class SessionCellView`로 변경(`:2153`).

(b) 멤버 선언에 추가 (`metaLabel` 선언 `:2179` 뒤):

```swift
    /// Dedicated cost label pinned to the title row's trailing edge.
    /// Carries the session total so it survives sidebar narrowing — the
    /// title truncates first (lower compression resistance), the price
    /// stays. Mirrors the turn outline's Cost column tinting via CostColor.
    private let costLabel = NSTextField(labelWithString: "")
```

(c) `setupSubviews()`에서 `costLabel` 스타일 + 우선순위 (`metaLabel` 스타일 블록 `:2267-2275` 부근에 추가):

```swift
        costLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        costLabel.textColor = .labelColor
        costLabel.alignment = .right
        costLabel.lineBreakMode = .byClipping
        costLabel.maximumNumberOfLines = 1
        // 비용은 핵심 지표 — 절대 안 잘리고 폭도 안 늘어남. 제목이 먼저 …로 양보.
        costLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        costLabel.setContentHuggingPriority(.required, for: .horizontal)
```

(d) `setupSubviews()`의 뷰 배열에 `costLabel` 추가 (`:2295-2296`):

```swift
        for v in [activeDot, customTitleIcon, pinIcon, titleLabel, branchIcon, branchLabel, metaLabel,
                  costLabel, subAgentIcon, subAgentCountLabel] {
```

(e) 제목 라벨이 먼저 잘리도록 우선순위 낮춤 + 제약 교체. 기존 `titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)` (`:2350`)을 제거하고, `NSLayoutConstraint.activate([...])` 블록(`:2320-2376`)에 아래를 반영:

```swift
            // Title now yields to the cost label on the right.
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLeadingNoTag,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: costLabel.leadingAnchor, constant: -8),

            // Dedicated cost label — title-row trailing, baseline-aligned to title.
            costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            costLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
```

그리고 `setupSubviews` 시작부에 제목 압축 우선순위 추가(스타일 블록 `:2219-2222` 근처):

```swift
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
```

- [ ] **Step 4: Set the cost label in configure + move tooltip + add test seams**

`configure(...)`에서:

(a) 비용 라벨 세팅 추가 (`metaParts` 조립 `:2449-2455` 직후, `metaLabel.toolTip` 세팅 `:2456` 앞):

```swift
        let costDisplay = CostColor.display(totalCost: totalCost, confidence: costConfidence)
        costLabel.stringValue = costDisplay.text
        costLabel.textColor = costDisplay.color
        // Codex 신뢰도 설명 툴팁은 비용 라벨로 이동(이전엔 metaLabel에 붙였음).
        costLabel.toolTip = Self.costTooltip(provider: provider, confidence: costConfidence)
```

주의: `CostColor.display`의 파라미터명은 `cost:`이므로 호출은 `CostColor.display(cost: totalCost, confidence: costConfidence)`가 정확하다. (위 시드 인터페이스의 `display(cost:confidence:)` 그대로.)

(b) `metaParts`에서 비용 세그먼트 제거 (`:2449-2454`):

```swift
        let metaParts = [
            projectLabel,
            startTime,
            "\(requests) req",
        ].compactMap { $0 }.filter { !$0.isEmpty }
```

이제 미사용이 된 지역 변수 `let cost = Self.costLabel(...)` (`:2442`)는 삭제한다.

(c) 클래스에 테스트 시드 추가 (`costLabel` private static 헬퍼들 근처 `:2529` 부근):

```swift
    func costDisplayForTesting(totalCost: Double, confidence: CostConfidence) -> (text: String, color: NSColor) {
        let d = CostColor.display(cost: totalCost, confidence: confidence)
        return (d.text, d.color)
    }
    var costLabelCompressionResistanceForTesting: Float {
        costLabel.contentCompressionResistancePriority(for: .horizontal).rawValue
    }
    var titleLabelCompressionResistanceForTesting: Float {
        titleLabel.contentCompressionResistancePriority(for: .horizontal).rawValue
    }
```

- [ ] **Step 5: Run test to verify it passes + build**

Run: `RunSomeTests` (target `LupenTests`, `SessionCostLabelTests`)
Expected: PASS (3 tests).

Run: `BuildProject`
Expected: BUILD SUCCEEDED. 미사용 `Self.costLabel(totalCost:confidence:)` 정적 헬퍼가 다른 곳에서 안 쓰이면 경고 없도록 둘 다 확인 — 안 쓰이면 제거(아래 Task 4에서 처리).

- [ ] **Step 6: Commit**

```bash
git add Lupen/UI/Dashboard/SessionListViewController.swift LupenTests/UI/Dashboard/SessionCostLabelTests.swift Lupen.xcodeproj/project.pbxproj
git commit -m "feat(ui): dedicated cost label on session sidebar rows"
```

---

## Task 4: `SessionFingerprint`에 cost 반영 + 데드코드 정리

cost-only 백필(엔드타임 불변)에서도 행이 다시 그려지도록 렌더 스킵 가드(`SessionFingerprint`)에 cost를 포함한다. 그리고 비용을 메타에서 떼어내며 미사용이 된 `SessionCellView.costLabel(totalCost:confidence:)` 정적 헬퍼를 제거한다.

**Files:**
- Modify: `Lupen/UI/Dashboard/SessionListViewController.swift` — `RenderSnapshot.SessionFingerprint`(정의 `:192-219`, `RenderSnapshot` 안에 중첩) 및 fingerprint 생성 지점(`:930` 부근의 스냅샷 빌드).

**실제 정의(확인됨):** `SessionFingerprint`는 `RenderSnapshot` 구조체 안에 중첩된 `struct SessionFingerprint: Equatable`이고 멤버는 `id: String`, `endTime: Date?`, `title: String`, `isCustomTitle: Bool`, `isPinned: Bool`, `isActive: Bool`. 현재 cost 필드 없음. Equatable은 자동 합성(멤버 추가만으로 비교에 반영). `RenderSnapshot`/`SessionFingerprint` 모두 현재 `private` 중첩이므로, 테스트 접근을 위해 둘 다 `internal`로 올린다(`@testable import Lupen`로 접근).

**Interfaces:**
- Consumes: `store.sessionListAggregates[session.id]?.costUSD` (이미 `sessionCell(for:)`에서 읽음, `:1620-1623`).
- Produces: 없음.

- [ ] **Step 1: Confirm the fingerprint build site**

Run (탐색): `grep -n "SessionFingerprint(" Lupen/UI/Dashboard/SessionListViewController.swift`
Expected: 생성 지점(스냅샷 빌드, `:930` 부근)을 식별 — 거기서 각 세션의 fingerprint를 만들 때 `session` 객체가 스코프에 있는지 확인(cost 조회에 필요). cost를 `store.sessionListAggregates[session.id]?.costUSD ?? 0`로 얻을 수 있는지 확인.

- [ ] **Step 2: Write the failing test**

`LupenTests/UI/Dashboard/SessionCostLabelTests.swift`에 추가 (fingerprint가 cost 변화를 구분하는지). `endTime`은 `Date?` 타입임에 유의:

```swift
    func testFingerprintDistinguishesCostChange() {
        let when = Date(timeIntervalSince1970: 100)
        let a = SessionListViewController.RenderSnapshot.SessionFingerprint(
            id: "s1", endTime: when, title: "t", isCustomTitle: false,
            isPinned: false, isActive: false, costUSD: 1.00
        )
        let b = SessionListViewController.RenderSnapshot.SessionFingerprint(
            id: "s1", endTime: when, title: "t", isCustomTitle: false,
            isPinned: false, isActive: false, costUSD: 2.00
        )
        XCTAssertNotEqual(a, b, "비용만 바뀌어도 fingerprint는 달라져 재렌더되어야 한다")
    }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `RunSomeTests` (target `LupenTests`, `SessionCostLabelTests/testFingerprintDistinguishesCostChange`)
Expected: FAIL — `costUSD` 인자 미존재 + `private` 접근 불가 컴파일 오류.

- [ ] **Step 4: Add costUSD to the fingerprint**

(a) `RenderSnapshot`와 그 안의 `SessionFingerprint`의 `private`를 `internal`(키워드 생략)로 변경해 `@testable` 접근 허용.

(b) `SessionFingerprint`에 `let costUSD: Double`를 `isActive: Bool` 뒤에 추가(자동 합성 Equatable이 비교에 반영). 멤버 위에 한 줄 주석:

```swift
            /// Session total cost. Included so a cost-only backfill (the
            /// finalize pass reprices requests without moving endTime)
            /// still invalidates the guard and repaints the price label.
            let costUSD: Double
```

(c) fingerprint 생성 지점(Step 1에서 확인한 `:930` 부근)에서 `costUSD: store.sessionListAggregates[session.id]?.costUSD ?? 0` 인자를 추가. (세션 객체 변수명은 그 지점의 실제 이름에 맞춤.)

(d) 미사용 데드코드 제거: `SessionCellView.costLabel(totalCost:confidence:)` 정적 헬퍼(`:2529-2531`)가 Task 3 이후 어디서도 안 쓰이면 삭제. (사용처 확인: `grep -n "\.costLabel(\|Self.costLabel(" Lupen/UI/Dashboard/SessionListViewController.swift` — 호출이 0이면 제거.)

- [ ] **Step 5: Run test + full UI dashboard suite + build**

Run: `RunSomeTests` (target `LupenTests`, `SessionCostLabelTests`)
Expected: PASS (4 tests).

Run: `RunSomeTests` (target `LupenTests`, `SessionListPaginationCollapseTests`, `SessionListLoadingStateTests`)
Expected: PASS — 기존 세션 리스트 동작 회귀 없음.

Run: `BuildProject`
Expected: BUILD SUCCEEDED, 경고 없음.

- [ ] **Step 6: Commit**

```bash
git add Lupen/UI/Dashboard/SessionListViewController.swift LupenTests/UI/Dashboard/SessionCostLabelTests.swift
git commit -m "fix(ui): include session cost in render fingerprint; drop dead helper"
```

---

## Task 5: 전체 회귀 + 시각 확인

전체 테스트와 빌드로 회귀를 확인하고, 실제 앱을 띄워 사이드바 비용 라벨이 넓을 때/좁을 때 의도대로 보이는지 눈으로 검증한다.

**Files:** 없음 (검증만).

- [ ] **Step 1: Run the full UI + domain test suites**

Run: `RunSomeTests` (target `LupenTests`, UI/Support + UI/Dashboard 그룹: `CostColorTests`, `CostFormatterTests`, `SessionCostLabelTests`, `TurnOutlineCostColorTests`, `DetailCostFormatterTests`)
Expected: 모두 PASS.

- [ ] **Step 2: Full build**

Run: `BuildProject`
Expected: BUILD SUCCEEDED, 경고 없음.

- [ ] **Step 3: 시각 확인 (manual)**

앱을 실행해 사이드바를 넓게/좁게 드래그하며 확인:
- 넓을 때: 비용이 제목 줄 우측에 우측 정렬로 표시.
- 좁을 때: 제목이 `…`로 먼저 잘리고 **비용은 온전히 유지**.
- 소액($0.1 이하) 흐림, Codex 추정(`≈`) 주황, 가격 불가 `N/A` 주황 확인.
- 선택된 행(파란 하이라이트)에서 흐림 비용이 묻히지 않는지 확인 — 묻히면 `verify` 단계에서 보고.

(실행 방법은 `run` 스킬 또는 프로젝트의 기존 실행 절차를 따른다. 자동 검증이 불가하면 사용자에게 스크린샷 확인을 요청.)

- [ ] **Step 4: 최종 정리 확인**

Run: `git status --short`
Expected: 추적되지 않은 임시 산출물(스크린샷 등) 없음. 있으면 제거.

---

## Self-Review

**1. Spec coverage** — 스펙 각 섹션 대응:
- §3.1 채택안(전용 우측 라벨) → Task 3.
- §3.2 컴포넌트(`costLabel` 멤버, 12pt semibold, 메타에서 제거) → Task 3.
- §3.3 레이아웃(compression resistance, baseline, 서브에이전트 유지) → Task 3.
- §3.4 색 재사용 + `CostColor` 추출 → Task 1·2.
- §4.1 fingerprint에 cost → Task 4.
- §4.2 선택 행 대비 → Task 5 Step 3(시각 확인) + 필요 시 후속.
- §4.3 비용 폰트 12pt → Task 3 Step 3(c).
- §4.4 테스트(색/구성/레이아웃) → Task 1·3·4 테스트.
- §5 변경 파일 요약 → File Structure 표 일치.

**2. Placeholder scan** — "TBD/적절히 처리" 없음. 모든 코드 스텝에 실제 코드 포함. 단 Task 4·5는 코드가 파일 내 위치(정의 순서)에 의존하므로 "Step 1에서 정의 확인" 후 동일 패턴 적용으로 명시(코드는 제공).

**3. Type consistency** — `CostColor.display(cost:confidence:prefix:exactColor:warningThreshold:)`가 Task 1 정의와 Task 2·3 호출에서 일치. `CostDisplay { text; color }` 일관. `costDisplayForTesting` 반환 튜플 `(text, color)` 일관. `RenderSnapshot.SessionFingerprint` 실제 정의 확인 완료(`:192-219`): 멤버 `id/endTime(Date?)/title/isCustomTitle/isPinned/isActive`, `RenderSnapshot` 안에 중첩, 현재 `private`. Task 4가 `costUSD: Double` 추가 + `internal` 승격으로 맞춤. 테스트의 `endTime`은 `Date`로 작성(Int 아님).

**열린 항목:** fingerprint 생성 지점(`:930` 부근)의 세션 변수명은 Task 4 Step 1에서 확인 후 동일 패턴 적용 — 코드는 제공됨(변수명만 현장 일치). 플레이스홀더 아님.
