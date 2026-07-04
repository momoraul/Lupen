//
//  TurnTimeline.swift
//  Lupen
//
//  Created by jaden on 2026/07/03.
//

import Foundation

/// C-24 — pure builder for the turn waterfall timeline: distributes a turn's
/// wall-clock time across category swimlanes (Thinking / top tools / Other
/// tools / Reply) so "why did this turn take 5 minutes" is answered at a
/// glance. Lane count is bounded, so a multi-thousand-step turn renders at
/// the same height as a ten-step one.
///
/// Attribution model — one uniform rule: **every gap belongs to the step
/// that arrives at its end** (timestamps are *arrival* times of JSONL
/// lines, so the gap before a line is the time spent producing it):
///   - gap → `tool_result`: the tool was executing (or, for
///     AskUserQuestion-style tools, waiting on the user) — tool lane,
///     named/detailed via the matching `tool_use`. Keying on the *result*
///     is load-bearing: Claude merges `tool_use` into the preceding
///     thinking step, so call→result forward spans lose the call's own
///     timestamp and silently drop lanes.
///   - gap → thought / tool-call step: the model was thinking/deciding —
///     Thinking lane. Kind-based, not content-based: Codex reasoning
///     arrives as `.thought` with an empty summary ~80% of a turn's wall
///     clock on real corpora.
///   - gap → reply: Reply lane. Everything else (user lines, stops) owns
///     nothing — those stretches are genuine idle.
///   Marginal attribution makes lane totals sum exactly to the wall clock
///   (parallel tool results split the shared wait between them).
///   - Idle stretches nothing owns (waiting for task notifications, the
///     user away overnight) are compressed out of the axis and shown as
///     break markers, the standard dense-trace treatment — otherwise a
///     23-hour turn squeezes five minutes of real work into slivers.
enum TurnTimeline {

    struct Segment: Sendable, Equatable {
        /// Step to jump to when the segment is clicked.
        let stepUuid: String
        /// Offset on the *display* axis (idle breaks compressed out).
        let start: TimeInterval
        let duration: TimeInterval
        /// Hover readout (one line, tight), e.g. "Bash · npm run build".
        let detail: String
        let isError: Bool
        /// Dwell tooltip (Xcode-timeline style): the full, untruncated-ish
        /// content — long tool inputs / result heads that don't fit the
        /// readout line.
        var tooltip: String = ""
    }

    struct Lane: Sendable, Equatable {
        let name: String
        let totalDuration: TimeInterval
        let segments: [Segment]
    }

    /// A compressed idle stretch: `hiddenDuration` of real time rendered as
    /// a fixed-width axis break at `displayStart`.
    struct BreakMarker: Sendable, Equatable {
        let displayStart: TimeInterval
        let displayWidth: TimeInterval
        let hiddenDuration: TimeInterval
    }

    struct Model: Sendable, Equatable {
        /// Wall clock of the whole turn (first → last step timestamp) —
        /// what the summary and the axis' right label report.
        let totalDuration: TimeInterval
        /// Axis extent after idle compression — what the view scales by.
        let displayDuration: TimeInterval
        let lanes: [Lane]
        let breaks: [BreakMarker]
        /// "3m 42s · Bash 62% · Thinking 18%" — scan line, accessibility
        /// value, and the plain-text fallback when no renderer is registered.
        let summaryText: String
    }

    // MARK: - Thresholds / caps

    /// Skip trivial turns — a timeline card on a two-step Q&A is clutter.
    static let minTurnDuration: TimeInterval = 5
    static let minStepCount = 8
    /// Distinct tool lanes before folding the tail into "Other tools".
    static let maxToolLanes = 4
    /// Uncovered stretches longer than this are compressed into a break.
    static let idleBreakThreshold: TimeInterval = 120

    private static let thinkingLane = "Thinking"
    private static let replyLane = "Reply"
    private static let otherToolsLane = "Other tools"

    // MARK: - Build

