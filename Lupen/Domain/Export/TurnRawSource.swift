//
//  TurnRawSource.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import Foundation

/// The disk half of raw enrichment: fetches a turn's original JSONL lines.
///
/// Split from `TurnRawEnricher` so the parsing logic stays pure and testable.
/// This type does the seeking; that one does the thinking.
///
/// Work is bounded by the turn, never by the session: reads are byte-offset
/// seeks recorded at import time (`raw_locators`), exactly the mechanism the Raw
/// tab already uses. A session with a million lines costs the same as one with a
/// hundred.
enum TurnRawSource {

    struct Loaded: Sendable {
        /// step uuid → original line.
        var lines: [String: Data] = [:]
        /// Codex `turn_context` envelope governing this turn, when found.
        var turnContext: Data?
        /// Steps whose line could not be recovered (source rotated, vacuumed,
        /// or rewritten past its recorded offset).
        var missingCount = 0
    }

    /// Maximum bytes scanned backwards from a turn's first line while looking
    /// for its Codex `turn_context`. The record is emitted once per turn, so it
    /// sits just above the turn's own lines in practice; a bounded window keeps
    /// a 100 MB rollout from turning an export into a full-file scan. Not found
    /// within the window means the fields stay `nil` — an honest unknown.
    static let turnContextScanWindow = 256 * 1024

    static func load(steps: [Step], provider: ProviderKind) -> Loaded {
        var loaded = Loaded()

        // Steps whose raw bytes are already in memory (Claude's materialize path
        // re-decodes through StepBuilder, which keeps `rawJSON`) need no I/O.
        var pending: [Step] = []
        for step in steps {
            if let raw = step.rawJSON, !raw.isEmpty {
                loaded.lines[step.uuid] = raw
            } else if step.rawJSONLocator != nil {
                pending.append(step)
            }
        }

        // Everything else is a seek. Group by file so each is opened once, and
        // read in offset order to keep the access pattern sequential.
        let byPath = Dictionary(grouping: pending) { $0.rawJSONLocator?.sourceURL.path ?? "" }
        for (path, group) in byPath where !path.isEmpty {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                loaded.missingCount += group.count
                continue
            }
            defer { try? handle.close() }
            let ordered = group.sorted {
                ($0.rawJSONLocator?.byteOffset ?? 0) < ($1.rawJSONLocator?.byteOffset ?? 0)
            }
            for step in ordered {
                if let line = read(step.rawJSONLocator, from: handle) {
                    loaded.lines[step.uuid] = line
                } else {
                    loaded.missingCount += 1
                }
            }
        }

        if provider == .codex {
            loaded.turnContext = codexTurnContext(steps: steps)
        }
        return loaded
    }

    // MARK: - Line reads

    private static func read(_ locator: RawPayloadLocator?, from handle: FileHandle) -> Data? {
        guard let locator,
              let offset = locator.byteOffset,
              let length = locator.lineByteCount, length > 0,
              (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: length),
              !data.isEmpty else { return nil }
        // Locator lengths include the terminator; JSONSerialization tolerates a
        // trailing newline but trimming keeps the bytes exactly one JSON value.
        return data.last == UInt8(ascii: "\n") ? Data(data.dropLast()) : data
    }

    // MARK: - Codex turn_context

    /// `turn_context` is its own envelope type, so it never has a step row and
    /// therefore never has a locator. It is emitted immediately before the turn
    /// it configures, so scan backwards from the turn's first line.
    private static func codexTurnContext(steps: [Step]) -> Data? {
        let locators = steps.compactMap(\.rawJSONLocator)
        guard let first = locators.min(by: { ($0.byteOffset ?? 0) < ($1.byteOffset ?? 0) }),
              let startOffset = first.byteOffset,
              let handle = try? FileHandle(forReadingFrom: first.sourceURL) else { return nil }
        defer { try? handle.close() }

        let windowStart = startOffset > UInt64(turnContextScanWindow)
            ? startOffset - UInt64(turnContextScanWindow)
            : 0
        guard (try? handle.seek(toOffset: windowStart)) != nil,
              let window = try? handle.read(upToCount: Int(startOffset - windowStart)),
              !window.isEmpty else { return nil }

        var lines = window.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // Unless the window starts at byte 0, its first line is a fragment of a
        // line that began before the window — not parseable, so drop it.
        if windowStart > 0, !lines.isEmpty { lines.removeFirst() }

        // Last one wins: the closest preceding context is the one in force.
        for line in lines.reversed() {
            let data = Data(line)
            guard data.count < 1_000_000,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "turn_context" else { continue }
            return data
        }
        return nil
    }
}
