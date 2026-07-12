//
//  CodexSourceLabelFormatter.swift
//  Lupen
//
//  Created by jaden on 2026/07/12.
//

import Foundation

/// Builds the teal source label shown on a merged Codex subagent turn in the
/// conversation outline. A subagent rollout records its `agent_nickname` and
/// `agent_role` in `session_meta`; this collapses them into one display string
/// so parallel reviewers read as "Galileo · reviewer-architecture" instead of
/// the indistinct `subagent <shortId>` fallback (sibling subagents spawned in
/// the same window share a UUIDv7 time prefix).
enum CodexSourceLabelFormatter {

    /// `"<nickname> · <role>"` when both are present, one alone when only one
    /// is, else the session-index `titleHint`, or `nil` when a piece carries
    /// none of them — the caller then keeps its short-id fallback.
    static func label(for metadata: CodexSessionMetadata) -> String? {
        label(nickname: metadata.agentNickname, role: metadata.agentRole)
            ?? nonEmpty(metadata.titleHint)
    }

    static func label(nickname: String?, role: String?) -> String? {
        switch (nonEmpty(nickname), nonEmpty(role)) {
        case let (name?, role?): return "\(name) · \(role)"
        case let (name?, nil): return name
        case let (nil, role?): return role
        case (nil, nil): return nil
        }
    }

    /// Distinctive short id for the no-name fallback. `prefix(8)` collides for
    /// UUIDv7 ids created in the same millisecond window (the first two hyphen
    /// groups are the 48-bit timestamp), so pair the timestamp anchor with the
    /// last group's random tail. Non-UUID ids keep the plain prefix.
    static func distinctiveShortId(_ rawID: String) -> String {
        let groups = rawID.split(separator: "-")
        guard groups.count >= 5, let last = groups.last else {
            return String(rawID.prefix(8))
        }
        return "\(groups[0])…\(last.suffix(6))"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
