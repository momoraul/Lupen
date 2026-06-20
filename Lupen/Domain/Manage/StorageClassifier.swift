//
//  StorageClassifier.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 경로를 삭제 안전 분류로 매핑한다. **allowlist 기반** — 명시적으로
/// 안전하다고 판정된 경로만 `deletable`이 되고, 규칙 밖은 모두 `locked`.
///
/// 절대 제약(plan §5.1):
/// - auth / config / 앱 상태 DB(`*.sqlite`)는 **하드 차단**(`blocked`).
/// - 인덱싱 중·세션영역 밖은 차단.
/// - 세션영역(`~/.claude/projects`·`~/.codex/sessions`) 내부만 삭제 허용.
struct StorageClassifier: Sendable {

    /// provider별 영역 정의. `sessionAreaRoots` 안의 파일만 삭제 후보가 된다.
    struct Scope: Sendable, Equatable {
        /// provider 홈 (`~/.claude` 또는 `~/.codex`).
        let providerHome: URL
        /// 정리 가능한 세션영역 루트 (`projects/` 또는 `sessions/`).
        let sessionAreaRoots: [URL]
    }

    let scope: Scope
    /// "활성"으로 간주할 최근 수정 임계. 이 안에 수정된 항목은 caution.
    var activeWindow: TimeInterval = 600  // 10분

    /// 경로 하나를 분류한다.
    /// - Parameters:
    ///   - isIndexed: 인덱스가 추적 중인 항목인가(미추적이면 caution↑).
    ///   - isIndexing: 현재 해당 provider가 인덱싱 중인가(맞으면 차단).
    ///   - lastModified: 마지막 수정 시각(활성 보호 판정).
    func classify(
        path: String,
        isIndexed: Bool,
        isIndexing: Bool,
        lastModified: Date?,
        now: Date = Date()
    ) -> (classification: StorageClassification, protection: StorageProtection) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent.lowercased()

        // 1) 하드 차단: auth/config/앱 상태 DB/lock — 어디에 있든 막는다.
        if Self.isHardBlocked(name: name) {
            return (.danger, .blocked)
        }

        // 2) 인덱싱 중 — 안전을 위해 일괄 차단.
        if isIndexing {
            return (.danger, .blocked)
        }

        // 3) 세션영역 내부가 아니면 정리 불가.
        guard isInsideSessionArea(url) else {
            // provider 홈 안이긴 하면(전체 디스크 항목) 읽기전용 차단,
            // 완전히 밖이면 미분류 잠김.
            return isInsideProviderHome(url) ? (.danger, .blocked) : (.unclassified, .locked)
        }

        // 4) 세션영역 내부 — deletable. 위험도만 분류.
        if let lastModified, now.timeIntervalSince(lastModified) < activeWindow {
            return (.caution, .deletable)   // 최근 활동 — 주의하되 삭제 가능
        }
        if !isIndexed {
            return (.caution, .deletable)   // 미추적 — 주의
        }
        return (.safe, .deletable)
    }

    // MARK: - Hard-block rules

    /// auth/config/앱 상태 DB/lock 파일인지. 파일명 소문자 기준.
    static func isHardBlocked(name: String) -> Bool {
        // SQLite/DB/lock 계열 (앱 상태 — 절대 삭제 금지).
        let blockedSuffixes = [
            ".sqlite", ".sqlite3", ".db",
            ".sqlite-wal", ".sqlite-shm", ".sqlite3-wal", ".sqlite3-shm",
            ".db-wal", ".db-shm", ".lock"
        ]
        if blockedSuffixes.contains(where: { name.hasSuffix($0) }) { return true }

        // auth / credentials / config 계열.
        let blockedPrefixes = ["auth", "credentials", ".credentials", "config", ".env"]
        if blockedPrefixes.contains(where: { name.hasPrefix($0) }) { return true }

        let blockedExact = ["config.toml", "config.json", "auth.json", ".env"]
        if blockedExact.contains(name) { return true }

        return false
    }

    // MARK: - Containment

    func isInsideSessionArea(_ url: URL) -> Bool {
        scope.sessionAreaRoots.contains { Self.isDescendant(url, of: $0) }
    }

    func isInsideProviderHome(_ url: URL) -> Bool {
        Self.isDescendant(url, of: scope.providerHome)
    }

    /// `url`이 `root`의 (엄격한) 하위 경로인가. 경로 컴포넌트 prefix 비교라
    /// `..`/심볼릭이 섞여도 `standardizedFileURL`로 정규화 후 판정한다.
    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let u = url.standardizedFileURL.pathComponents
        let r = root.standardizedFileURL.pathComponents
        guard u.count > r.count else { return false }
        return Array(u.prefix(r.count)) == r
    }
}
