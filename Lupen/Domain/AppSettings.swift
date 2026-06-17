import Foundation
import Observation

/// How the sidebar organises its session list.
///
/// `grouped` mirrors the original Mail-like design — sessions nested under
/// collapsible project headers. `flat` collapses the hierarchy into a single
/// 1-depth list sorted by most-recent activity (see
/// `SessionGrouping.flatSorted`) with the project name surfaced in the cell's
/// meta row so rows from different projects are still distinguishable.
///
/// Stored verbatim in `app_settings.json` — the raw string is the persistence
/// key, so renaming a case is a file-format break.
enum SessionListLayoutMode: String, Codable, CaseIterable, Sendable {
    case grouped
    case flat

    /// Human-readable label shown in Preferences and the View menu. Kept on
    /// the enum (rather than a separate formatter) so there's one place to
    /// update if we ever add a third mode.
    var localizedTitle: String {
        switch self {
        case .grouped: return "Group by Project"
        case .flat:    return "Flat List (Recent First)"
        }
    }
}

/// App-wide user preferences that outlive a single window lifetime.
///
/// `@Observable` so SwiftUI forms, AppKit menus, and the sidebar can share a
/// single source of truth — any mutation fires observation and the sidebar
/// rebuilds on the same run-loop tick. Persistence is debounced
/// (`persistDebounce`) so a burst of pin toggles or rapid picker flips
/// produces a single disk write after the user settles.
///
/// All mutation must happen on the main actor. Background threads that need
/// a read-only snapshot should hop via `DispatchQueue.main.async`.
@Observable
@MainActor
final class AppSettings {

    // MARK: - Observable fields

    var sessionListLayout: SessionListLayoutMode {
        didSet {
            guard oldValue != sessionListLayout else { return }
            schedulePersist()
        }
    }

    /// Global provider mode. Every user-visible surface should render data
    /// for this provider only.
    var activeProvider: ProviderKind {
        didSet {
            guard oldValue != activeProvider else { return }
            schedulePersist()
        }
    }

    /// IDs of sessions the user has pinned to the top of the Flat layout.
    /// Grouped layout ignores these at sort time (see
    /// `SessionGrouping.groupByProject`) but the cell still renders a pin
    /// icon so the state is visible.
    var pinnedSessionIds: Set<String> {
        didSet {
            guard oldValue != pinnedSessionIds else { return }
            schedulePersist()
        }
    }

    var claudeCodeRootPath: String? {
        didSet {
            guard oldValue != claudeCodeRootPath else { return }
            schedulePersist()
        }
    }

    var codexRootPath: String? {
        didSet {
            guard oldValue != codexRootPath else { return }
            schedulePersist()
        }
    }

    var providerConfigurations: ProviderConfigurationStore {
        didSet {
            guard oldValue != providerConfigurations else { return }
            schedulePersist()
        }
    }

    /// Whether the status-bar item renders the today's-cost string next
    /// to the icon. Observed by `StatusBarController` so flipping the
    /// toggle in Preferences takes effect instantly.
    var showTodayCostInMenuBar: Bool {
        didSet {
            guard oldValue != showTodayCostInMenuBar else { return }
            schedulePersist()
        }
    }

    /// Whether the menu-bar cost rounds to whole dollars (`$23`) or
    /// shows cents (`$23.47`). Observed by `StatusBarController` so the
    /// toggle takes effect immediately. Only honoured when
    /// `showTodayCostInMenuBar` is true.
    var compactCurrencyInMenuBar: Bool {
        didSet {
            guard oldValue != compactCurrencyInMenuBar else { return }
            schedulePersist()
        }
    }

    /// Whether `applicationDidFinishLaunching` should open the Dashboard
    /// window automatically. Off by default — the typical menu-bar
    /// idle state is no-window.
    var openDashboardOnLaunch: Bool {
        didSet {
            guard oldValue != openDashboardOnLaunch else { return }
            schedulePersist()
        }
    }

    /// Mirror of the `SMAppService.mainApp` state; the `didSet` on this
    /// property calls into the `LaunchAtLoginService` to bring the
    /// system state in line, then persists the new value so the
    /// Preferences toggle survives relaunches even if the system
    /// `.status` lookup is slow on next boot.
    var startAtLogin: Bool {
        didSet {
            guard oldValue != startAtLogin else { return }
            LaunchAtLoginService.setEnabled(startAtLogin)
            schedulePersist()
        }
    }

