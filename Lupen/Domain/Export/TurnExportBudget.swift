//
//  TurnExportBudget.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import Foundation

/// Size policy for the turn analysis export.
///
/// A single turn can hold megabytes of tool output — a `Read` of a large file, a
/// `Bash` dump, a `Grep` across the tree. Pasting that into a chat is useless at
/// best and misleading at worst, so every body is clipped.
///
/// ## The one rule that matters
///
/// **Never hand a model a fragment that looks complete.** A silently truncated
/// tool result reads as the whole result, and the analyst then reasons about
/// output that does not exist. Every clip therefore leaves a marker carrying the
/// exact number of characters removed — the count is the point, because it tells
/// the model both that something is missing and how much.
///
/// Head-and-tail rather than head-only for tool results: the tail is where exit
/// codes, error summaries, and "N matches" lines live, and those are usually the
/// diagnostically interesting part.
struct TurnExportBudget: Sendable, Equatable {

    /// Total character ceiling for the rendered document. ~60k characters is
    /// roughly 15k tokens — comfortable in any long-context chat while still
    /// leaving the analyst's own reasoning room.
    let totalCharacters: Int
    /// The opening prompt. Generous, because this is the artifact most likely to
    /// be the thing that needs editing — but not unbounded: a pasted log or diff
    /// as a prompt would otherwise consume the whole document.
    let promptHead: Int
    /// Extended-thinking bodies.
    let thinkingHead: Int
    /// Tool input JSON.
    let toolInputHead: Int
    /// Tool result content, split head/tail.
    let toolResultHead: Int
    let toolResultTail: Int
    /// Assistant reply / trace bodies.
    let traceBodyHead: Int

    static let `default` = TurnExportBudget(
        totalCharacters: 60_000,
        promptHead: 8_000,
        thinkingHead: 2_000,
        toolInputHead: 1_500,
        toolResultHead: 1_200,
        toolResultTail: 400,
        traceBodyHead: 1_500
    )

    // MARK: - Clipping

    /// Clips `text` to `head` (+ optional `tail`) characters, inserting an
    /// explicit marker naming how many characters were removed.
    ///
    /// Returns the input unchanged when it already fits, so short bodies never
    /// gain marker noise. `head`/`tail` are clamped at zero; a non-positive
    /// `head` with no `tail` yields the marker alone rather than an empty string
    /// that would silently read as "there was no output".
    static func clip(_ text: String, head: Int, tail: Int = 0) -> String {
        let head = max(0, head)
        let tail = max(0, tail)
        let total = text.count
        guard total > head + tail else { return text }

        let omitted = total - head - tail
        let headPart = String(text.prefix(head))
        let tailPart = tail > 0 ? String(text.suffix(tail)) : ""
        let marker = omissionMarker(omitted)

        if tailPart.isEmpty {
            return headPart + "\n" + marker
        }
        return headPart + "\n" + marker + "\n" + tailPart
    }

    /// The marker text. Kept in one place so tests and the renderer agree, and
    /// so a future parser can recognize it.
    static func omissionMarker(_ characters: Int) -> String {
        "[… \(formatted(characters)) characters omitted …]"
    }

    /// Thousands-separated and locale-stable — an exported document should not
    /// read differently on a Korean vs. US machine. `CLIFormat.int` groups by
    /// hand (no locale, no allocation), so the marker is identical everywhere.
    private static func formatted(_ value: Int) -> String {
        CLIFormat.int(value)
    }
}

/// Tracks the running character spend against a `TurnExportBudget` and records
/// what had to be dropped.
///
/// Degradation order is deliberate: the step trace's bodies go first (the tool
/// ledger above it still names every call), then thinking bodies. The verdict,
/// metrics, prompt, skills and subagent sections are never dropped — they are
/// the parts that make the document worth sending at all.
struct TurnExportLedger: Sendable {

    private(set) var spent = 0
    let budget: TurnExportBudget

    /// Dropped-item descriptions in first-seen order, with occurrence counts.
    /// Kept as an ordered key list plus a count map rather than by re-parsing
    /// formatted strings — the rendered text is an output, not a data store.
    private var omissionOrder: [String] = []
    private var omissionCounts: [String: Int] = [:]

    init(budget: TurnExportBudget = .default) {
        self.budget = budget
    }

    /// Human-readable omission lines, e.g. `"step body ×12"`.
    var omissions: [String] {
        omissionOrder.map { key in
            let count = omissionCounts[key] ?? 1
            return count > 1 ? "\(key) ×\(count)" : key
        }
    }

    var remaining: Int { max(0, budget.totalCharacters - spent) }

    /// Records `count` characters as spent.
    mutating func spend(_ count: Int) {
        spent += max(0, count)
    }

    /// Charges `text` against the budget and returns it, or returns `nil` when
    /// the budget is exhausted — in which case the caller drops the body and the
    /// reason is recorded for the document's "Omitted" note.
    mutating func admit(_ text: String, describedAs description: @autoclosure () -> String) -> String? {
        guard remaining > 0 else {
            note(description())
            return nil
        }
        if text.count > remaining {
            let clipped = TurnExportBudget.clip(text, head: remaining)
            spend(clipped.count)
            note(description())
            return clipped
        }
        spend(text.count)
        return text
    }

    /// Records a dropped item, collapsing repeats into a count so the document
    /// says "step body ×12" instead of listing twelve identical lines.
    mutating func note(_ description: String) {
        if omissionCounts[description] == nil {
            omissionOrder.append(description)
        }
        omissionCounts[description, default: 0] += 1
    }
}
