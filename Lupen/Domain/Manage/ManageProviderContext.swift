//
//  ManageProviderContext.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// The management-screen context for a single provider — the classifier scope
/// and FS scan roots. AppDelegate constructs it from the active provider's
/// source paths (Claude `projects/`, Codex home) and passes it to `ManageStore`.
struct ManageProviderContext: Sendable, Equatable {
    let provider: ProviderKind
    /// The provider home (`~/.claude` or `~/.codex`) — the scan root of the All Disk tab.
    let providerHome: URL
    /// The cleanable session-area roots (`projects/` or `sessions/`).
    let sessionAreaRoots: [URL]

    var classifierScope: StorageClassifier.Scope {
        StorageClassifier.Scope(providerHome: providerHome, sessionAreaRoots: sessionAreaRoots)
    }

    /// Claude: `~/.claude/projects` is the session area, its parent is the home.
    static func claude(projectsDirectory: URL) -> ManageProviderContext {
        ManageProviderContext(
            provider: .claudeCode,
            providerHome: projectsDirectory.deletingLastPathComponent(),
            sessionAreaRoots: [projectsDirectory]
        )
    }

    /// Codex: `~/.codex` is the home, `sessions/` is the session area.
    static func codex(codexHome: URL) -> ManageProviderContext {
        ManageProviderContext(
            provider: .codex,
            providerHome: codexHome,
            sessionAreaRoots: [codexHome.appendingPathComponent("sessions")]
        )
    }
}