    /// Whether the menu-bar icon should overlay a yellow warning badge
    /// when `ParseDiagnostics.warningCount > 0`. Default is on in DEBUG
    /// (the maintainer wants the regression signal) and off in
    /// RELEASE (most warnings — Claude Code added a new tool / block /
    /// stop_reason — are only actionable for the Lupen developer; end
    /// users either can't act or don't care). The Diagnostics window
    /// is always available regardless of this toggle.
    var showParseWarningBadge: Bool {
        didSet {
            guard oldValue != showParseWarningBadge else { return }
            schedulePersist()
        }
    }

    /// Whether the menu-bar icon should overlay a red error badge when
    /// `ParseDiagnostics.errorCount > 0`. Same default rule as
    /// `showParseWarningBadge` — DEBUG=on, RELEASE=off. Errors are
    /// rarer and usually indicate malformed JSONL, but off-by-default
    /// in release keeps the menu bar visually quiet on first launch.
    var showParseErrorBadge: Bool {
        didSet {
            guard oldValue != showParseErrorBadge else { return }
            schedulePersist()
        }
    }

    /// Phase 8.8 — statusline integration prefs. Persisted as a single
    /// nested object inside `app_settings.json` so a Connect that
    /// flips half a dozen fields in one shot only triggers one debounced
    /// write. Mutate via `updateStatuslinePrefs(_:)` to keep the
    /// persist path coherent.
    var statuslinePrefs: StatuslinePrefsData {
        didSet {
            guard oldValue != statuslinePrefs else { return }
            schedulePersist()
        }
    }

    // MARK: - Dependencies

    private let storage: AppSettingsStorage

    // MARK: - Persistence debounce

    private var pendingPersist: DispatchWorkItem?
    private static let persistDebounce: TimeInterval = 0.25

    // MARK: - Init

    init(storage: AppSettingsStorage = AppSettingsStorage()) {
        self.storage = storage
        let loaded = storage.load()
        self.sessionListLayout = loaded.sessionListLayout
        self.activeProvider = loaded.activeProvider
        self.pinnedSessionIds = Set(loaded.pinnedSessionIds)
        self.claudeCodeRootPath = loaded.claudeCodeRootPath
        self.codexRootPath = loaded.codexRootPath
        self.providerConfigurations = loaded.providerConfigurations
        self.showTodayCostInMenuBar = loaded.showTodayCostInMenuBar
        self.compactCurrencyInMenuBar = loaded.compactCurrencyInMenuBar
        self.openDashboardOnLaunch = loaded.openDashboardOnLaunch
        // Prefer the system's current SMAppService status over the
        // persisted value so a user who disabled "Open at Login" in
        // System Settings → General → Login Items doesn't see the
        // toggle re-enable itself next launch. The persisted value is
        // only used as a fallback until macOS reports its state.
        self.startAtLogin = LaunchAtLoginService.currentStatus() ?? loaded.startAtLogin
        self.showParseWarningBadge = loaded.showParseWarningBadge
        self.showParseErrorBadge = loaded.showParseErrorBadge
        self.statuslinePrefs = loaded.statuslinePrefs
    }

    // Note: no `deinit { pendingPersist?.cancel() }` — the scheduled
    // work item captures `self` weakly, so a deallocated AppSettings
    // makes the closure body's `guard let self` no-op and the work item
    // drops out of the main run loop after firing once. Short-lived test
    // instances therefore don't leak or mis-write.

    // MARK: - Pin API

    func isPinned(_ sessionId: String) -> Bool {
        pinnedSessionIds.contains(sessionId)
            || pinnedSessionIds.contains(normalizedPinId(sessionId))
    }

    /// Toggle membership of `sessionId` in the pinned set. Idempotent at the
    /// semantic level — a second call with the same id just flips back.
    func togglePin(sessionId: String) {
        let normalized = normalizedPinId(sessionId)
        if pinnedSessionIds.contains(sessionId) {
            pinnedSessionIds.remove(sessionId)
        } else if pinnedSessionIds.contains(normalized) {
            pinnedSessionIds.remove(normalized)
        } else {
            pinnedSessionIds.insert(normalized)
        }
    }

