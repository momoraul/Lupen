import Foundation

protocol ProviderUsageVerifier: Sendable {
    var provider: ProviderKind { get }

    func computeReport(files: [URL]) -> GroundTruth.Report

    /// SQLite-first (plan 4.5): the view side is the provider index.
    /// Returns divergences plus the sessions still pending import (6.8).
    func verify(
        report: GroundTruth.Report,
        againstSQLite store: ProviderStore
    ) -> GroundTruthVerifier.SQLiteVerification
}

extension ProviderUsageVerifier {
    func verify(
        report: GroundTruth.Report,
        againstSQLite store: ProviderStore
    ) -> GroundTruthVerifier.SQLiteVerification {
        GroundTruthVerifier.verify(report: report, againstSQLite: store)
    }
}

struct ClaudeUsageVerifier: ProviderUsageVerifier {
    let provider: ProviderKind = .claudeCode

    func computeReport(files: [URL]) -> GroundTruth.Report {
        GroundTruthCalculator.compute(files: files)
    }
}

/// Codex ground truth, grouped (plan 4.5-B).
///
/// Files are grouped by the scanner's identity rule (parent-chain walk
/// bounded to known files — `CodexMetadataScanner.rootRawSessionId`),
/// processed root chain first / creation order within a chain, with the
/// loader-grade carries: subagent replay trim against the accumulated
/// parent summary, hash-keyed same-raw replay trim per duplicated
/// chain, and cumulative `previousTotal` handoff across a chain's
/// pieces. The usage FOLD over the kept lines stays this verifier's own
/// independent computation (resolveUsage / turn attribution / pricing) —
/// only the line-selection primitives are shared with the importer, and
/// those carry their own test suites.
struct CodexUsageVerifier: ProviderUsageVerifier {
    let provider: ProviderKind = .codex

    func computeReport(files: [URL]) -> GroundTruth.Report {
        var usageLines: [GroundTruth.UsageLine] = []
        var issues: [GroundTruth.ReportIssue] = []

        // 1. First-line metadata for every file; unreadable files are
        //    surfaced and excluded from grouping (scanner parity).
        var metadataByURL: [URL: CodexSessionMetadata] = [:]
        for url in files {
            do {
                metadataByURL[url] = try CodexSessionMetadataReader.readMetadata(from: url)
            } catch {
                let fallbackId = ProviderScopedID(
                    provider: .codex,
                    rawSessionId: url.deletingPathExtension().lastPathComponent
                ).value
                issues.append(GroundTruth.ReportIssue(
                    sessionId: fallbackId,
                    kind: .sourceRejected(reason: error.localizedDescription)
                ))
            }
        }
        let allMetadata = Array(metadataByURL.values)
        let knownRawIds = Set(allMetadata.map(\.id))
        let parentByRawId = CodexMetadataScanner.parentMap(for: allMetadata)

        var groups: [String: [(url: URL, metadata: CodexSessionMetadata)]] = [:]
        for (url, metadata) in metadataByURL {
            let groupId = CodexMetadataScanner.rootRawSessionId(
                startingAt: metadata.id,
                parentByRawSessionId: parentByRawId,
                knownRawSessionIds: knownRawIds
            )
            groups[groupId, default: []].append((url, metadata))
        }

        // 2. Per group: chains root-first, creation order within.
        for (groupRawId, members) in groups.sorted(by: { $0.key < $1.key }) {
            let groupSessionId = ProviderScopedID(
                provider: .codex, rawSessionId: groupRawId
            ).value

            var chains: [String: [(url: URL, metadata: CodexSessionMetadata)]] = [:]
            for member in members {
                chains[member.metadata.id, default: []].append(member)
            }
            for rawId in chains.keys {
                chains[rawId]?.sort { lhs, rhs in
                    let lt = lhs.metadata.createdAt ?? .distantPast
                    let rt = rhs.metadata.createdAt ?? .distantPast
                    if lt != rt { return lt < rt }
                    return lhs.url.path < rhs.url.path
                }
            }
            let orderedChainIds = chains.keys.sorted { lhs, rhs in
                if lhs == groupRawId { return true }
                if rhs == groupRawId { return false }
                let lt = chains[lhs]?.first?.metadata.createdAt ?? .distantPast
                let rt = chains[rhs]?.first?.metadata.createdAt ?? .distantPast
                if lt != rt { return lt < rt }
                return lhs < rhs
            }

            var parentSummary = CodexSubagentReplayTrimmer.ParentSummary()
            var groupLines: [GroundTruth.UsageLine] = []

            for chainId in orderedChainIds {
                let pieces = chains[chainId] ?? []
                let usesDiscriminator = pieces.count > 1
                var carry = CodexUsageSessionLoader.SameRawReplayCarry()
                // Effective cumulative total across the chain's pieces —
                // `last_token_usage` lines fold in (ParentSummary math),
                // unlike the raw `previousTotal` the fold tracks.
                var chainTracker = CodexSubagentReplayTrimmer.ParentSummary()

                for piece in pieces {
                    let decoded = Self.readDecodedLines(
                        from: piece.url,
                        sessionId: groupSessionId,
                        issues: &issues
                    )

                    // Subagent replay trim against the parent summary.
                    let subagentTrim = CodexSubagentReplayTrimmer.trim(
                        decoded, metadata: piece.metadata, parentSummary: parentSummary
                    )
                    // Same-raw replay trim within a duplicated chain.
                    let kept: [CodexLineReader.DecodedLine]
                    if usesDiscriminator {
                        let sameRaw = CodexUsageSessionLoader.trimSameRawReplay(
                            subagentTrim.decodedLines, carry: carry
                        )
                        kept = sameRaw.decodedLines
                        CodexUsageSessionLoader.appendSameRawReplayKeys(of: kept, to: &carry)
                    } else {
                        kept = subagentTrim.decodedLines
                    }

                    var previousTotal = subagentTrim.initialPreviousTotal
                        ?? (usesDiscriminator ? chainTracker.totals.last : nil)
                    let discriminator = usesDiscriminator
                        ? CodexSourceDiscriminator.key(for: piece.url)
                        : nil
                    groupLines.append(contentsOf: Self.usageLines(
                        groupSessionId: groupSessionId,
                        metadata: piece.metadata,
                        decodedLines: kept,
                        sourceDiscriminator: discriminator,
                        previousTotal: &previousTotal,
                        issues: &issues
                    ))
                    if usesDiscriminator {
                        chainTracker.absorb(kept)
                    }
                    if chainId == groupRawId {
                        parentSummary.absorb(kept)
                    }
                }
            }

            // Long-context pricing is a session-scope decision (2.6) —
            // apply per GROUP, the visible session.
            usageLines.append(contentsOf: applySessionLongContextPricing(to: groupLines))
        }

        return GroundTruth.Report(
            provider: .codex,
            usageLines: usageLines,
            perSession: GroundTruthCalculator.aggregate(usageLines: usageLines),
            issues: issues
        )
    }

