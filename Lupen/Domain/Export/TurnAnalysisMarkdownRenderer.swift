//
//  TurnAnalysisMarkdownRenderer.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import Foundation

/// Renders a `TurnAnalysisBundle` as the Markdown document the user hands to an
/// AI.
///
/// ## Why Markdown
///
/// Format choice is a second-order decision — across a large multi-model
/// benchmark, input format moved accuracy only a few points while model
/// capability accounted for a ~21-point gap. So the format was picked on the
/// criterion that actually differs: **the user must be able to read this before
/// pasting it into an external service.** It contains their prompts, file paths,
/// and command output. A human-reviewable artifact is a privacy feature.
///
/// ## Why this section order
///
/// Budget → mechanism → evidence → ask. A reader who stops after the first
/// screen still has the actionable part, and the closing questions keep the
/// model from producing a summary instead of a fix.
///
/// Pure string work — no AppKit, no filesystem, injected date — matching
/// `ReportsCSVExporter`'s contract so the whole document is snapshot-testable.
enum TurnAnalysisMarkdownRenderer {

    struct Options: Sendable, Equatable {
        /// Rewrites the user's home directory to `~` throughout the document.
        /// On by default: absolute paths carry the account name, and the
        /// document is destined for somewhere outside the machine.
        var redactHomeDirectory: Bool
        /// Injected rather than read from the environment so the redaction is
        /// testable and deterministic.
        var homeDirectoryPath: String?
        /// Injected for deterministic output.
        var generatedAt: Date?

        init(
            redactHomeDirectory: Bool = true,
            homeDirectoryPath: String? = NSHomeDirectory(),
            generatedAt: Date? = nil
        ) {
            self.redactHomeDirectory = redactHomeDirectory
            self.homeDirectoryPath = homeDirectoryPath
            self.generatedAt = generatedAt
        }
    }

    // MARK: - Entry point

    static func render(_ bundle: TurnAnalysisBundle, options: Options = Options()) -> String {
        var out: [String] = []

        out.append(contentsOf: titleAndSummary(bundle, options: options))
        out.append(contentsOf: analysisBrief(bundle))
        out.append(contentsOf: verdict(bundle))
        out.append(contentsOf: context(bundle))
        out.append(contentsOf: tokenSection(bundle))
        out.append(contentsOf: timeSection(bundle))
        out.append(contentsOf: promptSection(bundle))
        out.append(contentsOf: skillSection(bundle))
        out.append(contentsOf: subAgentSection(bundle))
        out.append(contentsOf: toolSection(bundle))
        out.append(contentsOf: traceSection(bundle))
        out.append(contentsOf: omissionSection(bundle))
        out.append(contentsOf: questions())

        let document = out.joined(separator: "\n")
        return redacted(document, options: options)
    }

    // MARK: - Header

    private static func titleAndSummary(
        _ bundle: TurnAnalysisBundle,
        options: Options
    ) -> [String] {
        let header = bundle.header
        let title = [header.projectLabel, header.sessionTitle]
            .compactMap { $0 }
            .joined(separator: " / ")
        var lines = ["# Lupen Turn Analysis\(title.isEmpty ? "" : " — \(title)")", ""]
        lines.append("<!-- lupen-turn-export: v\(TurnAnalysisBundle.schemaVersion) -->")
        if let generatedAt = options.generatedAt {
            lines.append("<!-- generated: \(iso(generatedAt)) -->")
        }
        lines.append("")

        lines.append("| metric | value | vs. session median |")
        lines.append("|---|---|---|")
        lines.append(row("Cost", money(bundle.metrics.costUSD.value), ratio(bundle.metrics.costUSD)))
        lines.append(row("Tokens", integer(Int(bundle.metrics.totalTokens.value)), ratio(bundle.metrics.totalTokens)))
        if let duration = bundle.metrics.durationSeconds {
            lines.append(row("Duration", TurnTimeline.formatDuration(duration.value), ratio(duration)))
        }
        lines.append(row("Steps", integer(bundle.header.stepCount), "—"))
        lines.append("")
        // Key the note on the population that actually backs the ratios, not the
        // raw turn count: a session whose other turns are zero-cost stubs shows
        // "—" in every "vs. median" cell, so a "median of N turns" line would
        // claim a baseline the table never displays.
        if bundle.metrics.baselineTurnCount >= 2 {
            lines.append(
                "_Baseline is the median of \(bundle.metrics.baselineTurnCount) "
                + "turns in this session._"
            )
            lines.append("")
        }
        return lines
    }

