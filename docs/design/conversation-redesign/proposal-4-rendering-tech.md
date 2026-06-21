---
title: "Conversation 탭 리디자인 — 제안 4: rich 렌더링 기술 선택"
author: jaden
perspective: 렌더링 기술 구현
status: draft
date: 2026-06-21
---

# 제안 4 — AppKit rich 대화 뷰: 렌더링 기술 선택

> 목표: 지난 turn의 "내 프롬프트 + LLM 출력 대화"를 전용 Claude Code/Codex/Cursor 앱 수준으로
> 가독성 좋고 rich하게 보여주는 Conversation 탭. 현재는 단일 `NSTextView`에 USER/ASSISTANT 평문만
> 그려서 빈약하고 `(no response available)` 같은 빈 상태가 그대로 노출된다.

이 문서는 **"어떤 렌더링 기술로 만들 것인가"** 한 가지 관점만 다룬다. (정보 구조/큐레이션 규칙은 다른 제안서 소관)

---

## 0. 현재 상태 (코드 근거)

확인한 실제 구현:

- 단일 `NSTextView`에 직접 만든 `NSAttributedString`을 통째로 set
  - `Lupen/UI/Dashboard/DetailViewController.swift:1465` `final class ConversationDetailView: NSView, NSTextViewDelegate`
  - `DetailViewController.swift:1468` `private let textView = NSTextView()`
  - `DetailViewController.swift:1585` `textView.textStorage?.setAttributedString(attributed)`
- 구조는 USER 헤더 → 본문 → 빈 줄 → ASSISTANT 헤더 → 본문, 전부 평문
  - `DetailViewController.swift:1533` `"USER\n"`, `:1575` `"ASSISTANT\n"`
  - `DetailViewController.swift:1576` `assistantContent`를 **마크다운 파싱 없이** body 폰트로 그대로 append
- 빈 상태 문자열이 그대로 노출됨
  - `DetailViewController.swift:1566` `"(no prompt available)"`, `:1579` `"(no response available)"`
- 이미지 마커(`[Image source:]`, `[Image #N]`)만 SF Symbol 첨부로 치환하고 `file://` 링크 클릭을 가로채 Finder로 reveal
  - `DetailViewController.swift:1599` `buildBodyWithImageLinks(...)`, `:1653` `textView(_:clickedOnLink:at:)`
- **마크다운/코드 하이라이팅/diff/표/인용 블록 처리는 전혀 없음.**

데이터 모델은 이미 풍부하다 — 렌더링만 빈약한 것이 핵심 병목:

- `Lupen/Domain/Conversation/Step.swift:35` `struct Step`: `text`, `thinkingText`, `images`, `imageSourcePaths`,
  `mentionedFilePaths`, `attachments`, `toolCalls: [ToolUseInfo]`, `toolResult: ToolResultInfo?`,
  `model`, `tokens`, `cost`, `stopReasonKind` 등 (`Step.swift:76`~`:128`)
- `Lupen/Domain/Conversation/StepKind.swift`: `prompt / toolResult / toolCall / thought / reply / stop / interruption`
  7종 분류 — 말풍선/스타일을 종류별로 다르게 그릴 재료가 이미 있음.

즉 **모델은 rich한데 표현 레이어가 평문 한 덩어리**라서, 이 제안의 핵심은 "표현 레이어를 무엇으로 다시 짤지"다.

### 통합 지점 (난이도 산정의 근거)

Conversation 탭은 다른 탭들과 형제 `NSView`로, 단일 `containerView` 안에서 `isHidden` 토글로 전환된다.

- `DetailViewController.swift:34` `private let conversationView: ConversationDetailView`
- `DetailViewController.swift:113` `[conversationView, attachmentsView, tokensView, usageView, rawView]`
- `DetailViewController.swift:351` `containerView.addSubview(tabView)`
- `DetailViewController.swift:293`~ `updateVisibility()`가 모든 자식의 `isHidden`을 단일 지점에서 결정

→ **`ConversationDetailView`를 통째로 다른 구현으로 교체해도 주변 코드 영향이 격리된다.** 새 뷰가
`NSView` 하나만 노출하면 `configure(...)` 호출 시그니처만 맞추면 끝. 이게 기술 선택의 리스크를 크게 낮춘다.