    // MARK: - Line reading

    private static func readDecodedLines(
        from url: URL,
        sessionId: String,
        issues: inout [GroundTruth.ReportIssue]
    ) -> [CodexLineReader.DecodedLine] {
        var decodedLines: [CodexLineReader.DecodedLine] = []
        _ = CodexLineReader.streamEntries(from: url) { streamed in
            switch streamed {
            case .decoded(let line):
                decodedLines.append(line)
            case .rejected(_, let lineOrdinal, _):
                issues.append(GroundTruth.ReportIssue(
                    sessionId: sessionId,
                    kind: .parserRejectedLine(
                        category: "malformedJSON",
                        lineNumber: lineOrdinal + 1,   // ordinals are 0-based
                        detail: "invalid Codex JSONL"
                    )
                ))
            }
            return true
        }
        for line in decodedLines {
            let batch = CodexLineDiagnostics.batch(fileURL: nil, decodedLines: [line])
            for item in batch.items {
                guard case .codexUnknownLineType(let detail) = item.rejection else { continue }
                issues.append(GroundTruth.ReportIssue(
                    sessionId: sessionId,
                    kind: .parserRejectedLine(
                        category: item.rejection.categoryKey,
                        lineNumber: Self.lineNumber(of: line),
                        detail: detail
                    )
                ))
            }
        }
        return decodedLines
    }

    private static func lineNumber(of line: CodexLineReader.DecodedLine) -> Int {
        // Reader ordinals are 0-based; report 1-based file lines.
        (line.rawLocator?.lineOrdinal).map { $0 + 1 } ?? 0
    }

    // MARK: - Usage fold (independent computation)