    /// Drop every pinned id. Called from the Preferences "Unpin All" button.
    func unpinAll() {
        guard !pinnedSessionIds.isEmpty else { return }
        pinnedSessionIds.removeAll()
    }

    /// Override provider only for the current process. Used by launch
    /// smoke tests so they can exercise Claude/Codex startup without
    /// mutating the user's persisted app mode.
    func setActiveProviderForCurrentLaunch(_ provider: ProviderKind) {
        guard activeProvider != provider else { return }
        activeProvider = provider
        pendingPersist?.cancel()
        pendingPersist = nil
    }

    /// Remove pinned ids that no longer correspond to a live session.
    /// Intended for the one-shot launch-time prune; safe to call with an
    /// empty set (no-op). Takes a `Set` so the caller can build it once from
    /// `store.sessions.map(\.id)` and reuse for other prune passes.
    func prunePins(keepingLiveIds liveIds: Set<String>) {
        let providerToPrune = activeProvider
        let scopedLiveIds = Set(liveIds.map {
            ProviderScopedID.normalize($0, defaultProvider: providerToPrune)
        })
        let intersected = Set(pinnedSessionIds.filter { id in
            guard let scoped = ProviderScopedID(value: id) else {
                return liveIds.contains(id)
                    || scopedLiveIds.contains(ProviderScopedID.normalize(id, defaultProvider: providerToPrune))
            }
            guard scoped.provider == providerToPrune else {
                return true
            }
            return scopedLiveIds.contains(id)
        })
        guard intersected != pinnedSessionIds else { return }
        pinnedSessionIds = intersected
    }

    private func normalizedPinId(_ sessionId: String) -> String {
        ProviderScopedID.normalize(sessionId, defaultProvider: activeProvider)
    }

    // MARK: - Persistence

    /// Cancel any scheduled write and reschedule one `persistDebounce`
    /// seconds out. The work item reads the live properties at fire time,
    /// so whichever values happen to be set when the timer elapses are
    /// what land on disk — even if the user flipped things again between
    /// schedule and fire.
    private func schedulePersist() {
        pendingPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let snapshot = self.currentSnapshot()
            let storage = self.storage
            DispatchQueue.global(qos: .utility).async {
                storage.save(snapshot)
            }
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.persistDebounce,
            execute: work
        )
    }

    /// Synchronous flush. Exposed for tests that need to assert "disk
    /// matches in-memory right now" without waiting out the debounce.
    func persistNow() {
        pendingPersist?.cancel()
        pendingPersist = nil
        storage.save(currentSnapshot())
    }

    /// Build an `AppSettingsData` from every observable property the
    /// file format knows about. Single source of truth for
    /// `schedulePersist` and `persistNow` so new fields only need to be
    /// added in one place.
    private func currentSnapshot() -> AppSettingsData {
        AppSettingsData(
            sessionListLayout: sessionListLayout,
            activeProvider: activeProvider,
            pinnedSessionIds: Array(pinnedSessionIds).sorted(),
            claudeCodeRootPath: claudeCodeRootPath,
            codexRootPath: codexRootPath,
            providerConfigurations: providerConfigurations,
            showTodayCostInMenuBar: showTodayCostInMenuBar,
            compactCurrencyInMenuBar: compactCurrencyInMenuBar,
            openDashboardOnLaunch: openDashboardOnLaunch,
            startAtLogin: startAtLogin,
            showParseWarningBadge: showParseWarningBadge,
            showParseErrorBadge: showParseErrorBadge,
            statuslinePrefs: statuslinePrefs
        )
    }

    // MARK: - Statusline prefs API

    /// Mutate the statusline prefs through this helper so the closure
    /// receives an inout reference and the resulting struct gets
    /// assigned in one go (triggers a single Observation event +
    /// debounced persist).
    func updateStatuslinePrefs(_ mutate: (inout StatuslinePrefsData) -> Void) {
        var copy = statuslinePrefs
        mutate(&copy)
        statuslinePrefs = copy
    }
}
