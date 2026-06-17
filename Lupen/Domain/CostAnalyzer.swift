import Foundation

/// Pure, stateless aggregation helpers that turn the in-memory session /
/// Turn graph into three rollups the Reports window renders:
///
/// 1. `byProject` — sum cost across every session grouped by raw
///    `projectPath`. Answers "which project is burning the most".
/// 2. `bySkill` — sum cost across every Turn whose prompt Step looks
///    like a provider skill-command invocation (`/name …` for Claude
///    Code, `$name …` for Codex). Answers "which skill commands drive
///    the bill".
/// 3. `byModel` — sum cost across every request grouped by model name
///    (synthetic / unknown excluded). Answers "Opus vs Sonnet vs
///    Haiku split".
///
/// The analyzer intentionally does **no** filtering itself — the caller
/// (UI or test) passes in whatever session / Turn subset the current
/// date range / project filter resolves to. Keeping filter logic out
/// of here lets the same rollups serve multiple UI surfaces without
/// duplicating date / project predicates.
///
/// Synthetic-model exclusion mirrors `AppStateStore.todayAggregateCost`
/// — we only count requests whose `model` is a real Claude model (per
/// `PricingTable.isSyntheticModel`). Requests without a computed cost
/// (missing pricing, future models) contribute to the **count** but
/// not to the **total cost**, matching the rest of the app.
enum CostAnalyzer {

    // MARK: - Summaries

    struct ProjectSummary: Sendable, Equatable, Identifiable {
        /// Raw encoded `projectPath` — stable key for dedup / selection.
        let projectKey: String
        /// Human-friendly label from `ProjectLabelFormatter`.
        let projectLabel: String
        let sessionCount: Int
        let totalCost: CostBreakdown
        /// Model that contributed the most cost within this project.
        /// Nil only if every request was synthetic or had no computed
        /// cost.
        let primaryModel: String?
        var id: String { projectKey }
    }

    struct SkillSummary: Sendable, Equatable, Identifiable {
        /// Skill name *without* the provider command prefix (e.g.
        /// "gsd-next", "compact", "flow-all"). Mirrors the provider
        /// prompt command shape while keeping the aggregation key prefix
        /// independent.
        let skillName: String
        /// Number of Turns started by this skill.
        let invocationCount: Int
        /// Sum of `Turn.aggregateCost` across every Turn started by
        /// this skill.
        let totalCost: CostBreakdown
        /// `totalCost.totalCostUSD / invocationCount`. Zero when no
        /// invocations.
        let avgCostPerInvocation: Double
        /// Highest-cost model attributed to this skill's Turns.
        let primaryModel: String?
        var id: String { skillName }
    }

    struct ModelSummary: Sendable, Equatable, Identifiable {
        let modelName: String
        /// Number of requests that ran on this model.
        let usageCount: Int
        let totalCost: CostBreakdown
        /// `totalCost.totalCostUSD / usageCount`.
        let avgCostPerRequest: Double
        /// Subset of `usageCount` that used Opus fast-mode pricing.
        let fastCount: Int
        var id: String { modelName }
    }

    // MARK: - Project aggregation

