import Foundation

/// Second-pass attachment extractor. Takes raw `Step`s produced by
/// `StepBuilder` / `ConversationAssembler` and returns the same Steps
/// with their `attachments` array populated.
///
/// Separated from `StepBuilder` because `toolOutput` attachments need
/// session-wide tool-use name lookup (a `tool_result` step knows only
/// its parent `toolUseId`, not the parent tool's *name*), which a
/// per-entry builder can't do without extra plumbing.
///
/// ## Extraction sources
///
/// Per Step, in this order:
///   1. Inline image blocks in the prompt — `.inlinePromptImage`.
///   2. Legacy `[Image source: /path]` meta paths merged into the
///      prompt by the assembler — `.promptImageMeta`.
///   3. Abs paths heuristically detected inside prompt text —
///      `.promptTextMention`. Skipped when `isSystemInjected` so
///      Skill meta entries ("Base directory for this skill: …") don't
///      leak into the UI as if the user had attached them.
///   4. Tool-call input — Write/Read/Edit `file_path`, WebFetch
///      `url`, Glob `path`, etc. Known-tool dispatch + heuristic
///      fallback for unknown tools.
///   5. Tool-result output — "File created successfully at: …" and
///      "Applied N edits to …" patterns, plus a leading heuristic
///      scan. The parent tool's name is looked up via the provided
///      `toolNameByUseId` index.
///   6. Assistant reply / thought text mentions — abs paths via
///      `FilePathDetector` + markdown links. Skipped for
///      `isSystemInjected` steps.
enum AttachmentResolver {

    /// Returns new Steps with `attachments` populated. The input order
    /// is preserved; no other fields are touched. The
    /// `toolNameByUseId` index must cover every `toolUseId` that may
    /// appear in input Steps' `toolResult`s — the caller (Assembler)
    /// builds this by sweeping every Step's `toolCalls`.
    ///
    /// `diagnostics` accumulates warnings for unknown-tool cases so
    /// `ParseDiagnostics` can surface regressions when a new tool
    /// appears whose input shape isn't in the dispatch table.
    static func resolveAll(
        steps: [Step],
        toolNameByUseId: [String: String],
        diagnostics: inout [String]
    ) -> [Step] {
        steps.map { step in
            let attachments = resolve(
                step: step,
                toolNameByUseId: toolNameByUseId,
                diagnostics: &diagnostics
            )
            return Self.withAttachments(step, attachments)
        }
    }

    /// Computes the `attachments` array for a single Step. Pure: no
    /// mutation of `step`, caller re-homes it via `withAttachments`.
    static func resolve(
        step: Step,
        toolNameByUseId: [String: String],
        diagnostics: inout [String]
    ) -> [AttachmentRef] {
        var result: [AttachmentRef] = []

        // --- 1. Inline prompt images ---
        for (idx, image) in step.images.enumerated() {
            let media = image.mediaType ?? "image"
            let locator = "#inline:\(idx):\(media)"
            result.append(AttachmentRef(
                kind: .inlineImage,
                origin: .inlinePromptImage,
                locator: locator,
                toolName: nil,
                mediaType: image.mediaType
            ))
        }

        // --- 2. [Image source: …] meta paths ---
        for path in step.imageSourcePaths {
            result.append(AttachmentRef(
                kind: .image,
                origin: .promptImageMeta,
                locator: path
            ))
        }

        // --- 3. Prompt text mentions (skip system-injected) ---
        if !step.isSystemInjected {
            for path in step.mentionedFilePaths {
                // Prompt-level mentions only go here when the Step is
                // actually a prompt. Tool-call / reply / thought Steps
                // also carry `mentionedFilePaths` (built from `text`),
                // but we route those paths through `replyMention`
                // below so they're grouped correctly in the UI.
                if step.kind == .prompt {
                    result.append(AttachmentRef(
                        kind: .file,
                        origin: .promptTextMention,
                        locator: path
                    ))
                }
            }
        }

        // --- 4. Tool-call inputs ---
        if !step.toolCalls.isEmpty {
            for call in step.toolCalls {
                let refs = extractToolInput(call: call, diagnostics: &diagnostics)
                result.append(contentsOf: refs)
            }
        }

        // --- 5. Tool-result outputs ---
        if let tr = step.toolResult, !tr.isError {
            let toolName = toolNameByUseId[tr.toolUseId]
            result.append(contentsOf: extractToolOutput(content: tr.content, toolName: toolName))
        }

        // --- 6. Reply / thought text mentions ---
        //
        // `.prompt` handled above. `.toolResult` never carries a
        // human-authored text field so we skip it. Every other Step
        // type can carry assistant prose that may reference files.
        if !step.isSystemInjected {
            switch step.kind {
            case .reply, .thought, .toolCall:
                if let text = step.text {
                    let refs = extractReplyMentions(text: text)
                    result.append(contentsOf: refs)
                }
            case .prompt, .toolResult, .stop, .interruption:
                break
            }
        }

        return result
    }

