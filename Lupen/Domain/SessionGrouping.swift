import Foundation

/// Pure utility for grouping sessions by `projectPath`. Kept independent
/// of `AppStateStore` so the rules stay unit-testable; the
/// `SessionListViewController` consumes the output directly.
enum SessionGrouping {

    struct Group {
        /// Raw `session.projectPath` (encoded directory name). Sessions
        /// with `projectPath == nil` share the `""` key and land in the
        /// "Unknown" group.
        let key: String
        let label: String
        let sessions: [Session]
    }

    /// Group sessions by project.
    ///
    /// Rules:
    /// 1. Same `projectPath` → same group.
    /// 2. `projectPath == nil` collapses into a single `""` / "Unknown"
    ///    group.
    /// 3. Within a group, sort by **endTime DESC** (most recent activity
    ///    first; nil → `.distantPast`). endTime not startTime: a long-
    ///    running session that streamed seconds ago should outrank a
    ///    short session that started 5 minutes ago, matching Mail/Xcode
    ///    intuition.
    /// 4. Group order is "most recent endTime in group" DESC, except
    ///    "Unknown" is always pinned to the bottom so real projects
    ///    surface first.
    /// 5. Empty input → empty output.
    static func groupByProject(_ sessions: [Session]) -> [Group] {
        guard !sessions.isEmpty else { return [] }

        var buckets: [String: [Session]] = [:]
        for session in sessions {
            let key = session.projectPath ?? ""
            buckets[key, default: []].append(session)
        }

        let sortedBuckets: [(key: String, sessions: [Session])] = buckets.map { (key, list) in
            let sortedList = list.sorted { a, b in
                let ta = a.endTime ?? .distantPast
                let tb = b.endTime ?? .distantPast
                return ta > tb
            }
            return (key: key, sessions: sortedList)
        }

        // Unknown is pulled out so it can be appended last.
        let namedBuckets = sortedBuckets.filter { $0.key != "" }
        let unknownBucket = sortedBuckets.first(where: { $0.key == "" })

        let orderedNamed = namedBuckets.sorted { a, b in
            let ta = a.sessions.first?.endTime ?? .distantPast
            let tb = b.sessions.first?.endTime ?? .distantPast
            return ta > tb
        }

        var result: [Group] = orderedNamed.map { bucket in
            Group(
                key: bucket.key,
                label: ProjectLabelFormatter.decode(bucket.key),
                sessions: bucket.sessions
            )
        }
        if let unknown = unknownBucket {
            result.append(Group(
                key: "",
                label: "Unknown",
                sessions: unknown.sessions
            ))
        }
        return result
    }

    /// Flat 1-depth ordering used by the sidebar's Flat layout mode.
    ///
    /// Rules (top → bottom):
    /// 1. Sessions whose id is in `pinnedIds` come first, regardless of
    ///    endTime.
    /// 2. Within pinned and within unpinned, endTime DESC (most recent
    ///    activity first). Sessions with `endTime == nil` treat as
    ///    `.distantPast` so they sink to the bottom of their partition.
    ///
    /// Pure, stable, and keyed only on the two inputs — lets the sidebar
    /// observation guard cheaply compare "what the last render saw" against
    /// "what this render would produce" via a fingerprint of pinned ids +
    /// session endTimes.
    static func flatSorted(
        _ sessions: [Session],
        pinnedIds: Set<String> = []
    ) -> [Session] {
        guard !sessions.isEmpty else { return [] }
        return sessions.sorted { a, b in
            let pa = pinnedIds.contains(a.id)
            let pb = pinnedIds.contains(b.id)
            if pa != pb { return pa }  // pinned sessions precede unpinned
            let ta = a.endTime ?? .distantPast
            let tb = b.endTime ?? .distantPast
            return ta > tb
        }
    }
}
