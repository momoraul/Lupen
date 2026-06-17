import Foundation

/// Decodes a single JSONL line (`Data`) into a `RichEntry`.
///
/// Uses structured `JSONDecoder` decoding but tolerates multiple shapes for content blocks.
/// Returns nil if `type` is neither "user" nor "assistant", or if required fields are missing.
enum RichEntryDecoder {

    private static let decoderThreadKey = "io.lupen.RichEntryDecoder.decoder"

    private static func decoder() -> JSONDecoder {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[decoderThreadKey] as? JSONDecoder {
            return existing
        }
        let decoder = JSONDecoder()
        dictionary[decoderThreadKey] = decoder
        return decoder
    }

    /// Fixed-config `ISO8601DateFormatter` instances. Allocating a new
    /// formatter on every call was the single biggest Phase A cost —
    /// Instruments showed `NSISO8601DateFormatter.__allocating_init`
    /// consuming 17.17 G cycles (14.4% of total app time, 50% of
    /// `decodeDetailed`) on a 90k-line parse.
    ///
    /// `ISO8601DateFormatter` is thread-safe as long as its options are
    /// not mutated concurrently; both instances are configured once
    /// during lazy static-let init and then only read.
    /// `nonisolated(unsafe)` is required because class instances are
    /// not implicitly `Sendable`, but the concurrency guarantee above
    /// plus never-mutated state makes this safe for the Phase A
    /// `DispatchQueue.concurrentPerform` workers.
    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso8601NoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601 timestamp parsing. Most Claude Code builds emit fractional seconds,
    /// but older/variant versions may omit them — try both formats. Formatter
    /// instances are cached via `static let` (see above).
    static func parseTimestamp(_ s: String) -> Date? {
        if let d = iso8601Fractional.date(from: s) { return d }
        return iso8601NoFractional.date(from: s)
    }

    /// Lightweight parent link — extracts `(sessionId, uuid) → parentUuid` from
    /// every JSONL line (including attachment / system / file-history-snapshot).
    /// Used by the Assembler's parent-chain walk to hop over dropped intermediate
    /// links.
    struct ParentLink: Sendable {
        let sessionId: String
        let uuid: String
        let parentUuid: String?
    }

    /// Extracts only `(sessionId, uuid, parentUuid)` without a full decode. nil = ignore.
    static func extractParentLink(_ data: Data) -> ParentLink? {
        // Reading only `LineHeader` skips the `message` / content-block decode
        // cost. On a 90k-line file this path alone saves a large fraction of
        // Phase A time (assistant content blocks can be several KB). Accuracy
        // matches `RawLine` since only `sessionId` / `uuid` / `parentUuid` are
        // needed.
        let header = scanHeader(data)
        guard let sessionId = header.sessionId, let uuid = header.uuid else {
            return nil
        }
        return ParentLink(sessionId: sessionId, uuid: uuid, parentUuid: header.parentUuid)
    }

    /// Lightweight per-line metadata — carries only type/uuid/parentUuid/
    /// sessionId/customTitle. Lets a worker derive every per-line signal
    /// (parentLink / custom-title classification / user-entry detection) from
    /// a **single JSON decode** instead of one decode per signal.
    ///
    /// Unlike `RawLine`, this excludes `message`, avoiding content-block /
    /// usage subtree decode cost. Cuts 90k lines × 5 signal-decodes down to
    /// 90k lines × 2 decodes (header + decodeDetailed).
    struct LineHeader: Sendable {
        let type: String?
        let uuid: String?
        let parentUuid: String?
        let sessionId: String?
        let customTitle: String?
    }

    /// Extracts a `LineHeader` from a line in a single decode pass. On
    /// malformed JSON / decode failure, returns a struct with all-nil fields
    /// (callers already guard via nil checks).
    ///
    /// Callers:
    ///   - Phase A main loop (`AppStateStore.performInitialParse`) — derives
    ///     multiple per-line signals from this single struct.
    ///   - `extractParentLink` / `extractCustomTitle` / `isUserEntry` — thin
    ///     wrappers for non-hot-path / test compatibility.
    static func scanHeader(_ data: Data) -> LineHeader {
        guard let raw = try? decoder().decode(HeaderShape.self, from: data) else {
            return LineHeader(type: nil, uuid: nil, parentUuid: nil, sessionId: nil, customTitle: nil)
        }
        return LineHeader(
            type: raw.type,
            uuid: raw.uuid,
            parentUuid: raw.parentUuid,
            sessionId: raw.sessionId,
            customTitle: raw.customTitle
        )
    }

    /// Internal Decodable shape used by `LineHeader`. Functionally overlaps
    /// with `CustomTitleLine`, but kept separate (header vs. /rename record)
    /// so future field additions on either side don't collide.
    private struct HeaderShape: Decodable {
        let type: String?
        let uuid: String?
        let parentUuid: String?
        let sessionId: String?
        let customTitle: String?
    }