    // MARK: - Tool input extraction

    /// Tools whose input is known not to carry attachments. Listing them
    /// here keeps the unknown-tool warning channel reserved for genuinely
    /// novel shapes — search queries, todo lists, agent prompts, task
    /// management, status checks, plan-mode entries are not attachments.
    ///
    /// **Maintenance**: when Claude Code introduces a new first-party
    /// tool, add it here (or to the structured dispatch in
    /// `extractToolInput`) before it surfaces in user diagnostics. The
    /// `knownFirstPartyToolNames` registry below is what tests check
    /// exhaustively so a missing addition is loud.
    private static let knownNoPathTools: Set<String> = [
        "WebSearch", "Agent", "Workflow", "Task", "TodoWrite", "ToolSearch",
        "AgentWait", "AgentClose",
        "ExitPlanMode", "EnterPlanMode", "ScheduleWakeup",
        // Task management family — TaskCreate carries subject/description,
        // TaskUpdate / TaskOutput / TaskList carry task_id + status fields.
        // None embed paths.
        "TaskCreate", "TaskUpdate", "TaskOutput", "TaskList",
        // Skill invocation — `{"skill": "name", "args": "string"}`.
        "Skill",
        // Interactive question prompt — `{"questions": [{header, options}…]}`.
        "AskUserQuestion",
        // Claude Code worktree cleanup control.
        "ExitWorktree",
        // Codex writes to a running `exec_command` session's stdin. Deliberately
        // *not* normalised to `Bash`: it executes nothing, and relabelling it
        // would report a keystroke as a shell command. Registered here so the
        // resolver stops treating it as a tool of unknown shape — measured on
        // 14,422 real calls, its arguments are `chars` / `session_id` /
        // `yield_time_ms` / `max_output_tokens`, `chars` is empty on all but 153
        // of them, and not one carries a path.
        "write_stdin",
    ]

    /// Tools whose shape is known but open-ended. We should suppress the
    /// "unknown attachment shape" diagnostic when no path exists, while still
    /// running the heuristic extractor so path-bearing payloads are not lost.
    private static let knownHeuristicSilentTools: Set<String> = [
        "StructuredOutput",
    ]

    /// Tools we know how to extract structured paths / URLs from. The
    /// dispatch table in `extractToolInput` enumerates them; this set
    /// mirrors that for `knownFirstPartyToolNames` registry.
    /// Internal rather than private so `TurnFileAccess` can be pinned against
    /// it: a tool added here but not classified there has its paths silently
    /// dropped from the file-access card and the turn export.
    static let knownPathExtractingTools: Set<String> = [
        "Read", "Write", "Edit", "MultiEdit",
        "NotebookEdit", "NotebookRead",
        "Glob", "Grep",
        "WebFetch",
        "Bash", "bash",
        "Monitor",
    ]

