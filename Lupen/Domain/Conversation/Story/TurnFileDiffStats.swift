//
//  TurnFileDiffStats.swift
//  Lupen
//
//  Created by jaden on 2026/07/26.
//

import Foundation

/// C-22 — per-file added/removed line counts for one turn.
///
/// Split out from `TurnFileAccess` because it needs **disk**: the counts live
/// in `toolUseResult.structuredPatch` (Claude) and `patch_apply_end.changes`
/// (Codex), neither of which survives into the snapshot that `Step` carries.
/// The card therefore renders immediately from the snapshot and fills these in
/// afterwards, rather than blocking a turn selection on file reads.
///
/// Reading the raw line is cheap and bounded: `Step.rawJSONLocator` gives a
/// byte offset, so the cost is proportional to the turn, not the session — the
/// same escape hatch the turn-analysis export uses.
struct TurnFileDiffStats: Sendable, Equatable {

    struct Delta: Sendable, Equatable {
        var added: Int = 0
        var removed: Int = 0
        /// Whether the file did not exist before this turn. Distinguishing a
        /// create from an overwrite is the one thing the snapshot alone cannot
        /// do, which is half the reason this type reads raw at all.
        var isNewFile: Bool = false
    }

    var byPath: [String: Delta] = [:]

    /// Steps whose raw line could not be read (file rotated away, offset stale).
    /// Kept so the UI can tell "changed nothing" from "we could not look" —
    /// the same honesty split `TurnRawFacts` keeps.
    var missingLineCount: Int = 0

    /// Whether a parse ever ran. Distinguishes "we looked and this file had no
    /// patch" from "we never looked", which otherwise both present as an empty
    /// `byPath` with nothing missing — and the two must not render the same.
    /// Only `parse` sets it, so a default value is honestly "not measured".
    private(set) var didLoad = false

    var isEmpty: Bool { byPath.isEmpty }

    // MARK: - Load

    /// Reads the turn's raw lines and parses them. Blocking file I/O — call it
    /// off the main actor.
    ///
    /// Provider-free: the parse keys off payload shape, and the line reader
    /// only needs each step's byte offset, so a turn can be handed over
    /// without the caller knowing which provider produced it.
    static func load(steps: [Step]) -> TurnFileDiffStats {
        let loaded = TurnRawSource.loadLines(steps: steps)
        return parse(lines: loaded.lines, missingLineCount: loaded.missingCount)
    }

    // MARK: - Parse

    /// Builds stats from already-loaded raw JSONL lines, keyed by step uuid.
    ///
    /// Provider-agnostic on purpose: a turn is one provider's, but keying the
    /// parse off the payload shape rather than an enum means a Codex line and
    /// a Claude line can both be handed in without the caller having to know
    /// which it holds.
    static func parse(lines: [String: Data], missingLineCount: Int = 0) -> TurnFileDiffStats {
        var stats = TurnFileDiffStats()
        stats.didLoad = true
        stats.missingLineCount = missingLineCount

        for data in lines.values {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let payload = object as? [String: Any] else { continue }
            applyClaude(payload, to: &stats)
            applyCodex(payload, to: &stats)
        }
        return stats
    }

    // MARK: - Claude Code

    /// `toolUseResult.structuredPatch` is an array of hunks whose `lines` carry
    /// a leading `+` / `-` / space, exactly as a unified diff does. Shape is
    /// stable — every hunk in the local corpus carries the same five keys.
    ///
    /// An **empty** `structuredPatch` alongside a non-empty `content` is the
    /// unambiguous new-file signal: every zero-hunk result in the corpus is a
    /// `Write` with `type == "create"`, and no `Edit` produces one.
    private static func applyClaude(_ payload: [String: Any], to stats: inout TurnFileDiffStats) {
        guard let result = payload["toolUseResult"] as? [String: Any] else { return }
        guard let path = nonEmpty(result["filePath"]) else { return }

        var delta = stats.byPath[path] ?? Delta()

        if let hunks = result["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            for hunk in hunks {
                guard let hunkLines = hunk["lines"] as? [String] else { continue }
                for line in hunkLines {
                    // A hunk line is prefixed, so an empty line is context.
                    guard let marker = line.first else { continue }
                    if marker == "+" { delta.added += 1 }
                    if marker == "-" { delta.removed += 1 }
                }
            }
        } else if let content = result["content"] as? String {
            // Zero hunks: a freshly created file, whose whole body is added.
            // Sticky rather than assigned — `parse` walks an unordered
            // dictionary, so two results for one path must not let the later
            // one clear what the earlier established.
            if nonEmpty(result["originalFile"]) == nil { delta.isNewFile = true }
            delta.added += lineCount(of: content)
        }