### 환경 (제약이자 기회)

- `Lupen.xcodeproj/project.pbxproj`: `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.2`
  → **macOS 26 전용**. iOS 16/macOS 13 호환을 신경 쓸 필요가 전혀 없다. 최신 `AttributedString(markdown:)`,
  SwiftUI 텍스트 개선, TextKit 2가 전부 무조건 가능.
- SPM 의존성은 GRDB / Sparkle / swift-argument-parser 3개뿐 (`Package.resolved`).
  → 새 렌더링 라이브러리 도입은 의존성 트리를 의미 있게 늘리는 결정이므로 신중해야 한다.
- 프로젝트 원칙: **제로 네트워크**. 이것이 WKWebView 옵션 평가에 직접 영향(아래 참조).
- SwiftUI는 이미 앱 전반에서 `NSHostingView`/`NSHostingController`로 AppKit에 임베드 중
  (Preferences, Reports, Diagnostics, Log, 그리고 Dashboard의 `LaunchProgressView`까지).
  → **SwiftUI를 AppKit 안에 끼워 넣는 패턴이 이미 검증된 사내 표준이다.** 새로운 통합 기술이 아니다.

---

## 1. 후보 기술 4종 비교

| 기준 | A. NSTextView + NSAttributedString (TextKit 2) | B. WKWebView (md→HTML/CSS) | C. SwiftUI(NSHostingView) | D. NSStackView/NSCollectionView 조립 |
|---|---|---|---|---|
| 마크다운 | `AttributedString(markdown:)` 인라인만 기본 지원, 블록(표/코드펜스/인용)은 직접 처리 | 완벽 (md 라이브러리→HTML) | 인라인 기본, 블록은 MarkdownUI/Textual 필요 | 라이브러리 + 직접 조립 |
| 코드 하이라이팅 | Splash 등으로 AttributedString 생성 가능 | highlight.js/Splash→HTML, 가장 풍부 | MarkdownUI + Splash 연동 | Splash→AttributedString |
| diff 표시 | 줄별 배경색으로 직접 구현 (중간) | CSS로 쉬움 | 커스텀 뷰로 구현 (쉬움) | 커스텀 행 뷰 (쉬움) |
| 인라인 이미지/첨부 | text attachment (이미 함) | `<img>` 자연스러움 | 이미지 인라인+선택은 약점 | 셀에 NSImageView (쉬움) |
| 선택/복사 | **네이티브 최강** (전체 연속 선택) | 가능하나 JS/포커스 이슈 | **블록 경계 넘는 선택이 약점** | 셀 경계에서 선택 끊김 |
| 검색 하이라이트 | 텍스트 스토리지에 직접 적용 (강함) | `window.find`/JS 주입 | 직접 구현 부담 | 셀별 직접 구현 |
| 긴 대화 성능/가상화 | TextKit 2가 viewport 기반 레이아웃 (강함) | DOM 비대 시 무거움 | List/LazyVStack 재사용 (강함) | 셀 재사용 (강함) |
| 다크모드 | NSColor 다이내믹 자동 | CSS `prefers-color-scheme` 직접 | 자동 | 자동 |
| 접근성(VoiceOver) | 네이티브 강함 | 웹 ARIA, AppKit과 결 다름 | 강함 | 강함 |
| Lupen 통합 난이도 | **낮음** (이미 NSTextView) | 중간 (새 스택, 제로네트워크 검토) | **낮음** (NSHostingView 표준화됨) | 중간 (보일러플레이트 큼) |
| 의존성 추가 | 없음~Splash 1개 | md 변환기 1개 | MarkdownUI/Textual + Splash | Splash 정도 |

---

## 2. 각 옵션 트레이드오프 상세

### A. NSTextView + NSAttributedString (+ TextKit 2)
- **장점**: 지금 코드의 직계 진화. 텍스트 선택/복사/검색 하이라이트가 네이티브로 가장 강력하고,
  TextKit 2는 viewport 기반 레이아웃으로 긴 문서 스크롤이 GPU 친화적이다. 의존성 0으로도 출발 가능.
  macOS의 텍스트 렌더링 충실도가 가장 높다는 평가([Eclectic Light], [fatbobman]).