    /// Single registry of every first-party Claude Code tool the resolver
    /// recognises — union of the path-extracting and no-path sets.
    /// Tests assert this stays in sync with the `extractToolInput`
    /// dispatch so a refactor that drops a case fails fast instead of
    /// silently regressing into the warning path.
    static var knownFirstPartyToolNames: Set<String> {
        knownPathExtractingTools
            .union(knownNoPathTools)
            .union(knownHeuristicSilentTools)
    }

    /// Known-tool dispatch. Returns `[]` for tools we intentionally
    /// skip (WebSearch / TaskList / …) and falls back to a heuristic
    /// scan for everything we don't recognise.
    ///
    /// **Diagnostic policy**: the unknown-tool warning fires only on
    /// the `default:` branch — i.e., a tool name not in either
    /// `knownPathExtractingTools`, `knownNoPathTools`, or
    /// `knownHeuristicSilentTools`. Known tools whose structured field
    /// decode fails (truncated `inputJSON` from
    /// snapshot v4's 1 KB cap is the common case) silently fall to the
    /// heuristic without warning, because failure here means "input
    /// was mangled," not "a brand-new tool shape arrived." That
    /// distinction was the cause of the `Edit` warning surfaced once
    /// per session whenever a long replace_all hit the truncation
    /// boundary past the file_path key.
    private static func extractToolInput(
        call: ToolUseInfo,
        diagnostics: inout [String]
    ) -> [AttachmentRef] {
        let name = call.name
        let input = call.inputJSON

        switch name {
        case "Read", "Write", "Edit", "MultiEdit":
            if let path = decodeStringField(input, "file_path") {
                return [ref(origin: .toolInput, kind: .file, locator: path, toolName: name)]
            }
            return heuristicFallbackSilent(input: input, toolName: name)

        case "NotebookEdit", "NotebookRead":
            if let path = decodeStringField(input, "notebook_path") {
                return [ref(origin: .toolInput, kind: .file, locator: path, toolName: name)]
            }
            return heuristicFallbackSilent(input: input, toolName: name)

        case "Glob", "Grep":
            if let path = decodeStringField(input, "path") {
                return [ref(origin: .toolInput, kind: .directory, locator: path, toolName: name)]
            }
            return []

        case "WebFetch":
            if let urlString = decodeStringField(input, "url") {
                let kind: AttachmentRef.Kind = urlString.hasPrefix("file://") ? .file : .url
                return [ref(origin: .toolInput, kind: kind, locator: urlString, toolName: name)]
            }
            return heuristicFallbackSilent(input: input, toolName: name)

        case "Bash", "bash":
            // Claude Code emits both casings depending on internal routing
            // (the tool definition is `Bash` but some CLI versions log
            // the lowercase variant). Treat them identically.
            if let cmd = decodeStringField(input, "command") ?? decodeStringField(input, "cmd") {
                let paths = FilePathDetector.extract(from: cmd)
                return paths.map {
                    ref(origin: .toolInput, kind: .file, locator: $0, toolName: name)
                }
            }
            // Codex's `exec` reaches here. It is the same shell, but it arrives
            // as a `custom_tool_call` whose input is JavaScript source rather
            // than JSON — `const r = await tools.exec_command({cmd:"…"})` — so
            // neither field decodes and returning `[]` left every one of those
            // calls with no paths at all. Same fallback as `Monitor` below,
            // which was written for exactly this shape of miss.
            return heuristicFallbackSilent(input: input, toolName: name)

        case "Monitor":
            if let cmd = decodeStringField(input, "command") ?? decodeStringField(input, "cmd") {
                let paths = FilePathDetector.extract(from: cmd)
                if !paths.isEmpty {
                    return paths.map {
                        ref(origin: .toolInput, kind: .file, locator: $0, toolName: name)
                    }
                }
            }
            return heuristicFallbackSilent(input: input, toolName: name)

        default:
            if knownNoPathTools.contains(name) {
                // Listed in the no-path registry — silently empty.
                return []
            }
            if knownHeuristicSilentTools.contains(name) {
                return heuristicFallbackSilent(input: input, toolName: name)
            }
            // Genuinely unknown — could be a new first-party tool, an
            // mcp__* server tool, or an exotic 3rd-party. Heuristic
            // tries to recover paths/URLs from the JSON; if empty and
            // the name isn't an `mcp__*` tool, we emit the diagnostic.
            return heuristicFallback(input: input, toolName: name, diagnostics: &diagnostics)
        }
    }

