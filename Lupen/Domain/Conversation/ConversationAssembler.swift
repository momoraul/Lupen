import Foundation

/// Core domain service that assembles JSONL entries into `Turn`s.
///
/// Goals:
/// - Track the Prompt → ... → Reply/Stop chain and group it into a single Turn.
/// - Incremental updates: new Steps are appended to the appropriate existing Turn.
/// - Turn ID = root Prompt Step's UUID (deterministic, unique per session).
/// - Deduplication: the same `(sessionId, uuid)` is ignored on re-ingest.
/// - Ordering: Steps are kept in ascending timestamp order.
/// - Session scoping: every index keys on `(sessionId, uuid)`.
/// - Orphan repair: if a parent arrives later, the orphan Turn is merged into its real Turn.
///
/// See `docs/CONVERSATION-MODEL.md` for the full rules.
///
/// ## Thread safety
/// Not thread-safe. Callers must serialize access (e.g. main actor).
final class ConversationAssembler {

    // MARK: - Keys

    /// `(sessionId, uuid)` composite key. Scoped so the same uuid in different
    /// sessions never collides.
    ///
    /// Bump `SnapshotSchema.currentVersion` when fields change.
    struct StepKey: Hashable, Sendable, Codable {
        let sessionId: String
        let uuid: String
    }

    /// `(sessionId, turnId)` composite key.
    ///
    /// `Codable` — same rationale as above.
    struct TurnKey: Hashable, Sendable, Codable {
        let sessionId: String
        let turnId: String
    }

    // MARK: - State

    private var stepsByKey: [StepKey: Step] = [:]
    /// (sessionId, uuid) → turnId (local uuid, unique within the session).
    private var turnIdByKey: [StepKey: String] = [:]
    /// (sessionId, turnId) → step uuids in sorted order.
    private var stepUuidsByTurnKey: [TurnKey: [String]] = [:]
    /// sessionId → set of turnIds for that session.
    private var turnIdsBySession: [String: Set<String>] = [:]
    /// (sessionId, tool_use_id) → tool name.
    private var toolNameByKey: [StepKey: String] = [:]

    /// Tool names `AttachmentResolver` couldn't extract any path / URL
    /// from during `buildTurn`. First-seen set — each unknown tool is
    /// recorded once regardless of how many times it appears across
    /// Turns. Drained by `AppStateStore` at parse-pass end so each
    /// tool becomes a single `unknownToolForAttachmentExtraction`
    /// warning in `ParseDiagnostics` (not one per tool-call
    /// occurrence, which would spam the Diagnostics window).
    private(set) var unknownAttachmentToolNames: Set<String> = []

    /// Assistant `stop_reason` raw strings that fell outside Lupen's
    /// `StopReason` enum (likely a new value Anthropic introduced).
    /// First-seen set with the same draining pattern as
    /// `unknownAttachmentToolNames` — one diagnostic per distinct
    /// string per parse pass, not per occurrence.
    private(set) var unknownStopReasonRawValues: Set<String> = []

    /// sessionId-scoped `toolUseId → toolName` index maintained in
    /// parallel with `toolNameByKey`. `buildTurn` used to flatten
    /// `toolNameByKey` into a session view on every call (O(N) for
    /// every Turn render), which made the main thread freeze when
    /// the outline asked for Turns repeatedly on large datasets.
    /// This parallel index makes the lookup `buildTurn` needs
    /// essentially free (single dict read) and is updated in the
    /// same few writer sites that mutate `toolNameByKey`.
    private var toolNameByUseIdBySession: [String: [String: String]] = [:]
    /// (sessionId, uuid) → parentUuid. Includes entries that don't decode into
    /// a Step (attachment/system/etc.) so parent-chain walks can hop over
    /// dropped intermediate links.
    private var parentUuidByKey: [StepKey: String?] = [:]
    /// (sessionId, messageId) → uuid of the existing Step. Index for merging
    /// multiple assistant entries that share the same messageId.
    private var stepUuidByMessageId: [StepKey: String] = [:]