    /// Rollup sessions by raw `projectPath`. Sessions without a project
    /// path bucket under the "" key with label "Unknown".
    ///
    /// Output is sorted by `totalCost.totalCostUSD` descending — the
    /// "most expensive project first" default the Reports UI wants.
    ///
    /// `requestTimestampRange` lets the caller narrow aggregation to
    /// requests whose `timestamp` falls inside a closed interval —
    /// matches how `UsageTimelineAnalyzer` buckets per-request, so the
    /// Reports tabs and the Overview chart agree on "today / yesterday"
    /// totals. `sessionCount` counts only sessions that contributed at
    /// least one in-range request (under the same range); a session
    /// that started yesterday but had no requests today would not
    /// inflate "Today"'s session count.
    static func byProject(
        _ sessions: [Session],
        costsByRequestId: [String: CostBreakdown?],
        requestTimestampRange: ClosedRange<Date>? = nil
    ) -> [ProjectSummary] {
        var grouped: [String: [Session]] = [:]
        for session in sessions {
            grouped[session.projectPath ?? "", default: []].append(session)
        }

        var summaries: [ProjectSummary] = []
        summaries.reserveCapacity(grouped.count)
        for (key, group) in grouped {
            var total = Self.zeroCost
            var modelCostAcc: [String: Double] = [:]
            var contributingSessions = 0
            for session in group {
                var hasInRangeRequest = false
                for request in session.requests {
                    if let range = requestTimestampRange,
                       !range.contains(request.timestamp) {
                        continue
                    }
                    hasInRangeRequest = true
                    guard let model = request.model,
                          !PricingTable.isSyntheticModel(model)
                    else { continue }
                    guard case .some(.some(let c)) = costsByRequestId[request.id]
                    else { continue }
                    total = Self.add(total, c)
                    modelCostAcc[model, default: 0] += c.totalCostUSD
                }
                if requestTimestampRange == nil || hasInRangeRequest {
                    contributingSessions += 1
                }
            }
            // Skip projects whose sessions had zero in-range activity —
            // otherwise "Today" shows a long list of yesterday-only
            // projects with $0 rows.
            guard contributingSessions > 0 else { continue }
            let primary = modelCostAcc.max(by: { $0.value < $1.value })?.key
            let label = key.isEmpty ? "Unknown" : ProjectLabelFormatter.decode(key)
            summaries.append(ProjectSummary(
                projectKey: key,
                projectLabel: label,
                sessionCount: contributingSessions,
                totalCost: total,
                primaryModel: primary
            ))
        }
        return summaries.sorted {
            $0.totalCost.totalCostUSD > $1.totalCost.totalCostUSD
        }
    }

    // MARK: - Skill aggregation

    /// Rollup Turns by provider skill-command name. Only Turns whose
    /// `promptStep.text` matches the provider's command pattern
    /// contribute.
    ///
    /// Cost attribution: **entire Turn cost** is charged to the skill
    /// that started it, per Plan 4 Open Question #2 Option A. A Turn
    /// that begins with `/compact` bills 100% of its assistant
    /// response + tool calls to "compact".
    ///
    /// Model attribution: step-level cost weighting. A single Turn can
    /// touch multiple models (e.g. Opus planning → Sonnet execution);
    /// the model whose steps contributed the most cost wins.
    static func bySkill(
        _ turnsBySession: [String: [Turn]],
        provider: ProviderKind = .claudeCode,
        knownCodexSkillNames: Set<String>? = nil,
        turnTimestampRange: ClosedRange<Date>? = nil
    ) -> [SkillSummary] {
        var costByName: [String: CostBreakdown] = [:]
        var countByName: [String: Int] = [:]
        var modelCostByName: [String: [String: Double]] = [:]

        for (_, turns) in turnsBySession {
            for turn in turns {
                // Per-request bucketing parity: if the caller supplies a
                // range, skip Turns whose prompt landed outside it. A
                // Turn without a resolvable start time conservatively
                // drops out of any bounded range.
                if let range = turnTimestampRange {
                    guard let start = turn.startTime,
                          range.contains(start)
                    else { continue }
                }
                guard let text = turn.promptStep?.text,
                      let skill = extractSkillName(
                        from: text,
                        provider: provider,
                        knownCodexSkillNames: knownCodexSkillNames
                      )
                else { continue }
                costByName[skill] = Self.add(costByName[skill] ?? Self.zeroCost,
                                             turn.aggregateCost)
                countByName[skill, default: 0] += 1

                for step in turn.steps {
                    guard let model = step.model,
                          !PricingTable.isSyntheticModel(model),
                          let cost = step.cost
                    else { continue }
                    modelCostByName[skill, default: [:]][model, default: 0]
                        += cost.totalCostUSD
                }
            }
        }

        var summaries: [SkillSummary] = []
        summaries.reserveCapacity(costByName.count)
        for (name, cost) in costByName {
            let count = countByName[name] ?? 0
            let avg = count > 0 ? cost.totalCostUSD / Double(count) : 0
            let primary = modelCostByName[name]?
                .max(by: { $0.value < $1.value })?.key
            summaries.append(SkillSummary(
                skillName: name,
                invocationCount: count,
                totalCost: cost,
                avgCostPerInvocation: avg,
                primaryModel: primary
            ))
        }
        return summaries.sorted {
            $0.totalCost.totalCostUSD > $1.totalCost.totalCostUSD
        }
    }

    // MARK: - Model aggregation