    private static func analysisBrief(_ bundle: TurnAnalysisBundle) -> [String] {
        var lines = ["## What to analyze", ""]
        lines.append(
            "This is a single turn from an AI coding session, exported because it consumed "
            + "an unusual amount of time or tokens. Identify the largest concrete causes and "
            + "propose specific changes to the **skill**, **subagent**, or **prompt** involved."
        )
        lines.append("")
        lines.append(
            "Durations marked _(derived)_ are attributed from timestamp gaps, not measured — "
            + "rank by them, but do not quote them as facts. Token slices marked _(est.)_ are "
            + "split from character shares; only the totals are billed numbers."
        )
        lines.append("")
        if !bundle.caveats.isEmpty {
            for caveat in bundle.caveats {
                lines.append("> ⚠ \(caveat)")
            }
            lines.append("")
        }
        return lines
    }

    // MARK: - 1. Verdict

    private static func verdict(_ bundle: TurnAnalysisBundle) -> [String] {
        var lines = ["## 1. Where the money went", ""]
        if bundle.costDrivers.isEmpty {
            lines.append("No billed cost was recorded for this turn.")
            lines.append("")
            return lines
        }
        lines.append("| driver | cost | share |")
        lines.append("|---|---|---|")
        for driver in bundle.costDrivers {
            lines.append(row(driver.label, money(driver.costUSD), percent(driver.share)))
        }
        lines.append("")

        // Cache misses are a common hidden cost, so surface them under the
        // ranking — but as a lead to check, not a verdict. The driver table
        // above is the authority on where the money actually went; asserting
        // the miss "dominated" would contradict it on an output-bound turn.
        if !bundle.cacheDiagnostics.isEmpty {
            let reasons = bundle.cacheDiagnostics.reasonCounts
                // Key tiebreak so ties don't order by dict hash (nondeterministic
                // across launches) — two exports of one turn must match.
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "`\($0.key)` ×\($0.value)" }
                .joined(separator: ", ")
            lines.append(
                "> ⚠ **\(bundle.cacheDiagnostics.missCount) prompt-cache miss(es)** — \(reasons)."
            )
            lines.append(
                "> A miss re-bills the affected context at input rate instead of the cheaper "
                + "cache-read rate. Check whether the \"Input (uncached)\" or \"Cache writes\" "
                + "rows above are inflated — if those already sit low in the ranking, the miss "
                + "was not this turn's main cost."
            )
            lines.append("")
        }
        return lines
    }

    // MARK: - 2. Context

    private static func context(_ bundle: TurnAnalysisBundle) -> [String] {
        let header = bundle.header
        var lines = ["## 2. Turn context", ""]
        var facts: [(String, String?)] = [
            ("Provider", header.provider == .codex ? "Codex" : "Claude Code"),
            ("Model(s)", header.models.isEmpty ? nil : header.models.joined(separator: ", ")),
            ("Started", header.startedAt.map(iso)),
            ("Ended", header.endedAt.map(iso)),
            ("Steps", "\(header.stepCount) (\(header.billableStepCount) billable)"),
            ("Status", status(header)),
            ("Stop reasons", header.stopReasons.isEmpty ? nil : header.stopReasons.joined(separator: ", ")),
            ("Reasoning effort", header.reasoningEffort),
            ("Personality", header.personality),
            ("Approval policy", header.approvalPolicy),
            ("Sandbox policy", header.sandboxPolicy),
            ("Git branch", header.gitBranch),
            ("Working directory", header.workingDirectory)
        ]
        if let confidence = header.costConfidence {
            facts.append(("Cost confidence", "\(confidence.rawValue) — the total is approximate"))
        }
        for (label, value) in facts {
            guard let value, !value.isEmpty else { continue }
            // singleLine so a log-sourced value (cwd, git branch) with an
            // embedded newline can't break the bullet and inject a fake line.
            lines.append("- **\(label)**: \(singleLine(value))")
        }
        lines.append("")
        return lines
    }

    private static func status(_ header: TurnAnalysisBundle.Header) -> String {
        var flags: [String] = []
        flags.append(header.isComplete ? "complete" : "incomplete")
        if header.isInterrupted { flags.append("interrupted by user") }
        if header.endedWithApiError { flags.append("ended with an API error") }
        return flags.joined(separator: ", ")
    }

    // MARK: - 3. Tokens

    private static func tokenSection(_ bundle: TurnAnalysisBundle) -> [String] {
        let tokens = bundle.tokens
        let cost = bundle.cost
        var lines = ["## 3. Tokens and cost", ""]
        lines.append("| category | tokens | cost |")
        lines.append("|---|---|---|")
        lines.append(row("Input (uncached)", integer(tokens.inputTokens), money(cost.inputCostUSD)))
        lines.append(row("Cache read", integer(tokens.cacheReadInputTokens), money(cost.cacheReadCostUSD)))
        lines.append(row(
            "Cache write",
            integer(tokens.cacheCreationInputTokens),
            money(cost.cacheCreate1hCostUSD + cost.cacheCreate5mCostUSD)
        ))
        lines.append(row("Output", integer(tokens.outputTokens), money(cost.outputCostUSD)))
        if tokens.reasoningOutputTokens > 0 {
            lines.append(row("Reasoning", integer(tokens.reasoningOutputTokens), "(billed as output)"))
        }
        lines.append(row("**Total**", "**\(integer(tokens.totalContextTokens))**", "**\(money(cost.totalCostUSD))**"))
        lines.append("")

        if let window = tokens.contextWindow, window > 0 {
            // The model's window capacity, stated as a bare fact. Deliberately
            // NOT a "% filled": totalContextTokens is the turn's CUMULATIVE
            // token sum across every step (cache reads re-count each turn), not
            // a point-in-time occupancy, so dividing it by the capacity
            // produced figures well over 100% and read as a context overflow
            // that never happened.
            lines.append("Model context window: \(integer(window)) tokens.")
            lines.append("")
        }
        if let ratio = tokens.cacheEfficiencyRatio {
            lines.append("Cache efficiency: \(percent(ratio)) of input tokens were served from cache.")
            lines.append("")
        }

        if !bundle.composition.isEmpty {
            lines.append("### Cost by category")
            lines.append("")
            lines.append("| category | tokens | cost |")
            lines.append("|---|---|---|")
            // Already ordered by cost; the column sums to the turn total.
            for slice in bundle.composition {
                let label = slice.isEstimate ? "\(slice.label) _(est.)_" : slice.label
                lines.append(row(label, integer(slice.tokens), slice.costUSD.map(money) ?? "—"))
            }
            lines.append("")
        }
        return lines
    }

    // MARK: - 4. Time

    private static func timeSection(_ bundle: TurnAnalysisBundle) -> [String] {
        let timeline = bundle.timeline
        guard timeline.totalSeconds != nil || !timeline.measured.isEmpty else { return [] }
        var lines = ["## 4. Where the time went", ""]
        if let summary = timeline.summary {
            lines.append("\(summary)")
            lines.append("")
        }
        if !timeline.lanes.isEmpty {
            lines.append("| lane | time _(derived)_ |")
            lines.append("|---|---|")
            for lane in timeline.lanes.sorted(by: { $0.seconds > $1.seconds }) {
                lines.append(row(lane.label, TurnTimeline.formatDuration(lane.seconds)))
            }
            lines.append("")
        }
        if !timeline.measured.isEmpty {
            lines.append("### Measured durations")
            lines.append("")
            lines.append("These are recorded by the tooling, not inferred from timestamps.")
            lines.append("")
            lines.append("| what | time | detail |")
            lines.append("|---|---|---|")
            for item in timeline.measured {
                lines.append(row(
                    item.label,
                    TurnTimeline.formatDuration(item.seconds),
                    item.detail ?? "—"
                ))
            }
            lines.append("")
        }
        return lines
    }

    // MARK: - 5. Prompt

    private static func promptSection(_ bundle: TurnAnalysisBundle) -> [String] {
        guard let prompt = bundle.prompt else { return [] }
        return ["## 5. The prompt that started this turn", ""]
            + fencedBlock(prompt)
            + [""]
    }

    // MARK: - 6. Skills

    private static func skillSection(_ bundle: TurnAnalysisBundle) -> [String] {
        guard !bundle.skills.isEmpty else { return [] }
        var lines = ["## 6. Skills involved", ""]
        let inferred = bundle.skills.contains { !$0.isAttributed }
        if inferred {
            lines.append(
                "_Spans are inferred from step ordering — the log carries no explicit skill "
                + "attribution for this turn, so boundaries are approximate._"
            )
            lines.append("")
        }
        lines.append("| skill | steps | tokens | cost | share of turn |")
        lines.append("|---|---|---|---|---|")
        for skill in bundle.skills {
            lines.append(row(
                skill.name,
                integer(skill.stepCount),
                integer(skill.tokens),
                money(skill.costUSD),
                percent(skill.shareOfTurn)
            ))
        }
        lines.append("")
        return lines
    }

    // MARK: - 7. Sub-agents

    private static func subAgentSection(_ bundle: TurnAnalysisBundle) -> [String] {
        guard !bundle.subAgents.isEmpty else { return [] }
        var lines = ["## 7. Subagents spawned", ""]
        lines.append(
            "_Each subagent's cost below is already included in the turn total above — "
            + "do not add these to it._"
        )
        lines.append("")
        for agent in bundle.subAgents {
            let name = [agent.agentType, agent.nickname].compactMap { $0 }.joined(separator: " · ")
            // singleLine the heading: a log-sourced nickname with an embedded
            // newline would otherwise end the H3 and inject a fake heading.
            lines.append("### \(singleLine(name.isEmpty ? agent.identifier : name))")
            lines.append("")
            if let description = agent.description {
                lines.append("> \(singleLine(description))")
                lines.append("")
            }
            var facts: [String] = []
            if let model = agent.model { facts.append("model `\(model)`") }
            if let seconds = agent.durationSeconds {
                facts.append("ran \(TurnTimeline.formatDuration(seconds)) _(measured)_")
            }
            if let tokens = agent.tokens { facts.append("\(integer(tokens)) tokens") }
            if let calls = agent.toolCallCount { facts.append("\(calls) tool calls") }
            if let cost = agent.costUSD { facts.append("cost \(money(cost))") }
            if !facts.isEmpty {
                lines.append("- " + facts.joined(separator: " · "))
            }
            if !agent.toolStats.isEmpty {
                let stats = agent.toolStats
                    .filter { $0.value > 0 }
                    // Key tiebreak for determinism across launches (dict source).
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .map { "\($0.key) \($0.value)" }
                    .joined(separator: ", ")
                if !stats.isEmpty { lines.append("- tool breakdown: \(stats)") }
            }
            lines.append("")
        }
        return lines
    }

    // MARK: - 8. Tools

    private static func toolSection(_ bundle: TurnAnalysisBundle) -> [String] {
        guard !bundle.toolCalls.isEmpty else { return [] }
        var lines = ["## 8. Tool calls", ""]

        // The time column is derived by default (Claude has no per-call
        // duration); cells that were actually tool-measured say so, so a real
        // measurement is not discounted under the blanket label.
        lines.append("| tool | calls | errors | result chars | time _(derived unless noted)_ |")
        lines.append("|---|---|---|---|---|")
        for total in bundle.toolTotals {
            lines.append(row(
                total.name,
                integer(total.callCount),
                total.errorCount > 0 ? integer(total.errorCount) : "—",
                integer(total.totalResultCharacters),
                toolTime(total.derivedSeconds, measured: total.allMeasured, idle: total.includesLikelyIdle)
            ))
        }
        lines.append("")

        lines.append("### Call-by-call")
        lines.append("")
        lines.append("| # | tool | input | result chars | time _(derived unless noted)_ | error |")
        lines.append("|---|---|---|---|---|---|")
        // The turns this export targets can hold hundreds of tool calls; an
        // uncapped ledger alone would blow the whole-document budget. Cap the
        // per-call rows (the per-tool totals above still cover every call) and
        // say how many were dropped.
        for call in bundle.toolCalls.prefix(maxCallByCallRows) {
            let name = call.mcpServer.map { "\(call.name) (\($0))" } ?? call.name
            lines.append(row(
                integer(call.ordinal),
                name,
                singleLine(call.inputSummary),
                call.resultCharacters.map(integer) ?? "—",
                toolTime(call.derivedSeconds, measured: call.isMeasured, idle: call.includesLikelyIdle),
                call.isError ? "yes" : ""
            ))
        }
        lines.append("")
        if bundle.toolCalls.count > maxCallByCallRows {
            let dropped = bundle.toolCalls.count - maxCallByCallRows
            lines.append("_\(integer(dropped)) more call(s) omitted — see the per-tool totals above._")
            lines.append("")
        }
        return lines
    }

    /// Row cap for the call-by-call ledger. The per-tool totals table stays
    /// complete; only the exhaustive list is bounded.
    private static let maxCallByCallRows = 200

    /// A tool time cell. A measured value is marked so it is not discounted
    /// under the column's default "derived" label; an idle-inflated derived gap
    /// is flagged so the reader does not chase a tool that ran in milliseconds.
    private static func toolTime(_ seconds: TimeInterval?, measured: Bool, idle: Bool) -> String {
        guard let seconds else { return "—" }
        let formatted = TurnTimeline.formatDuration(seconds)
        if measured { return "\(formatted) _(measured)_" }
        return idle ? "\(formatted) ⚠ idle?" : formatted
    }

    // MARK: - 9. Trace

    private static func traceSection(_ bundle: TurnAnalysisBundle) -> [String] {
        guard !bundle.trace.isEmpty else { return [] }
        var lines = ["## 9. Step trace", ""]
        for entry in bundle.trace {
            var headerParts = ["**\(entry.ordinal). \(entry.kind.shortLabel)**"]
            if let model = entry.model, model != "<synthetic>" { headerParts.append("`\(model)`") }
            if let seconds = entry.derivedSeconds {
                // Long gaps are flagged rather than dropped: the elapsed time is
                // real and worth seeing, but calling it compute would send the
                // analyst chasing a stretch where nothing was running.
                headerParts.append(
                    entry.includesLikelyIdle
                        ? "\(TurnTimeline.formatDuration(seconds)) _(derived, likely mostly idle)_"
                        : "\(TurnTimeline.formatDuration(seconds)) _(derived)_"
                )
            }
            if let tokens = entry.tokens, tokens > 0 { headerParts.append("\(integer(tokens)) tok") }
            if let cost = entry.costUSD, cost > 0 { headerParts.append(money(cost)) }
            lines.append(headerParts.joined(separator: " · "))
            if let body = entry.body, !body.isEmpty {
                lines.append("")
                lines.append(contentsOf: fencedBlock(body))
            }
            lines.append("")
        }
        return lines
    }

    /// Wraps verbatim content (prompt, trace body) in a fenced code block whose
    /// fence is longer than any run of backticks inside it. Content that itself
    /// contains ``` or ```` — a tool that read a Markdown file, or a prompt
    /// about Markdown — would otherwise close the block on its first bare
    /// backtick line and inject live, attacker-shaped structure (fake sections,
    /// fake cost tables) into the document.
    static func fencedBlock(_ body: String, lang: String = "text") -> [String] {
        var longestRun = 0
        var current = 0
        for character in body {
            if character == "`" {
                current += 1
                longestRun = max(longestRun, current)
            } else {
                current = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return ["\(fence)\(lang)", body, fence]
    }

    // MARK: - Omissions

    private static func omissionSection(_ bundle: TurnAnalysisBundle) -> [String] {
        guard !bundle.omissions.isEmpty else { return [] }
        var lines = ["## Omitted from this export", ""]
        lines.append(
            "The following were cut to keep the document a usable size. Ask for them "
            + "specifically if the analysis needs them."
        )
        lines.append("")
        for omission in bundle.omissions {
            lines.append("- \(omission)")
        }
        lines.append("")
        return lines
    }

    // MARK: - Questions

    private static func questions() -> [String] {
        [
            "## 10. Questions to answer",
            "",
            "1. Which single change would cut the most cost or time here without losing the result?",
            "2. Did any subagent cost more than the value of what it returned?",
            "3. Did the opening prompt under-specify something that caused rework or backtracking?",
            "4. Were any tool calls redundant — re-reading content already in context, or",
            "   searching for something already found?",
            "5. If there were cache misses, what caused them and is the trigger avoidable?",
            "6. Concretely: what should change in the skill definition, the subagent prompt,",
            "   or the way the request was phrased?",
            ""
        ]
    }

    // MARK: - Redaction

    /// Rewrites the home directory to `~`. A whole-document pass rather than
    /// per-field, because paths turn up inside prompts, tool inputs, tool output
    /// and error text — anywhere a field-by-field approach would miss.
    private static func redacted(_ document: String, options: Options) -> String {
        guard options.redactHomeDirectory,
              let home = options.homeDirectoryPath,
              !home.isEmpty, home != "/" else { return document }
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        // Redact the home path at a path boundary. Two lookaheads:
        //   (?![A-Za-z0-9_-])   — not a name char, so "/Users/alice2" and
        //                         "/Users/alice-work" (siblings) are left intact;
        //   (?!\.[A-Za-z0-9])   — a following "." is a sibling suffix only when
        //                         it leads into more name chars (".bak"), so a
        //                         dotted sibling stays, but a sentence-ending
        //                         "/Users/alice." still redacts (privacy wins
        //                         the ambiguous case).
        // Both "/Users/alice" and "/Users/alice/x" redact; the bare cwd no
        // longer leaks the username.
        let pattern = NSRegularExpression.escapedPattern(for: trimmed)
            + "(?![A-Za-z0-9_-])(?!\\.[A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return document.replacingOccurrences(of: trimmed + "/", with: "~/")
        }
        let range = NSRange(document.startIndex..., in: document)
        return regex.stringByReplacingMatches(in: document, range: range, withTemplate: "~")
    }

    // MARK: - Formatting

    private static func row(_ cells: String...) -> String {
        "| " + cells.map(cell).joined(separator: " | ") + " |"
    }

    /// Markdown tables break on a literal `|` and on newlines, so both are
    /// neutralized. Done at render time rather than in the bundle so the data
    /// stays clean for any other consumer.
    private static func cell(_ value: String) -> String {
        singleLine(value).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Sub-cent costs are common per-step, so small values keep more precision
    /// instead of collapsing to `$0.00` and reading as free.
    static func money(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if abs(value) < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    /// Thousands-grouped, e.g. `412,905`. Reuses the CLI's allocation-free
    /// grouping helper rather than spinning up a NumberFormatter per cell (this
    /// is called once per numeric cell across the whole document).
    static func integer(_ value: Int) -> String {
        CLIFormat.int(value)
    }

    /// Small-but-nonzero shares render as "<1%" rather than "0%": a driver row
    /// with a real dollar amount reading "0%" is internally contradictory.
    static func percent(_ share: Double) -> String {
        if share > 0, share < 0.005 { return "<1%" }
        return String(format: "%.0f%%", share * 100)
    }

    private static func ratio(_ metric: TurnAnalysisBundle.Metric) -> String {
        guard let ratio = metric.ratioToSessionMedian else { return "—" }
        // A small positive ratio reads as "0.0×" (negligible) under %.1f; show
        // "<0.1×" so it isn't mistaken for "zero times the median".
        if ratio > 0, ratio < 0.05 { return "<0.1×" }
        return String(format: "%.1f×", ratio)
    }

    /// Cached: the format, locale and time zone are constant, and DateFormatter
    /// is the most expensive Foundation formatter to build — no reason to
    /// reconstruct it for each of the (few) timestamps in a document.
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}
