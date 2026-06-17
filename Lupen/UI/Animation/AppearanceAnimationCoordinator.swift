import Foundation
import QuartzCore

/// Phase 8.3 — per-VC adapter that owns the diff state for an
/// `NSOutlineView` and dispenses triggers to the row-view factory.
/// One coordinator per outline view: the sidebar, the conversation
/// outline, the dropdown popover (if ever wired) each construct their
/// own.
///
/// Lifecycle inside a `reloadData()`:
///
///   1. VC builds the new tree (existing logic, untouched).
///   2. VC calls `prepare(orderedIDs:parentByID:)` with the *visible*
///      row identities in display order. Coordinator computes triggers
///      via `AppearanceDiffEngine` against the previous snapshot,
///      updates its `recent` cooldown record, and stores the triggers
///      in a per-id pending map (wiping the prior cycle's leftovers).
///   3. VC calls `outlineView.reloadData()`. AppKit marks the table
///      dirty but does NOT synchronously create row views — that
///      happens on the next display pass on the runloop.
///   4. Display pass — AppKit invokes `rowView(for:)` for every
///      visible row. Inside `rowView(for:)` the VC asks `consume(id:)`
///      — if a trigger is queued for this row, the row view schedules
///      its CAAnimation.
///   5. Drainage of unmatched triggers is implicit: the next call to
///      `prepare(...)` wipes the pending map. Any rows that scrolled
///      into view between two reload cycles get to consume their
///      trigger when AppKit finally asks for their row view, which is
///      consistent with "this row just arrived" UX.
///
/// The coordinator is `@MainActor` because every consumer is. The
/// `now` injection seam lets tests hand in a fixed clock — the
/// engine's diff is a pure function and the coordinator does no I/O.
@MainActor
final class AppearanceAnimationCoordinator {

    private var lastSnapshot: AppearanceDiffEngine.Snapshot
    private var recent: AppearanceDiffEngine.Recent
    private var pendingTriggersByID: [String: AppearanceDiffEngine.Trigger]
    private let policy: AppearanceDiffEngine.Policy
    private let now: () -> CFTimeInterval

    init(
        policy: AppearanceDiffEngine.Policy = .production,
        now: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }
    ) {
        self.lastSnapshot = .empty
        self.recent = .empty
        self.pendingTriggersByID = [:]
        self.policy = policy
        self.now = now
    }

    /// Compute triggers for the upcoming reload. Call BEFORE
    /// `outlineView.reloadData()` so the per-id map is populated when
    /// AppKit asks for row views.
    ///
    /// `orderedIDs` should contain only the rows that participate in
    /// the animation system — top-level + expanded children of
    /// animatable categories. Categories the spec excludes (project
    /// group headers in the sidebar; skillGroup / subAgent in the
    /// outline) must NOT be in this list, otherwise their identifiers
    /// would consume budget against the hard cap and starve the
    /// rows we actually want to highlight.
    ///
    /// `parentByID` is consulted for `appeared` coalescing — siblings
    /// under the same parent share a sync start. For top-level rows
    /// pass nothing (the engine substitutes its `<root>` synthetic key).
    ///
    /// `collapsedParents` enables the **rollup-to-ancestor** policy:
    /// when callers include hidden descendants in `orderedIDs` (e.g.,
    /// Step ids under a collapsed Turn header) and mark the hiding
    /// ancestor as collapsed, the engine translates the descendant's
    /// trigger up to the ancestor (deduplicated). The visible row
    /// then animates "something updated below". Pass an empty set
    /// (default) to keep the legacy "every id in orderedIDs is
    /// visible" behaviour.
    func prepare(
        orderedIDs: [String],
        parentByID: [String: String] = [:],
        collapsedParents: Set<String> = []
    ) {
        let snapshot = AppearanceDiffEngine.Snapshot(
            orderedIDs: orderedIDs,
            parentByID: parentByID,
            timestamp: now()
        )
        let triggers = AppearanceDiffEngine.diff(
            previous: lastSnapshot,
            current: snapshot,
            recent: recent,
            policy: policy,
            collapsedParents: collapsedParents
        )
        // Merge selected start / cooldown timestamps into `recent` so
        // the next cycle's diff sees the up-to-date throttle state.
        // The engine returned the chosen `syncStart` per appear so we
        // record exactly that — this is what makes the coalesce
        // window slide forward as bursts continue.
        for trigger in triggers {
            switch trigger {
            case .appeared(_, let parentId, let syncStart):
                let key = parentId ?? AppearanceDiffEngine.rootKey
                recent.lastAppearByParent[key] = syncStart
            case .reordered(let id, _):
                recent.lastReorderById[id] = snapshot.timestamp
            }
        }
        lastSnapshot = snapshot
        // Replace, never merge — last cycle's unconsumed triggers
        // already had their chance during the prior reloadData; if
        // they weren't drained then, they're stale by now.
        pendingTriggersByID.removeAll(keepingCapacity: true)
        for trigger in triggers {
            pendingTriggersByID[trigger.id] = trigger
        }
    }

    /// Drain (and remove) the pending trigger for a given row id.
    /// Called by the row-view factory inside `outlineView(_:rowViewForItem:)`.
    func consume(id: String) -> AppearanceDiffEngine.Trigger? {
        pendingTriggersByID.removeValue(forKey: id)
    }

    /// Reset the coordinator to an empty baseline — useful when the
    /// underlying data source is wiped (Rebuild Index) and the next
    /// reload should be treated as a fresh cold start.
    func reset() {
        lastSnapshot = .empty
        recent = .empty
        pendingTriggersByID.removeAll(keepingCapacity: true)
    }

    // MARK: - Test seams

    /// Read-only inspection of the queued trigger count. Tests use
    /// this to verify `prepare` populated the expected number of
    /// rows; production code never reads it.
    var pendingCountForTesting: Int { pendingTriggersByID.count }

    /// Read-only inspection of the prior snapshot identifiers. Tests
    /// use this to verify the cold-start path is engaged on the first
    /// `prepare` call.
    var lastSnapshotIDsForTesting: [String] { lastSnapshot.orderedIDs }
}

// MARK: - Style mapping

extension LupenAnimatedRowView.Style {
    /// Maps an engine trigger to the visual style appropriate for
    /// that row category. The trigger itself is category-agnostic
    /// (the engine sees only "id + parent"); the call site brings
    /// the category context.
    static func from(
        trigger: AppearanceDiffEngine.Trigger,
        isStreamingChild: Bool
    ) -> LupenAnimatedRowView.Style {
        switch trigger {
        case .appeared:
            return isStreamingChild ? .streamingAppear : .appear
        case .reordered:
            return .reorder
        }
    }
}

extension AppearanceDiffEngine.Trigger {
    /// `syncStart` for `.appeared`, `nil` for `.reordered` (reorders
    /// don't coalesce — each fires on its own clock).
    var syncStart: CFTimeInterval? {
        switch self {
        case .appeared(_, _, let s): return s
        case .reordered: return nil
        }
    }
}