    /// Rollup requests by model name.
    ///
    /// `fastCount` counts requests whose `speed == "fast"` — i.e. Opus
    /// fast-mode — so the Reports view can show what fraction of usage
    /// was the pricier Opus speed tier. Requests with no computed cost
    /// (e.g. because pricing is missing) still increment `usageCount`
    /// and `fastCount` so the totals match the request log, but they
    /// contribute 0 to `totalCost`.
    static func byModel(
        _ sessions: [Session],
        costsByRequestId: [String: CostBreakdown?],
        requestTimestampRange: ClosedRange<Date>? = nil
    ) -> [ModelSummary] {
        var costByModel: [String: CostBreakdown] = [:]
        var countByModel: [String: Int] = [:]
        var fastCountByModel: [String: Int] = [:]

        for session in sessions {
            for request in session.requests {
                if let range = requestTimestampRange,
                   !range.contains(request.timestamp) {
                    continue
                }
                guard let model = request.model,
                      !PricingTable.isSyntheticModel(model)
                else { continue }
                countByModel[model, default: 0] += 1
                if request.speed == "fast" {
                    fastCountByModel[model, default: 0] += 1
                }
                if case .some(.some(let c)) = costsByRequestId[request.id] {
                    costByModel[model] = Self.add(
                        costByModel[model] ?? Self.zeroCost, c)
                }
            }
        }

        var summaries: [ModelSummary] = []
        summaries.reserveCapacity(countByModel.count)
        for (model, count) in countByModel {
            let cost = costByModel[model] ?? Self.zeroCost
            let avg = count > 0 ? cost.totalCostUSD / Double(count) : 0
            summaries.append(ModelSummary(
                modelName: model,
                usageCount: count,
                totalCost: cost,
                avgCostPerRequest: avg,
                fastCount: fastCountByModel[model] ?? 0
            ))
        }
        return summaries.sorted {
            $0.totalCost.totalCostUSD > $1.totalCost.totalCostUSD
        }
    }

    // MARK: - Helpers

    /// Extract the skill name from a prompt Step's text using the
    /// provider's command grammar.
    static func extractSkillName(
        from promptText: String?,
        provider: ProviderKind,
        knownCodexSkillNames: Set<String>? = nil
    ) -> String? {
        switch provider {
        case .claudeCode:
            return extractClaudeSlashSkillName(from: promptText)
        case .codex:
            return extractCodexDollarSkillName(
                from: promptText,
                knownSkillNames: knownCodexSkillNames
            )
        }
    }

    /// Legacy Claude Code convenience overload.
    ///
    /// Matches `RichEntryDecoder.parseSlashCommand` output shape
    /// (`/name args` or just `/name`). Returns the name portion
    /// without the leading `/`. Returns nil when:
    ///   - text is nil / empty / whitespace-only,
    ///   - doesn't start with `/`,
    ///   - has `/` followed immediately by whitespace or end-of-string
    ///     (i.e. no name to extract).
    ///
    /// Accepts arbitrary whitespace after the name (space, tab,
    /// newline) — the parseSlashCommand output always concatenates
    /// `/name` + space + args, but we tolerate newlines defensively
    /// for any future variant.
    ///
    /// Examples:
    ///   - `/gsd-next` → `"gsd-next"`
    ///   - `/gsd-plan-phase 4/5` → `"gsd-plan-phase"`
    ///   - `/commit -m "foo bar"` → `"commit"`
    ///   - `/` → nil
    ///   - `"hello"` → nil
    static func extractSkillName(from promptText: String?) -> String? {
        extractClaudeSlashSkillName(from: promptText)
    }

    static func skillCommandPrefix(for provider: ProviderKind) -> String {
        switch provider {
        case .claudeCode:
            return "/"
        case .codex:
            return "$"
        }
    }

    // MARK: - Private

    private static func extractClaudeSlashSkillName(from promptText: String?) -> String? {
        guard let raw = promptText else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let body = trimmed.dropFirst()
        if let end = body.firstIndex(where: { $0.isWhitespace }) {
            let name = String(body[..<end])
            return name.isEmpty ? nil : name
        }
        return String(body)
    }