    static func build(steps: [Step]) -> Model? {
        let visible = steps.filter { !$0.isSystemInjected }
        guard let first = visible.first?.timestamp,
              let last = visible.last?.timestamp else { return nil }
        let total = last.timeIntervalSince(first)
        guard total > 0 else { return nil }
        guard total >= minTurnDuration || visible.count >= minStepCount else { return nil }

        // tool_use id → (call info, the step carrying it) for naming a
        // result's lane and giving the click-jump a card that exists (the
        // ToolGroup card anchors on the *call* step's uuid).
        var callsById: [String: (call: ToolUseInfo, stepUuid: String)] = [:]
        for step in visible {
            for call in step.toolCalls where callsById[call.id] == nil {
                callsById[call.id] = (call, step.uuid)
            }
        }

        var thinking: [Segment] = []
        var reply: [Segment] = []
        var toolSegments: [String: [Segment]] = [:]   // tool name → segments
        // Last step that maps to a conversation card — the jump target for
        // results whose call is unmatched (a result step itself maps to no
        // card, so anchoring on it makes the click a dead no-op).
        var lastAnchorUuid: String?

        for (index, step) in visible.enumerated() {
            let offset = step.timestamp.timeIntervalSince(first)
            let gap = index > 0
                ? max(0, step.timestamp.timeIntervalSince(visible[index - 1].timestamp))
                : 0
            let start = offset - gap
            if step.kind != .toolResult && step.kind != .stop {
                lastAnchorUuid = step.uuid
            }

            switch step.kind {
            case .toolResult:
                guard let result = step.toolResult else { break }
                let matched = callsById[result.toolUseId]
                let name = matched?.call.name ?? "Tool"
                // Unmatched results (the call step lost its tool_use — seen
                // with huge Write inputs) still tell the user WHAT ran, via
                // the result's own content head.
                let detail = matched.map { "\($0.call.name) · \($0.call.abbreviatedInput(limit: 60))" }
                    ?? "Tool · \(result.abbreviatedContent(limit: 60))"
                // Multi-line dwell tooltip: the input plus the result's first
                // lines. `abbreviatedContent` is a one-liner — useless for
                // code-shaped results whose first line is a lone brace.
                var tooltipLines = [name]
                if let matched { tooltipLines.append(matched.call.abbreviatedInput(limit: 300)) }
                let head = Self.contentHead(result.content)
                if !head.isEmpty { tooltipLines.append(head) }
                let tooltip = tooltipLines.joined(separator: "\n")
                toolSegments[name, default: []].append(Segment(
                    stepUuid: matched?.stepUuid ?? lastAnchorUuid ?? step.uuid,
                    start: start, duration: gap,
                    detail: detail,
                    isError: result.isError,
                    tooltip: tooltip
                ))
            case .thought, .toolCall:
                // "What was it thinking about" hook: Claude thought steps
                // often carry the visible preamble in `text` (thinkingText
                // holds only the extended-thinking block, frequently absent),
                // so fall back across both. Pure tool-call steps have
                // neither — a bare "Thinking" is correct there.
                let head = (step.thinkingText ?? step.text)
                    .map { Self.contentHead($0, maxLines: 4, maxChars: 240) } ?? ""
                thinking.append(Segment(
                    stepUuid: step.uuid, start: start, duration: gap,
                    detail: "Thinking", isError: false,
                    tooltip: head.isEmpty ? "Thinking" : "Thinking\n\(head)"
                ))
            case .reply:
                let head = step.text
                    .map { Self.contentHead($0, maxLines: 4, maxChars: 240) } ?? ""
                reply.append(Segment(
                    stepUuid: step.uuid, start: start, duration: gap,
                    detail: "Reply", isError: false,
                    tooltip: head.isEmpty ? "Reply" : "Reply\n\(head)"
                ))
            case .interruption:
                reply.append(Segment(
                    stepUuid: step.uuid, start: start, duration: gap,
                    detail: "Interrupted", isError: true,
                    tooltip: "Interrupted"
                ))
            default:
                break
            }
        }

        // Lane assembly: Thinking, tools by descending time (top N, rest
        // folded), Reply. Empty/zero lanes are dropped.
        var lanes: [Lane] = []
        if !thinking.isEmpty { lanes.append(makeLane(thinkingLane, thinking)) }

        let rankedTools = toolSegments
            .map { makeLane($0.key, $0.value) }
            .sorted { ($0.totalDuration, $1.name) > ($1.totalDuration, $0.name) }
        lanes.append(contentsOf: rankedTools.prefix(maxToolLanes))
        if rankedTools.count > maxToolLanes {
            let overflow = rankedTools.dropFirst(maxToolLanes).flatMap(\.segments)
            lanes.append(makeLane(otherToolsLane, overflow.sorted { $0.start < $1.start }))
        }
        if !reply.isEmpty { lanes.append(makeLane(replyLane, reply)) }
        lanes = lanes.filter { $0.totalDuration > 0 }

        guard !lanes.isEmpty else { return nil }

        let (compressedLanes, breaks, displayDuration) = compressIdleGaps(
            lanes: lanes, total: total
        )

        return Model(
            totalDuration: total,
            displayDuration: displayDuration,
            lanes: compressedLanes,
            breaks: breaks,
            summaryText: summary(total: total, lanes: lanes, breaks: breaks)
        )
    }

