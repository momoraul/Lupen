import Foundation

/// Wires up the two periodic background tasks the statusline subsystem
/// needs after launch:
///
/// - **Health check** (every 5 min): re-runs `loadIncrementally` +
///   `refreshState`. When the derived state lands on `.drifted`
///   (Lupen.app moved or wrapper's `LUPEN_BIN` no longer matches), the
///   scheduler auto-heals by rewriting the wrapper script. broken /
///   never-connected states are left alone — those need user action.
///
/// - **Daily retention sweep** (every 24 h): drops samples older than
///   `RateLimitSampleStore.retentionDays` so the JSONL log doesn't
///   grow unbounded across long-running Lupen sessions. The launch
///   path already runs one sweep — this keeps the file trimmed during
///   sessions that span multiple days.
///
/// Owned by `AppDelegate`. Tests can construct it directly with custom
/// intervals to exercise the loop body without sleeping.
@MainActor
final class StatuslineMaintenanceScheduler {

    /// Default cadence — 5 min for health, 24 h for retention. Production
    /// uses these; tests inject smaller values. `nonisolated` so the
    /// init's default-arg expression doesn't drag main-actor isolation.
    nonisolated static let defaultHealthCheckInterval: TimeInterval = 5 * 60
    nonisolated static let defaultRetentionSweepInterval: TimeInterval = 24 * 60 * 60

    private let service: StatuslineConnectionService
    private let sampleStore: RateLimitSampleStore
    private let healthCheckInterval: TimeInterval
    private let retentionSweepInterval: TimeInterval

    private var healthTimer: Timer?
    private var retentionTimer: Timer?

    init(
        service: StatuslineConnectionService,
        sampleStore: RateLimitSampleStore,
        healthCheckInterval: TimeInterval = StatuslineMaintenanceScheduler.defaultHealthCheckInterval,
        retentionSweepInterval: TimeInterval = StatuslineMaintenanceScheduler.defaultRetentionSweepInterval
    ) {
        self.service = service
        self.sampleStore = sampleStore
        self.healthCheckInterval = healthCheckInterval
        self.retentionSweepInterval = retentionSweepInterval
    }

    /// Start both timers. Safe to call once after launch; subsequent
    /// calls reset the schedule (tests rely on this for re-arming with
    /// fresh intervals).
    func start() {
        stop()
        healthTimer = Timer.scheduledTimer(
            withTimeInterval: healthCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runHealthCheck()
            }
        }
        retentionTimer = Timer.scheduledTimer(
            withTimeInterval: retentionSweepInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runRetentionSweep()
            }
        }
    }

    /// Cancel both timers. AppDelegate owns this scheduler for the
    /// app's lifetime so `stop()` is mainly used by tests.
    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
    }

    // MARK: - Tick bodies (exposed for tests)

    /// Pull any new samples from disk, recompute connection state, and
    /// auto-heal `.drifted` if detected. Intended to be cheap enough
    /// that a 5-min cadence is invisible in process activity.
    func runHealthCheck() async {
        await sampleStore.loadIncrementally()
        service.refreshState()
        service.syncSamplePrefsFromStore()
        if case .drifted = service.state {
            service.healDrift()
        }
    }

    /// Drop samples older than the retention window. Equivalent to the
    /// one-shot sweep AppDelegate runs at launch — wrapping it in a
    /// repeating timer keeps long-running sessions trimmed.
    func runRetentionSweep() async {
        await sampleStore.runRetentionSweep()
    }
}
