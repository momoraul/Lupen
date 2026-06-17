import Foundation
import Observation

/// Top-level orchestrator for Lupen's statusline integration. Holds the
/// derived `StatuslineConnectionState` plus convenience facades for the
/// patch service and sample store. UI surfaces (Settings tab, Dashboard
/// banner, menu-bar dropdown row) read this object via Observation and
/// stay in sync with whatever the user has configured on disk.
///
/// Recomputes state on:
///   * launch (`refreshState()` called once after init)
///   * Settings or Reports window opening
///   * sample-store changes (incremental load done elsewhere)
///   * explicit Connect / Disconnect / drift heal
///
/// The service does NOT install a background timer here — that's the
/// caller's responsibility (`AppDelegate` or a dedicated watchdog) so
/// tests can run deterministically.
@Observable
@MainActor
final class StatuslineConnectionService {

    /// Derived state. UI surfaces bind to this.
    private(set) var state: StatuslineConnectionState = .neverConnected

    /// Last time `refreshState()` ran successfully.
    private(set) var lastRefreshAt: Date?

    /// Detected chain target (the user's pre-existing statusline
    /// command) — exposed so the Connect sheet can pre-fill the
    /// "Keep my existing statusline" path field.
    private(set) var detectedChainTarget: String?

    let settings: AppSettings
    private let patchService: StatuslinePatchService
    let sampleStore: RateLimitSampleStore

    /// 24-hour stale threshold. Samples older than this transition the
    /// state from `.connectedActive` → `.connectedStale`.
    nonisolated static let staleThresholdSeconds: TimeInterval = 24 * 3600

    init(
        settings: AppSettings,
        patchService: StatuslinePatchService = StatuslinePatchService(),
        sampleStore: RateLimitSampleStore
    ) {
        self.settings = settings
        self.patchService = patchService
        self.sampleStore = sampleStore
    }

    // MARK: - Refresh

    /// Recompute `state` from the current on-disk facts plus the
    /// in-memory sample store.
    func refreshState(now: Date = Date()) {
        let settingsInspection = patchService.inspectSettings()
        let wrapperInspection = patchService.inspectWrapper()
        detectedChainTarget = detectExistingChainTarget(
            settingsInspection: settingsInspection
        )

        state = Self.derive(
            settings: settingsInspection,
            wrapper: wrapperInspection,
            connectedAt: settings.statuslinePrefs.connectedAt,
            lastSampleAt: sampleStore.lastSampleAt,
            now: now
        )
        lastRefreshAt = now
    }

    /// Pure derivation. Exposed `internal` so tests can drive every
    /// state directly without touching the file system. `nonisolated`
    /// because it's a pure function with no instance state — keeps
    /// tests free of `@MainActor` boilerplate.
    nonisolated static func derive(
        settings: StatuslinePatchService.SettingsInspection,
        wrapper: StatuslinePatchService.WrapperInspection,
        connectedAt: Date?,
        lastSampleAt: Date?,
        now: Date
    ) -> StatuslineConnectionState {
        // No prior connect attempt — neverConnected unless we somehow
        // observe the user manually wired up the wrapper.
        if connectedAt == nil {
            // If the user hand-installed our wrapper we still treat
            // them as connectedAwaitingFirst. Rare case; simpler than
            // a sixth state.
            if let cmd = settings.statusLineCommand,
               cmd.hasSuffix("lupen-statusline-tap.sh"),
               wrapper.exists {
                return .connectedAwaitingFirst
            }
            return .neverConnected
        }

        // Connected at some point. Triage the on-disk facts.
        guard settings.exists else {
            return .broken(reason: .settingsFileMissing)
        }
        guard settings.parses else {
            return .broken(reason: .settingsMalformed)
        }
        guard let cmd = settings.statusLineCommand,
              cmd.hasSuffix("lupen-statusline-tap.sh") else {
            return .broken(reason: .settingsNotPointingToWrapper)
        }
        guard wrapper.exists else {
            return .broken(reason: .wrapperMissing)
        }
        guard wrapper.executable else {
            return .broken(reason: .wrapperUnexecutable)
        }
        if !wrapper.lupenBinaryLineMatches {
            return .drifted
        }

        // Healthy plumbing. Are samples flowing?
        guard let lastSample = lastSampleAt else {
            return .connectedAwaitingFirst
        }
        if now.timeIntervalSince(lastSample) > Self.staleThresholdSeconds {
            return .connectedStale
        }
        return .connectedActive
    }