    private static func usageLines(
        groupSessionId: String,
        metadata: CodexSessionMetadata,
        decodedLines: [CodexLineReader.DecodedLine],
        sourceDiscriminator: String?,
        previousTotal: inout CodexTokenUsage?,
        issues: inout [GroundTruth.ReportIssue]
    ) -> [GroundTruth.UsageLine] {
        let entries = decodedLines.map(\.entry)
        let eventUserMessages = eventUserMessageTexts(in: entries)
        var lines: [GroundTruth.UsageLine] = []
        var currentModel = metadata.model
        var currentTurnId: String?
        var generatedTurnOrdinal = 0
        var skippedDuplicateCumulativeCount = 0
        var unknownPricingKeys: Set<String> = []
        var hasSeenLiveEventUserMessage = false
        let requestIdPrefix = sourceDiscriminator.map {
            "\(metadata.scopedId):source:\($0)"
        } ?? metadata.scopedId

        for decodedLine in decodedLines {
            let entry = decodedLine.entry
            guard let payload = entry.payload else { continue }
            let recordLineNumber = lineNumber(of: decodedLine)

            if entry.type == "turn_context" || payload.type == "turn_context" {
                currentTurnId = payload.turnId ?? currentTurnId
                currentModel = payload.model ?? currentModel
                continue
            }

            if entry.type == "response_item",
               payload.type == "message",
               payload.role == "user",
               payload.turnId == nil {
                let text = normalized(payload.messageText)
                if !eventUserMessages.isEmpty && !eventUserMessages.contains(text) {
                    continue
                }
                // Generated ids are a fallback for context-less files —
                // a live `turn_context` id keeps owning the turn (the
                // loader attributes usage to it across user messages).
                if currentTurnId == nil {
                    generatedTurnOrdinal += 1
                    currentTurnId = generatedTurnId(generatedTurnOrdinal)
                }
                continue
            }

            if entry.type == "event_msg",
               payload.type == "user_message" {
                hasSeenLiveEventUserMessage = true
                if currentTurnId == nil {
                    generatedTurnOrdinal += 1
                    currentTurnId = generatedTurnId(generatedTurnOrdinal)
                }
                continue
            }

            guard entry.type == "event_msg", payload.type == "token_count" else {
                continue
            }

            let duplicateCountBefore = skippedDuplicateCumulativeCount
            guard let usage = resolveUsage(
                payload.info,
                previousTotal: &previousTotal,
                skippedDuplicates: &skippedDuplicateCumulativeCount
            ) else {
                if skippedDuplicateCumulativeCount == duplicateCountBefore {
                    issues.append(GroundTruth.ReportIssue(
                        sessionId: groupSessionId,
                        kind: .missingUsageEvent(lineNumber: recordLineNumber)
                    ))
                }
                continue
            }

            let timestamp = CodexTimestampParser.parse(entry.timestamp)
                ?? CodexTimestampParser.parse(payload.timestamp)
                ?? metadata.createdAt
                ?? Date(timeIntervalSince1970: 0)
            if CodexForkReplayFilter.shouldSkip(
                metadata: metadata,
                eventTimestamp: timestamp,
                hasSeenLiveEventUserMessage: hasSeenLiveEventUserMessage
            ) {
                continue
            }

            let model = payload.model ?? payload.info?.model ?? payload.info?.modelName ?? currentModel
            if let model, !PricingTable.isSyntheticModel(model),
               PricingTable.rates(for: model) == nil,
               unknownPricingKeys.insert("\(groupSessionId)|\(model)").inserted {
                issues.append(GroundTruth.ReportIssue(
                    sessionId: groupSessionId,
                    kind: .unknownPricing(model: model)
                ))
            }

            let tokens = usage.normalizedTokenBreakdown()
            let requestId = Self.requestId(
                prefix: requestIdPrefix,
                turnId: payload.turnId ?? currentTurnId,
                ordinal: lines.count
            )
            lines.append(GroundTruth.UsageLine(
                filePath: metadata.fileURL.path,
                lineNumber: recordLineNumber,
                sessionId: groupSessionId,
                uuid: requestId,
                entryType: "token_count",
                requestId: requestId,
                messageId: nil,
                model: model,
                stopReason: nil,
                isSidechain: false,
                inputTokens: tokens.inputTokens,
                outputTokens: tokens.outputTokens,
                reasoningOutputTokens: tokens.reasoningOutputTokens,
                cacheCreationInputTokens: tokens.cacheCreationInputTokens,
                cacheReadInputTokens: tokens.cacheReadInputTokens,
                cacheCreationEphemeral1h: tokens.cacheCreationEphemeral1h,
                cacheCreationEphemeral5m: tokens.cacheCreationEphemeral5m,
                lineCostUSD: 0
            ))
        }

        return lines
    }