        if nonEmpty(result["type"]) == "create" { delta.isNewFile = true }
        stats.byPath[path] = delta
    }

    // MARK: - Codex

    /// `patch_apply_end.changes` maps an **absolute** path to a per-file change
    /// — `unified_diff` for an update, `content` for an add. Paths are absolute
    /// in every observed event, so no working-directory resolution is needed.
    private static func applyCodex(_ payload: [String: Any], to stats: inout TurnFileDiffStats) {
        let container = (payload["payload"] as? [String: Any]) ?? payload
        guard nonEmpty(container["type"]) == "patch_apply_end" else { return }
        guard let changes = container["changes"] as? [String: Any] else { return }

        for (path, raw) in changes {
            guard let change = raw as? [String: Any] else { continue }
            var delta = stats.byPath[path] ?? Delta()
            let kind = nonEmpty(change["type"])

            if let diff = change["unified_diff"] as? String {
                let counted = countUnifiedDiff(diff)
                delta.added += counted.added
                delta.removed += counted.removed
            } else if let content = change["content"] as? String {
                // A delete carries the removed file's whole body in `content`
                // and no diff. Counting it as added would report `+179` for a
                // file that vanished — the sign inverted.
                if kind == "delete" {
                    delta.removed += lineCount(of: content)
                } else {
                    delta.added += lineCount(of: content)
                }
            }
            // Sticky: `parse` walks an unordered dictionary, so a later entry
            // for the same path must not be able to clear an earlier "new".
            if kind == "add" { delta.isNewFile = true }
            stats.byPath[path] = delta
        }
    }

    /// Counts a unified diff body.
    ///
    /// `---` / `+++` are only file headers *before* the first `@@`; after it a
    /// line starting `---` is a removed line whose content begins `--`. Naively
    /// skipping every such line drops real deletions — measured at 115 lines
    /// across 113 diffs locally (markdown table rules, `--flag` arguments, YAML
    /// front matter). Codex in fact emits no headers at all — every observed
    /// `unified_diff` starts at `@@` — so this only matters for a diff pasted
    /// in from elsewhere.
    static func countUnifiedDiff(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        var inHunk = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                inHunk = true
                continue
            }
            if !inHunk, line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            guard let marker = line.first else { continue }
            if marker == "+" { added += 1 }
            if marker == "-" { removed += 1 }
        }
        return (added, removed)
    }

    // MARK: - Helpers

    private static func lineCount(of body: String) -> Int {
        guard !body.isEmpty else { return 0 }
        // A trailing newline terminates the last line rather than starting a
        // new empty one.
        let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// Serializes and memoizes the raw reads behind `TurnFileDiffStats`.
///
/// Two problems it solves, both measured:
///
/// - **Unbounded concurrency.** `Task.detached` does not inherit its parent's
///   cancellation (the same trap `ScanCancellationFlag` documents), so
///   cancelling a card's load only suppressed the result — the read ran to
///   completion regardless. Twelve rapid turn selections put twelve blocking
///   reads on the cooperative pool at once. An actor bounds that to one.
/// - **Repeated identical reads.** The card is rebuilt on every turn selection
///   *and* every highlight change, so arrowing through the steps of one turn
///   re-read and re-parsed the same bytes each time — up to ~4 GB for the
///   largest observed turn (3.5 MB × 1,184 steps).
actor TurnFileDiffCache {
    static let shared = TurnFileDiffCache()

    /// Small because entries are only worth keeping while the user is moving
    /// around one region of a session; a turn costs p50 67 KB of parsed JSON.
    ///
    /// Eviction is insertion-order, not least-recently-used: a hit does not
    /// reorder. With a cap this small and keys that change as a live turn
    /// grows, the difference is not worth the bookkeeping.
    private let limit = 24
    private var cache: [String: TurnFileDiffStats] = [:]
    private var order: [String] = []

    func stats(for key: String, load: @Sendable () -> TurnFileDiffStats) -> TurnFileDiffStats {
        if let hit = cache[key] {
            return hit
        }
        let stats = load()
        cache[key] = stats
        order.append(key)
        if order.count > limit, let evicted = order.first {
            order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return stats
    }

    /// Test seam — the cache is process-wide, so a test that seeds it would
    /// otherwise leak into the next one.
    func removeAll() {
        cache.removeAll()
        order.removeAll()
    }

    func cachedCountForTesting() -> Int { cache.count }
}
