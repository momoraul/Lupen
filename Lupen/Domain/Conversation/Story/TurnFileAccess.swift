//
//  TurnFileAccess.swift
//  Lupen
//
//  Created by jaden on 2026/07/26.
//

import Foundation

/// C-22 — pure builder for the turn file-access card: which files the agent
/// read and wrote, in what order, so "what did this turn do to the code" is
/// answered at a glance. Row count is bounded, so a 27-file turn renders at
/// the same height as a two-file one.
///
/// **Why an op-order axis and not wall clock.** Measured on the local corpus:
/// a turn's wall clock is p50 369s, but the time attributable to *all* of its
/// file operations is p50 0.27s — file ops are local disk reads, and a turn's
/// time is dominated by model thinking. On a 370pt wall-clock axis a single op
/// is p50 0.03pt wide and 99% fall under 2pt, so minimum-width inflation and
/// neighbour merging would destroy the ordering this card exists to show. The
/// wall-clock view stays with `TurnTimeline`; the two are complementary.
///
/// **Why rows are ordered by first touch, not op count.** First-touch order
/// makes the marks descend like a staircase, and that staircase *is* the
/// process — the order the agent worked through the files. Ranking by op count
/// would sort the rows but destroy the narrative.
///
/// **Why the op sequence is driven by `Step.toolCalls`, not by attachments.**
/// `AttachmentResolver` appends `.toolInput` refs per call, in call order
/// (`AttachmentResolver.resolve` step 4), but the refs themselves carry no
/// ordinal and no call id. Walking the calls keeps the axis in true execution
/// order even when one step batches a search and a read, and it lets two
/// identical calls in one step (same tool, same file) claim one ref each
/// instead of collapsing into a single op.
///
/// **No verdicts.** A re-read is drawn, never labelled. Measured locally: 70%
/// of turns that read a file changed nothing, so any "read a lot, changed
/// little" framing would fire on the common case and read as a verdict on
/// legitimate exploration. Efficiency is left legible in the shape — a long
/// run on one row, an outlined mark after a filled one — and the reading is
/// the user's.
///
/// **Scope: tool-derived refs only.** Prompt/reply *mentions* are not
/// operations the agent performed, so they are excluded; the Attachments tab
/// already covers "what was mentioned". Only `.toolInput` / `.toolOutput`
/// count here.
enum TurnFileAccess {

    // MARK: - Model

    /// What the agent did to a file in one operation.
    ///
    /// Deliberately **not** derived from `ToolUseInfo.normalizedToolName` or
    /// `StepKindStyle.displayName`: those two disagree with each other
    /// (`write_file` → `Write` vs `Edit`) and both are display-name tables.
    /// This one is semantic, and `operationTableCoversResolverTools` pins it
    /// to `AttachmentResolver`'s path-extracting registry so a tool added
    /// there cannot be silently dropped here.
    enum Operation: String, Sendable, Equatable {
        /// File content pulled into context.
        case read
        /// Part of a file rewritten in place.
        case edit
        /// Whole file written. **Cannot yet distinguish "created" from
        /// "overwrote"** — that needs `toolUseResult.type == "create"`, which
        /// lives in the raw JSONL rather than the snapshot.
        case write

        /// Depth ladder — a row reports its deepest operation.
        var depth: Int {
            switch self {
            case .read:  return 1
            case .edit:  return 2
            case .write: return 3
            }
        }
    }

    /// One file operation, at a fixed position on the op-sequence axis.
    struct Op: Sendable, Equatable {
        /// 1-based position on the op axis, unique across the model, so the
        /// sequence strip and the per-file rows share one coordinate space.
        let ordinal: Int
        let operation: Operation
        /// Jump target. Always the step carrying the **`tool_use`**, never a
        /// `tool_result` step: result steps map to no conversation card, so
        /// anchoring there would make the click a dead no-op.
        let stepUuid: String
        /// Whether the tool call failed. Sourced from the *result* step, not
        /// from this step — `AttachmentResolver` skips output refs entirely
        /// when `isError` is set, so a failed call is only visible by joining
        /// the result's `toolUseId` back to the call.
        let isError: Bool
        /// Display name for the hover readout.
        let toolName: String
    }

