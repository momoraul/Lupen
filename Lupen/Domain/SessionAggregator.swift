import Foundation

/// Sole entry point for Lupen's cost/token pipeline. Output drives both
/// the UI totals and the Verify Costs window's left column (compared
/// against `GroundTruthCalculator`, which reads JSONL independently —
/// shared bugs cannot hide in one and not the other).
///
/// Dedup is per-session (keyed by `(sessionId, requestId ?? uuid)`) and
/// must agree with `GroundTruthCalculator.pickFinal` so B and C cannot
/// disagree on which line is "the billable one". Within a bucket: prefer
/// `stop_reason != nil`, then max output_tokens, then max input_tokens.
enum SessionAggregator {

    struct Result: Sendable {
        let sessions: [Session]
        let costsByRequestId: [String: CostBreakdown?]
    }

    /// - Parameters:
    ///   - entries: `AppStateStore.allRawEntries` in full. Caller invokes
    ///     once after per-file drain completes.
    ///   - projectPathMap: sessionId → project folder name from
    ///     FileDiscovery. Missing sessions get `projectPath = nil`.
    static func aggregate(
        _ entries: [RawEntry],
        projectPathMap: [String: String] = [:]
    ) -> Result {
        // Bucket assistant entries by (sessionId, requestId ?? uuid).
        // Per-session scoping avoids cross-session collisions when two
        // sessions share a requestId, and mirrors GroundTruthCalculator.
        // Sequential because inner dict-of-dict updates would need
        // fine-grained locking on every entry — parallelism pays off in
        // the next step instead.
        var buckets: [String: [String: RawEntry]] = [:]  // [sessionId: [key: bestEntry]]

        for entry in entries {
            // No usage → no billable line.
            guard entry.message.usage != nil else { continue }
            // Defensive: future filter changes must not let user lines
            // slip through.
            guard entry.type == "assistant" else { continue }

            let key = entry.requestId ?? entry.uuid
            let sessionBucket = buckets[entry.sessionId] ?? [:]
            if let existing = sessionBucket[key] {
                if isBetter(entry, than: existing) {
                    buckets[entry.sessionId, default: [:]][key] = entry
                }
            } else {
                buckets[entry.sessionId, default: [:]][key] = entry
            }
        }

        // Sessions are independent after bucketing → concurrentPerform.
        // Freezing the work list into a sorted array gives a
        // deterministic index → sessionId map so the merge phase can
        // iterate by index without re-reading the shared dict.
        let sessionIds = buckets.keys.sorted()
        let sessionBuckets: [[String: RawEntry]] = sessionIds.map { buckets[$0] ?? [:] }

        // Each worker owns its own index exclusively, so no
        // coordination is needed beyond the Sendable contract.
        let perSessionRequests = ThreadSafeSlots<[ParsedRequest]>(count: sessionIds.count)
        let perSessionCosts = ThreadSafeSlots<[(String, CostBreakdown?)]>(count: sessionIds.count)

        DispatchQueue.concurrentPerform(iterations: sessionIds.count) { idx in
            let keyToEntry = sessionBuckets[idx]
            var requests: [ParsedRequest] = []
            requests.reserveCapacity(keyToEntry.count)
            var costs: [(String, CostBreakdown?)] = []
            costs.reserveCapacity(keyToEntry.count)
            for (_, entry) in keyToEntry {
                let scopedSessionId = ProviderScopedID.normalize(entry.sessionId, defaultProvider: .claudeCode)
                guard let request = parsedRequest(from: entry, scopedSessionId: scopedSessionId) else { continue }
                requests.append(request)
                costs.append((
                    request.id,
                    CostCalculator.calculateCost(
                        tokens: request.tokens,
                        model: request.model,
                        speed: request.speed
                    )
                ))
            }
            // Intra-session order pinned by timestamp — matches the
            // sequential implementation exactly.
            requests.sort { $0.timestamp < $1.timestamp }
            perSessionRequests.set(idx, requests)
            perSessionCosts.set(idx, costs)
        }

        // Merge in sorted-id order so repeat runs produce byte-identical
        // Session arrays and costsByRequestId maps.
        var sessions: [Session] = []
        sessions.reserveCapacity(sessionIds.count)
        var costsByRequestId: [String: CostBreakdown?] = [:]
        costsByRequestId.reserveCapacity(entries.count)
        for (idx, sessionId) in sessionIds.enumerated() {
            let scopedSessionId = ProviderScopedID.normalize(sessionId, defaultProvider: .claudeCode)
            let requests = perSessionRequests.take(idx) ?? []
            sessions.append(Session(
                id: scopedSessionId,
                provider: .claudeCode,
                rawSessionId: sessionId,
                requests: requests,
                projectPath: projectPathMap[scopedSessionId] ?? projectPathMap[sessionId]
            ))
            if let costs = perSessionCosts.take(idx) {
                for (k, v) in costs {
                    costsByRequestId[k] = v
                }
            }
        }

        // Final sort by startTime; sessionId is the tiebreaker so
        // cache-restored sessions with nil/identical startTime stay in
        // a deterministic order.
        sessions.sort {
            let l = $0.startTime ?? .distantPast
            let r = $1.startTime ?? .distantPast
            if l != r { return l < r }
            return $0.id < $1.id
        }
        return Result(sessions: sessions, costsByRequestId: costsByRequestId)
    }

    /// Pre-sized, index-addressed storage for concurrent writes —
    /// each worker owns exactly one slot, so the NSLock only serialises
    /// write visibility to the merge phase.
    private final class ThreadSafeSlots<T>: @unchecked Sendable {
        private var storage: [T?]
        private let lock = NSLock()
        init(count: Int) { self.storage = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ value: T) {
            lock.lock(); storage[i] = value; lock.unlock()
        }
        func take(_ i: Int) -> T? {
            lock.lock(); defer { lock.unlock() }
            let v = storage[i]
            storage[i] = nil
            return v
        }
    }