    // MARK: - Init

    init() {}

    /// Clears every index.
    func reset() {
        stepsByKey.removeAll()
        turnIdByKey.removeAll()
        stepUuidsByTurnKey.removeAll()
        turnIdsBySession.removeAll()
        toolNameByKey.removeAll()
        toolNameByUseIdBySession.removeAll()
        parentUuidByKey.removeAll()
        stepUuidByMessageId.removeAll()
    }

    // MARK: - Snapshot (Plan 13)


    /// Registers `(sessionId, uuid, parentUuid)` links for every JSONL line.
    /// Includes entries that don't decode into a Step (attachment, system,
    /// file-history-snapshot, ...) so parent-chain walks can hop over them.
    func registerParentLinks(_ links: [RichEntryDecoder.ParentLink]) {
        for link in links {
            let key = StepKey(sessionId: link.sessionId, uuid: link.uuid)
            parentUuidByKey[key] = link.parentUuid
        }
    }

    // MARK: - Ingest

    /// Reflects an already-decoded `RichEntry` list into Steps/Turns.
    /// Duplicate `(sessionId, uuid)` is ignored. Query via `turns(in:)` after.
    ///
    /// - Returns: `(sessionId, turnId)` set of Turns added or updated by this call.
    @discardableResult
    func ingest(_ entries: [RichEntry]) -> Set<TurnKey> {
        let sortedAll = entries.sorted { $0.timestamp < $1.timestamp }
        var affectedTurns: Set<TurnKey> = []

        for entry in sortedAll {
            let key = StepKey(sessionId: entry.sessionId, uuid: entry.uuid)

            // Record parent link for every entry, even ones we skip below
            // (must happen before the merge/dedup branches).
            parentUuidByKey[key] = entry.parentUuid

            if stepsByKey[key] != nil { continue }

            // Image-source meta entries (`[Image source: /path]`) are not
            // emitted as Steps. Claude Code auto-injects them; surfacing
            // them as a separate row inside the user's Turn would be
            // confusing. Instead, walk the parent chain to the nearest
            // prompt Step and merge the path into its imageSourcePaths.
            // No extra cache invalidation is needed — `turns(in:)` rebuilds
            // Turns from stepsByKey on every call.
            if entry.isImageSourceMeta {
                if let promptKey = findNearestPromptStepKey(
                    fromParent: entry.parentUuid,
                    in: entry.sessionId
                ), let existing = stepsByKey[promptKey] {
                    // imageSourcePaths changed → re-run attachment
                    // resolution so new `.promptImageMeta` refs land
                    // in the prompt Step's manifest. The resolve cost
                    // is paid once per meta-merge, not per render.
                    stepsByKey[promptKey] = resolvedStepForStorage(
                        mergingImageSourcePaths(
                            into: existing,
                            newPaths: entry.imageSourcePaths
                        )
                    )
                    if let turnId = turnIdByKey[promptKey] {
                        affectedTurns.insert(TurnKey(sessionId: entry.sessionId, turnId: turnId))
                    }
                }
                continue
            }

            // Merge by messageId: if an assistant Step with the same
            // (sessionId, messageId) already exists, fold the new entry's
            // blocks/tokens into it.
            if entry.entryType == .assistant, let mid = entry.messageId {
                let midKey = StepKey(sessionId: entry.sessionId, uuid: mid)
                if let existingUuid = stepUuidByMessageId[midKey],
                   let existingStep = stepsByKey[StepKey(sessionId: entry.sessionId, uuid: existingUuid)] {
                    let merged = mergeAssistant(existing: existingStep, withNew: entry)
                    // Update the tool-name index first so attachment
                    // resolve (next line) sees any newly merged tool
                    // calls when computing the merged Step's
                    // `attachments` manifest.
                    for call in merged.toolCalls {
                        indexToolName(sessionId: entry.sessionId, useId: call.id, name: call.name)
                    }
                    stepsByKey[StepKey(sessionId: entry.sessionId, uuid: existingUuid)]
                        = resolvedStepForStorage(merged)
                    recordUnknownStopReasonIfNeeded(in: merged)
                    // The merged Step stays in the same Turn — re-emit the
                    // affectedTurns entry so downstream rebuilds pick it up.
                    if let turnId = turnIdByKey[StepKey(sessionId: merged.sessionId, uuid: existingUuid)] {
                        affectedTurns.insert(TurnKey(sessionId: merged.sessionId, turnId: turnId))
                    }
                    // Pointer-only write for the new uuid; the Step itself
                    // is the existing one we just merged into.
                    turnIdByKey[key] = turnIdByKey[StepKey(sessionId: merged.sessionId, uuid: existingUuid)]
                    continue
                }
            }

            let step = StepBuilder.build(from: entry)
            recordUnknownStopReasonIfNeeded(in: step)
            if let mid = entry.messageId {
                stepUuidByMessageId[StepKey(sessionId: entry.sessionId, uuid: mid)] = entry.uuid
            }

            // Update the tool_use index BEFORE attachment resolve runs —
            // resolve reads `toolNameByUseIdBySession` to populate the
            // toolName field on toolOutput rows.
            for call in step.toolCalls {
                indexToolName(sessionId: step.sessionId, useId: call.id, name: call.name)
            }
            stepsByKey[key] = resolvedStepForStorage(step)

            let turnId = resolveTurnId(for: step)
            turnIdByKey[key] = turnId
            insertStep(step, intoTurn: turnId)
            turnIdsBySession[step.sessionId, default: []].insert(turnId)
            affectedTurns.insert(TurnKey(sessionId: step.sessionId, turnId: turnId))
        }

        // Orphan repair: if a freshly ingested Step is the parent of an
        // existing orphan Turn, merge the orphan into it.
        let repairedTurns = repairOrphans(afterIngesting: sortedAll.map { $0.sessionId })
        affectedTurns.formUnion(repairedTurns)

        return affectedTurns
    }

