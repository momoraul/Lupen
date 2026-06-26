//
//  SessionSourceRegistry.swift
//  Lupen
//
//  Created by jaden on 2026/06/26.
//

import Foundation

/// Single source of truth for the *canonical, ordered* list of session
/// sources the app knows about. It overlays three layers:
///
///   1. **builtins** — Claude Code / Codex defaults, always present, enabled.
///   2. **auto-detected** — `KnownSourceLocations.detect()` candidates,
///      disabled until the user activates them (whitelist model).
///   3. **saved overrides** — `AppSettings.sessionSources`: the user's
///      enable/name changes to the above, plus any folders they added.
///
/// The picker, indexing driver set, and active-source resolution all read
/// from this one composition so they never disagree about which sources
/// exist or are active.
///
/// Pure and fully injectable — `compose` takes the three layers directly so
/// the merge policy is unit-testable without touching disk or environment.
enum SessionSourceRegistry {

    /// Built-in source ids equal `ProviderKind.rawValue` so each maps to its
    /// pre-existing index folder (`providers/<id>/index.sqlite3`) — upgrading
    /// to the multi-source model re-uses the current index with no rebuild.
    static var claudeBuiltinID: String { ProviderKind.claudeCode.rawValue }
    static var codexBuiltinID: String { ProviderKind.codex.rawValue }

    /// The single built-in source for a parser kind. Used both as the default
    /// active source and as the projection-swap target while only built-in
    /// sources are activatable. Enabled by default; id equals the kind's
    /// rawValue (see above). Root is injected so it stays faithful to the
    /// env-aware default the pipeline actually scans.
    static func builtinSource(for kind: ProviderKind, claudeRoot: URL, codexRoot: URL) -> SessionSource {
        switch kind {
        case .claudeCode:
            return SessionSource(
                id: claudeBuiltinID,
                name: ProviderRegistry.descriptor(for: .claudeCode).displayName,
                kind: .claudeCode, root: claudeRoot, origin: .builtin, enabled: true
            )
        case .codex:
            return SessionSource(
                id: codexBuiltinID,
                name: ProviderRegistry.descriptor(for: .codex).displayName,
                kind: .codex, root: codexRoot, origin: .builtin, enabled: true
            )
        }
    }

    /// The two always-present built-in sources, enabled by default.
    static func builtins(claudeRoot: URL, codexRoot: URL) -> [SessionSource] {
        [
            builtinSource(for: .claudeCode, claudeRoot: claudeRoot, codexRoot: codexRoot),
            builtinSource(for: .codex, claudeRoot: claudeRoot, codexRoot: codexRoot),
        ]
    }

    /// Compose the canonical list: code-provided candidates first (builtins,
    /// then auto-detected, order preserved), each overlaid with the user's
    /// saved `name`/`enabled` if present; then any saved sources that aren't
    /// code candidates (the user-added folders) appended in saved order.
    ///
    /// Merge contract for candidates: **code owns identity** (`kind`/`root`/
    /// `origin`) since a builtin/detected path can move between releases,
    /// while the **user owns `name` and `enabled`** (their desired state, as
    /// last persisted).
    ///
    /// Two uniqueness invariants hold on the output, both resolved by
    /// emission order (builtin > detected > user-added):
    ///   - **unique id** — a repeated id collapses to its first occurrence.
    ///   - **unique root** — two sources must never point at the same
    ///     normalized directory, or that directory would be indexed twice.
    ///     This matters because the builtins' roots are env-aware
    ///     (`$CLAUDE_CONFIG_DIR`/`$CODEX_HOME`), so a detected candidate
    ///     (or a user-added folder) can resolve to a builtin's root under a
    ///     different id; the builtin wins and the duplicate is dropped.
    static func compose(
        builtins: [SessionSource],
        detected: [SessionSource],
        saved: [SessionSource]
    ) -> [SessionSource] {
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SessionSource] = []
        var emittedIDs = Set<String>()
        var emittedRoots = Set<String>()

        // Append a source unless its id or root was already emitted. Earlier
        // layers win, so builtins are never dropped in favour of a detected
        // or user-added collision.
        func emit(_ source: SessionSource) {
            guard !emittedIDs.contains(source.id),
                  !emittedRoots.contains(source.root.path) else { return }
            emittedIDs.insert(source.id)
            emittedRoots.insert(source.root.path)
            result.append(source)
        }

        for candidate in builtins + detected {
            if let override = savedByID[candidate.id] {
                var merged = candidate
                merged.name = override.name
                merged.enabled = override.enabled
                emit(merged)
            } else {
                emit(candidate)
            }
        }

        // Saved entries with no matching candidate are the user's added
        // folders (or a once-detected source whose path is no longer present).
        for source in saved where !emittedIDs.contains(source.id) {
            emit(source)
        }

        return result
    }

    /// App-facing convenience: wire the real builtins, auto-detection, and the
    /// user's saved overrides into one composed list. Roots/environment are
    /// injectable for tests; defaults use the live providers and process env.
    static func resolve(
        saved: [SessionSource],
        claudeRoot: URL = ClaudeProvider().defaultSourceRoot,
        // Codex's root is the codexHome (parent of sessions/), since the
        // importer reads session_index.jsonl from there too.
        codexRoot: URL = CodexSessionDiscovery().codexHome,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [SessionSource] {
        compose(
            builtins: builtins(claudeRoot: claudeRoot, codexRoot: codexRoot),
            detected: KnownSourceLocations.detect(
                environment: environment, home: home, fileManager: fileManager
            ),
            saved: saved
        )
    }
}

extension Array where Element == SessionSource {
    /// Whitelist projection — only enabled sources are indexed and shown in
    /// the mode picker.
    var enabledSources: [SessionSource] { filter(\.enabled) }

    /// First source whose stable id matches, or nil.
    func source(id: String) -> SessionSource? { first { $0.id == id } }
}