    struct FileRow: Sendable, Equatable {
        let path: String
        /// Ascending by `ordinal`.
        let ops: [Op]
        /// Deepest operation **attempted** — what the row's badge shows. A
        /// file whose only edit failed still reports `.edit` here, because
        /// that is what the agent tried; whether it landed is `errorCount` /
        /// `hasSucceededChange`.
        let deepest: Operation
        let errorCount: Int

        /// Position of the first operation — the row sort key.
        var firstOrdinal: Int { ops.first?.ordinal ?? .max }

        /// True when at least one edit/write on this file succeeded. Drives
        /// the changed-file count, so a turn whose edits all failed is not
        /// summarised as having changed anything.
        var hasSucceededChange: Bool {
            ops.contains { !$0.isError && $0.operation != .read }
        }

        /// True when a read follows an edit/write of the same file. Exposed as
        /// shape only; never labelled as waste (see the type doc).
        var hasReadAfterChange: Bool {
            var changed = false
            for op in ops {
                switch op.operation {
                case .edit, .write: changed = true
                case .read where changed: return true
                case .read: break
                }
            }
            return false
        }
    }

    /// A mark on the aggregate sequence strip — only what the strip draws.
    struct SequenceMark: Sendable, Equatable {
        let ordinal: Int
        /// `nil` for a search op: searches have no file, but they are the
        /// visible "exploring" phase and belong on the axis.
        let operation: Operation?
        let isError: Bool
    }

    struct Model: Sendable, Equatable {
        /// First-touch order, capped at `maxFileRows`.
        let rows: [FileRow]
        /// Files beyond the cap. Carried in full, not just counted, so the
        /// folded row can open in place instead of being a dead end.
        let foldedRows: [FileRow]
        var foldedFileCount: Int { foldedRows.count }
        /// Ops belonging to folded files, so the counts still add up.
        let foldedOpCount: Int
        /// Search calls (Grep/Glob). Mostly path-less — measured: Glob
        /// supplies its `path` argument on 0.9% of calls — so they get a lane
        /// rather than invented rows.
        let searchOpCount: Int
        /// Shell-scraped paths, held apart from the ranked rows. Measured
        /// accuracy is 14.9% (n=18,255), so these are never ranked as facts.
        let heuristicPaths: [String]
        /// Shell calls seen, whether or not a path was scraped from them.
        let heuristicOpCount: Int
        /// Every op in order, including searches — the aggregate strip.
        let sequence: [SequenceMark]
        /// Distinct files touched, before the row cap.
        let fileCount: Int
        /// Files where a change actually **landed** — an edit or write that
        /// did not error. Not simply "deepest is edit/write": an attempt that
        /// failed leaves the row badged as an edit but changes nothing, and
        /// measured Edit failure is 2.5%, so the distinction decides how the
        /// turn is summarised.
        let changedFileCount: Int
        let readOpCount: Int
        /// Scan line, accessibility value, and the plain-text fallback when
        /// no renderer is registered.
        let summaryText: String

        /// True when this turn never went past reading. Measured: 70% of turns
        /// that read a file changed nothing, so this is the common case and must
        /// not be summarised as a failure.
        ///
        /// Not `changedFileCount == 0`. A turn whose only edit *failed* also
        /// changed nothing, but `summaryText` reports it as "1 file · 1 failed"
        /// — and the card header picks its symbol from this, so the old
        /// definition drew a magnifying glass beside text saying an attempt had
        /// failed. Anything beyond a read, landed or not, disqualifies the
        /// claim.
        var isExplorationOnly: Bool {
            rows.allSatisfy { $0.deepest == .read } && foldedRows.allSatisfy { $0.deepest == .read }
        }
    }

    // MARK: - Thresholds / caps

    /// Distinct file rows before folding the tail. Measured: a cap of 10
    /// leaves 95.9% of turns with no folded row.
    static let maxFileRows = 10

    // MARK: - Build

