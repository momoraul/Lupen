import Foundation
import QuartzCore

/// Phase 8.3 — derives the "what should animate" set from two snapshots
/// of an outline view's row identity, applying throttle / cooldown /
/// hard-cap policy. Pure function so the policy is unit-testable
/// without spinning up an `NSOutlineView`.
///
/// Caller flow:
///   1. Build a `Snapshot` from the about-to-render row identifiers.
///   2. Call `diff(previous:current:recent:policy:)` → list of triggers.
///   3. After consuming the triggers (e.g. enqueueing CAAnimations on
///      the matching `LupenAnimatedRowView`s), update the `Recent` record
///      with each trigger's start time so the next cycle's throttle has
///      the right state.
///
/// Spec sources:
///   - UX brief: §3 throttle policy, §5 scope, §7 testability seam.
///   - HIG / Motion: subtle animations should suppress under high
///     event frequency rather than strobe.
enum AppearanceDiffEngine {

    /// Snapshot of an outline view's visible row identity at one
    /// reload boundary. The engine compares two of these and emits the
    /// transitions worth animating.
    ///
    /// `orderedIDs` carries the canonical display order — index in this
    /// array is what the engine compares for reorder detection.
    /// `parentByID` lets the engine bucket throttle by parent (e.g. all
    /// new Steps under the same Turn share a 400 ms cooldown). Top-
    /// level rows (Turns, Sessions) have no parent — pass `nil` for
    /// those entries.
    ///
    /// `timestamp` is the `current` snapshot's wall clock at the moment
    /// `diff` is called. The engine uses it as "now" for cooldown
    /// arithmetic. Use `CACurrentMediaTime()` in production; tests can
    /// inject a fixed value for determinism.
    struct Snapshot: Equatable, Sendable {
        let orderedIDs: [String]
        let parentByID: [String: String]
        let timestamp: CFTimeInterval

        static let empty = Snapshot(orderedIDs: [], parentByID: [:], timestamp: 0)

        init(
            orderedIDs: [String],
            parentByID: [String: String] = [:],
            timestamp: CFTimeInterval
        ) {
            self.orderedIDs = orderedIDs
            self.parentByID = parentByID
            self.timestamp = timestamp
        }
    }

    /// Per-cycle history the engine reads but does not mutate. The VC
    /// owns these dictionaries and updates them after consuming the
    /// engine's output.
    ///
    /// `lastAppearByParent` — parent id → wall clock of the most
    /// recent `appeared` trigger that fired under this parent. Top-
    /// level rows share the synthetic key `<root>`.
    ///
    /// `lastReorderById` — id → wall clock of the most recent
    /// `reordered` trigger that fired for this row.
    struct Recent: Equatable, Sendable {
        var lastAppearByParent: [String: CFTimeInterval]
        var lastReorderById: [String: CFTimeInterval]

        init(
            lastAppearByParent: [String: CFTimeInterval] = [:],
            lastReorderById: [String: CFTimeInterval] = [:]
        ) {
            self.lastAppearByParent = lastAppearByParent
            self.lastReorderById = lastReorderById
        }

        static let empty = Recent()
    }

    /// Tunables. Defaults match the UX spec for production.
    struct Policy: Equatable, Sendable {
        /// Within this window, all `appeared` rows under the same parent
        /// share a single fade-in start time (visual coalescing into one
        /// sweep). Outside the window, the next arrival starts a new
        /// burst. UX spec §3 — 400 ms.
        var perParentCoalesceMs: Int = 400

        /// Within this window, repeat `reordered` triggers on the same
        /// id are silently dropped. Active streaming sessions get
        /// bumped to the top continuously; without this rule the
        /// sidebar would pulse non-stop. UX spec §3 — 2000 ms.
        var perIDReorderCooldownMs: Int = 2000

        /// Hard ceiling on triggers per cycle. Bulk operations (initial
        /// import, large reparse) would otherwise paint half the
        /// viewport simultaneously and the user would read it as a
        /// re-render flash, not as item arrivals. UX spec §3 — 12.
        var maxPerCycle: Int = 12

        /// When `previous.orderedIDs.isEmpty`, treat the whole current
        /// snapshot as the cold-start baseline and emit nothing. UX
        /// spec §5 — initial load suppression.
        var suppressOnEmptyPrevious: Bool = true

        static let production = Policy()
    }

