import Foundation

/// Launch progress observation state for the SQLite-first startup
/// (plan 3.6): metadata scan, then background detail indexing.
///
/// ## Phase transitions
///
/// ```
/// idle
///  └── scanningFiles          (metadata scan: shells + source registry)
///       ├── indexing          (scan queued N atomic units; imports drain)
///       │    └── done
///       └── done              (nothing queued AND coverage complete)
/// ```
///
/// `idle` = launch path not yet entered. `done` = terminal — signal for
/// the UI to hide the progress view. A rescan that queues nothing new
/// while units are still in flight stays in `.indexing` (the driver
/// also requires complete coverage before flipping to `.done`).
///
/// The legacy snapshot/incremental phases (`loadingSnapshot`,
/// `applyingIncremental`, `fullReparseFallback`) died with the caches
/// they reported on (plan 5.1/5.3); progress is unit-counted, never
/// byte-counted.
///
/// ## Threading
///
/// Value-type struct. `AppStateStore` holds it as `var launchProgress`
/// (@Observable); only the startup driver mutates it, on the main actor.
struct LaunchProgress: Sendable, Equatable {

    enum Phase: String, Codable, Sendable, Equatable, CaseIterable {
        case idle
        case scanningFiles
        /// Metadata scan done, scoped detail imports draining in the
        /// background. Progress is unit-counted (sessions).
        case indexing
        case done
    }

    // MARK: - State

    var phase: Phase = .idle

    /// SQLite-first detail-import coverage (`.indexing` phase): atomic
    /// units queued by the metadata scan vs units imported so far.
    var pendingUnits: Int = 0
    var processedUnits: Int = 0

    /// Time the current phase was entered. Callers must reset this on
    /// every phase transition.
    var startedAt: Date = Date()

    // MARK: - Derived

    /// Unit-counted fraction for `.indexing`; 0 elsewhere (signals the
    /// bar to render indeterminate / hide).
    var fraction: Double {
        guard phase == .indexing, pendingUnits > 0 else { return 0 }
        return max(0, min(1.0, Double(processedUnits) / Double(pendingUnits)))
    }

    /// Phase + numeric context, ready to render in the UI.
    var humanSummary: String {
        switch phase {
        case .idle, .done:
            return ""
        case .scanningFiles:
            return "Scanning session files…"
        case .indexing:
            guard pendingUnits > 0 else { return "Indexing sessions…" }
            return "Indexing sessions — \(processedUnits) of \(pendingUnits) imported"
        }
    }

    // MARK: - Transitions (helpers for callers)

    /// Fresh state at a new phase. Convenience factory so call sites
    /// don't forget to reset `startedAt`.
    static func transition(to phase: Phase, now: Date = Date()) -> LaunchProgress {
        var p = LaunchProgress()
        p.phase = phase
        p.startedAt = now
        return p
    }
}