    /// Merges assistant entries that share a messageId at the block level.
    /// Keeps the first entry's tokens/cost to avoid double-counting.
    private func mergeAssistant(existing: Step, withNew new: RichEntry) -> Step {
        let newStep = StepBuilder.build(from: new)

        let mergedText: String? = {
            switch (existing.text, newStep.text) {
            case (nil, nil): return nil
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (let a?, let b?): return a + "\n" + b
            }
        }()

        let mergedThinking: String? = {
            switch (existing.thinkingText, newStep.thinkingText) {
            case (nil, nil): return nil
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (let a?, let b?): return a + "\n" + b
            }
        }()

        let mergedToolCalls = existing.toolCalls + newStep.toolCalls
        let mergedImages = existing.images + newStep.images

        // stopReason: new is likely later in time, so prefer new (fall back
        // to existing only when new is nil).
        let finalStopReason = newStep.stopReason ?? existing.stopReason

        // Reclassify kind based on the merged content. A thinking block
        // (even an empty signature-only extended-thinking block) or any
        // plain text means `.thought`.
        let existingHadThinking = (existing.kind == .thought || existing.thinkingText != nil) ||
            (existing.kind == .toolCall && existing.toolCalls.isEmpty && existing.text == nil)
            // ^ Recover the case where a "thinking only" first entry was
            //   originally classified as toolCall.
        let newHasThinking = new.blocks.contains(where: { $0.isThinking })
        let hasThinking = existingHadThinking || newHasThinking
        let hasText = (mergedText?.isEmpty == false) || hasThinking
        let hasToolUse = !mergedToolCalls.isEmpty
        // Apply the same Turn-boundary rule as `StepBuilder.classify`.
        // If `pause_turn` is classified as `.stop` the Turn ends early and
        // cost / skill-group / attachment attribution gets split apart
        // (research-turn-model §2.6).
        let kind: StepKind
        let reasonKind = StopReason(rawString: finalStopReason)
        if reasonKind == .toolUse || reasonKind == .pauseTurn || hasToolUse {
            kind = hasText ? .thought : .toolCall
        } else if reasonKind == .endTurn {
            kind = .reply
        } else {
            kind = .stop
        }

        let mergedRequestIds = (existing.requestIds + newStep.requestIds).reduce(into: [String]()) { result, id in
            if !result.contains(id) {
                result.append(id)
            }
        }

        // tokens/cost: keep existing's values (only the first entry carries
        // usage, or all entries carry the same value).
        return Step(
            uuid: existing.uuid,
            parentUuid: existing.parentUuid,
            sessionId: existing.sessionId,
            timestamp: existing.timestamp,
            kind: kind,
            isSystemInjected: existing.isSystemInjected,
            isSidechain: existing.isSidechain,
            agentId: existing.agentId ?? newStep.agentId,
            isCompactSummary: existing.isCompactSummary,
            text: mergedText,
            thinkingText: mergedThinking,
            images: mergedImages,
            toolCalls: mergedToolCalls,
            toolResult: existing.toolResult ?? newStep.toolResult,
            requestId: existing.requestId ?? newStep.requestId,
            requestIds: mergedRequestIds,
            messageId: existing.messageId ?? newStep.messageId,
            model: existing.model ?? newStep.model,
            speed: existing.speed ?? newStep.speed,
            stopReason: finalStopReason,
            stopReasonKind: StopReason(rawString: finalStopReason),
            tokens: existing.tokens ?? newStep.tokens,
            cost: existing.cost ?? newStep.cost,
            rawJSON: existing.rawJSON ?? newStep.rawJSON,
            rawJSONLocator: existing.rawJSONLocator ?? newStep.rawJSONLocator
        )
    }

