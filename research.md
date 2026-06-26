# Research: 다중 세션 소스 경로 인식/추가 개선

> 작성: jaden · 2026-06-26 · 브랜치 feat/appearance-mode
> 목적: Xcode Coding Assistant처럼 별도 경로에 저장되는 세션을 Lupen이 모니터링하지 못하는 문제의 해결 방향 조사

## 1. 문제 정의

Claude Code는 실행 환경(프런트엔드)에 따라 세션 JSONL을 서로 다른 루트에 쓴다.

| 실행 환경 | 세션 저장 경로(실측) |
|---|---|
| 터미널 `claude` CLI | `~/.claude/projects/<슬러그>/*.jsonl` |
| Xcode Coding Assistant | `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects/<슬러그>/*.jsonl` |

두 경로 모두 같은 프로젝트 슬러그(`-Users-user--work--lupen-main`)를 쓰지만, Lupen은 **`~/.claude/projects` 한 곳만** 스캔하므로 Xcode 세션의 비용·대화가 전혀 잡히지 않는다. 사용자가 다른 프런트엔드를 쓰면 모니터링 사각지대가 생긴다.

## 2. 현재 경로 결정 구조 (코드 근거)

### 2.1 Claude Code 루트
- `FileDiscovery.baseDirectory` — `Lupen/Data/FileDiscovery.swift:20-26`
  - `CLAUDE_CONFIG_DIR` 환경변수 → 없으면 `~/.claude`. **단일 경로만** 반환.
- `ClaudeProvider.defaultSourceRoot` = `fileDiscovery.projectsDirectory` (`~/.claude/projects`) — `ClaudeProvider.swift:25-27`
- `AppStateStore.effectiveProjectsDirectory` — `Lupen/Domain/AppStateStore.swift:78-80`
  - `projectsDirectoryOverride ?? claudeProvider.defaultSourceRoot`. **단일 루트.**
- `CLIRefresher.source(for:)` — `Lupen/CLI/CLIRefresher.swift:29-34`
  - Claude는 `FileDiscovery().projectsDirectory` **하나**만 인덱싱.

### 2.2 Codex 루트
- `CodexSessionDiscovery.codexHome` — `Lupen/Domain/Codex/CodexSessionDiscovery.swift:10-23`
  - 생성자 인자 → `CODEX_HOME` 환경변수 → `~/.codex`. **단일 경로.**

### 2.3 파일 감시
- `SQLiteFirstStartup.startWatching()` — `Lupen/Store/SQLiteFirstStartup.swift:278-293`
  - source(claude/codex)에서 **단일 디렉토리** 하나를 골라 watcher에 전달.
- `FileWatcher.startWatching(directory:)` — `Lupen/Data/FileWatcher.swift:43-89`
  - `let paths = [directory.path]` — FSEventStream **하나**, 경로 배열 원소 1개.
  - `self.stream` 단일 보관. **멀티 루트 감시 미지원.**
  - 단, `FSEventStreamCreate`의 `paths` 인자는 원래 **다중 경로 배열을 받는 API** → 한 스트림으로 여러 루트 감시가 기술적으로 가능(중요).

### 2.4 이미 존재하는 멀티 루트 스켈레톤 (핵심)
- `ProviderConfiguration.sourceRoots: [URL]` (복수 배열) — `Lupen/Domain/Providers/ProviderConfiguration.swift:11-23`
- `AppSettingsData.providerConfigurations: ProviderConfigurationStore` 로 **이미 영속화됨** — `AppSettingsStorage.swift:17`
- **그러나** grep 결과 `sourceRoots`를 실제 discover/scan/watch에서 읽는 코드는 **0곳**. `fingerprint` 직렬화에만 쓰임.
- **결론: 멀티 루트용 데이터 모델/영속화는 이미 깔려 있고, 파이프라인 연결만 안 된 상태.** 개선 비용이 생각보다 작다.

## 3. 제약 / 함정