- **단점**: 블록 레벨 마크다운(표, 코드펜스 배경, 인용 막대, 체크리스트)을 전부 `NSTextList`/문단 스타일/
  text attachment로 손수 조립해야 함. "말풍선(버블) UI"처럼 컨테이너 단위 배경/모서리 둥글림을 한 텍스트뷰
  안에서 구현하는 건 어색하다(문단 배경은 가능하나 카드 레이아웃엔 부적합).
- **적합도**: 한 turn = "긴 글 한 편"으로 보고, 자연스러운 본문 흐름 + 인라인 코드/리스트/이미지 정도면 최적.
  카드/버블이 즐비한 화면을 원하면 부적합.

### B. WKWebView (마크다운→HTML/CSS)
- **장점**: 마크다운/코드 하이라이팅/표/diff/수식까지 가장 풍부하고 빠르게 만들 수 있다. 디자인 자유도 최고
  (CSS). LLM 채팅 UI를 웹뷰로 만드는 사례가 흔함([designcode], [Eclectic Light]).
- **단점 (Lupen 한정 치명적)**:
  - **제로 네트워크 원칙과 충돌**. 외부 CDN(highlight.js, KaTeX)을 절대 못 부르므로 모든 자산을 번들에
    인라인해야 한다. WKWebView가 무심코 외부 리소스를 로드하지 않도록 CSP/스킴 핸들러를 잠가야 함.
  - AppKit 네이티브 패널 한복판에 웹뷰 한 장을 끼우면 **선택/포커스/접근성/우클릭 메뉴/스크롤 관성**이
    주변 AppKit과 미묘하게 어긋난다. Lupen은 "Activity Monitor/Xcode 인스펙터 같은 네이티브 데이터 표면"을
    지향(`DetailStyles.swift` 주석)하므로 톤이 깨진다.
  - DOM이 커지면(아주 긴 turn) 메모리/레이아웃 비용이 텍스트뷰보다 무겁다.
- **적합도**: diff/표/수식이 핵심이고 디자인을 크게 자유화하고 싶을 때만. Lupen 철학과는 가장 멀다.

### C. SwiftUI (NSHostingView) — **권고안**
- **장점**:
  - **사내 표준 패턴**. 이미 Preferences/Reports/Diagnostics/Log/LaunchProgress가 전부 SwiftUI를
    `NSHostingView`로 AppKit에 임베드함. Conversation 탭만 새 기술이 아니다. 통합 위험이 최저.
  - 채팅 UI(말풍선, 카드, role별 스타일, 헤더/푸터 메타데이터)를 선언형으로 빠르게 조립. `List`/`LazyVStack`
    가상화로 긴 대화 성능 확보.
  - macOS 26 전용이라 SwiftUI 텍스트/레이아웃의 최신 개선을 제약 없이 사용.
  - 다크모드/다이내믹 타입/접근성이 기본으로 따라온다.
- **단점/리스크**:
  - SwiftUI `Text`의 기본 마크다운은 **인라인 한정**(링크/강조/취소선) — 이미지·코드펜스·표 등 블록은 안 됨
    ([hackingwithswift], [gonzalezreal]). 블록 렌더링엔 라이브러리나 보강이 필요.
  - **블록 경계를 넘는 텍스트 선택/복사가 SwiftUI의 약점**([fatbobman]: SwiftUI는 "뷰 per 노드"라
    연속 선택이 안 됨). Lupen은 "복사 가능한 데이터 표면"이 중요(`DetailStyles.swift` 주석)이라 이게 핵심 과제.
  - MarkdownUI는 **maintenance mode**, 후속작 Textual은 아직 초기([swift-markdown-ui README]).
    외부 라이브러리에 큰 면적을 의존하는 건 리스크.
- **적합도**: 채팅스러운 큐레이션 화면(role 버블/카드, step 요약, 메타 칩)에는 가장 자연스럽다.