    /// Extracts `(sessionId, title)` from the
    /// `{"type":"custom-title","customTitle":"...","sessionId":"..."}` entry
    /// Claude Code records when `/rename` sets a session title. Returns nil
    /// for any other entry type.
    ///
    /// Same pattern as `extractParentLink` — called independently of the
    /// main decode pipeline against every line, so even though
    /// `knownSilentTypes` silent-drops this entry the title is still
    /// preserved as session metadata.
    ///
    /// A session may have multiple `/rename` calls, so callers accumulate
    /// with a last-write-wins policy.
    struct CustomTitleRecord: Sendable, Equatable {
        let sessionId: String
        let title: String
    }

    static func extractCustomTitle(_ data: Data) -> CustomTitleRecord? {
        customTitleRecord(from: scanHeader(data))
    }

    /// Derives a `CustomTitleRecord` from a `LineHeader`. Lets a worker that
    /// already ran `scanHeader` reuse the result instead of decoding twice.
    static func customTitleRecord(from header: LineHeader) -> CustomTitleRecord? {
        guard header.type == "custom-title", let sid = header.sessionId else {
            return nil
        }
        let trimmed = (header.customTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CustomTitleRecord(sessionId: sid, title: trimmed)
    }

    /// Shape dedicated to `extractCustomTitle` — reads only the three needed
    /// fields instead of a full `RawLine` decode. Also reused by
    /// `isUserEntry` which only needs `type` (the decoder fills missing
    /// fields with nil).
    private struct CustomTitleLine: Decodable {
        let type: String?
        let sessionId: String?
        let customTitle: String?
    }

    /// Lightweight check for whether a line is a `"type":"user"` entry.
    ///
    /// At session start Claude Code carry-forwards the previous session's
    /// `custom-title` to the top of the file (around lines 1–2). To the
    /// user this looks like a bug — the sidebar shows a title they never
    /// `/rename`d. Distinguishing requires a "before vs. after the first
    /// user prompt" boundary, which this helper provides (see
    /// `extractCustomTitleDecision`).
    static func isUserEntry(_ data: Data) -> Bool {
        scanHeader(data).type == "user"
    }


    /// Decodes a single line. Returns nil on decode failure or unsupported `type`.
    ///
    /// Use `decodeDetailed(_:)` if the rejection reason (format violation vs.
    /// expected filter drop) is needed.
    static func decode(_ data: Data) -> RichEntry? {
        switch decodeDetailed(data) {
        case .entry(let e): return e
        case .drop: return nil
        }
    }

    /// Detailed decode that classifies the rejection reason via
    /// `DecodeRejection`.
    ///
    /// Callers (parser / `AppStateStore`) inspect the result and only
    /// report `.error`/`.warning` severity rejections to `ParseDiagnostics`;
    /// normal silent drops are ignored.
    ///
    /// Known non-conversational JSONL types Claude Code emits. These don't
    /// participate in Turn/Step/token accounting and serve only as session
    /// metadata (hook tracking, timing, permission state, etc.). Silent-
    /// dropped at decode time.
    ///
    /// Per-type purpose:
    /// - `system`        : timing / hook summaries (turn_duration, stop_hook_summary)
    /// - `attachment`    : hook responses (hook_success, async_hook_response)
    /// - `permission-mode`: session permission state (no uuid; violates required-field rules)
    /// - `mode`          : session mode state (normal/plan/etc.; no conversation body)
    /// - `agent-name`    : agent name attached to the session (e.g. "start")
    /// - `custom-title`  : user-assigned session title
    /// - `last-prompt`   : tracks the most recent user prompt (no uuid).
    ///                    Backstop for long multi-byte prompts (e.g. Korean)
    ///                    where the EntryFilter prefix check can be bypassed
    ///                    by a UTF-8 cut.
    /// - `pr-link`       : Claude Code records this when it recognises a PR/MR URL
    ///                    (sessionId/prNumber/prUrl/prRepository/timestamp). No
    ///                    uuid/parentUuid/conversation body — metadata only.
    /// - `ai-title`      : auto-generated session title (`{type, aiTitle, sessionId}`).
    ///                    No uuid / timestamp. Re-emitted whenever Claude Code
    ///                    refreshes the suggestion.
    /// - `file-history-snapshot` / `last-prompt` : EntryFilter prefix-check is
    ///                    the primary defence, but lines that push the marker
    ///                    past the prefix window need this backstop too.
    ///
    /// When a new complex type surfaces as an `unknownType` warning, the
    /// Lupen dev analyses it and adds it here. Simple session-scoped scalar
    /// metadata is handled by `isSessionScopedScalarMetadata(...)` below so
    /// Claude Code can add fields like `agent-setting` without starting a
    /// diagnostics whack-a-mole. See `docs/PARSE-DIAGNOSTICS.md`.
    ///
    /// **Decisive safety net**: `finishDecodeDetailed` runs the type switch
    /// *before* uuid / sessionId / timestamp validation, so a new meta type
    /// not yet listed here surfaces as `unknownType(...)` rather than a
    /// misleading `missingRequiredField('uuid')`. This Set's role is only
    /// "fully silent — no warning either"; the safety guarantee comes from
    /// the branch ordering.
    private static let knownSilentTypes: Set<String> = [
        "system",
        "attachment",
        "permission-mode",
        "mode",
        "agent-name",
        "custom-title",
        "last-prompt",
        // PR/MR link metadata — Claude Code records repo/branch context
        // when the user pastes a PR URL. No uuid, no conversation body.
        "pr-link",
        // AI-generated session title (`{type:"ai-title", aiTitle, sessionId}`).
        // No uuid / timestamp. Repeats throughout the JSONL whenever
        // Claude Code refreshes the suggestion.
        "ai-title",
        // File-state snapshot — Claude Code records `{type, messageId,
        // snapshot}` blobs to support undo / time-travel. No uuid.
        "file-history-snapshot",
        // Internal task-queue bookkeeping (`{type:"queue-operation", ...}`).
        // EntryFilter prefix-check is the primary defence (this is the
        // single highest-volume type after `attachment` — 1.8k/session
        // observed); registering here too is a backstop for sub-agent
        // JSONLs where parentUuid/cwd/sessionId/version push the
        // `type` field past the 200-byte prefix window.
        "queue-operation",
        // Hook progress events (Claude Code's PreToolUse / PostToolUse
        // hook system records "hook_progress" markers as type=progress
        // entries inside sub-agent JSONLs). EntryFilter has a prefix
        // check too but sub-agent lines carry parentUuid + cwd +
        // sessionId + version BEFORE "type", pushing the marker past
        // the 200-byte prefix window — full-decode silent drop is the
        // backstop.
        "progress"
    ]

    static func decodeDetailed(_ data: Data) -> DecodeOutcome {
        decodeDetailedWithRejections(data).outcome
    }

    /// Same as `decodeDetailed(_:)` but also returns any **non-fatal**
    /// per-block diagnostics accumulated while the entry was built
    /// (unknown content block types, inline-image-attachment info
    /// counters). Caller can append these straight onto a
    /// `ParseDiagnosticsBatch`. Returning a separate list rather than
    /// stuffing them into `DecodeOutcome` keeps the success/drop
    /// semantics of `DecodeOutcome` clean — an entry that "succeeded
    /// *but* we noticed something worth warning about" would otherwise
    /// need a third case.
    static func decodeDetailedWithRejections(
        _ data: Data
    ) -> (outcome: DecodeOutcome, extraRejections: [DecodeRejection]) {
        if EntryFilter.shouldReject(data) {
            return (.drop(.filteredPreCheck), [])
        }

        let raw: RawLine
        do {
            raw = try decoder().decode(RawLine.self, from: data)
        } catch {
            return (.drop(.malformedJSON(error.localizedDescription)), [])
        }

        var rejections: [DecodeRejection] = []
        let outcome = finishDecodeDetailed(data: data, raw: raw, rejections: &rejections)
        return (outcome, rejections)
    }

    /// Phase A hot-path 1-pass decode.
    ///
    /// Returns the combined result of `decodeDetailed(_:)` + `scanHeader(_:)`
    /// from a **single RawLine decode**. Phase A workers previously decoded
    /// each line twice (shallow `scanHeader` + deep `decodeDetailed`); this
    /// collapses to one decode, saving ~4s on a 90k-line file.
    ///
    /// The returned `LineHeader` is assembled from `RawLine` fields so it is
    /// semantically equivalent to `scanHeader`. On rare early-exit paths
    /// (EntryFilter reject / malformedJSON) we fall back to `scanHeader`
    /// to preserve accuracy.
    ///
    /// Non-hot-path callers (tests / diagnostic code / `extractParentLink`)
    /// keep using `decodeDetailed(_:) -> DecodeOutcome` and `scanHeader(_:)
    /// -> LineHeader`; signatures remain compatible.
    static func decodeDetailedWithHeader(_ data: Data) -> (outcome: DecodeOutcome, header: LineHeader) {
        let (outcome, header, _) = decodeDetailedWithHeaderAndRejections(data)
        return (outcome, header)
    }

    /// Same as `decodeDetailedWithHeader(_:)` plus per-block diagnostics —
    /// mirrors `decodeDetailedWithRejections(_:)` but on the hot path
    /// that also needs the `LineHeader`. Phase A of the parse pipeline
    /// (see `AppStateStore`) uses this to append block-level warnings
    /// to the per-file `ParseDiagnosticsBatch` without re-decoding.
    static func decodeDetailedWithHeaderAndRejections(
        _ data: Data
    ) -> (outcome: DecodeOutcome, header: LineHeader, extraRejections: [DecodeRejection]) {
        if EntryFilter.shouldReject(data) {
            return (.drop(.filteredPreCheck), scanHeader(data), [])
        }
        let raw: RawLine
        do {
            raw = try decoder().decode(RawLine.self, from: data)
        } catch {
            // Malformed JSON — if RawLine fails, HeaderShape almost
            // certainly fails too. `scanHeader` returns an empty header in
            // that case, which downstream callers naturally discard via
            // their existing nil-field checks.
            return (.drop(.malformedJSON(error.localizedDescription)), scanHeader(data), [])
        }
        let header = LineHeader(
            type: raw.type,
            uuid: raw.uuid,
            parentUuid: raw.parentUuid,
            sessionId: raw.sessionId,
            customTitle: raw.customTitle
        )
        var rejections: [DecodeRejection] = []
        let outcome = finishDecodeDetailed(data: data, raw: raw, rejections: &rejections)
        return (outcome, header, rejections)
    }

    /// Shared back half of `decodeDetailed` and `decodeDetailedWithHeader`.
    /// Handles type validation / required-field checks / image-source meta
    /// branching / `RichEntry` construction after the caller has already
    /// run the `RawLine` decode + `EntryFilter` stage.
    ///
    /// Parameters:
    ///   - `data`: original bytes, retained as `RichEntry.rawJSON`.
    ///   - `raw`: already-decoded `RawLine` (caller-supplied for reuse).
    private static func finishDecodeDetailed(
        data: Data,
        raw: RawLine,
        rejections: inout [DecodeRejection]
    ) -> DecodeOutcome {
        guard let type = raw.type else {
            return .drop(.missingRequiredField("type"))
        }

        // Known non-conversational types — silent-drop even when they
        // violate required-field rules (uuid, etc). Must run before the
        // generic required-field checks so entries like `permission-mode`
        // (no uuid) don't surface as `.missingRequiredField` errors.
        if Self.knownSilentTypes.contains(type) {
            return .drop(.filteredPreCheck)
        }
        if Self.isSessionScopedScalarMetadata(data: data, raw: raw) {
            return .drop(.filteredPreCheck)
        }

        // **Branch ordering decision** — type validation runs before the
        // required-field checks (uuid/sessionId/timestamp). Each new meta
        // type Claude Code introduces (`ai-title`, `pr-link`,
        // `file-history-snapshot`, ...) often has no uuid/timestamp. If
        // required-field checks ran first, those new meta types would
        // surface as misleading `missingRequiredField('uuid')` errors,
        // leaving the user wondering "why is uuid missing from our data?"
        // Running the type switch first routes any non-user/assistant
        // type to `unknownType(...)` (.warning) — the accurate diagnosis
        // that "Claude Code added a new entry type, please investigate".
        // This is the safety net that keeps un-registered new types out
        // of the noisy .error bucket.
        let entryType: RichEntry.EntryType
        switch type {
        case "user": entryType = .user
        case "assistant": entryType = .assistant
        default:
            // Not in EntryFilter, not in knownSilentTypes — likely a
            // Claude Code format change or new entry kind → warning.
            return .drop(.unknownType(type))
        }

        // Required-field checks (user/assistant only) — checked individually
        // to report the specific missing field. By this point `type` is
        // guaranteed to be conversational.
        guard let uuid = raw.uuid else {
            return .drop(.missingRequiredField("uuid"))
        }
        guard let sessionId = raw.sessionId else {
            return .drop(.missingRequiredField("sessionId"))
        }
        guard let timestampStr = raw.timestamp else {
            return .drop(.missingRequiredField("timestamp"))
        }

        guard let timestamp = Self.parseTimestamp(timestampStr) else {
            return .drop(.badTimestamp(timestampStr))
        }

        let blocks = decodeBlocks(raw.message?.content, rejections: &rejections)

        // Emit one `inlineImageAttachment` info counter per `.image`
        // block encountered on a user entry. This is intentionally
        // coarse (counter only, never a warning) — inline images are
        // the default for current Claude Code; we're just making the
        // frequency observable in the Diagnostics window so a sudden
        // drop to zero (or a sudden climb) is noticeable.
        if entryType == .user {
            for block in blocks {
                if case .image = block {
                    rejections.append(.inlineImageAttachment)
                }
            }
        }

        // Drop fully-empty user entries so they don't fragment a Turn.
        // Expected occurrence (sub-skill trigger). The parent link is
        // collected separately via `extractParentLink`.
        if entryType == .user && blocks.isEmpty {
            return .drop(.emptyUserContent)
        }

        // User entries containing only `[Image source: /path/...]` text are
        // **not dropped** — they're converted to a `RichEntry` carrying only
        // `imageSourcePaths`. The Assembler doesn't emit these as Steps;
        // instead it walks the parent chain and merges the paths into the
        // nearest prompt Step's `imageSourcePaths`.
        if entryType == .user, isImageSourceMetaOnly(blocks) {
            let paths = extractImageSourcePaths(blocks)
            guard !paths.isEmpty else {
                return .drop(.imageSourceMeta)
            }
            return .entry(RichEntry(
                uuid: uuid,
                parentUuid: raw.parentUuid,
                sessionId: sessionId,
                timestamp: timestamp,
                entryType: .user,
                blocks: [],  // empty so the Assembler doesn't emit a Step
                rawJSON: data,
                isImageSourceMeta: true,
                imageSourcePaths: paths,
                isSidechain: raw.isSidechain == true,
                agentId: raw.agentId
            ))
        }

        // Drop system-meta entries Claude Code auto-injects under the user
        // role. The specific kind identifier is preserved in the rejection
        // reason for diagnostic visibility.
        if entryType == .user, let metaKind = detectClaudeCodeSystemMeta(blocks) {
            return .drop(.claudeCodeSystemMeta(metaKind))
        }
        // Async `Agent` tool_use launch confirmation result. Body
        // is pure system metadata ("Async agent launched
        // successfully.\nagentId: …\nThe agent is working in the
        // background…\noutput_file: …") — zero cost, no user
        // value. The matching SubAgent header (Phase B graft)
        // already conveys the only useful fact (this sub-agent
        // started). Without this drop the launch confirmation
        // surfaces as a separate ↪ toolResult Step right after
        // the SubAgent header rows, repeating the same info three
        // times for parallel calls.
        if entryType == .user, isAgentLaunchEnvelopeToolResult(blocks) {
            return .drop(.claudeCodeSystemMeta("agent-launch-envelope"))
        }

        // <command-message>skill-name</command-message> entries → rewrite as
        // "/skill-name args" text so they show up as proper slash-command prompts.
        let finalBlocks: [RichContentBlock]
        if entryType == .user, let slashText = Self.parseSlashCommand(blocks) {
            finalBlocks = [.text(slashText)]
        } else {
            finalBlocks = blocks
        }

        return .entry(RichEntry(
            uuid: uuid,
            parentUuid: raw.parentUuid,
            sessionId: sessionId,
            timestamp: timestamp,
            entryType: entryType,
            requestId: raw.requestId,
            messageId: raw.message?.id,
            model: raw.message?.model,
            stopReason: raw.message?.stopReason,
            usage: raw.message?.usage,
            blocks: finalBlocks,
            rawJSON: data,
            isSystemInjected: raw.isMeta == true,
            isSidechain: raw.isSidechain == true,
            agentId: raw.agentId,
            isCompactSummary: raw.isCompactSummary == true,
            gitBranch: raw.gitBranch
        ))
    }

    private static let conversationSignalKeys: Set<String> = [
        "uuid",
        "parentUuid",
        "timestamp",
        "requestId",
        "message",
        "toolUseResult",
        "usage"
    ]

    private static func isSessionScopedScalarMetadata(data: Data, raw: RawLine) -> Bool {
        guard raw.sessionId != nil,
              raw.uuid == nil,
              raw.parentUuid == nil,
              raw.timestamp == nil,
              raw.requestId == nil,
              raw.message == nil else {
            return false
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["type"] is String,
              dict["sessionId"] is String else {
            return false
        }
        guard !dict.keys.contains(where: { conversationSignalKeys.contains($0) }) else {
            return false
        }
        for (key, value) in dict where key != "type" && key != "sessionId" {
            guard isScalarJSONValue(value) else { return false }
        }
        return true
    }

    private static func isScalarJSONValue(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is NSNull
    }

    /// Matches both `[Image source: /path]` (older Claude Code) and
    /// `[Image: source: /path]` (newer Claude Code). The capture group 1 is
    /// the path. Used by both `isImageSourceMetaOnly` and
    /// `extractImageSourcePaths` so the two helpers can never drift.
    private static let imageSourcePattern: NSRegularExpression = {
        // \[Image[:\s]+source:\s*(.+?)\]
        //    ^ optional colon + required space between "Image" and "source:"
        //         ^ any chars (non-greedy) inside brackets
        let pattern = #"\[Image[:\s]*source:\s*([^\]]+)\]"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// True iff `blocks` consists exclusively of "image source" meta text blocks.
    /// Recognises both Claude Code formats:
    ///   - `[Image source: /path]`        (legacy)
    ///   - `[Image: source: /path]`       (current)
    private static func isImageSourceMetaOnly(_ blocks: [RichContentBlock]) -> Bool {
        guard !blocks.isEmpty else { return false }
        for block in blocks {
            guard case .text(let s) = block else { return false }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            // Require exactly one image-source marker spanning the entire
            // trimmed text — any surrounding content means it's a regular
            // prompt that happens to reference an image, not a meta entry.
            let matches = imageSourcePattern.matches(in: trimmed, options: [], range: range)
            guard matches.count == 1,
                  let match = matches.first,
                  match.range.location == 0,
                  match.range.length == ns.length else {
                return false
            }
        }
        return true
    }

    /// Regex-extracts image paths from "image source" meta entry blocks. Supports both formats.
    static func extractImageSourcePaths(_ blocks: [RichContentBlock]) -> [String] {
        var paths: [String] = []
        for block in blocks {
            guard case .text(let s) = block else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            imageSourcePattern.enumerateMatches(in: trimmed, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 2 else { return }
                let pathRange = match.range(at: 1)
                guard pathRange.location != NSNotFound else { return }
                let path = ns.substring(with: pathRange)
                    .trimmingCharacters(in: .whitespaces)
                if !path.isEmpty {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    /// Detects whether `blocks` is a system-meta entry Claude Code auto-injects
    /// under the user role (slash command output, compaction, etc.) and returns
    /// the specific kind identifier. nil = not system meta.
    ///
    /// Sample return values: "command-name", "local-command-stdout",
    /// "system-reminder". The specific kind ends up in the diagnostics log,
    /// which helps when tracking Claude Code updates.
    ///
    /// **NOTE**: the post-`/compact` resume prompt ("This session is being
    /// continued from a previous conversation...") is intentionally excluded
    /// from this match path — it acts as a chain hub, so instead of dropping
    /// it we identify it via the JSONL `isCompactSummary: true` flag and
    /// keep it as a real `.prompt` (see `RichEntry.isCompactSummary`).
    private static func detectClaudeCodeSystemMeta(_ blocks: [RichContentBlock]) -> String? {
        guard !blocks.isEmpty else { return nil }
        var combined = ""
        for block in blocks {
            switch block {
            case .text(let s), .thinking(let s):
                combined += s
            default:
                return nil  // any non-text block → not a meta entry
            }
        }
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        // Note: <command-message> is NOT dropped here. `parseSlashCommand`
        // rewrites it as slash-command text so it survives as a prompt.
        let metaPrefixes: [(prefix: String, kind: String)] = [
            ("<command-name>",        "command-name"),
            ("<local-command-stdout>", "local-command-stdout"),
            ("<local-command-caveat>", "local-command-caveat"),
            // `<system-reminder>` is injected by Claude Code itself
            // (e.g. hook success lines, TodoWrite nudges, skill-bundle
            // load reminders). Rendering these as user prompts
            // inflates Turn counts and pollutes prompt search — they
            // are not user-authored content. Matches research-turn-model
            // §5 hardNoise list; the rest of that list is already
            // filtered via EntryFilter / PricingTable / .interruption.
            ("<system-reminder>",     "system-reminder"),
            // NOTE: "This session is being continued from a previous
            // conversation..." (the post-compact resume prompt) is
            // **NOT** dropped here. It carries the JSONL flag
            // `isCompactSummary: true` and is preserved as a real
            // `.prompt` Step so post-compact assistants can chain
            // back to it via parentUuid. The display layer
            // (TurnPreview / Step.oneLineSummary) substitutes a
            // short "↻ Compact resume" label so the long synthetic
            // summary doesn't pollute the outline.
            // Claude Code re-injects the result of an async `Agent`
            // tool_use back into the parent conversation as a synthetic
            // user message that begins with `<task-notification>`. Its
            // body carries `<task-id>` (= sub-agent's agentId) and
            // `<tool-use-id>` (= the parent Agent tool_use id), plus
            // `<status>` / `<summary>` / `<result>`. Treating it as a
            // regular user prompt fragments the outline — each
            // notification spawns a new top-level Turn alongside the
            // original "I called Agent X" Turn, splitting cost and
            // breaking the conversation flow visually.
            //
            // Drop here so the downstream assistant response (the user's
            // actual reply to "task done, here's the result") falls
            // through ConversationAssembler's parent-chain hop and
            // joins the parent Turn that issued the Agent call.
            ("<task-notification>",   "task-notification")
        ]
        for (prefix, kind) in metaPrefixes {
            if trimmed.hasPrefix(prefix) { return kind }
        }

        // `[Request interrupted by user]` is NOT dropped. Although Claude
        // Code auto-injects it, it carries workflow signal ("the user stopped
        // here") and is rendered as an `.interruption` Step kind instead
        // (see `StepBuilder.classify`).

        return nil
    }

    /// Backwards-compatible Bool variant.
    private static func isClaudeCodeSystemMeta(_ blocks: [RichContentBlock]) -> Bool {
        detectClaudeCodeSystemMeta(blocks) != nil
    }

    /// True when `blocks` is exactly one `tool_result` whose body
    /// starts with the async `Agent` launch envelope. SubAgentLinker
    /// already extracts the agentId from this body via the raw byte
    /// stream, so dropping the decoded entry doesn't break the
    /// linkage map — the result Step just disappears from the
    /// conversation outline.
    static func isAgentLaunchEnvelopeToolResult(_ blocks: [RichContentBlock]) -> Bool {
        guard blocks.count == 1 else { return false }
        guard case .toolResult(_, let content, _) = blocks[0] else { return false }
        return content.hasPrefix("Async agent launched")
    }

    /// For a slash-command invocation matching the
    /// `<command-message>name</command-message>` pattern, returns text of the
    /// form `/name args`. Returns nil otherwise.
    ///
    /// Pattern:
    /// ```
    /// <command-message>worklog-gh-cli</command-message>
    /// <command-name>/worklog-gh-cli</command-name>
    /// <command-args>4/10</command-args>
    /// ```
    /// → `/worklog-gh-cli 4/10`
    static func parseSlashCommand(_ blocks: [RichContentBlock]) -> String? {
        guard !blocks.isEmpty else { return nil }
        var combined = ""
        for block in blocks {
            guard case .text(let s) = block else { return nil }
            combined += s
        }
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<command-message>") else { return nil }

        // Extract command name from <command-message>NAME</command-message>
        guard let nameEnd = trimmed.range(of: "</command-message>") else { return nil }
        let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 17)..<nameEnd.lowerBound])

        // Extract optional args from <command-args>ARGS</command-args>
        var args = ""
        if let argsStart = trimmed.range(of: "<command-args>"),
           let argsEnd = trimmed.range(of: "</command-args>") {
            args = String(trimmed[argsStart.upperBound..<argsEnd.lowerBound])
        }

        let slash = "/\(name)"
        return args.isEmpty ? slash : "\(slash) \(args)"
    }

    /// True iff the trimmed text is one of the `[Request interrupted ...]` user-stop markers.
    static func isUserInterruptionMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "[Request interrupted by user]" ||
            trimmed == "[Request interrupted by user for tool use]" ||
            trimmed == "[Request interrupted]"
    }

    // MARK: - Block decoding

    /// Converts a `content` field (`String` or `[Any]`) into `[RichContentBlock]`.
    /// Blocks with an unknown `type` are dropped and an
    /// `unknownContentBlockType` warning is appended to `rejections`. The
    /// drop itself is non-fatal (the entry still builds), but it signals to
    /// the user that Claude Code introduced a new block shape.
    /// Block types Claude Code emits that Lupen doesn't yet render but
    /// recognises as expected. Drop them silently — surfacing each one
    /// as `unknownContentBlockType` would spam the Diagnostics window
    /// the moment a user attaches a PDF without telling us anything we
    /// don't already know.
    ///
    /// **Maintenance**: when a new shape arrives that we *want* to
    /// render (e.g. `audio`, `video`, `file`), add the case to
    /// `RichContentBlock` + `convertBlock` instead of adding it here.
    /// This set is for "we know about it, we just don't surface it
    /// (yet)."
    private static let knownUnhandledBlockTypes: Set<String> = [
        // Anthropic 2025 PDF / file attachment block. `source.type` is
        // `base64` with `media_type: application/pdf` plus a `data`
        // payload. Could be wired into the Attachments tab as a future
        // enhancement; for now we drop without warning.
        "document",
    ]

    private static func decodeBlocks(
        _ content: RawContent?,
        rejections: inout [DecodeRejection]
    ) -> [RichContentBlock] {
        guard let content else { return [] }
        switch content {
        case .string(let s):
            return s.isEmpty ? [] : [.text(s)]
        case .blocks(let blocks):
            var result: [RichContentBlock] = []
            result.reserveCapacity(blocks.count)
            for block in blocks {
                if let converted = convertBlock(block) {
                    result.append(converted)
                } else if let type = block.type, !type.isEmpty {
                    if Self.knownUnhandledBlockTypes.contains(type) {
                        // Recognised shape, no UI consumer yet — drop
                        // silently without a warning.
                        continue
                    }
                    // Unknown block type. Record once per occurrence; the
                    // ParseDiagnostics ring buffer will dedupe surface
                    // samples by recency. Empty/nil type is rare and
                    // covered by entry-level field-required checks.
                    rejections.append(.unknownContentBlockType(type))
                }
            }
            return result
        }
    }

    private static func convertBlock(_ block: RawBlock) -> RichContentBlock? {
        switch block.type {
        case "text":
            let text = block.text ?? ""
            return .text(text)

        case "thinking":
            let text = block.thinking ?? block.text ?? ""
            return .thinking(text)

        case "tool_use":
            guard let id = block.id, let name = block.name else { return nil }
            let inputJSON: String
            if let inputData = block.inputJSONData {
                inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
            } else {
                inputJSON = "{}"
            }
            return .toolUse(id: id, name: name, inputJSON: inputJSON)

        case "tool_result":
            guard let toolUseId = block.toolUseId else { return nil }
            let contentText: String
            // `content` may be either a String or a block array
            if let simple = block.contentString {
                contentText = simple
            } else if let nested = block.contentBlocks {
                contentText = nested.compactMap { $0.text }.joined(separator: "\n")
            } else {
                contentText = ""
            }
            return .toolResult(
                toolUseId: toolUseId,
                content: contentText,
                isError: block.isError ?? false
            )

        case "image":
            let media = block.source?.mediaType
            // Unlike the `[Image source: path]` meta entry, an inline image
            // block doesn't carry a path (only base64 data). The `path: nil`
            // here leaves room for a future `source.path` extension field.
            return .image(mediaType: media, path: nil)

        default:
            return nil
        }
    }

    // MARK: - Raw decoder shapes

    private struct RawLine: Decodable {
        let type: String?
        let uuid: String?
        let parentUuid: String?
        let sessionId: String?
        let timestamp: String?
        let requestId: String?
        let isMeta: Bool?
        let isSidechain: Bool?
        /// JSONL `isCompactSummary: true` — the ground-truth flag Claude Code
        /// explicitly sets on the synthetic user message ("This session is
        /// being continued from a previous conversation...") emitted right
        /// after auto- or manual `/compact`. Preferred over body-prefix
        /// matching since the latter breaks under i18n / wording changes.
        let isCompactSummary: Bool?
        /// Sub-agent runtime ID. Present only on sub-agent JSONL lines
        /// (e.g. `agentId: "a5ab166735f956e5c"`); always absent on the
        /// parent JSONL. Matched against `SubAgentLinker.Link.agentId`
        /// to graft sub-agents under the parent's `Agent` Step (Phase B).
        let agentId: String?
        /// Title value from the `custom-title` entry that `/rename` records.
        /// Always nil on user / assistant lines. Lets
        /// `decodeDetailedWithHeader` derive `LineHeader.customTitle` from
        /// a single RawLine decode instead of running `scanHeader` again.
        let customTitle: String?
        /// Checked-out git branch Claude Code records per entry.
        let gitBranch: String?
        let message: RawMessage?
    }

    private struct RawMessage: Decodable {
        let id: String?
        let role: String?
        let model: String?
        let stopReason: String?
        let usage: RawEntry.UsageData?
        let content: RawContent?

        enum CodingKeys: String, CodingKey {
            case id, role, model, usage, content
            case stopReason = "stop_reason"
        }
    }

    private enum RawContent: Decodable {
        case string(String)
        case blocks([RawBlock])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let b = try? c.decode([RawBlock].self) {
                self = .blocks(b)
            } else {
                self = .blocks([])
            }
        }
    }

    /// Permissive block decoder — declares each per-type field as optional
    /// so a single shape covers text / thinking / tool_use / tool_result /
    /// image without per-type Decodable variants.
    private struct RawBlock: Decodable {
        let type: String?
        // text / thinking
        let text: String?
        let thinking: String?
        // tool_use
        let id: String?
        let name: String?
        let inputJSONData: Data?
        // tool_result
        let toolUseId: String?
        let contentString: String?
        let contentBlocks: [NestedBlock]?
        let isError: Bool?
        // image
        let source: RawImageSource?

        struct NestedBlock: Decodable {
            let type: String?
            let text: String?
        }

        struct RawImageSource: Decodable {
            let type: String?
            let mediaType: String?
            let data: String?

            enum CodingKeys: String, CodingKey {
                case type, data
                case mediaType = "media_type"
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, text, thinking, id, name, input, source
            case toolUseId = "tool_use_id"
            case content
            case isError = "is_error"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try c.decodeIfPresent(String.self, forKey: .type)
            self.text = try c.decodeIfPresent(String.self, forKey: .text)
            self.thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
            self.toolUseId = try c.decodeIfPresent(String.self, forKey: .toolUseId)
            self.isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
            self.source = try c.decodeIfPresent(RawImageSource.self, forKey: .source)

            // `input` is arbitrary JSON — re-serialise and store as Data
            // (with `.sortedKeys` so two equivalent inputs hash identically).
            if c.contains(.input) {
                if let anyJSON = try? c.decode(AnyJSON.self, forKey: .input) {
                    self.inputJSONData = try? JSONSerialization.data(
                        withJSONObject: anyJSON.value, options: [.sortedKeys]
                    )
                } else {
                    self.inputJSONData = nil
                }
            } else {
                self.inputJSONData = nil
            }

            // `content` is either String or [NestedBlock]
            if c.contains(.content) {
                if let s = try? c.decode(String.self, forKey: .content) {
                    self.contentString = s
                    self.contentBlocks = nil
                } else if let blocks = try? c.decode([NestedBlock].self, forKey: .content) {
                    self.contentString = nil
                    self.contentBlocks = blocks
                } else {
                    self.contentString = nil
                    self.contentBlocks = nil
                }
            } else {
                self.contentString = nil
                self.contentBlocks = nil
            }
        }
    }
}

/// Wrapper that decodes arbitrary JSON into a Swift `Any` value.
private struct AnyJSON: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let i = try? container.decode(Int.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else if let arr = try? container.decode([AnyJSON].self) {
            self.value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyJSON].self) {
            self.value = dict.mapValues(\.value)
        } else {
            self.value = NSNull()
        }
    }
}
