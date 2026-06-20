//
//  ManageProviderContext.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 한 provider에 대한 관리 화면 컨텍스트 — 분류기 영역과 FS 스캔 루트.
/// AppDelegate가 활성 provider의 소스 경로(Claude `projects/`, Codex 홈)로
/// 구성해 `ManageStore`에 넘긴다.
struct ManageProviderContext: Sendable, Equatable {
    let provider: ProviderKind
    /// provider 홈 (`~/.claude` 또는 `~/.codex`) — 전체 디스크 탭의 스캔 루트.
    let providerHome: URL
    /// 정리 가능한 세션영역 루트 (`projects/` 또는 `sessions/`).
    let sessionAreaRoots: [URL]

    var classifierScope: StorageClassifier.Scope {
        StorageClassifier.Scope(providerHome: providerHome, sessionAreaRoots: sessionAreaRoots)
    }

    /// Claude: `~/.claude/projects`가 세션영역, 그 부모가 홈.
    static func claude(projectsDirectory: URL) -> ManageProviderContext {
        ManageProviderContext(
            provider: .claudeCode,
            providerHome: projectsDirectory.deletingLastPathComponent(),
            sessionAreaRoots: [projectsDirectory]
        )
    }

    /// Codex: `~/.codex`가 홈, `sessions/`가 세션영역.
    static func codex(codexHome: URL) -> ManageProviderContext {
        ManageProviderContext(
            provider: .codex,
            providerHome: codexHome,
            sessionAreaRoots: [codexHome.appendingPathComponent("sessions")]
        )
    }
}