    /// Builds the model, or `nil` when there is nothing worth a card.
    ///
    /// Returns `nil` unless at least one structured file operation happened.
    /// Measured: 65% of turns touch no file at all, and a card on a
    /// search-only or shell-guess-only turn would be noise — or, worse, would
    /// present 85%-wrong paths as fact.
    static func build(steps: [Step]) -> Model? {
        let visible = steps.filter { !$0.isSystemInjected }
        guard !visible.isEmpty else { return nil }

        var callStepByToolUseId: [String: String] = [:]
        /// `tool_use` ids whose result reported a failure. Collected in a
        /// first pass because the failure lives on a later step than the call
        /// that owns the path.
        var erroredToolUseIds: Set<String> = []
        for step in visible {
            for call in step.toolCalls where callStepByToolUseId[call.id] == nil {
                callStepByToolUseId[call.id] = step.uuid
            }
            if let result = step.toolResult, result.isError {
                erroredToolUseIds.insert(result.toolUseId)
            }
        }

        var builder = Builder(
            callStepByToolUseId: callStepByToolUseId,
            erroredToolUseIds: erroredToolUseIds
        )
        for step in visible { builder.consume(step) }
        return builder.finish()
    }

    // MARK: - Classification

    /// Raw tool name → file operation.
    ///
    /// Names here are the ones that actually reach `AttachmentRef.toolName`.
    /// Codex normalizes its snake_case names *upstream* — `displayToolName`
    /// runs when the `ToolUseInfo` is built, before attachments are resolved
    /// (`CodexConversationAssembler` lines 161 / 284), turning `read_file` →
    /// `Read`, `write_file` → `Write`, `apply_patch` → `Edit`, and
    /// `exec_command` → `Bash` — so snake_case entries here would be dead
    /// code. Codex patch output refs are likewise tagged `"Edit"`.
    ///
    /// `MultiEdit` / `Notebook*` have **zero occurrences in the local
    /// corpus** but are in `AttachmentResolver`'s registry, so they are kept:
    /// a first appearance should classify rather than vanish.
    static func operation(forToolName name: String) -> Operation? {
        switch name {
        case "Read", "NotebookRead":
            return .read
        case "Edit", "MultiEdit", "NotebookEdit":
            return .edit
        case "Write":
            return .write
        default:
            return nil
        }
    }

    /// Tools whose job is locating files rather than reading them.
    static func isSearchTool(_ name: String) -> Bool {
        name == "Grep" || name == "Glob"
    }

    /// Shell tools — any path attributed to these is a scrape of the command
    /// string, never a structured field. Both `Bash` casings are real
    /// (`AttachmentResolver` supports each because Claude Code logs both),
    /// and `Monitor` also carries a `command`.
    static func isShellTool(_ name: String) -> Bool {
        switch name {
        case "Bash", "bash", "Monitor":
            return true
        default:
            return false
        }
    }

    /// Every tool name this type classifies. Kept as an explicit set so the
    /// test suite can pin it against `AttachmentResolver`'s registry.
    static var classifiedToolNames: Set<String> {
        ["Read", "NotebookRead", "Edit", "MultiEdit", "NotebookEdit", "Write",
         "Grep", "Glob", "Bash", "bash", "Monitor"]
    }

    // MARK: - Builder

    /// Mutable accumulator, kept out of `Model` so the model stays a plain
    /// value with no build-time scratch state.
    private struct Builder {
        let callStepByToolUseId: [String: String]
        let erroredToolUseIds: Set<String>

        private var ordinal = 0
        /// Insertion-ordered paths — first touch wins the row position.
        private var pathOrder: [String] = []
        private var opsByPath: [String: [Op]] = [:]
        /// Ordinals already accounted for by a `tool_result` output ref. A
        /// write surfaces twice — once as the call's argument and once as
        /// "File created successfully at …" — and the two ids differ on Codex
        /// (`:tool:N` vs `:patch:N`), so id-based dedup cannot catch it.
        /// Matching on the path and consuming one unconfirmed op does.
        private var confirmedOrdinals: Set<Int> = []
        private var sequence: [SequenceMark] = []
        private var searchOpCount = 0
        private var heuristicPaths: [String] = []
        private var heuristicPathSet: Set<String> = []
        private var heuristicOpCount = 0
        /// Last step that maps to a conversation card, for refs whose call
        /// cannot be found. Codex `patch_apply_end` has no `tool_use` at all,
        /// so this is its normal path rather than an edge case.
        private var lastAnchorUuid: String?

        init(callStepByToolUseId: [String: String], erroredToolUseIds: Set<String>) {
            self.callStepByToolUseId = callStepByToolUseId
            self.erroredToolUseIds = erroredToolUseIds
        }

        mutating func consume(_ step: Step) {
            if step.kind != .toolResult && step.kind != .stop {
                lastAnchorUuid = step.uuid
            }
            consumeCalls(step)
            consumeOutputRefs(step)
        }

