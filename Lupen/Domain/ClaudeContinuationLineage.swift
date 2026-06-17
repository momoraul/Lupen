import Foundation

/// Resolves Claude Code compact / resume lineages by requestId sharing.
///
/// When a session hits the context limit and `/compact` runs — or the user
/// runs `--resume` (a session fork) — Claude Code writes a **new session
/// file** that replays the prior transcript verbatim, including every
/// billable `requestId`, then continues. So the SAME requestId appears in
/// several session files. `requests.id` is a global key (one row per
/// billable request, so `SUM(requests)` single-counts), which means the
/// shared requestId lands under whichever file imported first — leaving
/// the other sessions' per-session views undercounted and Verify Costs
/// red with "missing billable requestId".
///
/// `/compact` records a `logicalParentUuid`; `--resume` records **none** —
/// yet both replay the same requestIds. So lineage is detected here purely
/// by **requestId-set sharing**, never by that marker. Each requestId is
/// assigned a single canonical owner (the highest-ranked session carrying
/// it: most billable requests, then latest endTime, then rawId). A session
/// that owns none of its requestIds is a pure replay and is hidden;
/// partial branches keep their own requests and stay visible.
///
/// The same pure resolution feeds both the importer side (re-home requests
/// to their owner, hide pure replays) and the independent ground-truth
/// verifier (attribute each line to its canonical owner), so the stored
/// view and the check attribute every requestId identically and agree.
enum ClaudeContinuationLineage {

    /// One session's facts the resolver needs. `requestIds` is the set of
    /// billable request ids the session's file carries (dedup happens
    /// upstream). Rank uses only the set size and rawId — no timestamp — so
    /// the DB side and the ground-truth side compute an identical owner map
    /// from data they both have exactly, with no date-parsing in the path.
    struct SessionInput: Equatable {
        let rawId: String
        let logicalParentUuid: String?
        let requestIds: Set<String>

        init(
            rawId: String,
            logicalParentUuid: String?,
            requestIds: Set<String>
        ) {
            self.rawId = rawId
            self.logicalParentUuid = logicalParentUuid
            self.requestIds = requestIds
        }
    }

    struct Resolution: Equatable {
        /// rawIds to hide from the session list (`visible = false`) —
        /// sessions that own none of their requestIds because every one
        /// belongs to a higher-ranked session that replayed it.
        let hidden: Set<String>
        /// Every session's canonical leaf rawId (self when visible).
        let canonicalByRawId: [String: String]
        /// Canonical owner rawId for each requestId carried by **more than
        /// one** session (a replay). Non-shared requestIds are implicitly
        /// owned by their only session and omitted. Drives the per-request
        /// re-home so each owner's stored view equals its ground-truth.
        let ownerByRequestId: [String: String]
        /// Every session that carries at least one shared requestId — the
        /// re-home changes these sessions' request rows, so their costs must
        /// be re-finalized (long-context pricing is session-scoped).
        let affectedRawIds: Set<String>
    }