### D. NSStackView / NSCollectionView 행 조립
- **장점**: 셀(행) 단위로 step별 다른 위젯(텍스트 카드 / 코드 카드 / diff 카드 / 이미지 / 툴콜 칩)을 자유 조립.
  NSCollectionView는 셀 재사용으로 긴 대화에 강함. 각 셀 내부는 다시 작은 NSTextView로 선택/복사 보장 가능.
- **단점**: 보일러플레이트가 가장 많다(데이터소스/레이아웃/사이징 캐시). 셀 경계를 넘는 연속 선택은 불가
  (셀별 선택만). 사실상 위 SwiftUI `List`로 얻는 것을 AppKit으로 더 힘들게 만드는 셈.
- **적합도**: SwiftUI를 피해야 할 강한 이유가 있을 때의 순수 AppKit 폴백.

---

## 3. 권고안

### 메인 권고: **C (SwiftUI + NSHostingView) 채팅 셸 + 셀 본문은 "텍스트 선택 우선" 하이브리드**

큐레이션된 채팅 화면(role 버블/카드, step 칩, 메타 정보)은 SwiftUI의 강점이 그대로 들어맞고, **이미 검증된
사내 임베드 패턴**이라 통합 리스크가 가장 낮다. 단, SwiftUI의 약점인 "블록 넘는 선택/복사"와 "블록 마크다운"은
다음 두 보강으로 메운다:

1. **본문 텍스트 블록은 SwiftUI `Text` 대신 얇은 `NSViewRepresentable(NSTextView)` 래퍼로 렌더**
   (한 메시지 본문 = 한 텍스트뷰). 마크다운은 `AttributedString(markdown:)`(인라인) +
   코드펜스/리스트/인용은 직접 attribute 조립. 이러면 **메시지 내부 연속 선택/복사/검색 하이라이트가
   네이티브로 살아난다**. 옵션 C의 최대 약점을 옵션 A의 최강점으로 덮는 구조.
2. **코드 블록은 Splash로 `NSAttributedString` 신택스 하이라이팅**해서 같은 텍스트뷰(또는 코드 전용 카드)에
   넣는다. Splash는 순수 Swift·네트워크 없음·가벼움([Splash])이라 제로네트워크/의존성 최소화 원칙에 부합.
   Swift 외 언어는 1차로는 단색 모노스페이스로 두고 점진 확장.

> 핵심: **"바깥 채팅 레이아웃은 SwiftUI, 안쪽 본문 텍스트는 NSTextView"**. 두 기술의 약점이 서로의 강점으로
> 정확히 상쇄된다.

### 마크다운 파서 선택
- **권장: Apple `swift-markdown`(cmark-gfm 기반) 또는 Foundation `AttributedString(markdown:)`**
  - 인라인만 빠르게 원하면 Foundation 내장 `AttributedString(markdown:)` — **의존성 0**.
  - 표/체크리스트/코드펜스까지 정확히 다루려면 Apple `swift-markdown`으로 AST를 받아 우리가
    `NSAttributedString`으로 매핑(블록 스타일을 우리 디자인에 맞춤). Apple 공식·GFM 호환.
- **MarkdownUI/Textual는 비권장(주력 의존으로는)**: maintenance mode + 후속작 초기 단계라 큰 면적을
  맡기기엔 리스크. 다만 빠른 프로토타입엔 참고 가능.

### diff 표시
- Edit/MultiEdit 툴콜의 old/new를 줄 단위로 비교해 **추가=초록 배경 / 삭제=빨강 배경**을 문단 attribute로
  적용(같은 NSTextView 안에서). diff 라이브러리 없이 단순 LCS 한 번이면 충분. 화면 자유도가 더 필요해지면
  diff만 별도 카드 뷰로 분리.

---

## 4. 화면 레이아웃 스케치 (ASCII)

한 turn을 "큐레이션된 채팅"으로 — 노이즈(중간 toolResult 원문, 시스템 주입 등)는 접고, 대화·결정·산출만.

