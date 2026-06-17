import Foundation

/// Independent ground-truth calculator.
///
/// ## Why it exists
///
/// The main pipeline (`RichEntryDecoder` -> `ConversationAssembler` ->
/// `Deduplicator` -> `SessionGrouper` -> `CostCalculator`) hasn't been
/// production-verified, so "compare against the main pipeline" is
/// self-reference and cannot be trusted.
///
/// Solution: a minimal calculator that uses **none** of that logic. Reads
/// JSONL bytes directly, pulls `usage` per line, multiplies by
/// `PricingTable` rates. Simple enough that anyone reading it can confirm
/// correctness by eye — that simplicity is the basis for trust.
///
/// Shared dependencies (not self-reference, just neutral data / layout):
///   - `PricingTable.rates(for:)` — Anthropic's official price table.
///   - `FileDiscovery` — `~/.claude/projects/` layout rules.
///
/// Intentionally NOT used:
///   - `RichEntryDecoder`, `ConversationAssembler`, `Deduplicator`,
///     `SessionGrouper`, `TokenCalculator.toRequest`, `CostCalculator`
///
/// ## Returned data
///
/// - `usageLines`: raw record for **every** line carrying a `usage` block.
///   Each carries uuid / type / requestId / token detail / lineCost so the
///   view can later detect (per-uuid) when a line went missing.
/// - `perSession`: per-session totals after dedup. Grouped by requestId,
///   one "final" line chosen per group via the rule in `pickFinal`.
///
/// ## Dedup rule (simple)
///
/// Streaming snapshots share a requestId; only one line is billable.
/// Selection:
///   1. If any rows have `stop_reason != nil`, prefer those.
///   2. Within the chosen pool, pick max `output_tokens`.
enum GroundTruthCalculator {

    private static let decoderThreadKey = "io.lupen.GroundTruthCalculator.decoder"

    private static func decoder() -> JSONDecoder {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[decoderThreadKey] as? JSONDecoder {
            return existing
        }
        let decoder = JSONDecoder()
        dictionary[decoderThreadKey] = decoder
        return decoder
    }

