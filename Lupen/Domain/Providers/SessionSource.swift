//
//  SessionSource.swift
//  Lupen
//
//  Created by jaden on 2026/06/26.
//

import Foundation

/// One indexing instance: a single root directory parsed with a given
/// `ProviderKind`. Multiple sources may share a kind — e.g. the default
/// `~/.claude/projects` and an Xcode Coding Assistant path are two Claude
/// sources, each indexed in isolation (its own `providers/<id>/index.sqlite3`).
///
/// `id` is the stable slug — the on-disk index-folder name and the CLI query
/// key — and must never change once created. `name` is the user-facing label
/// (mode picker, CLI `--provider`); it is editable but must stay unique.
///
/// Persisted in `app_settings.json` under `sessionSources`. Built-in sources
/// and auto-detected candidates are injected at runtime, so this list only
/// needs to carry the user's overrides (added sources + enable/name changes);
/// an empty list means "defaults only".
struct SessionSource: Identifiable, Codable, Equatable, Sendable {

    /// Where the source came from — drives default-enabled and removability.
    enum Origin: String, Codable, Sendable {
        case builtin        // Claude Code / Codex defaults — always present
        case autoDetected   // from KnownSourceLocations — disabled until activated
        case userAdded      // a folder the user registered
    }

    /// Stable identity / index-folder slug. Unique across sources and (like
    /// `ProviderID`) must not contain the `ProviderScopedID` separator.
    let id: String
    /// User-facing, editable label. Unique across sources.
    var name: String
    /// Parser/format. Two kinds only (claude/codex); each source picks one.
    let kind: ProviderKind
    /// Single root directory (standardized at init). Identity is the
    /// standardized path, not the resolved inode — two symlinked paths to the
    /// same directory are treated as distinct sources.
    let root: URL
    let origin: Origin
    /// Whitelist flag — only enabled sources are indexed and shown.
    var enabled: Bool

    /// `id` validity: non-empty and free of the `ProviderScopedID` separator
    /// (`:`), since `id` becomes the on-disk index-folder slug and CLI key.
    /// Mirrors `ProviderID`'s constraint.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains(ProviderScopedID.separator)
    }

    /// Normalize a root to a directory-hint-free, standardized file URL so that
    /// `encode(path)` → `decode(fileURLWithPath:)` round-trips identically. A
    /// trailing slash on a directory URL would otherwise be lost on the path
    /// round-trip, making the re-decoded source compare unequal to the original.
    static func normalizedRoot(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    init(id: String, name: String, kind: ProviderKind, root: URL, origin: Origin, enabled: Bool) {
        precondition(Self.isValidID(id), "SessionSource.id must be non-empty and must not contain ':'")
        self.id = id
        self.name = name
        self.kind = kind
        self.root = Self.normalizedRoot(root)
        self.origin = origin
        self.enabled = enabled
    }

    // `root` is encoded as a plain filesystem path (not URL's default
    // `file://…` form) so `app_settings.json` stays human-readable and diffable.
    enum CodingKeys: String, CodingKey { case id, name, kind, root, origin, enabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try c.decode(String.self, forKey: .id)
        guard Self.isValidID(decodedId) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid SessionSource id: \(decodedId)"
            ))
        }
        self.id = decodedId
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decode(ProviderKind.self, forKey: .kind)
        self.root = Self.normalizedRoot(URL(fileURLWithPath: try c.decode(String.self, forKey: .root)))
        self.origin = try c.decode(Origin.self, forKey: .origin)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(root.path, forKey: .root)
        try c.encode(origin, forKey: .origin)
        try c.encode(enabled, forKey: .enabled)
    }
}