    /// Reflects an already-built `Step` list (alternate pipeline / tests).
    @discardableResult
    func ingestSteps(_ steps: [Step]) -> Set<TurnKey> {
        let filtered = steps.filter { stepsByKey[StepKey(sessionId: $0.sessionId, uuid: $0.uuid)] == nil }
        let sortedNew = filtered.sorted { $0.timestamp < $1.timestamp }

        var affectedTurns: Set<TurnKey> = []
        var touchedSessions: [String] = []

        for step in sortedNew {
            let key = StepKey(sessionId: step.sessionId, uuid: step.uuid)
            for call in step.toolCalls {
                indexToolName(sessionId: step.sessionId, useId: call.id, name: call.name)
            }
            stepsByKey[key] = resolvedStepForStorage(step)
            let turnId = resolveTurnId(for: step)
            turnIdByKey[key] = turnId
            insertStep(step, intoTurn: turnId)
            turnIdsBySession[step.sessionId, default: []].insert(turnId)
            affectedTurns.insert(TurnKey(sessionId: step.sessionId, turnId: turnId))
            touchedSessions.append(step.sessionId)
        }

        affectedTurns.formUnion(repairOrphans(afterIngesting: touchedSessions))
        return affectedTurns
    }

    // MARK: - Queries

    /// Returns the session's Turns in ascending start-time order.
    ///
    /// `isInterrupted` semantics:
    /// - Claude Code CLI injects `[Request interrupted by user]` (or
    ///   `[Request interrupted by user for tool use]`) whenever the user
    ///   cancels mid-Turn. `RichEntryDecoder` / `StepBuilder` turn these
    ///   into a Step with `kind == .interruption`. That Step is the
    ///   *ground truth* for "the user cut this Turn short" — nothing else
    ///   is reliable.
    /// - The previous heuristic ("last step isn't reply/stop + there's a
    ///   later Turn") over-flagged. An assistant that legitimately ended a
    ///   Turn on a tool call (rare but legal: e.g. an aborted file write,
    ///   a max_tokens cutoff, a middle-of-session conversation continue)
    ///   would show up as "interrupted" even though the user never
    ///   interrupted anything. The flag was driving a ⚠︎/slash icon in the
    ///   outline, which kept showing on normal prompts and eroded trust.
    /// - New rule: a Turn is interrupted iff it contains at least one
    ///   `.interruption` Step. Everything else — tool-only endings,
    ///   trailing in-flight Turns, etc. — is treated as non-interrupted.
    func turns(in sessionId: String) -> [Turn] {
        let turnIds = turnIdsBySession[sessionId] ?? []
        let unsorted = turnIds.map { buildTurn(sessionId: sessionId, turnId: $0, isInterrupted: false) }
        let sorted = unsorted.sorted {
            ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast)
        }
        return sorted.map { turn in
            let interrupted = turn.steps.contains { $0.kind == .interruption }
            guard interrupted else { return turn }
            return Turn(
                id: turn.id,
                sessionId: turn.sessionId,
                steps: turn.steps,
                isInterrupted: true
            )
        }
    }

    /// Returns every Turn grouped by sessionId.
    func turnsBySession() -> [String: [Turn]] {
        var result: [String: [Turn]] = [:]
        for (sessionId, _) in turnIdsBySession {
            result[sessionId] = turns(in: sessionId)
        }
        return result
    }

    /// Looks up a single Turn. Use `turns(in:)` if accurate `isInterrupted`
    /// is required.
    func turn(sessionId: String, id turnId: String) -> Turn? {
        let key = TurnKey(sessionId: sessionId, turnId: turnId)
        guard stepUuidsByTurnKey[key] != nil else { return nil }
        return buildTurn(sessionId: sessionId, turnId: turnId, isInterrupted: false)
    }

    /// Total Turn count.
    var turnCount: Int { stepUuidsByTurnKey.count }

    /// Total Step count.
    var stepCount: Int { stepsByKey.count }

    /// Resolves a tool name from its tool_use_id. O(1) lookup.
    func toolName(forUseId useId: String, in sessionId: String) -> String? {
        toolNameByKey[StepKey(sessionId: sessionId, uuid: useId)]
    }

    /// Returns unknown-tool names accumulated since the last call and
    /// clears the internal set. `AppStateStore` calls this after each
    /// parse pass and turns each returned name into one
    /// `unknownToolForAttachmentExtraction` warning in
    /// `ParseDiagnostics`.
    func drainAttachmentToolDiagnostics() -> [String] {
        defer { unknownAttachmentToolNames.removeAll() }
        return Array(unknownAttachmentToolNames).sorted()
    }

    /// Returns unknown `stop_reason` raw strings accumulated since the
    /// last call and clears the internal set. Each value becomes one
    /// `unknownStopReason` warning in `ParseDiagnostics`.
    func drainUnknownStopReasonDiagnostics() -> [String] {
        defer { unknownStopReasonRawValues.removeAll() }
        return Array(unknownStopReasonRawValues).sorted()
    }

    /// Writes `(sessionId, useId) → name` into both index maps.
    /// Keeps `toolNameByUseIdBySession` in sync with `toolNameByKey`
    /// so `buildTurn`'s per-session lookup stays O(1).
    private func indexToolName(sessionId: String, useId: String, name: String) {
        toolNameByKey[StepKey(sessionId: sessionId, uuid: useId)] = name
        toolNameByUseIdBySession[sessionId, default: [:]][useId] = name
    }

    /// Single-session convenience method (legacy/test compatibility).
    func toolName(forUseId useId: String) -> String? {
        for (key, name) in toolNameByKey where key.uuid == useId {
            return name
        }
        return nil
    }

    // MARK: - Internal: Turn ID resolution

    /// Walks the parentUuid chain to find the root `.prompt`'s UUID.
    /// Hops over undecoded intermediate entries (attachment, ...) via
    /// `parentUuidByKey`. Falls back to self-root (orphan Turn) on failure.
    private func resolveTurnId(for step: Step) -> String {
        if step.kind == .prompt {
            // System-injected prompts (isMeta=true, e.g. "Base directory
            // for this skill: ...") always join the parent Turn via a full
            // chain walk, even when the direct parent is missing — the
            // sub-skill trigger (an empty user entry) is dropped from
            // stepsByKey, but its parentUuidByKey link survives.
            if step.isSystemInjected {
                return walkParentChain(
                    startingFrom: step.parentUuid,
                    in: step.sessionId,
                    fallback: step.uuid
                )
            }
            // Regular prompt: only join the parent Turn when the *direct*
            // parent is itself a `.prompt` Step. Example: slash-command
            // invocation (command-message prompt) → skill body (user text
            // prompt) — these two user entries belong to the same Turn.
            //
            // Important: an indirect parent reached via chain walk
            // (assistant reply → next user prompt) is a legitimate new
            // Turn, so we deliberately do NOT walk here — only the direct
            // parentUuid is consulted.
            if let parentId = step.parentUuid {
                let parentKey = StepKey(sessionId: step.sessionId, uuid: parentId)
                if let parentStep = stepsByKey[parentKey], parentStep.kind == .prompt {
                    return parentStep.uuid
                }
            }
            return step.uuid
        }
        return walkParentChain(
            startingFrom: step.parentUuid,
            in: step.sessionId,
            fallback: step.uuid
        )
    }

    /// Walks the parent chain and returns the `StepKey` of the nearest
    /// `.prompt` Step. Used when merging image-source meta entries into
    /// their prompt Step. Similar to `walkParentChain` but returns the
    /// **StepKey** rather than a turnId — we need to fetch and update the
    /// actual Step value in `stepsByKey`.
    private func findNearestPromptStepKey(
        fromParent start: String?,
        in sessionId: String
    ) -> StepKey? {
        var cursor: String? = start
        var visited = Set<String>()
        while let uuid = cursor {
            if visited.contains(uuid) { return nil }  // cycle guard
            visited.insert(uuid)
            let key = StepKey(sessionId: sessionId, uuid: uuid)
            if let step = stepsByKey[key] {
                if step.kind == .prompt {
                    return key
                }
                cursor = step.parentUuid
                continue
            }
            // Undecoded intermediate entry (attachment, ...) — hop the
            // parent link.
            if let parentLink = parentUuidByKey[key], let next = parentLink {
                cursor = next
                continue
            }
            return nil
        }
        return nil
    }

    /// Returns a **new** Step value with `newPaths` appended to the prompt
    /// Step's image source paths (Step is immutable, so we rebuild it).
    /// Deduplicates paths.
    private func mergingImageSourcePaths(into step: Step, newPaths: [String]) -> Step {
        var seen = Set(step.imageSourcePaths)
        var merged = step.imageSourcePaths
        for p in newPaths where seen.insert(p).inserted {
            merged.append(p)
        }
        return Step(
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
            imageSourcePaths: merged,
            mentionedFilePaths: step.mentionedFilePaths,
            attachments: step.attachments,
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

    /// Shared chain walker — used for both Step resolution and orphan
    /// repair.
    /// 1) stepsByKey hit → return its uuid if `.prompt`, otherwise hop on
    ///    its parentUuid
    /// 2) turnIdByKey hit → return that turnId
    /// 3) parentUuidByKey hit (undecoded intermediate entry) → hop on its
    ///    parentUuid
    /// 4) On failure, return `fallback`.
    private func walkParentChain(
        startingFrom start: String?,
        in sessionId: String,
        fallback: String
    ) -> String {
        var cursor: String? = start
        var visited = Set<String>()
        while let uuid = cursor {
            if visited.contains(uuid) { break }  // cycle guard
            visited.insert(uuid)
            let key = StepKey(sessionId: sessionId, uuid: uuid)

            // (a) Step with a known turnId — return immediately.
            if let known = turnIdByKey[key] {
                return known
            }
            // (b) Decoded Step exists — check its kind.
            if let parentStep = stepsByKey[key] {
                if parentStep.kind == .prompt {
                    return parentStep.uuid
                }
                cursor = parentStep.parentUuid
                continue
            }
            // (c) Undecoded intermediate entry (attachment, ...) — hop on
            //     its parent link.
            if let parentLink = parentUuidByKey[key] {
                cursor = parentLink
                continue
            }
            // (d) Chain broken — orphan.
            break
        }
        return fallback
    }

    // MARK: - Orphan repair

    /// Orphan Turn = turnId == step.uuid AND step.kind != .prompt. After
    /// each ingest pass, re-resolve each orphan's parent chain and move
    /// the orphan into the real Turn if possible.
    private func repairOrphans(afterIngesting touchedSessions: [String]) -> Set<TurnKey> {
        let sessions = Set(touchedSessions)
        guard !sessions.isEmpty else { return [] }

        var repaired: Set<TurnKey> = []
        // Snapshot the touched sessions' turnIds.
        var candidateOrphans: [(sessionId: String, turnId: String)] = []
        for sessionId in sessions {
            guard let ids = turnIdsBySession[sessionId] else { continue }
            for turnId in ids {
                // turnId is the step's own uuid — check whether it's an orphan.
                let selfKey = StepKey(sessionId: sessionId, uuid: turnId)
                if let step = stepsByKey[selfKey], step.kind != .prompt {
                    candidateOrphans.append((sessionId, turnId))
                }
            }
        }

        for (sessionId, orphanTurnId) in candidateOrphans {
            let turnKey = TurnKey(sessionId: sessionId, turnId: orphanTurnId)
            guard let stepUuids = stepUuidsByTurnKey[turnKey] else { continue }
            guard let firstUuid = stepUuids.first,
                  let firstStep = stepsByKey[StepKey(sessionId: sessionId, uuid: firstUuid)] else { continue }

            // Re-resolve the chain via the shared walker (parent-link hops
            // included).
            let resolved = walkParentChain(
                startingFrom: firstStep.parentUuid,
                in: sessionId,
                fallback: orphanTurnId
            )
            if resolved == orphanTurnId { continue }
            let newRoot: String = resolved

            // Move every step from the orphan Turn to the newRoot Turn.
            let newTurnKey = TurnKey(sessionId: sessionId, turnId: newRoot)
            // newTurnKey may be absent from stepUuidsByTurnKey — this can
            // happen when the real prompt is registered but no Turn entry
            // exists yet. Default to an empty list to keep the merge safe.
            var targetList = stepUuidsByTurnKey[newTurnKey] ?? []
            turnIdsBySession[sessionId, default: []].insert(newRoot)

            for orphanedUuid in stepUuids {
                if targetList.contains(orphanedUuid) { continue }
                // Insert at the timestamp-sorted position.
                guard let step = stepsByKey[StepKey(sessionId: sessionId, uuid: orphanedUuid)] else { continue }
                var insertAt = targetList.count
                for i in 0..<targetList.count {
                    guard let existing = stepsByKey[StepKey(sessionId: sessionId, uuid: targetList[i])] else { continue }
                    if step.timestamp < existing.timestamp {
                        insertAt = i
                        break
                    }
                }
                targetList.insert(orphanedUuid, at: insertAt)
                turnIdByKey[StepKey(sessionId: sessionId, uuid: orphanedUuid)] = newRoot
            }
            stepUuidsByTurnKey[newTurnKey] = targetList

            // Drop the now-empty orphan Turn.
            stepUuidsByTurnKey.removeValue(forKey: turnKey)
            turnIdsBySession[sessionId]?.remove(orphanTurnId)
            repaired.insert(newTurnKey)
        }

        return repaired
    }

    // MARK: - Internal: Turn assembly

    /// Inserts a Step at its timestamp-sorted position.
    private func insertStep(_ step: Step, intoTurn turnId: String) {
        let turnKey = TurnKey(sessionId: step.sessionId, turnId: turnId)
        var list = stepUuidsByTurnKey[turnKey] ?? []
        if list.contains(step.uuid) { return }
        let ts = step.timestamp
        var insertAt = list.count
        for i in 0..<list.count {
            let existingKey = StepKey(sessionId: step.sessionId, uuid: list[i])
            guard let existing = stepsByKey[existingKey] else { continue }
            if ts < existing.timestamp {
                insertAt = i
                break
            }
        }
        list.insert(step.uuid, at: insertAt)
        stepUuidsByTurnKey[turnKey] = list
    }

    /// Assembles the `Turn` from the current step list for `turnId`.
    ///
    /// Hot path: called on every `turns(in:)` / `turnsBySession()`.
    /// Attachment resolution was originally inside this function and
    /// ran on every call — that made the main thread freeze on
    /// repeated Turn queries. Resolution is now a one-time pass at
    /// ingest (see `resolveAttachmentsIfNeeded`), so `buildTurn` is
    /// back to what it used to do before the attachment feature:
    /// compactMap Steps and wrap them in a `Turn`.
    private func buildTurn(sessionId: String, turnId: String, isInterrupted: Bool) -> Turn {
        let turnKey = TurnKey(sessionId: sessionId, turnId: turnId)
        let uuids = stepUuidsByTurnKey[turnKey] ?? []
        let steps = uuids.compactMap { stepsByKey[StepKey(sessionId: sessionId, uuid: $0)] }
        return Turn(id: turnId, sessionId: sessionId, steps: steps, isInterrupted: isInterrupted)
    }

    /// One-shot attachment resolve for a Step about to land in
    /// `stepsByKey`. Writes the resolved result into `stepsByKey`
    /// with `attachments` filled.
    ///
    /// Invoked from the three Step writers: (1) new entry ingest,
    /// (2) assistant-merge ingest, (3) `ingestSteps` bulk load. Each
    /// writer passes the Step value it's about to store; we replace
    /// it with the attachment-augmented copy before the write.
    private func resolvedStepForStorage(_ step: Step) -> Step {
        let toolNameByUseId = toolNameByUseIdBySession[step.sessionId] ?? [:]
        var diagnostics: [String] = []
        let refs = AttachmentResolver.resolve(
            step: step,
            toolNameByUseId: toolNameByUseId,
            diagnostics: &diagnostics
        )
        for toolName in diagnostics {
            let (inserted, _) = unknownAttachmentToolNames.insert(toolName)
            if inserted {
                LoggerService.shared.logFromAnyThread(
                    .warning,
                    "AttachmentResolver didn't find paths/URLs for tool '\(toolName)' — possible new input shape",
                    context: "AttachmentResolver"
                )
            }
        }
        return AttachmentResolver.withAttachments(step, refs)
    }

    /// Records a Step's raw `stop_reason` in the first-seen set when
    /// the typed `stopReasonKind` is nil but the raw string is
    /// non-empty — i.e. Claude emitted a stop_reason Lupen's enum
    /// doesn't know. `AppStateStore` drains the set after each parse
    /// pass and turns each distinct value into one `unknownStopReason`
    /// warning in `ParseDiagnostics`.
    private func recordUnknownStopReasonIfNeeded(in step: Step) {
        guard step.stopReasonKind == nil,
              let raw = step.stopReason,
              !raw.isEmpty else { return }
        unknownStopReasonRawValues.insert(raw)
    }
}