    static func compute(files: [URL]) -> GroundTruth.Report {
        var usageLines: [GroundTruth.UsageLine] = []

        for url in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var lineNumber = 0
            var sessionIdFromFile: String? = nil  // path-derived fallback

            for rawString in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                lineNumber += 1
                if rawString.isEmpty { continue }

                let data = Data(rawString.utf8)
                guard let raw = try? decoder().decode(RawLine.self, from: data) else { continue }

                // Capture a fallback sessionId from the first line that
                // has it (some sub-agent shapes omit sessionId on some
                // lines — if this ever changes we keep working).
                if sessionIdFromFile == nil, let sid = raw.sessionId {
                    sessionIdFromFile = sid
                }

                guard raw.type == "assistant",
                      let msg = raw.message,
                      let usage = msg.usage else {
                    continue
                }

                let sessionId = raw.sessionId ?? sessionIdFromFile ?? ""
                let uuid = raw.uuid ?? ""
                guard !sessionId.isEmpty, !uuid.isEmpty else { continue }

                let inputTokens = usage.input_tokens ?? 0
                let outputTokens = usage.output_tokens ?? 0
                let cacheCreation = usage.cache_creation_input_tokens ?? 0
                let cacheRead = usage.cache_read_input_tokens ?? 0
                let eph1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
                let eph5m = usage.cache_creation?.ephemeral_5m_input_tokens ?? 0

                let cost = computeCost(
                    input: inputTokens,
                    output: outputTokens,
                    cacheCreationLegacy: cacheCreation,
                    cacheCreation1h: eph1h,
                    cacheCreation5m: eph5m,
                    cacheRead: cacheRead,
                    model: msg.model,
                    speed: usage.speed
                )

                usageLines.append(GroundTruth.UsageLine(
                    filePath: url.path,
                    lineNumber: lineNumber,
                    sessionId: sessionId,
                    uuid: uuid,
                    entryType: raw.type ?? "",
                    requestId: raw.requestId,
                    messageId: msg.id,
                    model: msg.model,
                    stopReason: msg.stop_reason,
                    isSidechain: raw.isSidechain ?? false,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationInputTokens: cacheCreation,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationEphemeral1h: eph1h,
                    cacheCreationEphemeral5m: eph5m,
                    lineCostUSD: cost
                ))
            }
        }

        // Attribute each replayed requestId to its single canonical owner —
        // the exact resolution the importer applies. The owner map is built
        // from THESE usageLines grouped by their own `sessionId`, which is
        // the SAME grouping the importer's `request_membership` uses (one row
        // per request keyed by its line's sessionId). Deriving it from the
        // files' STEM instead would disagree whenever one file carries more
        // than one sessionId — a `--resume` that keeps the parent's id on
        // replayed lines — and re-home the replayed lines off their true
        // session. Key matches `aggregate`: requestId, or uuid when absent.
        //
        // SIDECHAINS ARE EXCLUDED from the owner-rank input — the importer's
        // `request_membership` excludes them too (ProviderStore.replaceSource,
        // v13). A subagent-heavy session carries many sidechain requestIds; if
        // those inflate its rank, it wrongly out-ranks a `--resume` superset
        // and steals the replayed requestIds the importer hands the superset —
        // the two owner maps diverge and Verify Costs flags the (mirror-image)
        // mismatch. Sidechain lines still survive `kept` below: their requestId
        // is absent from the map, so they stay on their own session (the
        // importer never re-homes a sidechain row either).
        var requestIdsBySession: [String: Set<String>] = [:]
        for line in usageLines where !line.isSidechain {
            requestIdsBySession[line.sessionId, default: []].insert(line.requestId ?? line.uuid)
        }
        let inputs = requestIdsBySession.map {
            ClaudeContinuationLineage.SessionInput(
                rawId: $0.key, logicalParentUuid: nil, requestIds: $0.value
            )
        }
        let owner = ClaudeContinuationLineage.resolve(inputs).ownerByRequestId
        let kept = owner.isEmpty
            ? usageLines
            : usageLines.filter { (owner[$0.requestId ?? $0.uuid] ?? $0.sessionId) == $0.sessionId }
        let perSession = aggregate(usageLines: kept)
        return GroundTruth.Report(provider: .claudeCode, usageLines: kept, perSession: perSession)
    }

    // MARK: - Aggregate

    /// Group by (sessionId, requestId). Within each group pick the
    /// "final" line per `pickFinal`. Sum across picked lines per session.
    ///
    /// Intentionally simple — no Deduplicator / SessionGrouper.
    static func aggregate(usageLines: [GroundTruth.UsageLine]) -> [String: GroundTruth.SessionGroundTruth] {
        // Bucket by sessionId first, then by requestId inside each.
        var bySession: [String: [String: [GroundTruth.UsageLine]]] = [:]
        var rawLineCount: [String: Int] = [:]
        for line in usageLines {
            let key = line.requestId ?? line.uuid  // fallback: treat each uuid as unique request
            bySession[line.sessionId, default: [:]][key, default: []].append(line)
            rawLineCount[line.sessionId, default: 0] += 1
        }

        var out: [String: GroundTruth.SessionGroundTruth] = [:]
        for (sessionId, byRequestId) in bySession {
            var dedupedLineCount = 0
            var totalCost: Double = 0
            var totalInput = 0
            var totalOutput = 0
            var totalReasoning = 0
            var totalCacheCreation = 0
            var totalCacheRead = 0
            var totalEph1h = 0
            var totalEph5m = 0
            var pickedUuids: [String] = []
            var pickedRequestIds: [String] = []

            for (requestIdKey, lines) in byRequestId {
                guard let final = pickFinal(from: lines) else { continue }
                dedupedLineCount += 1
                totalCost += final.lineCostUSD
                totalInput += final.inputTokens
                totalOutput += final.outputTokens
                totalReasoning += final.reasoningOutputTokens
                totalCacheCreation += final.cacheCreationInputTokens
                totalCacheRead += final.cacheReadInputTokens
                // Apply the same legacy-lump-as-5m fallback used in
                // `computeCost` (above) so the reported eph1h/eph5m
                // token counts agree with the cost that was actually
                // charged. Without this, view (which now folds the
                // lump into eph5m inside `TokenBreakdown.from`) and
                // truth disagree on the token total even though the
                // dollar figure matches — surfaced as a phantom
                // `cacheCreation5m` divergence in Verify Costs.
                if final.cacheCreationEphemeral1h > 0 || final.cacheCreationEphemeral5m > 0 {
                    totalEph1h += final.cacheCreationEphemeral1h
                    totalEph5m += final.cacheCreationEphemeral5m
                } else {
                    totalEph5m += final.cacheCreationInputTokens
                }
                pickedUuids.append(final.uuid)
                // The bucket key is `requestId ?? uuid`, matching the
                // semantics ParsedRequest uses for its `id` field
                // (`requestId ?? uuid`). That guarantees coverage
                // lookups are stable across dedup / merge transforms
                // inside the view pipeline.
                pickedRequestIds.append(requestIdKey)
            }

            out[sessionId] = GroundTruth.SessionGroundTruth(
                sessionId: sessionId,
                rawLineCount: rawLineCount[sessionId] ?? 0,
                dedupedLineCount: dedupedLineCount,
                dedupedTotalCostUSD: totalCost,
                dedupedInputTokens: totalInput,
                dedupedOutputTokens: totalOutput,
                dedupedReasoningOutputTokens: totalReasoning,
                dedupedCacheCreationInputTokens: totalCacheCreation,
                dedupedCacheReadInputTokens: totalCacheRead,
                dedupedCacheCreationEphemeral1h: totalEph1h,
                dedupedCacheCreationEphemeral5m: totalEph5m,
                pickedUuids: Set(pickedUuids),
                pickedRequestIds: Set(pickedRequestIds)
            )
        }
        return out
    }

    /// Pick the "final" billable line from a group sharing one requestId.
    /// Rule (simple, deterministic):
    ///   1. Prefer rows with `stopReason != nil`.
    ///   2. Within the preferred subset, pick max `outputTokens`.
    ///   3. Ties broken by max `inputTokens` (arbitrary but stable).
    private static func pickFinal(from lines: [GroundTruth.UsageLine]) -> GroundTruth.UsageLine? {
        guard !lines.isEmpty else { return nil }
        let preferred = lines.filter { $0.stopReason != nil }
        let pool = preferred.isEmpty ? lines : preferred
        return pool.max(by: { a, b in
            if a.outputTokens != b.outputTokens { return a.outputTokens < b.outputTokens }
            return a.inputTokens < b.inputTokens
        })
    }

    // MARK: - Cost

    /// Raw token × rate calculation. No sharing with `CostCalculator`.
    /// Returns 0 when pricing is unknown (rare; logged elsewhere).
    ///
    /// Internal (not private) so tests can anchor the
    /// "view ≡ truth" invariant against this exact function rather
    /// than re-coding the formula — a hand-copy drifts silently when
    /// rates or the legacy-fallback rule change.
    static func computeCost(
        input: Int, output: Int,
        cacheCreationLegacy: Int,
        cacheCreation1h: Int, cacheCreation5m: Int,
        cacheRead: Int,
        model: String?, speed: String?
    ) -> Double {
        guard let model else { return 0 }
        if PricingTable.isSyntheticModel(model) { return 0 }
        guard let baseRates = PricingTable.rates(for: model) else { return 0 }
        let cacheCreationInputForThreshold = (cacheCreation1h > 0 || cacheCreation5m > 0)
            ? cacheCreation1h + cacheCreation5m
            : cacheCreationLegacy
        let rates = baseRates.adjustedForPromptInputTokens(
            input + cacheCreationInputForThreshold + cacheRead
        )

        let perMillion: Double = 1_000_000
        let isFast = speed == "fast"

        let inputRate: Double
        let outputRate: Double
        if isFast, let fi = rates.fastInputPerMTok, let fo = rates.fastOutputPerMTok {
            inputRate = fi
            outputRate = fo
        } else {
            inputRate = rates.inputPerMTok
            outputRate = rates.outputPerMTok
        }

        // When the API provides split ephemeral counts, those are the
        // source of truth. Fall back to the legacy lump field when
        // split isn't present (older Claude Code versions).
        let creationPool: Double
        if cacheCreation1h > 0 || cacheCreation5m > 0 {
            creationPool = Double(cacheCreation1h) * rates.cacheWrite1hPerMTok
                         + Double(cacheCreation5m) * rates.cacheWrite5mPerMTok
        } else {
            // Legacy — treat as 5m ephemeral (Claude Code default).
            creationPool = Double(cacheCreationLegacy) * rates.cacheWrite5mPerMTok
        }

        return (
            Double(input) * inputRate
          + Double(output) * outputRate
          + creationPool
          + Double(cacheRead) * rates.cacheReadPerMTok
        ) / perMillion
    }

    // MARK: - Minimal decode shape

    /// Decode just what's needed — intentionally small. Adding fields
    /// here means the ground-truth logic changed and deserves review.
    private struct RawLine: Decodable {
        let type: String?
        let uuid: String?
        let sessionId: String?
        let requestId: String?
        let isSidechain: Bool?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let stop_reason: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation: CacheCreation?
            let speed: String?
        }

        struct CacheCreation: Decodable {
            let ephemeral_1h_input_tokens: Int?
            let ephemeral_5m_input_tokens: Int?
        }
    }
}