```
┌─ Conversation 탭 (SwiftUI List, NSHostingView로 임베드) ───────────────┐
│                                                                        │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ 🧑 You                                          14:03 · sonnet-4 │  │  ← role 헤더(메타 칩)
│  │ ----------------------------------------------------------------- │  │
│  │ DetailViewController의 Conversation 탭을 rich하게 바꿔줘.          │  │  ← 본문 = NSTextView 래퍼
│  │ 🖼 screenshot.png                                                 │  │     (선택/복사 네이티브)
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ 🤖 Assistant                                                      │  │
│  │ ----------------------------------------------------------------- │  │
│  │ 현재 구조를 먼저 확인하겠습니다.                                    │  │  ← thought(접기 가능)
│  │                                                                  │  │
│  │  ▸ 🔧 Read DetailViewController.swift                             │  │  ← toolCall 칩(기본 접힘)
│  │  ▸ 🔧 Edit DetailViewController.swift   (+18 −4)                  │  │
│  │                                                                  │  │
│  │  ```swift                                                        │  │  ← 코드: Splash 하이라이팅
│  │  func configure(messages: [Message]) {                          │  │     (NSAttributedString)
│  │      list.setMessages(messages)                                 │  │
│  │  }                                                              │  │
│  │  ```                                                            │  │
│  │                                                                  │  │
│  │  diff:  + list.setMessages(messages)     ← 초록 배경            │  │  ← diff 문단 배경
│  │         - textView.setString(text)       ← 빨강 배경            │  │
│  │                                                                  │  │
│  │ 완료했습니다. 이제 Conversation 탭이 …                            │  │  ← reply 본문
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  (빈 응답일 때) ⓘ 이 turn은 도구 실행만 있고 텍스트 응답은 없습니다.   │  ← "(no response available)" 대체
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

빈 상태 개선: 현재 `(no response available)`(`DetailViewController.swift:1579`) 대신, 그 turn에 실제로 무엇이
있었는지(예: "도구 3회 실행, 텍스트 응답 없음")를 안내 칩으로 보여줘 "비어 보이는" 느낌을 없앤다.

### 마크업/코드 스케치 (구조 감 잡기용)

```swift
// 바깥 셸 = SwiftUI, 임베드는 기존 사내 패턴 그대로 (NSHostingView)
struct ConversationView: View {
    let messages: [ConversationMessage]   // Step에서 큐레이션해 만든 표시용 모델
    var body: some View {
        List(messages) { msg in
            MessageRow(message: msg)       // role 헤더 + 본문 + 툴콜 칩
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }
}

// 본문 텍스트만 NSTextView로 — 선택/복사/검색 하이라이트를 네이티브로 보존
struct SelectableRichText: NSViewRepresentable {
    let attributed: NSAttributedString    // AttributedString(markdown:) + Splash 코드블록 합성
    func makeNSView(context: Context) -> NSTextView { /* isEditable=false, isSelectable=true */ }
    func updateNSView(_ tv: NSTextView, context: Context) {
        tv.textStorage?.setAttributedString(attributed)
    }
}
```

`DetailViewController`에서의 교체는 `conversationView` 한 곳만:
현재 `ConversationDetailView`(`:1465`)를 `NSHostingView<ConversationView>`를 감싼 `NSView`로 바꾸고
`configure(humanPrompt:assistantContent:)`(`:1513`) 대신 큐레이션된 `[ConversationMessage]`를 받게 한다.
형제 뷰 `isHidden` 토글 구조(`:293` `updateVisibility()`)는 손대지 않는다.

---

## 5. 적용 난이도 (Lupen 현 아키텍처 기준)

| 항목 | 난이도 | 근거 |
|---|---|---|
| SwiftUI 임베드 자체 | 낮음 | 이미 5+개 뷰가 NSHostingView 사용. 검증된 패턴. |
| Conversation 탭 교체 | 낮음 | 형제 NSView + `isHidden` 토글이라 격리됨(`DetailViewController.swift:113,351,293`) |
| 표시용 모델(Step→Message) 큐레이션 | 중간 | 모델은 풍부(`Step.swift`/`StepKind.swift`)하나 "무엇을 접고 무엇을 보일지" 규칙 설계 필요(타 제안서 영역) |
| 마크다운(인라인) | 낮음 | Foundation `AttributedString(markdown:)`, 의존성 0 |
| 마크다운(블록: 표/코드펜스/인용) | 중간 | Apple `swift-markdown` AST → 우리 attribute 매핑 |
| 코드 하이라이팅 | 중간 | Splash 1개 추가, Swift 우선·점진 확장 |
| diff | 낮음~중간 | LCS + 문단 배경, 라이브러리 불필요 |
| 본문 선택/복사 보존 | 중간 | NSViewRepresentable(NSTextView) 래퍼로 해결(이 제안의 핵심 설계) |

---

## 6. 트레이드오프·리스크 요약

- **C(SwiftUI)의 선택/복사 약점**은 본문을 NSTextView 래퍼로 처리해 상쇄 — 단, "메시지 경계를 넘는" 전체
  대화 통선택은 포기(메시지 단위 선택). 전용 앱들(Claude/ChatGPT)도 보통 메시지 단위 복사라 수용 가능.
- **외부 라이브러리 의존**: MarkdownUI/Textual에 주력 의존하는 건 비권장(유지보수 상태 불안정). Apple
  `swift-markdown` + Splash 정도로 의존을 최소화한다. 그래도 의존성 2개 증가 — Splash조차 피하려면 코드블록을
  단색 모노스페이스로 두는 옵션도 있음.
- **WKWebView(B)는 제로 네트워크/네이티브 톤 두 원칙과 정면 충돌**하므로 배제 권고. diff·표·수식 욕심이
  매우 커지기 전까지는 부적합.
- **순수 NSTextView(A)** 만으로 가는 길도 유효하다(의존성 0, 선택/복사 최강). 다만 "카드/버블 채팅 UI"
  레이아웃 자유도가 떨어져 전용 앱 같은 큐레이션 느낌을 내기 어렵다. 화면 방향이 "긴 글 한 편"이면 A가 더 단순.
- **성능**: SwiftUI `List` 가상화 + 메시지별 텍스트뷰로 긴 대화도 안전. 단, 메시지 내부가 비정상적으로 긴
  경우(거대한 단일 toolResult 등)는 큐레이션 단계에서 접기/말줄임으로 막아야 함.

---

## 7. 참고한 앱·기법과 출처

- 전용 채팅 앱 패턴 참고: Claude Code 앱 / Codex 앱 / Cursor / ChatGPT — role 버블, step 접기, 코드/ diff 카드.
- NSTextView vs WKWebView vs SwiftUI 텍스트 트레이드오프, TextKit 2 성능:
  [Eclectic Light — SwiftUI on macOS: text/markdown/html/PDF](https://eclecticlight.co/2024/05/07/swiftui-on-macos-text-rich-text-markdown-html-and-pdf-views/)
- SwiftUI rich text 레이아웃 심층(블록 선택 한계, NSTextView 브리징, "뷰 per 노드"):
  [fatbobman — A Deep Dive into SwiftUI Rich Text Layout](https://fatbobman.com/en/posts/a-deep-dive-into-swiftui-rich-text-layout/)
- SwiftUI `Text` 마크다운은 인라인 한정:
  [Hacking with Swift — render Markdown content in text](https://www.hackingwithswift.com/quick-start/swiftui/how-to-render-markdown-content-in-text)
- 마크다운 라이브러리/유지보수 상태(MarkdownUI maintenance, Textual 후속):
  [swift-markdown-ui (gonzalezreal)](https://github.com/gonzalezreal/swift-markdown-ui),
  [Better Markdown Rendering in SwiftUI](https://gonzalezreal.github.io/2023/02/18/better-markdown-rendering-in-swiftui.html)
- 코드 신택스 하이라이팅(순수 Swift, 경량):
  [Splash (JohnSundell)](https://github.com/JohnSundell/Splash)
- 웹뷰 코드 하이라이팅 사례(B 옵션 참고):
  [Design+Code — Code Highlighting in a WebView](https://designcode.io/swiftui-advanced-handbook-code-highlighting-in-a-webview/)
- LLM 스트리밍 채팅 UI(SwiftUI, MarkdownUI 의존):
  [GetStream — stream-chat-swift-ai](https://github.com/GetStream/stream-chat-swift-ai)