    private static func resolveUsage(
        _ info: CodexEntry.Info?,
        previousTotal: inout CodexTokenUsage?,
        skippedDuplicates: inout Int
    ) -> CodexTokenUsage? {
        guard let info else { return nil }

        if let total = info.totalTokenUsage,
           let previousTotal,
           total == previousTotal {
            skippedDuplicates += 1
            return nil
        }

        let usage: CodexTokenUsage?
        if let last = info.lastTokenUsage {
            usage = last
        } else if let total = info.totalTokenUsage {
            if let previousTotal {
                usage = total.delta(from: previousTotal)
            } else {
                usage = total
            }
        } else {
            usage = nil
        }

        if let total = info.totalTokenUsage {
            previousTotal = total
        }
        guard let usage, !usage.isZero else { return nil }
        return usage
    }

    private func computeCost(
        tokens: TokenBreakdown,
        model: String?,
        forceLongContext: Bool = false
    ) -> Double {
        Self.computeCost(tokens: tokens, model: model, forceLongContext: forceLongContext)
    }

    private static func computeCost(
        tokens: TokenBreakdown,
        model: String?,
        forceLongContext: Bool = false
    ) -> Double {
        guard let model else { return 0 }
        if PricingTable.isSyntheticModel(model) { return 0 }
        guard let baseRates = PricingTable.rates(for: model) else { return 0 }
        let rates = baseRates.adjustedForPromptInputTokens(
            tokens.inputTokens + tokens.cacheCreationInputTokens + tokens.cacheReadInputTokens,
            forceLongContext: forceLongContext
        )
        let perMillion = 1_000_000.0
        return (
            Double(tokens.inputTokens) * rates.inputPerMTok
          + Double(tokens.cacheReadInputTokens) * rates.cacheReadPerMTok
          + Double(tokens.outputTokens + tokens.reasoningOutputTokens) * rates.outputPerMTok
        ) / perMillion
    }

    private func applySessionLongContextPricing(
        to lines: [GroundTruth.UsageLine]
    ) -> [GroundTruth.UsageLine] {
        Self.applySessionLongContextPricing(to: lines)
    }

    private static func applySessionLongContextPricing(
        to lines: [GroundTruth.UsageLine]
    ) -> [GroundTruth.UsageLine] {
        var longContextModels: Set<String> = []
        for line in lines {
            guard let model = line.model,
                  let rates = PricingTable.rates(for: model) else {
                continue
            }
            let promptInputTokens = line.inputTokens
                + line.cacheCreationInputTokens
                + line.cacheReadInputTokens
            if rates.shouldUseLongContext(forPromptInputTokens: promptInputTokens) {
                longContextModels.insert(model)
            }
        }

        return lines.map { line in
            let tokens = TokenBreakdown(
                inputTokens: line.inputTokens,
                outputTokens: line.outputTokens,
                reasoningOutputTokens: line.reasoningOutputTokens,
                cacheCreationInputTokens: line.cacheCreationInputTokens,
                cacheReadInputTokens: line.cacheReadInputTokens,
                cacheCreationEphemeral1h: line.cacheCreationEphemeral1h,
                cacheCreationEphemeral5m: line.cacheCreationEphemeral5m
            )
            let forceLongContext = line.model.map { longContextModels.contains($0) } ?? false
            return GroundTruth.UsageLine(
                filePath: line.filePath,
                lineNumber: line.lineNumber,
                sessionId: line.sessionId,
                uuid: line.uuid,
                entryType: line.entryType,
                requestId: line.requestId,
                messageId: line.messageId,
                model: line.model,
                stopReason: line.stopReason,
                isSidechain: line.isSidechain,
                inputTokens: line.inputTokens,
                outputTokens: line.outputTokens,
                reasoningOutputTokens: line.reasoningOutputTokens,
                cacheCreationInputTokens: line.cacheCreationInputTokens,
                cacheReadInputTokens: line.cacheReadInputTokens,
                cacheCreationEphemeral1h: line.cacheCreationEphemeral1h,
                cacheCreationEphemeral5m: line.cacheCreationEphemeral5m,
                lineCostUSD: computeCost(
                    tokens: tokens,
                    model: line.model,
                    forceLongContext: forceLongContext
                )
            )
        }
    }

    private static func requestId(prefix: String, turnId: String?, ordinal: Int) -> String {
        let turnComponent = turnId?.isEmpty == false ? turnId! : "session"
        return "\(prefix):token_count:\(turnComponent):\(ordinal)"
    }

    private static func generatedTurnId(_ ordinal: Int) -> String {
        "generated-\(ordinal)"
    }

    private static func eventUserMessageTexts(in entries: [CodexEntry]) -> Set<String> {
        Set(entries.compactMap { entry in
            guard entry.type == "event_msg",
                  entry.payload?.type == "user_message" else {
                return nil
            }
            let text = normalized(entry.payload?.messageText)
            return text.isEmpty ? nil : text
        })
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }
}
