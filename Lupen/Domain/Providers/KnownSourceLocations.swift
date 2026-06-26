//
//  KnownSourceLocations.swift
//  Lupen
//
//  Created by jaden on 2026/06/26.
//

import Foundation

/// Auto-detection of well-known session-log locations beyond the two built-in
/// defaults (`~/.claude/projects`, `~/.codex/sessions`).
///
/// Detected sources are returned **disabled** — the user explicitly activates
/// them in Settings (whitelist model), so nothing is indexed without consent.
/// Pure and fully injectable (`environment`/`home`/`fileManager`) for tests.
/// Extend coverage by adding a row to `candidateTable`.
enum KnownSourceLocations {

    /// Existing, readable candidate directories, each as a disabled
    /// `.autoDetected` source. Built-in default roots are intentionally NOT
    /// returned here (they are injected separately as `.builtin`).
    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [SessionSource] {
        candidateTable(environment: environment, home: home).compactMap { candidate in
            guard isReadableDirectory(candidate.probe, fileManager: fileManager) else { return nil }
            return SessionSource(
                id: candidate.id,
                name: candidate.name,
                kind: candidate.kind,
                root: candidate.root,
                origin: .autoDetected,
                enabled: false
            )
        }
    }

    private struct Candidate {
        let id: String
        let name: String
        let kind: ProviderKind
        /// The base directory the pipeline indexes. For Claude this is the
        /// `projects` directory it scans directly; for Codex it is the
        /// `codexHome` (parent of `sessions/`), because the importer also
        /// reads `session_index.jsonl` from that parent.
        let root: URL
        /// The directory whose existence gates inclusion. Defaults to `root`;
        /// Codex probes `root/sessions` so a bare `$CODEX_HOME` without any
        /// recorded sessions isn't surfaced.
        var existenceProbe: URL? = nil
        var probe: URL { existenceProbe ?? root }
    }

    private static func candidateTable(environment: [String: String], home: URL) -> [Candidate] {
        var rows: [Candidate] = [
            Candidate(
                id: "xcode-claude",
                name: "Xcode Claude",
                kind: .claudeCode,
                root: home.appendingPathComponent(
                    "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects"
                )
            )
        ]
        if let dir = trimmedEnv(environment["CLAUDE_CONFIG_DIR"]) {
            rows.append(Candidate(
                id: "claude-config-dir",
                name: "CLAUDE_CONFIG_DIR",
                kind: .claudeCode,
                root: expand(dir).appendingPathComponent("projects")
            ))
        }
        if let dir = trimmedEnv(environment["CODEX_HOME"]) {
            let codexHome = expand(dir)
            rows.append(Candidate(
                id: "codex-home",
                name: "CODEX_HOME",
                kind: .codex,
                root: codexHome,
                existenceProbe: codexHome.appendingPathComponent("sessions")
            ))
        }
        return rows
    }

    private static func trimmedEnv(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    private static func isReadableDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
