//
//  CLISourceResolver.swift
//  Lupen
//
//  Created by jaden on 2026/06/26.
//

import Foundation

/// Resolves a `--provider`/`--source` CLI argument to a `SessionSource` so the
/// terminal and the app share one source definition (plan §5.4). Built-in
/// aliases keep working (`claude` / `claude-code` / `claudeCode`, `codex`);
/// any other argument matches an enabled source by its stable id or its
/// case-insensitive name.
///
/// ⚠️ Scope note (plan §5.4): user-registered sources are app↔CLI identical,
/// but env-derived built-in roots (CLAUDE_CONFIG_DIR / CODEX_HOME) depend on
/// the launch context, so a terminal run may resolve a different directory
/// than the GUI for the built-ins.
enum CLISourceResolver {

    /// Pure resolution against a provided source list.
    static func resolve(_ argument: String, in sources: [SessionSource]) -> SessionSource? {
        let arg = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        switch arg.lowercased() {
        case "claude", "claude-code", "claudecode":
            return sources.first { $0.origin == .builtin && $0.kind == .claudeCode }
        case "codex":
            return sources.first { $0.origin == .builtin && $0.kind == .codex }
        default:
            break
        }
        if let byId = sources.source(id: arg) { return byId }
        let lower = arg.lowercased()
        return sources.first { $0.name.lowercased() == lower }
    }

    /// Live resolution: load the persisted app settings, compose the canonical
    /// source list, and resolve. `settingsURL` is injectable for tests; the
    /// default reads the same file the GUI writes.
    static func resolveLive(_ argument: String, settingsURL: URL? = nil) -> SessionSource? {
        let saved = AppSettingsStorage(fileURL: settingsURL).load().sessionSources
        let resolved = SessionSourceRegistry.resolve(saved: saved)
        return resolve(argument, in: resolved)
    }
}