    private func detectExistingChainTarget(
        settingsInspection: StatuslinePatchService.SettingsInspection
    ) -> String? {
        // Priority 1: the chain target we already installed.
        if let chain = settingsInspection.chainCommand, !chain.isEmpty {
            return chain
        }
        // Priority 2: the user's previous statusLine.command if it's
        // not us. Used as a suggestion in the Connect sheet.
        if let cmd = settingsInspection.statusLineCommand,
           !cmd.hasSuffix("lupen-statusline-tap.sh") {
            return cmd
        }
        // Priority 3: well-known location.
        let conventional = StatuslinePaths.claudeConfigDirectory
            .appendingPathComponent("statusline.sh")
        if FileManager.default.fileExists(atPath: conventional.path) {
            return conventional.path
        }
        return nil
    }

    // MARK: - Connect / Disconnect

    /// Polling cadence + budget for the post-Connect "first sample"
    /// catcher. The user just clicked Connect — when Claude Code fires
    /// its next statusline trigger, we want the green dot to land in
    /// the Settings UI within a second instead of waiting for the user
    /// to close + reopen the window. 500ms × 60 ticks = 30s of polling
    /// after Connect; if no sample arrives in that window we assume the
    /// user isn't actively using Claude Code and stop. Subsequent
    /// refreshes still happen on window-open events (or, eventually,
    /// the Tier-1 FSEventStream watcher).
    nonisolated static let postConnectPollIntervalMS: UInt64 = 500
    nonisolated static let postConnectPollBudget: Int = 60

    func connect(chainCommand: String?, now: Date = Date()) throws {
        let result = try patchService.connect(chainCommand: chainCommand, now: now)
        settings.updateStatuslinePrefs { prefs in
            prefs.connectedAt = now
            prefs.chainEnabled = (chainCommand != nil)
            prefs.chainTargetPath = chainCommand
            prefs.lastBackupPath = result.backupURL.path
        }
        refreshState(now: now)

        // Kick a bounded "wait for first sample" polling loop. Skipped
        // when running under XCTest so unit tests don't sit in a 30s
        // tail every time `connect` is exercised.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            startPostConnectPolling()
        }
    }

    private func startPostConnectPolling() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<Self.postConnectPollBudget {
                if case .connectedActive = self.state { return }
                try? await Task.sleep(
                    nanoseconds: Self.postConnectPollIntervalMS * 1_000_000
                )
                await self.sampleStore.loadIncrementally()
                self.refreshState()
                self.syncSamplePrefsFromStore()
            }
        }
    }

    func disconnect(deletingSamples: Bool, now: Date = Date()) throws {
        let backupPath = settings.statuslinePrefs.lastBackupPath
            .map { URL(fileURLWithPath: $0) }
        try patchService.disconnect(restoringFrom: backupPath)

        if deletingSamples {
            // Use the store's actual fileURL — not a hardcoded global
            // path — so tests with custom store URLs and any future
            // multi-store scenario remove exactly the file the store
            // is configured to read.
            try? FileManager.default.removeItem(at: sampleStore.fileURL)
            sampleStore.reset()
        }

        settings.updateStatuslinePrefs { prefs in
            prefs.connectedAt = nil
            prefs.chainEnabled = false
            prefs.chainTargetPath = nil
            prefs.lastBackupPath = nil
            // lastSampleAt + totalSamplesCollected are intentionally
            // preserved — they're informational about what we *had*,
            // not part of the active connection.
        }
        refreshState(now: now)
    }

    // MARK: - Drift heal

    func healDrift(now: Date = Date()) {
        try? patchService.rewriteWrapperForCurrentBinaryPath(now: now)
        refreshState(now: now)
    }

    // MARK: - Sample-driven prefs sync

    /// Call after the sample store loads new lines so the persisted
    /// prefs (lastSampleAt + totalSamplesCollected) stay current. The
    /// store itself doesn't depend on prefs so this stays a one-way
    /// push. We only mutate prefs when something actually changes,
    /// otherwise every load would trigger a redundant Observation
    /// event + debounced disk write.
    func syncSamplePrefsFromStore() {
        let last = sampleStore.lastSampleAt
        let lifetime = sampleStore.lifetimeAppendCount
        let prefsChanged = settings.statuslinePrefs.lastSampleAt != last
            || settings.statuslinePrefs.totalSamplesCollected != lifetime
        guard prefsChanged else { return }
        settings.updateStatuslinePrefs { prefs in
            prefs.lastSampleAt = last
            prefs.totalSamplesCollected = lifetime
        }
    }
}