        /// Walks the step's calls in execution order, letting each claim the
        /// input refs it produced.
        private mutating func consumeCalls(_ step: Step) {
            guard !step.toolCalls.isEmpty else { return }
            var unclaimed = step.attachments.filter { $0.origin == .toolInput }

            for call in step.toolCalls {
                if TurnFileAccess.isSearchTool(call.name) {
                    ordinal += 1
                    sequence.append(
                        SequenceMark(
                            ordinal: ordinal, operation: nil,
                            isError: erroredToolUseIds.contains(call.id)
                        )
                    )
                    searchOpCount += 1
                    continue
                }

                if TurnFileAccess.isShellTool(call.name) {
                    heuristicOpCount += 1
                    // A shell call can scrape several paths (measured: 1 path
                    // on 2,349 calls, 2 on 268, 3+ on 95), so take them all.
                    while let index = unclaimed.firstIndex(where: { $0.toolName == call.name }) {
                        if let path = filePath(from: unclaimed.remove(at: index)),
                           heuristicPathSet.insert(path).inserted {
                            heuristicPaths.append(path)
                        }
                    }
                    continue
                }

                guard let operation = TurnFileAccess.operation(forToolName: call.name) else {
                    continue
                }
                // One structured file tool names exactly one path, so this
                // call claims the first ref still unclaimed under its name.
                // Two identical calls in one step therefore take one ref
                // each instead of collapsing.
                guard let index = unclaimed.firstIndex(where: {
                    $0.toolName == call.name && filePath(from: $0) != nil
                }), let path = filePath(from: unclaimed.remove(at: index)) else { continue }

                append(
                    Op(
                        ordinal: nextOrdinal(),
                        operation: operation,
                        stepUuid: step.uuid,
                        isError: erroredToolUseIds.contains(call.id),
                        toolName: call.name
                    ),
                    path: path
                )
            }
        }

        /// Output refs confirm an operation the call side already recorded.
        /// They only create an op when the path has none left unconfirmed —
        /// which is how a Codex patch, or a write whose input path was lost to
        /// snapshot truncation, still shows up.
        private mutating func consumeOutputRefs(_ step: Step) {
            let isPatchResult = step.toolResult?.toolUseId.contains(":patch:") == true

            for ref in step.attachments where ref.origin == .toolOutput {
                guard let path = filePath(from: ref) else { continue }
                guard let operation = outputOperation(for: ref, isPatchResult: isPatchResult)
                else { continue }

                if let pending = opsByPath[path]?.first(where: {
                    !confirmedOrdinals.contains($0.ordinal)
                }) {
                    confirmedOrdinals.insert(pending.ordinal)
                    continue
                }

                // A read's evidence is its input path. An output-only read ref
                // is a path that merely *appeared* in result text — measured at
                // 0.3% of Read results (a script header, a bridging header) —
                // so creating a row from one would invent a file the agent
                // never opened. Only changes may be recorded output-first.
                guard operation != .read else { continue }

                // Recorded as already confirmed. An op created here *is* the
                // output's own record, so leaving it open let the next output
                // ref for the same path consume it and record nothing of its
                // own — one mark for two edits, while the line deltas, read
                // separately from the raw JSONL, counted both. Codex reaches
                // this branch on most of its patches (measured: `exec_command`
                // outnumbers native `apply_patch` 151,266 to 13,363), and
                // re-patching one file inside a turn is ordinary, so the
                // contradiction was common rather than exotic.
                let ordinal = nextOrdinal()
                confirmedOrdinals.insert(ordinal)
                append(
                    Op(
                        ordinal: ordinal,
                        operation: operation,
                        stepUuid: anchor(for: step),
                        isError: false,
                        toolName: ref.toolName ?? "Edit"
                    ),
                    path: path
                )
            }
        }