    /// Codex user-facing skill invocations are prompt commands such as
    /// `$flow-all ...` or markdown-linked skill attachments such as
    /// `[$flow-all](/path/to/SKILL.md) ...`. The Codex app may prepend
    /// attachment metadata before "My request for Codex", so inspect
    /// the first user-request line rather than every line in a pasted
    /// body.
    private static func extractCodexDollarSkillName(
        from promptText: String?,
        knownSkillNames: Set<String>?
    ) -> String? {
        guard let raw = promptText else { return nil }
        guard let candidate = codexCommandCandidateLine(from: raw) else { return nil }
        return codexDollarSkillName(
            fromLineStart: candidate,
            knownSkillNames: knownSkillNames
        )
    }

    private static func codexCommandCandidateLine(from raw: String) -> String? {
        let lines = raw.components(separatedBy: .newlines)
        if let requestHeaderIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveContains("my request for codex:")
        }) {
            return lines[(requestHeaderIndex + 1)...]
                .lazy
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        return lines
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func codexDollarSkillName(
        fromLineStart line: String,
        knownSkillNames: Set<String>?
    ) -> String? {
        if line.hasPrefix("[$") {
            guard let closeBracket = line.firstIndex(of: "]") else { return nil }
            let linkStart = line.index(after: closeBracket)
            guard linkStart < line.endIndex,
                  line[linkStart] == "("
            else { return nil }
            let targetStart = line.index(after: linkStart)
            guard let closeParen = line[targetStart...].firstIndex(of: ")")
            else { return nil }
            let target = String(line[targetStart..<closeParen])
            guard codexMarkdownSkillTargetLooksValid(target) else { return nil }
            let token = String(line[line.index(after: line.startIndex)..<closeBracket])
            guard let name = normalizedCodexDollarSkillToken(token) else { return nil }
            return name
        }
        guard line.hasPrefix("$"),
              let token = line.split(whereSeparator: \.isWhitespace).first
        else { return nil }
        guard let name = normalizedCodexDollarSkillToken(String(token))
        else { return nil }
        if let knownSkillNames {
            return knownSkillNames.contains(name) ? name : nil
        }
        if codexUnknownSkillNameLooksIntentional(name) {
            return name
        }
        return nil
    }

    private static func normalizedCodexDollarSkillToken(_ token: String) -> String? {
        guard token.hasPrefix("$"), token.count > 1 else { return nil }
        let name = token.dropFirst()
        let commandPunctuation = CharacterSet(charactersIn: "-_:")
        guard let firstScalar = name.unicodeScalars.first,
              CharacterSet.letters.contains(firstScalar),
              name.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || commandPunctuation.contains($0)
              }) else {
            return nil
        }
        return String(name)
    }

    private static func codexMarkdownSkillTargetLooksValid(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.hasSuffix("/SKILL.md") || trimmed == "SKILL.md" else {
            return false
        }
        return trimmed.contains("/skills/") || trimmed.contains("/.agents/")
    }

    private static func codexUnknownSkillNameLooksIntentional(_ name: String) -> Bool {
        guard let firstScalar = name.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(firstScalar)
        else { return false }
        if name == "imagegen" { return true }
        return name.contains("-") || name.contains(":")
    }

    private static let zeroCost = CostBreakdown(
        inputCostUSD: 0,
        outputCostUSD: 0,
        cacheCreate1hCostUSD: 0,
        cacheCreate5mCostUSD: 0,
        cacheReadCostUSD: 0
    )

    private static func add(_ a: CostBreakdown, _ b: CostBreakdown) -> CostBreakdown {
        CostBreakdown(
            inputCostUSD: a.inputCostUSD + b.inputCostUSD,
            outputCostUSD: a.outputCostUSD + b.outputCostUSD,
            cacheCreate1hCostUSD: a.cacheCreate1hCostUSD + b.cacheCreate1hCostUSD,
            cacheCreate5mCostUSD: a.cacheCreate5mCostUSD + b.cacheCreate5mCostUSD,
            cacheReadCostUSD: a.cacheReadCostUSD + b.cacheReadCostUSD
        )
    }
}

enum CodexSkillCatalog {
    private struct Cache {
        let expiresAt: Date
        let names: Set<String>
    }

    private static let lock = NSLock()
    private static let cacheTTL: TimeInterval = 30
    private nonisolated(unsafe) static var cacheByRootsKey: [String: Cache] = [:]