    /// One animation request. The view layer decides the visual style
    /// (color / curve / duration) based on `kind`; the engine's job is
    /// just to identify the row + classify the change.
    enum Trigger: Equatable, Sendable {
        case appeared(id: String, parentId: String?, syncStart: CFTimeInterval)
        case reordered(id: String, parentId: String?)

        var id: String {
            switch self {
            case .appeared(let id, _, _): return id
            case .reordered(let id, _): return id
            }
        }
    }

    /// Computes the trigger set. `recent` is read-only here — the VC
    /// must merge the resulting trigger timestamps back into its own
    /// `Recent` record after consuming the output, so the next call has
    /// the up-to-date cooldown state.
    /// Computes the trigger set with optional **collapsed-parent
    /// translation**. When a child row's nearest visible ancestor is
    /// hidden under a collapsed disclosure (e.g., a Step under a
    /// collapsed Turn header), the engine rewrites the trigger to
    /// target that ancestor instead — and deduplicates so multiple
    /// hidden siblings translate to a single ancestor trigger. This
    /// makes the parent header pulse "something updated below" while
    /// the child rows themselves remain hidden.
    ///
    /// `collapsedParents` is the set of ids whose disclosure is
    /// **collapsed**. When the caller passes the full hierarchy in
    /// `current.orderedIDs` (visible OR potentially-visible) plus a
    /// complete `parentByID` chain, the engine walks each new id's
    /// chain upward and stops at the first ancestor NOT in this set.
    /// The trigger fires on that ancestor (deduplicated by id).
    ///
    /// Pass an empty set (default) for the legacy "everything is
    /// visible" behaviour.
    static func diff(
        previous: Snapshot,
        current: Snapshot,
        recent: Recent,
        policy: Policy = .production,
        collapsedParents: Set<String> = []
    ) -> [Trigger] {
        // Cold start — caller's first reload after construction. Every
        // row looks "new" relative to the empty baseline, but flashing
        // hundreds of rows on window-open is exactly the noise the
        // spec exists to prevent.
        if policy.suppressOnEmptyPrevious && previous.orderedIDs.isEmpty {
            return []
        }

        let previousIDs = Set(previous.orderedIDs)
        let currentIDs = Set(current.orderedIDs)

        // Reorder detection works on **relative** positions among
        // survivors (ids present in both snapshots), not absolute
        // indices. Two cycles where surviving ids keep the same
        // relative order — even if absolute indices shift because of
        // removals or appears — produce zero reorders. Without this
        // rule, removing one row would cascade-flash every row
        // beneath it ("they all moved up by one"), which the UX spec
        // explicitly calls out as noise.
        let survivorsCurrent = current.orderedIDs.filter { previousIDs.contains($0) }
        let survivorsPrevious = previous.orderedIDs.filter { currentIDs.contains($0) }

        var prevRelativeIdxByID: [String: Int] = [:]
        prevRelativeIdxByID.reserveCapacity(survivorsPrevious.count)
        for (idx, id) in survivorsPrevious.enumerated() {
            prevRelativeIdxByID[id] = idx
        }
        var currRelativeIdxByID: [String: Int] = [:]
        currRelativeIdxByID.reserveCapacity(survivorsCurrent.count)
        for (idx, id) in survivorsCurrent.enumerated() {
            currRelativeIdxByID[id] = idx
        }

        var triggers: [Trigger] = []
        triggers.reserveCapacity(min(policy.maxPerCycle, current.orderedIDs.count))
        // Track which visible-ancestor ids have already received a
        // translated trigger this cycle. Lets us count hard-cap
        // budget against *visible* effects rather than raw children.
        var emittedVisibleIDs: Set<String> = []

        // ── Appeared pass ───────────────────────────────────────────
        // Iterate `current.orderedIDs` so triggers come out in display
        // order — this also keeps the per-parent coalesce timestamp
        // consistent with what the user sees scroll into view first.
        var perParentSyncStart: [String: CFTimeInterval] = [:]
        for id in current.orderedIDs {
            guard !previousIDs.contains(id) else { continue }
            let parentId = current.parentByID[id]
            let parentKey = parentId ?? Self.rootKey

            // Synchronization rule (UX spec §3): if this parent had a
            // recent appeared trigger inside the coalesce window, share
            // its start time so multiple rows under the same parent
            // fade together in one visual sweep. Otherwise begin a new
            // burst at `current.timestamp`.
            let syncStart: CFTimeInterval
            if let recentParent = recent.lastAppearByParent[parentKey],
               (current.timestamp - recentParent) * 1000.0 < Double(policy.perParentCoalesceMs) {
                // Within window of the previously-recorded burst.
                syncStart = recentParent
            } else if let perCycleStart = perParentSyncStart[parentKey] {
                // Within this same cycle, an earlier sibling already
                // claimed a start time — share it so siblings burst
                // together even though `recent` from the prior cycle
                // is too old.
                syncStart = perCycleStart
            } else {
                syncStart = current.timestamp
                perParentSyncStart[parentKey] = syncStart
            }

            // Translate to nearest visible ancestor when appropriate.
            // Hidden children (parent is collapsed) re-target the
            // ancestor row; visible children pass through unchanged.
            let visibleId = collapsedParents.isEmpty
                ? id
                : Self.climbToVisibleAncestor(
                    id,
                    parentByID: current.parentByID,
                    collapsedParents: collapsedParents
                )
            // Dedup: multiple hidden siblings that climb to the same
            // ancestor produce a single trigger on that ancestor. The
            // first child's syncStart wins (display-order iteration
            // gives the topmost child priority).
            guard emittedVisibleIDs.insert(visibleId).inserted else { continue }

            let visibleParentId = visibleId == id
                ? parentId
                : current.parentByID[visibleId]
            triggers.append(.appeared(id: visibleId, parentId: visibleParentId, syncStart: syncStart))
            if triggers.count >= policy.maxPerCycle { break }
        }

        // ── Reordered pass ──────────────────────────────────────────
        // Only run if the appear pass left budget — bulk-import cycles
        // could otherwise consume the whole cap with appears and let
        // genuine reorders silently pass through.
        if triggers.count < policy.maxPerCycle {
            // Sort by current display position so the top of the
            // viewport is preferred when the hard cap kicks in.
            let reordered = currentIDs.intersection(previousIDs)
                .compactMap { id -> (String, Int)? in
                    guard let from = prevRelativeIdxByID[id],
                          let to = currRelativeIdxByID[id],
                          from != to else { return nil }
                    return (id, to)
                }
                .sorted { $0.1 < $1.1 }

            for (id, _) in reordered {
                let lastReorder = recent.lastReorderById[id] ?? -.infinity
                let elapsedMs = (current.timestamp - lastReorder) * 1000.0
                if elapsedMs < Double(policy.perIDReorderCooldownMs) {
                    continue
                }
                // Reorders also climb to visible ancestor under
                // collapsed disclosures — a hidden row's position
                // change inside its hidden context isn't user-visible,
                // but bubbles up to "container changed" on the header.
                let visibleId = collapsedParents.isEmpty
                    ? id
                    : Self.climbToVisibleAncestor(
                        id,
                        parentByID: current.parentByID,
                        collapsedParents: collapsedParents
                    )
                guard emittedVisibleIDs.insert(visibleId).inserted else { continue }
                let visibleParentId = visibleId == id
                    ? current.parentByID[id]
                    : current.parentByID[visibleId]
                triggers.append(.reordered(id: visibleId, parentId: visibleParentId))
                if triggers.count >= policy.maxPerCycle { break }
            }
        }

        return triggers
    }

    /// Walk `parentByID` upward starting from `id` until we find an
    /// id whose parent is NOT in `collapsedParents` (or whose chain
    /// runs out, meaning we've reached a top-level row). That
    /// ancestor is the nearest visible row in the disclosure
    /// hierarchy and the appropriate target for a translated
    /// animation trigger. Cycle-guarded.
    static func climbToVisibleAncestor(
        _ id: String,
        parentByID: [String: String],
        collapsedParents: Set<String>
    ) -> String {
        var cursor = id
        var visited: Set<String> = [id]
        while let parent = parentByID[cursor], collapsedParents.contains(parent) {
            if visited.contains(parent) { return cursor }  // cycle guard
            visited.insert(parent)
            cursor = parent
        }
        return cursor
    }

    /// Synthetic parent key for top-level rows (Sessions in the
    /// sidebar; Turns in the conversation outline). Distinct from any
    /// real id by the angle-bracket guard.
    static let rootKey = "<root>"
}