        /// Operation for a `.toolOutput` ref.
        ///
        /// Codex's `patch_apply_end` step carries **two** refs for the same
        /// path: one the assembler tags `"Edit"`, and one the resolver builds
        /// from a heuristic scan of the result body with **no tool name** at
        /// all (`toolNameByUseId` misses because the id is `…:patch:N`).
        /// `deduplicatedAttachments` compares `dedupPriority` with a strict
        /// `>`, and both refs are `.toolOutput`, so the tie leaves the
        /// *untagged* one standing. Requiring a tool name here would therefore
        /// drop Codex file changes entirely — and 57% of Codex patches run
        /// through `exec_command`, whose call step is tagged `Bash`, so the
        /// output side is the only record that a file changed at all.
        private func outputOperation(for ref: AttachmentRef, isPatchResult: Bool) -> Operation? {
            if let toolName = ref.toolName {
                return TurnFileAccess.operation(forToolName: toolName)
            }
            return isPatchResult ? .edit : nil
        }

        private mutating func nextOrdinal() -> Int {
            ordinal += 1
            return ordinal
        }

        private mutating func append(_ op: Op, path: String) {
            if opsByPath[path] == nil { pathOrder.append(path) }
            opsByPath[path, default: []].append(op)
            sequence.append(
                SequenceMark(ordinal: op.ordinal, operation: op.operation, isError: op.isError)
            )
        }

        /// Resolves a jump target for a ref whose call is unknown. Never
        /// returns a `.toolResult` / `.stop` uuid when any card-mapped step
        /// has been seen.
        private func anchor(for step: Step) -> String {
            if let id = step.toolResult?.toolUseId, let uuid = callStepByToolUseId[id] {
                return uuid
            }
            if step.kind == .toolResult || step.kind == .stop {
                return lastAnchorUuid ?? step.uuid
            }
            return step.uuid
        }

        /// `.file` / `.image` locators are real paths. `.directory` is a
        /// search root, `.url` a fetch, `.inlineImage` has no path.
        private func filePath(from ref: AttachmentRef) -> String? {
            switch ref.kind {
            case .file, .image:
                let trimmed = ref.locator.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .directory, .url, .inlineImage:
                return nil
            }
        }

        func finish() -> Model? {
            let allRows: [FileRow] = pathOrder.compactMap { path in
                guard let ops = opsByPath[path], !ops.isEmpty else { return nil }
                let deepest = ops.map(\.operation).max { $0.depth < $1.depth } ?? .read
                return FileRow(
                    path: path,
                    ops: ops,
                    deepest: deepest,
                    errorCount: ops.filter(\.isError).count
                )
            }
            guard !allRows.isEmpty else { return nil }

            let kept = Array(allRows.prefix(TurnFileAccess.maxFileRows))
            let folded = allRows.dropFirst(TurnFileAccess.maxFileRows)
            // A file only counts as changed once a change actually landed.
            // A failed `Edit` still produces an input-side ref (the resolver
            // reads the call, not the outcome), so counting attempts would
            // report "1개 파일 변경" for a turn that changed nothing —
            // measured Edit failure rate is 2.5%.
            let changed = allRows.filter { $0.hasSucceededChange }.count
            let reads = allRows.reduce(0) { total, row in
                total + row.ops.filter { $0.operation == .read }.count
            }

            return Model(
                rows: kept,
                foldedRows: Array(folded),
                foldedOpCount: folded.reduce(0) { $0 + $1.ops.count },
                searchOpCount: searchOpCount,
                heuristicPaths: heuristicPaths,
                heuristicOpCount: heuristicOpCount,
                sequence: sequence,
                fileCount: allRows.count,
                changedFileCount: changed,
                readOpCount: reads,
                summaryText: TurnFileAccess.summary(
                    fileCount: allRows.count,
                    changedFileCount: changed,
                    readOnlyFileCount: allRows.filter { $0.deepest == .read }.count,
                    readOpCount: reads,
                    searchOpCount: searchOpCount
                )
            )
        }
    }

    // MARK: - Summary