    static func currentSkillNames(
        codexHome: URL? = nil,
        agentSkillsRoot: URL? = nil,
        additionalRoots: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> Set<String> {
        let roots = skillRoots(
            codexHome: codexHome,
            agentSkillsRoot: agentSkillsRoot,
            additionalRoots: additionalRoots,
            environment: environment,
            fileManager: fileManager
        )
        let rootsKey = roots
            .map { $0.standardizedFileURL.path }
            .joined(separator: "\n")

        lock.lock()
        if let cache = cacheByRootsKey[rootsKey],
           cache.expiresAt > now {
            let names = cache.names
            lock.unlock()
            return names
        }
        lock.unlock()

        let names = loadSkillNames(roots: roots, fileManager: fileManager)

        lock.lock()
        cacheByRootsKey[rootsKey] = Cache(
            expiresAt: now.addingTimeInterval(cacheTTL),
            names: names
        )
        lock.unlock()
        return names
    }

    static func resetCacheForTesting() {
        lock.lock()
        cacheByRootsKey.removeAll()
        lock.unlock()
    }

    static func projectLocalSkillRoots(
        forProjectPaths projectPaths: [String],
        fileManager: FileManager = .default,
        maxAncestorDepth: Int = 6
    ) -> [URL] {
        var seen = Set<String>()
        var roots: [URL] = []

        for projectPath in Set(projectPaths).sorted() {
            let trimmed = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var directory = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
                .standardizedFileURL
            for _ in 0...maxAncestorDepth {
                for relativeRoot in [".agents/skills", ".codex/skills"] {
                    let root = directory
                        .appendingPathComponent(relativeRoot)
                        .standardizedFileURL
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        continue
                    }
                    if seen.insert(root.path).inserted {
                        roots.append(root)
                    }
                }

                let parent = directory.deletingLastPathComponent().standardizedFileURL
                guard parent.path != directory.path else { break }
                directory = parent
            }
        }

        return roots
    }

    private static func loadSkillNames(
        roots: [URL],
        fileManager: FileManager
    ) -> Set<String> {
        var names = Set<String>()
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.lastPathComponent == "SKILL.md" else { continue }
                for name in candidateSkillNames(from: url) {
                    names.insert(name)
                }
            }
        }
        return names
    }

    private static func skillRoots(
        codexHome explicitCodexHome: URL?,
        agentSkillsRoot explicitAgentSkillsRoot: URL?,
        additionalRoots: [URL],
        environment: [String: String],
        fileManager: FileManager
    ) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let codexHome = explicitCodexHome?.standardizedFileURL
            ?? environment["CODEX_HOME"]
            .flatMap { path -> URL? in
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            } ?? home.appendingPathComponent(".codex")
        let agentSkillsRoot = explicitAgentSkillsRoot?.standardizedFileURL
            ?? home.appendingPathComponent(".agents").appendingPathComponent("skills")
        let baseRoots = [
            codexHome.appendingPathComponent("skills"),
            agentSkillsRoot
        ]
        return uniqueRoots(baseRoots + additionalRoots)
    }

    private static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for root in roots {
            let standardized = root.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                result.append(standardized)
            }
        }
        return result
    }

    private static func candidateSkillNames(from skillFileURL: URL) -> Set<String> {
        var names = Set<String>()
        let folderName = skillFileURL.deletingLastPathComponent().lastPathComponent
        if normalizedCodexSkillName(folderName) == folderName {
            names.insert(folderName)
        }
        if let declaredName = declaredSkillName(in: skillFileURL),
           normalizedCodexSkillName(declaredName) == declaredName {
            names.insert(declaredName)
        }
        return names
    }

    private static func declaredSkillName(in skillFileURL: URL) -> String? {
        guard let contents = try? String(contentsOf: skillFileURL, encoding: .utf8)
        else { return nil }
        let lines = contents.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        else { return nil }
        for rawLine in lines.dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" {
                return nil
            }
            guard line.hasPrefix("name:") else { continue }
            let value = line.dropFirst("name:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func normalizedCodexSkillName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandPunctuation = CharacterSet(charactersIn: "-_:")
        guard let firstScalar = name.unicodeScalars.first,
              CharacterSet.letters.contains(firstScalar),
              name.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || commandPunctuation.contains($0)
              }) else {
            return nil
        }
        return name
    }
}