### 3.1 GUI 앱은 셸 환경변수를 못 본다 (중요)
- 현재 자동 인식의 유일한 수단은 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` 환경변수다.
- 메뉴바 앱은 launchd가 띄우므로 사용자가 `~/.zshrc` 등에 설정한 환경변수가 `ProcessInfo.environment`에 **들어오지 않을 수 있다**. (CLI는 셸에서 실행되어 보임 → 앱/CLI 간 인식 불일치 위험)
- 따라서 환경변수 의존만으로는 자동 인식이 불완전하다.

### 3.2 프로젝트 슬러그 충돌
- 서로 다른 루트에 같은 슬러그 디렉토리가 존재(예: 터미널과 Xcode 둘 다 `-Users-user--work--lupen-main`).
- `DiscoveredFile.projectPath`는 슬러그(디렉토리명)이므로, 단순 머지 시 두 루트의 세션이 **같은 프로젝트 그룹으로 합쳐진다**. 세션 자체는 UUID라 충돌하지 않지만, 같은 세션이 두 루트에 복제될 경우 중복 집계 위험.
- 머지 정책 필요: 세션 ID(UUID) 기준 dedup, 그리고 "어느 루트에서 왔는지" 출처 태그를 유지할지 결정.

### 3.3 샌드박스 — 유리한 점
- `Lupen.entitlements`가 빈 `<dict/>` → **샌드박스 비활성**. 임의 경로를 보안 스코프 북마크 없이 자유롭게 읽을 수 있다. 사용자 임의 폴더 추가 기능 구현 난도가 낮다.

### 3.4 인덱스/캐시 일관성
- SQLite 인덱스는 provider별 단일 DB(`LupenPaths.indexDatabaseURL`). 멀티 루트 세션을 같은 DB에 넣어도 세션 단위라 무방하나, `ProviderConfiguration.fingerprint`에 루트 집합이 포함되므로 **루트 추가/삭제 시 재인덱싱 트리거**가 자연스럽게 걸리도록 연결해야 함.

## 4. 개선 옵션

### 옵션 A — 자동 인식(Auto-discovery)
알려진 후보 경로를 부팅 시 스캔해 존재하면 자동 편입.
- 후보: `~/.claude/projects`(기본), `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects`(Xcode), `CLAUDE_CONFIG_DIR`(있으면), 향후 다른 IDE 통합 경로.
- 장점: 사용자 개입 0. "그냥 다 잡힘".
- 단점: 후보 목록을 코드에 하드코딩 → 새 프런트엔드 등장 시 업데이트 필요. 환경변수 한계(3.1).

### 옵션 B — 수동 추가(User-managed)
Settings에 "세션 폴더" 목록 + NSOpenPanel로 추가/제거.
- 장점: 임의 경로 지원, 명시적, 미래 호환. 구현 패턴 이미 존재(`ManageViewController.export()`의 NSOpenPanel, `PreferencesForm`의 섹션 패턴).
- 단점: 사용자가 경로를 알고 직접 추가해야 함(발견성 낮음).

### 옵션 C — 하이브리드 (권장)
자동 인식으로 알려진 경로를 기본 편입 + Settings에서 사용자가 추가/제거/토글.
- 이미 있는 `ProviderConfiguration.sourceRoots`를 **실제로 활성화**하는 방향과 정확히 일치.
- 자동 발견 경로는 "감지됨" 배지로 표시하고, 사용자가 끄거나 임의 경로를 더할 수 있게.

## 5. 권장 방향과 변경 범위 (Plan 후보)

하이브리드(C). 데이터 모델이 이미 멀티 루트라 "파이프라인을 배열로 일반화"하는 작업이 핵심이다.

1. **루트 해석 계층 신설** — provider별 "유효 루트 집합" 계산(기본 루트 + 자동 감지 + 사용자 추가 - 비활성). `sourceRoots`를 단일 진실 공급원으로.
2. **discover 멀티 루트화** — `discoverFiles(in:)`를 루트 배열에 대해 반복 후 머지. 세션 UUID 기준 dedup, 출처(루트) 태그 보존.
3. **FileWatcher 멀티 경로** — `startWatching(directories: [URL])`로 일반화하고 `FSEventStreamCreate`에 경로 배열 전달(스트림 1개 유지 가능).
4. **자동 감지기** — 알려진 후보 경로 존재 검사 모듈(테스트 가능하게 순수 함수로).
5. **Settings UI** — `PreferencesForm`에 "Session Sources" 섹션(목록 + 추가/제거, NSOpenPanel). Appearance Mode 추가 패턴(`PreferencesForm.swift:58-73`, `AppSettings` didSet→schedulePersist, `AppDelegate` withObservationTracking) 그대로 차용.
6. **재인덱싱 연결** — 루트 집합 변경 → `fingerprint` 변경 → 재스캔/재인덱싱(`syncStoreToActiveProvider` 경로).
7. **CLI 동기화** — `CLIRefresher.source(for:)`도 같은 루트 해석 계층을 사용하도록.

### 미해결 결정 사항 (Plan 단계에서 확정 필요)
- 자동 인식 범위: Xcode 경로만 추가할지, 일반화된 후보 목록을 둘지.
- 슬러그 충돌 시 UI 표기: 출처별로 구분 표시할지, 합쳐서 보여줄지.
- 자동 감지 경로를 기본 ON으로 할지(조용히 편입) vs 첫 발견 시 사용자에게 알릴지.
- 환경변수(`CLAUDE_CONFIG_DIR`/`CODEX_HOME`) 자동 인식의 GUI 한계를 어떻게 보완할지.

## 6. 참고 파일
- `Lupen/Data/FileDiscovery.swift` — 루트/스캔
- `Lupen/Data/FileWatcher.swift` — FSEvents 감시
- `Lupen/Domain/Providers/ProviderConfiguration.swift` — 멀티 루트 모델(미연결)
- `Lupen/Domain/AppStateStore.swift` — 앱 측 루트 결정
- `Lupen/Store/SQLiteFirstStartup.swift` — 부팅/감시 시작
- `Lupen/CLI/CLIRefresher.swift` — CLI 측 루트 결정
- `Lupen/UI/Preferences/PreferencesForm.swift` — 설정 UI(추가 패턴 참조)
- `Lupen/Cache/AppSettingsStorage.swift` — 설정 영속화
- `Lupen/Domain/Codex/CodexSessionDiscovery.swift` — Codex 루트