    // MARK: - Pick rule (identical to GroundTruth.pickFinal)

    /// Determines which RawEntry in a shared-key bucket survives dedup.
    /// Must match `GroundTruthCalculator.pickFinal` so B and C agree on
    /// which line is "the billable one".
    private static func isBetter(_ candidate: RawEntry, than current: RawEntry) -> Bool {
        let candidateFinal = candidate.message.stopReason != nil
        let currentFinal = current.message.stopReason != nil
        if candidateFinal && !currentFinal { return true }
        if !candidateFinal && currentFinal { return false }
        let candidateOutput = candidate.message.usage?.outputTokens ?? 0
        let currentOutput = current.message.usage?.outputTokens ?? 0
        if candidateOutput != currentOutput { return candidateOutput > currentOutput }
        let candidateInput = candidate.message.usage?.inputTokens ?? 0
        let currentInput = current.message.usage?.inputTokens ?? 0
        return candidateInput > currentInput
    }

    // MARK: - Entry → ParsedRequest

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Process-wide cache of timestamp string → parsed `Date`.
    /// `ISO8601DateFormatter.date(from:)` was the hottest leaf in
    /// `aggregate` (~47% of inlined time on a streaming user); since
    /// rebuild cycles re-parse the same strings, caching drops a 50k
    /// entry re-aggregation from ~500 ms to ~5 ms. NSCache is
    /// thread-safe and self-evicts under memory pressure; `countLimit`
    /// is a defensive ceiling against pathological (~millions of
    /// distinct timestamps) corpora. The cache is monotonic — same
    /// string always parses to the same Date — so cross-test
    /// contamination is harmless.
    nonisolated(unsafe) private static let dateCache: NSCache<NSString, NSDate> = {
        let c = NSCache<NSString, NSDate>()
        c.countLimit = 200_000
        return c
    }()

    private static func parseTimestamp(_ ts: String) -> Date? {
        let key = ts as NSString
        if let cached = dateCache.object(forKey: key) {
            return cached as Date
        }
        guard let parsed = iso8601Formatter.date(from: ts) else { return nil }
        dateCache.setObject(parsed as NSDate, forKey: key)
        return parsed
    }

    /// Test seam — drop the cache so a perf test can measure cold parse
    /// cost deterministically. Production code never calls this.
    static func clearDateCacheForTesting() {
        dateCache.removeAllObjects()
    }

    private static func parsedRequest(from entry: RawEntry, scopedSessionId: String) -> ParsedRequest? {
        guard let usage = entry.message.usage else { return nil }
        guard let date = parseTimestamp(entry.timestamp) else { return nil }
        return ParsedRequest(
            id: entry.requestId ?? entry.uuid,
            messageId: entry.message.id,
            sessionId: scopedSessionId,
            provider: .claudeCode,
            rawSessionId: entry.sessionId,
            model: entry.message.model,
            timestamp: date,
            parentUuid: entry.parentUuid,
            isSidechain: entry.isSidechain,
            speed: usage.speed,
            stopReason: entry.message.stopReason,
            tokens: TokenBreakdown.from(usage: usage),
            gitBranch: entry.gitBranch,
            slug: entry.slug
        )
    }
}

/// Shared by aggregator, StepBuilder, and the Verify Costs calculator.
extension TokenBreakdown {
    /// Convert a `RawEntry.UsageData` (one JSONL line's usage block) into
    /// the Lupen domain token breakdown used for cost computation.
    ///
    /// ## Cache-creation bucket assignment
    ///
    /// Claude Code emits two related fields:
    ///   - `cache_creation_input_tokens` (legacy lump, 5m-TTL by
    ///     Anthropic default)
    ///   - `cache_creation.{ephemeral_1h_input_tokens,
    ///     ephemeral_5m_input_tokens}` (split — newer CLI versions)
    ///
    /// Four real JSONL shapes show up in production:
    ///   1. No `cache_creation` object + lump > 0 → legacy-only line,
    ///      treat lump as 5m.
    ///   2. `cache_creation: {1h: X, 5m: Y}` with at least one > 0 →
    ///      honour the split, lump is descriptive redundancy.
    ///   3. `cache_creation: {1h: 0, 5m: 0}` + lump > 0 → transitional
    ///      shape; treat lump as 5m, matching GroundTruthCalculator.
    ///   4. All zero → zero cost.
    ///
    /// Must stay bit-exactly aligned with
    /// `GroundTruthCalculator.computeCost` — any asymmetry shows up in
    /// the Verify Costs window as a cost-only divergence.
    static func from(usage: RawEntry.UsageData) -> TokenBreakdown {
        let flat = usage.cacheCreationInputTokens ?? 0
        let read = usage.cacheReadInputTokens ?? 0
        let subEph1h = usage.cacheCreation?.ephemeral1hInputTokens ?? 0
        let subEph5m = usage.cacheCreation?.ephemeral5mInputTokens ?? 0
        let eph1h: Int
        let eph5m: Int
        if subEph1h > 0 || subEph5m > 0 {
            // Shape 2 — honour the split.
            eph1h = subEph1h
            eph5m = subEph5m
        } else {
            // Shapes 1 / 3 / 4 — lump as 5m (no-op when flat == 0).
            eph1h = 0
            eph5m = flat
        }
        return TokenBreakdown(
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheCreationInputTokens: flat,
            cacheReadInputTokens: read,
            cacheCreationEphemeral1h: eph1h,
            cacheCreationEphemeral5m: eph5m
        )
    }
}