    /// Scan line. Deliberately a **classification, not a ratio**: measured,
    /// 70% of turns that read a file changed nothing, so a "read N → changed
    /// M" framing would print "→ 0" on the common case and read as a verdict
    /// on what was legitimate exploration.
    /// English because the app's UI is English throughout — the
    /// `noKoreanStringLiteralInUI` guard enforces that under `Lupen/UI`, and
    /// this string renders straight into the card, so it holds to the same
    /// rule even though it lives under `Lupen/Domain`.
    static func summary(
        fileCount: Int,
        changedFileCount: Int,
        readOnlyFileCount: Int,
        readOpCount: Int,
        searchOpCount: Int
    ) -> String {
        var parts: [String] = []
        // Files that were written to but where nothing landed. Neither changed
        // nor read-only; naming them either way contradicts their own row,
        // which is badged "Failed".
        let failedFileCount = max(0, fileCount - changedFileCount - readOnlyFileCount)
        if changedFileCount == 0 {
            // "Explored only" is a claim that nothing was even attempted, so a
            // turn whose one edit failed does not get to make it.
            if failedFileCount > 0 {
                parts.append(pluralized(fileCount, "file"))
                parts.append("\(failedFileCount) failed")
            } else {
                parts.append("Explored only")
                parts.append(pluralized(fileCount, "file"))
            }
        } else {
            parts.append("\(pluralized(changedFileCount, "file")) changed")
            // Counted, not derived as `fileCount - changedFileCount`: a file
            // whose only edit failed is neither changed nor read-only, and
            // calling it read-only would assert it was never written to while
            // its own row shows a failed edit.
            if readOnlyFileCount > 0 {
                parts.append("\(readOnlyFileCount) read-only")
            }
            if failedFileCount > 0 { parts.append("\(failedFileCount) failed") }
        }
        // "2 read" beside "54 reads" named the same measure twice — one counts
        // files, the other operations. Name the unit.
        if readOpCount > fileCount { parts.append("\(readOpCount) read ops") }
        if searchOpCount > 0 {
            parts.append(pluralized(searchOpCount, "search", plural: "searches"))
        }
        return parts.joined(separator: " · ")
    }

    private static func pluralized(_ count: Int, _ noun: String, plural: String? = nil) -> String {
        count == 1 ? "\(count) \(noun)" : "\(count) \(plural ?? noun + "s")"
    }
}

/// Conversation block carrying a built model. Will be inserted by
/// `ConversationStoryBuilder` above the timeline card so the file view leads a
/// selected turn — that wiring lands with the renderer, not here.
///
/// `isHighlighted` is always `false` and this type is deliberately absent from
/// `ConversationStoryBuilder.anchorStepUuids(of:)`: the card is the *origin*
/// of jumps, never a destination. Registering its step uuids there would make
/// a tool-step selection in the tree retarget the highlight from the content
/// card to this overview card (same reasoning as `TimelineBlock`).
struct FileAccessBlock: ConversationBlock, Equatable {
    let id: String
    let model: TurnFileAccess.Model
    /// Reads per-file line deltas from the raw JSONL.
    ///
    /// Carried as a closure because the counts live in `toolUseResult`, which
    /// the snapshot drops — the card renders from the snapshot at once and
    /// fills these in afterwards rather than blocking a turn selection on file
    /// reads. `nil` where there is nothing to read from (tests, previews).
    let loadDiffStats: (@Sendable () -> TurnFileDiffStats)?

    /// Cache key for the deltas, carrying a freshness token.
    ///
    /// `id` alone is not enough: Lupen indexes live sessions, so a turn the
    /// agent is still working in *grows*. Keying on the turn alone would pin
    /// the first reading forever and leave the card showing `+12 −3` while an
    /// export of the same turn — which reads directly, without this cache —
    /// showed `+87 −40`. Including the step count and the last step's uuid
    /// makes a grown turn a different key, so it re-reads.
    let diffCacheKey: String

    init(
        id: String,
        model: TurnFileAccess.Model,
        diffCacheKey: String? = nil,
        loadDiffStats: (@Sendable () -> TurnFileDiffStats)? = nil
    ) {
        self.id = id
        self.model = model
        self.diffCacheKey = diffCacheKey ?? id
        self.loadDiffStats = loadDiffStats
    }

    /// Builds the freshness-carrying key for a turn.
    static func diffCacheKey(turnId: String, steps: [Step]) -> String {
        "\(turnId)#\(steps.count)#\(steps.last?.uuid ?? "")"
    }

    var tier: BlockTier { .primary }
    var role: BlockRole { .system }
    var isHighlighted: Bool { false }
    var plainTextFallback: String { "🗂 \(model.summaryText)" }

    /// Compares identity and content, not the loader — a closure is not
    /// comparable, and two blocks for the same turn describe the same card
    /// whichever reader they carry. Keeps this type a value like every other
    /// `ConversationBlock`.
    static func == (lhs: FileAccessBlock, rhs: FileAccessBlock) -> Bool {
        lhs.id == rhs.id && lhs.model == rhs.model
    }
}