    /// Pure resolution. Deterministic and order-independent.
    ///
    /// Lineage is detected purely by **requestId-set sharing** — never by
    /// `logicalParentUuid`. `/compact` writes that marker but `--resume` (a
    /// session fork) does not, even though both replay the prior
    /// transcript's requestIds verbatim into a new session file. Keying on
    /// the marker silently missed every resume/fork lineage. Each requestId
    /// is owned by the highest-ranked session whose file carries it; a
    /// session left owning none of its requestIds is a redundant snapshot
    /// and is hidden, its requests re-homed to the owner.
    static func resolve(_ sessions: [SessionInput]) -> Resolution {
        // Inverted index: which sessions carry each requestId.
        var carriersByRequest: [String: [SessionInput]] = [:]
        for session in sessions {
            for rid in session.requestIds {
                carriersByRequest[rid, default: []].append(session)
            }
        }

        // Canonical owner per SHARED requestId = its highest-ranked carrier.
        var ownerByRequestId: [String: String] = [:]
        var affectedRawIds: Set<String> = []
        for (rid, carriers) in carriersByRequest where carriers.count > 1 {
            if let owner = carriers.max(by: { rank($0) < rank($1) }) {
                ownerByRequestId[rid] = owner.rawId
            }
            for carrier in carriers { affectedRawIds.insert(carrier.rawId) }
        }

        // Per session: if it owns at least one of its requestIds it stays
        // visible; otherwise it is a pure replay → hidden, with its leaf =
        // the highest-ranked session among the owners of its requestIds.
        let rankByRawId = Dictionary(
            sessions.map { ($0.rawId, rank($0)) }, uniquingKeysWith: { first, _ in first }
        )
        var hidden: Set<String> = []
        var canonical: [String: String] = [:]
        for session in sessions {
            var ownsAny = false
            var leaf = session.rawId
            var leafRank = rank(session)
            for rid in session.requestIds {
                let owner = ownerByRequestId[rid] ?? session.rawId
                if owner == session.rawId {
                    ownsAny = true
                } else if let ownerRank = rankByRawId[owner], ownerRank > leafRank {
                    leafRank = ownerRank
                    leaf = owner
                }
            }
            if !session.requestIds.isEmpty && !ownsAny {
                hidden.insert(session.rawId)
                canonical[session.rawId] = leaf
            } else {
                canonical[session.rawId] = session.rawId
            }
        }

        return Resolution(
            hidden: hidden,
            canonicalByRawId: canonical,
            ownerByRequestId: ownerByRequestId,
            affectedRawIds: affectedRawIds
        )
    }

    /// Convenience: just the hidden set.
    static func hiddenRawIds(_ sessions: [SessionInput]) -> Set<String> {
        resolve(sessions).hidden
    }

    /// Total order for owner selection: more requests wins; ties break to
    /// the larger rawId. Both are derived identically on the DB and
    /// ground-truth sides, so the owner map can't diverge on a tiebreak.
    private static func rank(_ session: SessionInput) -> (Int, String) {
        (session.requestIds.count, session.rawId)
    }

    // MARK: - File-backed resolution (shared by import + ground truth)

    /// Reads the billable requestId set + `logicalParentUuid` straight from
    /// the session JSONL files and resolves. Both the import-side
    /// visibility pass and the independent ground-truth verifier call this
    /// with the same files for a lineage, so they reach the identical
    /// hidden set — the view and the check can't disagree.
    ///
    /// `rawIdForURL` maps a file URL back to its session raw id (the
    /// filename stem by default). Files that can't be read are skipped.
    static func resolveFiles(
        _ files: [URL],
        rawIdForURL: (URL) -> String = { $0.deletingPathExtension().lastPathComponent }
    ) -> Resolution {
        let inputs: [SessionInput] = files.compactMap { url in
            guard let scan = scanFile(url) else { return nil }
            return SessionInput(
                rawId: rawIdForURL(url),
                logicalParentUuid: scan.logicalParentUuid,
                requestIds: scan.requestIds
            )
        }
        return resolve(inputs)
    }

    /// Per-file billable facts. `requestIds` mirrors the ground-truth
    /// definition (assistant entries carrying a `usage` block; requestId,
    /// or uuid when absent). Strict-UTF8 read parity with
    /// `GroundTruthCalculator` so both see the same lines.
    struct FileScan: Equatable {
        let logicalParentUuid: String?
        let requestIds: Set<String>
    }

    static func scanFile(_ url: URL) -> FileScan? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var logicalParentUuid: String?
        var requestIds: Set<String> = []

        for raw in content.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if logicalParentUuid == nil, let lpu = obj["logicalParentUuid"] as? String {
                logicalParentUuid = lpu
            }
            // Sidechain (subagent) requests belong to the parent and are
            // excluded so they don't inflate a parent's owner rank — must
            // match `request_membership`, which also excludes them.
            guard (obj["type"] as? String) == "assistant",
                  (obj["isSidechain"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any],
                  message["usage"] != nil
            else { continue }

            let rid = (obj["requestId"] as? String) ?? (obj["uuid"] as? String)
            if let rid { requestIds.insert(rid) }
        }
        return FileScan(logicalParentUuid: logicalParentUuid, requestIds: requestIds)
    }
}