    /// Like `heuristicFallback` but never appends a diagnostic. Used by
    /// the structured-dispatch branches whose tool we recognise — a
    /// missed extraction here means truncated / malformed input, not a
    /// new shape.
    private static func heuristicFallbackSilent(
        input: String,
        toolName: String
    ) -> [AttachmentRef] {
        var sink: [String] = []
        let result = heuristicFallback(input: input, toolName: toolName, diagnostics: &sink)
        // sink is intentionally discarded — the silent contract.
        _ = sink
        return result
    }

    /// Heuristic fallback — structured parse failed or tool is unknown.
    /// Scans the raw JSON string for abs paths and URLs. If both
    /// heuristics return nothing, records a diagnostic so new tools
    /// with a novel input shape surface as a regression signal.
    ///
    /// `FilePathDetector` alone isn't enough here because it splits on
    /// whitespace / brackets — a JSON token like `{"target":"/tmp/x.png"}`
    /// stays glued together and never clears its leading-`/` gate. We
    /// add a JSON-string-literal scan (`"/abs/path"` regex) to recover
    /// paths that live inside a quoted value.
    ///
    /// **Empty-result diagnostic scope**: the warning is meant for
    /// first-party Anthropic tools whose input shape might quietly
    /// gain a new path-bearing field (a real regression signal). MCP
    /// tools (`mcp__*`) are explicitly third-party — every user has
    /// their own set, most of which are domain-specific (memory APIs,
    /// status checks, "think_about_*"-style reflection tools) that
    /// legitimately carry no attachments. Warning for each one floods
    /// Diagnostics with dozens of entries on first launch and trains
    /// the user to ignore the panel. So: heuristic still runs to catch
    /// any abs paths / URLs the MCP tool happens to pass, but the
    /// empty-result warning is suppressed for the `mcp__` namespace.
    /// First-party unknown tools (no `mcp__` prefix) keep emitting
    /// the warning so a new Anthropic shape still surfaces.
    private static func heuristicFallback(
        input: String,
        toolName: String,
        diagnostics: inout [String]
    ) -> [AttachmentRef] {
        var result: [AttachmentRef] = []
        var seen = Set<String>()

        func append(kind: AttachmentRef.Kind, locator: String) {
            guard seen.insert(locator).inserted else { return }
            result.append(ref(
                origin: .toolInput, kind: kind, locator: locator, toolName: toolName
            ))
        }

        // Every scan below runs on the raw serialized input, where a newline
        // inside a quoted value is two ordinary characters. `FilePathDetector`
        // handles that itself now — which is what covers the *structured*
        // branches above too — but the quoted-path and URL scans are regexes
        // over this string, so they need it applied here.
        let scannable = FilePathDetector.normalizingEscapedWhitespace(input)

        for path in FilePathDetector.extract(from: scannable) {
            append(kind: .file, locator: path)
        }
        for path in scanQuotedAbsPaths(scannable) {
            append(kind: .file, locator: path)
        }
        for url in extractURLs(from: scannable) {
            let kind: AttachmentRef.Kind = url.hasPrefix("file://") ? .file : .url
            append(kind: kind, locator: url)
        }

        if result.isEmpty && !toolName.hasPrefix("mcp__") {
            diagnostics.append(toolName)
        }
        return result
    }

    // MARK: - Compiled regex caches
    //
    // NSRegularExpression compilation is surprisingly expensive — the
    // pattern is JIT-assembled on every `init`, and doing that on
    // every Step during a full Turn rebuild (happens on every UI
    // render) produced visible main-thread stalls in the
    // Conversation outline. Cache every pattern in a file-level
    // `static let` so the cost is paid once per process.