    /// First lines of content for the dwell tooltip — capped by line count
    /// and total characters so a Read dump stays a preview. An over-long
    /// line is cut inline (single-paragraph replies are common — dropping
    /// the whole line would leave nothing), and the ellipsis appears only
    /// when something was actually cut (trailing newlines don't count).
    static func contentHead(
        _ content: String, maxLines: Int = 6, maxChars: Int = 360
    ) -> String {
        var rows = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while rows.last?.isEmpty == true { rows.removeLast() }

        var lines: [String] = []
        var used = 0
        var truncated = false
        for (index, line) in rows.enumerated() {
            if lines.count >= maxLines {
                truncated = true
                break
            }
            let remaining = maxChars - used
            if line.count > remaining {
                if remaining > 20 {
                    // Cut the long line inline; a separate "…" row is only
                    // added when further lines follow.
                    lines.append(String(line.prefix(remaining)) + "…")
                    truncated = index + 1 < rows.count
                } else {
                    truncated = true
                }
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        if truncated { lines.append("…") }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeLane(_ name: String, _ segments: [Segment]) -> Lane {
        Lane(
            name: name,
            totalDuration: segments.reduce(0) { $0 + $1.duration },
            segments: segments
        )
    }

    // MARK: - Idle compression

    /// Find stretches longer than `idleBreakThreshold` that no segment
    /// covers, collapse each to a fixed display width, and shift every
    /// segment left accordingly. Returns lanes in display coordinates.
    private static func compressIdleGaps(
        lanes: [Lane], total: TimeInterval
    ) -> ([Lane], [BreakMarker], TimeInterval) {
        // Merged coverage of all segments.
        let intervals = lanes
            .flatMap(\.segments)
            .map { (max(0, $0.start), min(total, $0.start + $0.duration)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var merged: [(TimeInterval, TimeInterval)] = []
        for interval in intervals {
            if var lastInterval = merged.last, interval.0 <= lastInterval.1 {
                lastInterval.1 = max(lastInterval.1, interval.1)
                merged[merged.count - 1] = lastInterval
            } else {
                merged.append(interval)
            }
        }

        // Holes = complement of coverage inside [0, total].
        var holes: [(TimeInterval, TimeInterval)] = []
        var cursor: TimeInterval = 0
        for interval in merged {
            if interval.0 - cursor > idleBreakThreshold { holes.append((cursor, interval.0)) }
            cursor = max(cursor, interval.1)
        }
        if total - cursor > idleBreakThreshold { holes.append((cursor, total)) }
        guard !holes.isEmpty else { return (lanes, [], total) }

        // Each hole renders as a fixed sliver of the *visible* time so the
        // break reads as a deliberate axis cut, not a small gap.
        let visibleTime = total - holes.reduce(0) { $0 + ($1.1 - $1.0) }
        let breakWidth = max(visibleTime * 0.03, 1)

        func display(_ t: TimeInterval) -> TimeInterval {
            var shifted = t
            for hole in holes {
                if hole.1 <= t {
                    shifted -= (hole.1 - hole.0) - breakWidth
                } else if hole.0 < t && t < hole.1 {
                    // Inside a hole (possible for zero-duration segments,
                    // which contribute no coverage): land proportionally
                    // within the break sliver instead of beyond the axis.
                    let fraction = (t - hole.0) / (hole.1 - hole.0)
                    shifted -= (t - hole.0) - breakWidth * fraction
                }
            }
            return shifted
        }

        let breaks = holes.map { hole in
            BreakMarker(
                displayStart: display(hole.0 + (hole.1 - hole.0)) - breakWidth,
                displayWidth: breakWidth,
                hiddenDuration: hole.1 - hole.0
            )
        }
        let remapped = lanes.map { lane in
            Lane(
                name: lane.name,
                totalDuration: lane.totalDuration,
                segments: lane.segments.map { segment in
                    Segment(
                        stepUuid: segment.stepUuid,
                        start: display(segment.start),
                        duration: segment.duration,
                        detail: segment.detail,
                        isError: segment.isError,
                        tooltip: segment.tooltip
                    )
                }
            )
        }
        return (remapped, breaks, display(total))
    }

    // MARK: - Summary

    /// Top-3 consumers as a share of wall clock (plus the idle total when
    /// the axis is compressed). Parallel tool time can push the sum past
    /// 100% — that's honest (overlap), not a bug.
    private static func summary(
        total: TimeInterval, lanes: [Lane], breaks: [BreakMarker]
    ) -> String {
        var parts = [formatDuration(total)]
        let ranked = lanes
            .filter { $0.totalDuration > 0 }
            .sorted { $0.totalDuration > $1.totalDuration }
            .prefix(3)
        for lane in ranked {
            let pct = Int((lane.totalDuration / total * 100).rounded())
            guard pct >= 1 else { continue }
            parts.append("\(lane.name) \(pct)%")
        }
        let hidden = breaks.reduce(0) { $0 + $1.hiddenDuration }
        if hidden > 0 {
            parts.append("idle \(formatDuration(hidden))")
        }
        return parts.joined(separator: " · ")
    }

    /// "1h 12m" / "3m 42s" / "42s" / "1.2s" — glance-sized durations.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if seconds >= 60 {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        if seconds >= 10 { return "\(Int(seconds.rounded()))s" }
        return String(format: "%.1fs", seconds)
    }
}

/// Conversation block carrying a built timeline. Inserted by
/// `ConversationStoryBuilder` as the first card of qualifying turns.
struct TimelineBlock: ConversationBlock, Equatable {
    let id: String
    let model: TurnTimeline.Model
    var tier: BlockTier { .primary }
    var role: BlockRole { .system }
    var isHighlighted: Bool { false }
    var plainTextFallback: String { "⏱ \(model.summaryText)" }
}