    private static let quotedAbsPathRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #""(/[^"]*?\.[A-Za-z0-9]{1,8})""#, options: [])
    }()

    /// A backslash ends the match as surely as whitespace does.
    ///
    /// The heuristic scan runs on raw tool input, where a newline inside a
    /// quoted value is the two characters `\` and `n` rather than an actual
    /// newline — so without this the URL in a real Codex shell command
    /// (`source_url: https://…/268\n+related_docs:`) matched straight through
    /// the escape and was registered twice: once clean, once with
    /// `\n+related_docs:\n+` glued to the end. A URL cannot contain a literal
    /// backslash — it has to be percent-encoded — so excluding it costs nothing.
    private static let urlRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?:https?|file)://[^\s\)\]\"\\]+"#, options: [])
    }()

    private static let markdownAbsPathLinkRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\[[^\]]+\]\(((?:/[^\)\s]+)|(?:https?://[^\)\s]+))\)"#,
            options: []
        )
    }()

    private static let outputSuccessRegexes: [NSRegularExpression] = outputSuccessPatterns
        .compactMap { try? NSRegularExpression(pattern: $0, options: []) }

    /// Finds abs paths sitting inside JSON string literals — i.e.
    /// `"…": "/abs/path.ext"` — which `FilePathDetector` misses because
    /// its tokenizer doesn't split on `"`.
    private static func scanQuotedAbsPaths(_ json: String) -> [String] {
        guard let re = quotedAbsPathRegex else { return [] }
        let ns = json as NSString
        let matches = re.matches(
            in: json, options: [], range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for m in matches where m.numberOfRanges >= 2 {
            let r = m.range(at: 1)
            guard r.location != NSNotFound else { continue }
            let path = ns.substring(with: r)
            if seen.insert(path).inserted {
                out.append(path)
            }
        }
        return out
    }

    // MARK: - Tool output extraction

    /// Recognise common success messages that include a file path and
    /// fall back to a leading heuristic scan for anything else.
    private static func extractToolOutput(
        content: String,
        toolName: String?
    ) -> [AttachmentRef] {
        var result: [AttachmentRef] = []
        var seenPaths = Set<String>()

        func push(_ path: String) {
            guard seenPaths.insert(path).inserted else { return }
            result.append(ref(
                origin: .toolOutput, kind: .file, locator: path, toolName: toolName
            ))
        }

        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for re in outputSuccessRegexes {
            let matches = re.matches(in: content, options: [], range: fullRange)
            for m in matches where m.numberOfRanges >= 2 {
                let r = m.range(at: 1)
                if r.location != NSNotFound {
                    let raw = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                    let path = strippingTrailingNote(raw)
                    if path.hasPrefix("/") {
                        push(path)
                    }
                }
            }
        }

        // Leading heuristic scan — bounded so a 2 KB Bash dump doesn't
        // sweep up every path in an `ls` listing as "output".
        let head = String(content.prefix(500))
        for path in FilePathDetector.extract(from: head) {
            push(path)
        }

        return result
    }

    private static let outputSuccessPatterns: [String] = [
        #"File created successfully at:\s+(.+?)\s*$"#,
        #"Applied \d+ edits? to\s+(.+?)\s*$"#,
        #"File modified:\s+(.+?)\s*$"#,
    ]

    /// Drops a trailing parenthetical note from a scraped path.
    ///
    /// Shortest closed parenthetical treated as prose rather than as part of
    /// the path.
    static let minTrailingNoteLength = 20

    /// The patterns above capture to end of line, and Claude Code appends a
    /// reminder to its own success messages:
    ///
    ///     File created successfully at: /a/b.swift (file state is current in
    ///     your context — no need to Read it back)
    ///
    /// Left in, that sentence becomes part of the locator, so the same file
    /// surfaces twice — once correctly via the heuristic scan below, once as a
    /// path ending in an English sentence.
    ///
    /// Two cases, decided by whether the parenthesis closes.
    ///
    /// **Unclosed** — the text was cut off, so the parenthetical is unusable
    /// either way. Nothing is required of the fragment's length, but it must
    /// look like prose — a space, and no path separator — because a tail that
    /// could equally be a decoration whose `)` was lost is kept: the shortened
    /// path may exist, and pointing a Reveal at the wrong real directory is
    /// worse than pointing it at nothing.
    ///
    /// **Closed** — the shape decides: three or more words and at least
    /// `minTrailingNoteLength` characters. `(2)`, `(copy)` and `(Draft Copy)`
    /// are ordinary path decorations and stay.
    ///
    /// A path that merely contains " (" mid-way, or ends in something other
    /// than `)`, is untouched either way.
    static func strippingTrailingNote(_ path: String) -> String {
        guard let open = path.range(of: " (", options: .backwards) else { return path }
        let tail = path[open.upperBound...]
        let isClosed = tail.hasSuffix(")") && !tail.dropLast().contains(")")
        let isTruncated = !tail.contains(")")

        // An unmatched "(" means the text was cut off, so the parenthetical is
        // unusable whichever it was — a note the message ended inside, or a
        // decoration whose ")" was lost with the rest of the line. Keeping it
        // yields a path that is certainly wrong; dropping it yields a valid
        // prefix, and the path itself came before the note. So the missing ")"
        // is the whole test, with no bar on length or word count.
        //
        // Length cannot decide this case anyway: "file state is" — the note cut
        // after three words — and "Draft Copy 2)" are both 13 characters and
        // three words. Only the closing parenthesis separates them, and a real
        // path has one.
        //
        // Two exceptions, both resting on the same asymmetry: keeping a note
        // fragment yields a path that does not exist, so Reveal fails
        // harmlessly, while stripping a decoration yields a *shorter* path that
        // may well exist, so Reveal opens the wrong thing and Copy Path copies
        // it. Nothing here checks the filesystem. So when the tail could be
        // either, keep it.
        //
        //  - A "/" means the text kept going as a path, so nothing was cut off
        //    there and the parenthesis belongs to a directory name:
        //    `/a/b (draft notes/c.swift` must survive whole.
        //  - Prose has a space. Without one the tail is indistinguishable from
        //    a decoration whose ")" was lost with the rest of the line, and
        //    `/Users/me/Docs (2` stripped to `/Users/me/Docs` is exactly the
        //    wrong-target case. The cost is a note truncated inside its first
        //    word surviving as a duplicate row — noisy, but on a path that
        //    cannot exist.
        if isTruncated {
            guard tail.contains(" "), !tail.contains("/") else { return path }
            return String(path[..<open.lowerBound])
        }
        guard isClosed else { return path }

        // Closed, so the whole parenthetical is there and its shape decides. A
        // note reads as prose: a sentence fragment, several words long. A single
        // space was too weak — it also matched a real directory named
        // `Old Version (Draft Copy)`, and stripping that loses part of an
        // existing path. The one known note clears these bounds many times over.
        let words = tail.split(separator: " ").count
        guard words >= 3, tail.count >= Self.minTrailingNoteLength else { return path }
        return String(path[..<open.lowerBound])
    }

    // MARK: - Reply / thought mentions

    private static func extractReplyMentions(text: String) -> [AttachmentRef] {
        var result: [AttachmentRef] = []
        var seen = Set<String>()

        func push(_ path: String, kind: AttachmentRef.Kind) {
            guard seen.insert(path).inserted else { return }
            result.append(ref(origin: .replyMention, kind: kind, locator: path, toolName: nil))
        }

        // Markdown links `[label](/abs/path)` — abs paths only per
        // plan; home-relative paths (Desktop/…, ~/…) deferred.
        if let re = markdownAbsPathLinkRegex {
            let ns = text as NSString
            let matches = re.matches(
                in: text, options: [], range: NSRange(location: 0, length: ns.length)
            )
            for m in matches where m.numberOfRanges >= 2 {
                let r = m.range(at: 1)
                guard r.location != NSNotFound else { continue }
                let raw = ns.substring(with: r)
                if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                    push(raw, kind: .url)
                } else {
                    push(raw, kind: .file)
                }
            }
        }

        // Plain abs paths.
        for path in FilePathDetector.extract(from: text) {
            push(path, kind: .file)
        }

        // Plain URLs.
        for url in extractURLs(from: text) {
            push(url, kind: .url)
        }

        return result
    }

    // MARK: - Helpers

    /// Parses `inputJSON` (may be truncated) and returns the string
    /// value at `key`. Returns nil on parse failure or type mismatch.
    private static func decodeStringField(_ json: String, _ key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj[key] as? String
    }

    /// Minimal URL scanner — matches `http://` / `https://` / `file://`
    /// runs terminated by whitespace or `)]`. Tuned to the prose we
    /// encounter in tool inputs and replies; full RFC 3986 parsing
    /// would over-collect query strings cut mid-URL.
    private static func extractURLs(from text: String) -> [String] {
        guard let re = urlRegex else { return [] }
        let ns = text as NSString
        let matches = re.matches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return [] }
        var seen = Set<String>()
        var results: [String] = []
        for m in matches {
            let raw = ns.substring(with: m.range)
            let trimmed = raw.trimmingTrailingURLPunctuation()
            if seen.insert(trimmed).inserted {
                results.append(trimmed)
            }
        }
        return results
    }

    private static func ref(
        origin: AttachmentRef.Origin,
        kind: AttachmentRef.Kind,
        locator: String,
        toolName: String?
    ) -> AttachmentRef {
        AttachmentRef(kind: kind, origin: origin, locator: locator, toolName: toolName)
    }

    /// Builds a new `Step` value identical to `step` except for the
    /// `attachments` field. Mirrors the pattern used by
    /// `ConversationAssembler.mergingImageSourcePaths` — Step is an
    /// immutable value type so any mutation requires full
    /// re-initialization.
    ///
    /// Exposed at module level so the assembler can re-run
    /// resolution at ingest time (writers place the resolved value
    /// into `stepsByKey` directly, avoiding the per-render cost).
    static func withAttachments(_ step: Step, _ attachments: [AttachmentRef]) -> Step {
        Step(
            uuid: step.uuid,
            parentUuid: step.parentUuid,
            sessionId: step.sessionId,
            timestamp: step.timestamp,
            kind: step.kind,
            isSystemInjected: step.isSystemInjected,
            isSidechain: step.isSidechain,
            agentId: step.agentId,
            isCompactSummary: step.isCompactSummary,
            text: step.text,
            thinkingText: step.thinkingText,
            images: step.images,
            imageSourcePaths: step.imageSourcePaths,
            mentionedFilePaths: step.mentionedFilePaths,
            attachments: attachments,
            toolCalls: step.toolCalls,
            toolResult: step.toolResult,
            requestId: step.requestId,
            requestIds: step.requestIds,
            messageId: step.messageId,
            model: step.model,
            speed: step.speed,
            stopReason: step.stopReason,
            stopReasonKind: step.stopReasonKind,
            tokens: step.tokens,
            cost: step.cost,
            rawJSON: step.rawJSON,
            rawJSONLocator: step.rawJSONLocator
        )
    }
}

private extension String {
    /// Drops trailing punctuation that is commonly appended to a URL
    /// in running text (`.`, `,`, `)`, `]`, quotes).
    func trimmingTrailingURLPunctuation() -> String {
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'"]
        var end = self.endIndex
        while end > self.startIndex {
            let prev = self.index(before: end)
            if trailing.contains(self[prev]) {
                end = prev
            } else {
                break
            }
        }
        return String(self[..<end])
    }
}
