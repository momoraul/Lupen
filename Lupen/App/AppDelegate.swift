import AppKit
import Darwin
import Observation

struct LaunchSmokeTestConfig: Equatable, Sendable {
    let provider: ProviderKind?
    let codexHome: URL?
    let timeoutSeconds: TimeInterval
    let openDashboard: Bool
    let idleSeconds: TimeInterval
    let runId: String?

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> LaunchSmokeTestConfig? {
        guard environment["LUPEN_SMOKE_TEST"] == "1" || arguments.contains("--lupen-smoke-test") else {
            return nil
        }

        let providerRaw = environment["LUPEN_SMOKE_PROVIDER"]
            ?? argumentValue(prefix: "--lupen-smoke-provider=", in: arguments)
        let provider = providerRaw.flatMap(ProviderKind.init(rawValue:))

        let codexHomeRaw = environment["LUPEN_SMOKE_CODEX_HOME"]
            ?? argumentValue(prefix: "--lupen-smoke-codex-home=", in: arguments)
        let codexHome = codexHomeRaw.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }

        let timeoutRaw = environment["LUPEN_SMOKE_TIMEOUT_SECONDS"]
            ?? argumentValue(prefix: "--lupen-smoke-timeout=", in: arguments)
        let timeout = timeoutRaw.flatMap(TimeInterval.init) ?? 120

        let openDashboard = environment["LUPEN_SMOKE_OPEN_DASHBOARD"] == "1"
            || arguments.contains("--lupen-smoke-open-dashboard")

        let idleRaw = environment["LUPEN_SMOKE_IDLE_SECONDS"]
            ?? argumentValue(prefix: "--lupen-smoke-idle=", in: arguments)
        let idleSeconds = idleRaw.flatMap(TimeInterval.init) ?? 0

        let runId = environment["LUPEN_SMOKE_RUN_ID"]
            ?? argumentValue(prefix: "--lupen-smoke-run-id=", in: arguments)

        return LaunchSmokeTestConfig(
            provider: provider,
            codexHome: codexHome,
            timeoutSeconds: max(1, timeout),
            openDashboard: openDashboard,
            idleSeconds: max(0, idleSeconds),
            runId: runId
        )
    }

    private static func argumentValue(prefix: String, in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(prefix) }.map {
            String($0.dropFirst(prefix.count))
        }
    }

    func checkpointMetadata(_ metadata: [String: String] = [:]) -> [String: String] {
        guard let runId else { return metadata }
        var merged = metadata
        merged["smokeRunId"] = runId
        return merged
    }
}

enum StartupDataLoadPlan: Equatable, Sendable {
    case claudeCode
    case codex(URL?)

    init(provider: ProviderKind, codexHome: URL?) {
        switch provider {
        case .claudeCode:
            self = .claudeCode
        case .codex:
            self = .codex(codexHome)
        }
    }

    var provider: ProviderKind {
        switch self {
        case .claudeCode:
            .claudeCode
        case .codex:
            .codex
        }
    }
}

enum HeadlessSmokeTestRunner {
    /// Plan 5.1: smoke runs measure the SQLite-first startup — the only
    /// data path left. The driver is event-driven, so the runner pumps
    /// the main run loop until the launch progress settles at `.done`
    /// (warm index: immediately; cold index: after the background
    /// scan + backfill) or the wall-clock budget expires.
    @MainActor
    static func runAndExit(config: LaunchSmokeTestConfig) -> Never {
        let provider = config.provider ?? .claudeCode
        let diagnosticsConfig = LaunchDiagnosticsConfig.current()

        let store = AppStateStore(launchDiagnosticsConfig: diagnosticsConfig)
        LaunchMemoryCheckpoint.record(
            "smoke.store.init.end",
            config: diagnosticsConfig,
            metadata: config.checkpointMetadata(["provider": provider.rawValue])
        )

        let source: ProviderIndexSource
        switch provider {
        case .claudeCode:
            source = .claude(projectsDirectory: FileDiscovery().projectsDirectory)
        case .codex:
            source = .codex(
                codexHome: CodexSessionDiscovery(codexHome: config.codexHome).codexHome
            )
        }
        store.setActiveProviderForProjectionSwap(provider)
        let startup: SQLiteFirstStartup
        do {
            startup = try SQLiteFirstStartup(source: source, appStore: store)
        } catch {
            let line = "LUPEN_SMOKE_TEST_FAILED provider=\(provider.rawValue) dbOpenError=\(error)"
            fputs(line + "\n", stderr)
            fflush(stderr)
            Darwin.exit(1)
        }
        startup.start()

        let deadline = Date().addingTimeInterval(config.timeoutSeconds)
        while store.launchProgress.phase != .done {
            guard Date() < deadline else {
                let line = "LUPEN_SMOKE_TEST_FAILED provider=\(provider.rawValue) "
                    + "timeout=\(Int(config.timeoutSeconds))s phase=\(store.launchProgress.phase.rawValue)"
                fputs(line + "\n", stderr)
                fflush(stderr)
                Darwin.exit(1)
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        LaunchMemoryCheckpoint.record(
            "smoke.load.end",
            config: diagnosticsConfig,
            metadata: config.checkpointMetadata([
                "provider": provider.rawValue,
                "sessions": "\(store.sessions.count)"
            ])
        )
        if config.idleSeconds > 0 {
            let idleDeadline = Date().addingTimeInterval(config.idleSeconds)
            while Date() < idleDeadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            LaunchMemoryCheckpoint.record(
                "smoke.idle.end",
                config: diagnosticsConfig,
                metadata: config.checkpointMetadata([
                    "provider": provider.rawValue,
                    "idleSeconds": String(format: "%.6f", config.idleSeconds),
                    "sessions": "\(store.sessions.count)"
                ])
            )
        }

        startup.stop()
        let line = ([
            "LUPEN_SMOKE_TEST_OK",
            "provider=\(provider.rawValue)",
            "sessions=\(store.sessions.count)",
            "phase=\(store.launchProgress.phase.rawValue)"
        ]).joined(separator: " ")
        print(line)
        fflush(stdout)
        Darwin.exit(0)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: AppStateStore!
    private var settings: AppSettings!
    private var statusBarController: StatusBarController!
    private var dashboardController: DashboardWindowController!
    private var diagnosticsWindowController: DiagnosticsWindowController?
    private var reportsWindowController: ReportsWindowController?
    private var verifyCostsWindowController: VerifyCostsWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var manageSessionsWindowController: ManageSessionsWindowController?
    /// Store cache the manage window uses to read an inactive provider's index.
    private var managedReadStores: [ProviderKind: ProviderStore] = [:]
    private var verifyUsageMenuItem: NSMenuItem?
    private lazy var logWindowController = LogWindowController(logger: LoggerService.shared)
    private let smokeTest = LaunchSmokeTestConfig.current()
    private let launchDiagnosticsConfig = LaunchDiagnosticsConfig.current()
    /// SQLite-first drivers, keyed by session-source id (a built-in's id is
    /// its `ProviderKind.rawValue`). Only the active source's driver projects
    /// into the store; switching is a projection swap. Keying by source id
    /// (not bare `ProviderKind`) lets sibling sources of the same kind each
    /// own a driver.
    private var sqliteFirstStartups: [String: SQLiteFirstStartup] = [:]
    private var sqliteFirstCodexHome: URL?
    private var smokeTestCompleted = false

    private func smokeCheckpointMetadata(_ metadata: [String: String] = [:]) -> [String: String] {
        smokeTest?.checkpointMetadata(metadata) ?? metadata
    }

    /// Held for the app's lifetime so macOS does not push Lupen into
    /// App Nap when no window is foregrounded.
    ///
    /// Accessory-policy apps (`LSUIElement = true`) are treated as
    /// background processes by App Nap and can be throttled to wake up
    /// only every few seconds. That's fatal for a menu-bar app whose
    /// whole job is to show the freshest "today cost" — FSEvents
    /// callbacks queue up, the wall-clock timer skips fires, and the
    /// status item displays stale numbers. `beginActivity` with
    /// `.userInitiated` opts out of App Nap for the duration the
    /// token is held; we release it in `applicationWillTerminate`.
    private var appNapActivityToken: NSObjectProtocol?

    /// Phase 8.8 — statusline integration objects, constructed alongside
    /// `store`/`settings` so windows that need them don't have to deal
    /// with `nil`. All three stay alive for the app's lifetime.
    private var rateLimitSampleStore: RateLimitSampleStore!
    private var statuslineService: StatuslineConnectionService!
    private var statuslineMaintenanceScheduler: StatuslineMaintenanceScheduler!

    private var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let log = LoggerService.shared
        log.info("Lupen launching", context: "App")
        LaunchMemoryCheckpoint.record(
            "app.launch.start",
            config: launchDiagnosticsConfig,
            metadata: smokeCheckpointMetadata(["smokeProvider": smokeTest?.provider?.rawValue ?? "none"])
        )
        setupMainMenu()

        // App Nap opt-out — held for the app's lifetime. Skip in the
        // test host so unit-test launches don't accumulate activity
        // tokens (each XCTest process re-launches the app).
        if !isTestHost {
            appNapActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled],
                reason: "Lupen menu-bar refresh"
            )
        }

        store = AppStateStore(launchDiagnosticsConfig: launchDiagnosticsConfig)
        LaunchMemoryCheckpoint.record(
            "app.store.init.end",
            config: launchDiagnosticsConfig,
            metadata: smokeCheckpointMetadata()
        )
        // App-wide user preferences (sidebar layout, pinned sessions).
        // Constructed before the dashboard so the split VC + sidebar can
        // observe it from their first viewDidLoad pass.
        settings = AppSettings()
        if let provider = smokeTest?.provider {
            settings.setActiveProviderForCurrentLaunch(provider)
        }
        LaunchMemoryCheckpoint.record(
            "app.settings.init.end",
            config: launchDiagnosticsConfig,
            metadata: smokeCheckpointMetadata(["activeProvider": settings.activeProvider.rawValue])
        )
        updateProviderSpecificMenuTitles()

        // Statusline integration. RateLimitSampleStore tails the JSONL
        // log written by `--statusline-tap` invocations; the connection
        // service computes the user-visible state from settings.json
        // and the sample stream. Both ride along for the app's lifetime.
        rateLimitSampleStore = RateLimitSampleStore()
        statuslineService = StatuslineConnectionService(
            settings: settings,
            sampleStore: rateLimitSampleStore
        )
        // First load + initial state. Subsequent updates happen on
        // demand (Settings/Reports window open, post-Connect bounded
        // polling) or via the maintenance scheduler started below.
        Task { @MainActor in
            await rateLimitSampleStore.loadIncrementally()
            await rateLimitSampleStore.runRetentionSweep()
            statuslineService.refreshState()
            statuslineService.syncSamplePrefsFromStore()
        }
        // Periodic background maintenance: health-check + auto-heal-drift
        // every 5 min; retention sweep every 24 h. Skipped in the test
        // host so unit-test launches don't accumulate scheduled timers
        // on the runloop.
        statuslineMaintenanceScheduler = StatuslineMaintenanceScheduler(
            service: statuslineService,
            sampleStore: rateLimitSampleStore
        )
        if !isTestHost {
            statuslineMaintenanceScheduler.start()
        }
        startObservingProviderMode()

        // Apply the persisted appearance override before any window or the
        // status item is built, then keep NSApp.appearance in sync as the
        // Preferences picker changes it.
        applyAppearance()
        startObservingAppearance()

        statusBarController = StatusBarController(
            store: store,
            settings: settings,
            rateLimitSampleStore: rateLimitSampleStore
        )
        dashboardController = DashboardWindowController(
            store: store,
            settings: settings,
            autoSelectFirstSessionOnShow: !launchDiagnosticsConfig.dashboardAutoSelectDisabled,
            openLogsAction: { [weak self] in
                self?.openLogs(nil)
            }
        )

        let dashboard = dashboardController!
        statusBarController.setClickHandler { _ in
            LoggerService.shared.debug("Click handler executing — calling showDashboard", context: "App")
            dashboard.showDashboard()
        }

        // Honour the user's "Open Dashboard on launch" preference. Skip
        // in the test host because tests don't want a window popping up.
        if !isTestHost && (smokeTest?.openDashboard == true || settings.openDashboardOnLaunch) {
            dashboard.showDashboard()
        }

        // Any surface (dropdown banner, future toast, menu) can request the
        // Diagnostics window via a notification — keeps those surfaces
        // decoupled from the controller instance lifetime.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenParseDiagnosticsNotification(_:)),
            name: .openParseDiagnostics,
            object: nil
        )

        // Same decoupling for the Dashboard (6.14): the observer was
        // dropped in 8a8e868 ("remove dropdown") but the posting surface
        // (`DropdownViewController.openDashboardClicked`) survived — any
        // panel that posts `.openDashboard` was silently dead. Selector-
        // based on self (app-lifetime object), so there is no
        // deallocated/duplicate-observer hazard.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenDashboardNotification(_:)),
            name: .openDashboard,
            object: nil
        )

        guard !isTestHost else {
            log.debug("Running as test host, skipping data load", context: "App")
            return
        }

        // Wall-clock coordinator: broadcasts a tick at each local-hour
        // boundary (and on wake / clock change) so views whose output
        // depends on the wall clock — menu-bar `todayAggregateCost`,
        // Reports' Today/Yesterday buckets — can refresh without waiting
        // for an unrelated data event. Cost is effectively zero when
        // nothing is subscribed.
        WallClockCoordinator.shared.start()

        let startupProvider = settings.activeProvider
        armSmokeTestTimeoutIfNeeded(provider: startupProvider)
        // Plan 5.1: SQLite-first is the only startup path — the legacy
        // cache/orchestrator pipeline was deleted. GUI smoke runs
        // measure this same path and exit once indexing settles.
        //
        // If the persisted active source is a user-added/auto-detected one,
        // restore it via the custom path; otherwise take the built-in plan
        // path (smoke runs only ever target built-ins).
        if let active = settings.resolvedSources.source(id: settings.activeSourceId),
           active.enabled, active.origin != .builtin {
            sqliteFirstActivateCustom(source: active)
        } else {
            startSQLiteFirstStartup(plan: StartupDataLoadPlan(
                provider: startupProvider,
                codexHome: codexHomeURLFromSettings()
            ))
        }
        if smokeTest != nil {
            pollSmokeTestCompletion(provider: startupProvider)
        }
    }

    /// GUI smoke runs (LUPEN_SMOKE_OPEN_DASHBOARD=1) have no completion
    /// callback from the event-driven driver, so poll the launch
    /// progress on main until it settles at `.done`. The wall-clock
    /// timeout armed in `applicationDidFinishLaunching` is the failure
    /// path.
    private func pollSmokeTestCompletion(provider: ProviderKind) {
        guard smokeTest != nil, !smokeTestCompleted else { return }
        if store?.launchProgress.phase == .done {
            finishSmokeTestIfNeeded(provider: provider, success: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pollSmokeTestCompletion(provider: provider)
        }
    }

    /// Plan 3.2: SQLite-first startup. Metadata scan → sidebar shells →
    /// prioritized detail imports, all through `SQLiteFirstStartup` /
    /// `ProviderIndexCoordinator`. Legacy cache, orchestrator, file
    /// watcher, and background provider sync stay parked while the flag
    /// is on (3.4/3.5 wire their SQLite-first replacements).
    private func startSQLiteFirstStartup(plan: StartupDataLoadPlan) {
        switch plan {
        case .claudeCode:
            sqliteFirstActivate(provider: .claudeCode, codexHome: nil)
        case .codex(let codexHome):
            sqliteFirstActivate(provider: .codex, codexHome: codexHome)
        }
    }

    /// Plan 3.5: provider switch = projection swap. The target
    /// provider's driver is created on first use and merely re-projects
    /// afterwards (a pair of SQLite reads — never a parse); all other
    /// drivers keep importing with their store writes muted.
    private func sqliteFirstActivate(provider: ProviderKind, codexHome: URL?) {
        guard let store else { return }
        let sourceId = provider.rawValue
        for (key, startup) in sqliteFirstStartups where key != sourceId {
            startup.deactivateProjection()
        }
        store.setActiveProviderForProjectionSwap(provider)

        if provider == .codex {
            // Ungated: the 3.8 supervised trial proved the streaming
            // import bounded on the real 100 GB corpus (the legacy
            // full-load entry points were deleted in 5.1).
            let resolvedHome = CodexSessionDiscovery(codexHome: codexHome).codexHome
            if sqliteFirstStartups[sourceId] != nil, sqliteFirstCodexHome != resolvedHome {
                sqliteFirstStartups[sourceId]?.stop()
                sqliteFirstStartups[sourceId] = nil
            }
            sqliteFirstCodexHome = resolvedHome
        }

        if let existing = sqliteFirstStartups[sourceId] {
            existing.activateProjection()
            return
        }

        let source: ProviderIndexSource
        switch provider {
        case .claudeCode:
            source = .claude(projectsDirectory: FileDiscovery().projectsDirectory)
        case .codex:
            source = .codex(
                codexHome: sqliteFirstCodexHome
                    ?? CodexSessionDiscovery(codexHome: nil).codexHome
            )
        }
        do {
            let startup = try SQLiteFirstStartup(source: source, appStore: store, sourceId: sourceId)
            sqliteFirstStartups[sourceId] = startup
            startup.start()   // a fresh driver starts with its projection active
            LaunchMemoryCheckpoint.record(
                "app.sqliteFirst.startupBegan",
                config: launchDiagnosticsConfig,
                metadata: ["provider": source.provider.rawValue]
            )
        } catch {
            // Derived-cache DB failed to open (disk issues — version
            // mismatches rebuild internally). Surface and leave the UI
            // empty rather than silently falling back to the legacy
            // full parse the flag was meant to avoid.
            LoggerService.shared.error(
                "SQLite-first startup failed: \(error)",
                context: "App"
            )
            store.isLoading = false
        }
    }

    private func armSmokeTestTimeoutIfNeeded(provider: ProviderKind) {
        guard let smokeTest else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + smokeTest.timeoutSeconds) { [weak self] in
            guard let self, !self.smokeTestCompleted else { return }
            let phase = self.store?.launchProgress.phase.rawValue ?? "unknown"
            self.finishSmokeTestIfNeeded(
                provider: provider,
                success: false,
                message: "timeout phase=\(phase)"
            )
        }
    }

    private func finishSmokeTestIfNeeded(
        provider: ProviderKind,
        success: Bool,
        message: String? = nil
    ) {
        guard let smokeTest, !smokeTestCompleted else { return }

        if success {
            LaunchMemoryCheckpoint.record(
                "smoke.gui.load.end",
                config: launchDiagnosticsConfig,
                metadata: smokeTest.checkpointMetadata([
                    "provider": provider.rawValue,
                    "sessions": "\(store?.sessions.count ?? 0)"
                ])
            )
        }

        if success, smokeTest.idleSeconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + smokeTest.idleSeconds) { [weak self] in
                guard let self, !self.smokeTestCompleted else { return }
                LaunchMemoryCheckpoint.record(
                    "smoke.idle.end",
                    config: self.launchDiagnosticsConfig,
                    metadata: smokeTest.checkpointMetadata([
                        "provider": provider.rawValue,
                        "idleSeconds": String(format: "%.6f", smokeTest.idleSeconds),
                        "sessions": "\(self.store?.sessions.count ?? 0)"
                    ])
                )
                self.exitSmokeTest(provider: provider, success: success, message: message)
            }
            return
        }

        exitSmokeTest(provider: provider, success: success, message: message)
    }

    private func exitSmokeTest(
        provider: ProviderKind,
        success: Bool,
        message: String?
    ) -> Never {
        smokeTestCompleted = true
        for startup in sqliteFirstStartups.values {
            startup.stop()
        }
        WallClockCoordinator.shared.stop()

        let summaryParts = smokeSummaryParts(provider: provider)
        let prefix = success ? "LUPEN_SMOKE_TEST_OK" : "LUPEN_SMOKE_TEST_FAILED"
        let line = ([prefix] + summaryParts + [message].compactMap { $0 }).joined(separator: " ")
        if success {
            print(line)
            fflush(stdout)
            Darwin.exit(0)
        } else {
            fputs(line + "\n", stderr)
            fflush(stderr)
            Darwin.exit(1)
        }
    }

    private func smokeSummaryParts(provider: ProviderKind) -> [String] {
        [
            "provider=\(provider.rawValue)",
            "sessions=\(store?.sessions.count ?? 0)",
            "phase=\(store?.launchProgress.phase.rawValue ?? "unknown")"
        ]
    }

    private func startObservingProviderMode() {
        withObservationTracking {
            _ = settings.activeSourceId
            _ = settings.codexRootPath
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateProviderSpecificMenuTitles()
                self?.syncStoreToActiveSource()
                self?.startObservingProviderMode()
            }
        }
    }

    /// Mirror the user's appearance override onto `NSApp.appearance`. `nil`
    /// (the `.system` case) hands appearance back to macOS; `.light`/`.dark`
    /// pin every window to that appearance. Windows redraw themselves on the
    /// change; the menu-bar item's baked, non-template icon does not, so we
    /// recompose it explicitly afterwards (no-op until the controller exists).
    private func applyAppearance() {
        let appearance: NSAppearance?
        switch settings.appearanceMode {
        case .system: appearance = nil
        case .light:  appearance = NSAppearance(named: .aqua)
        case .dark:   appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        statusBarController?.refreshForAppearanceChange()
    }

    /// Re-apply on every change to `settings.appearanceMode` and re-arm the
    /// one-shot observation (same pattern as `startObservingProviderMode`).
    private func startObservingAppearance() {
        withObservationTracking {
            _ = settings.appearanceMode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.applyAppearance()
                self?.startObservingAppearance()
            }
        }
    }

    private func updateProviderSpecificMenuTitles() {
        guard let settings else { return }
        verifyUsageMenuItem?.title = settings.activeProvider.verificationMenuTitle
    }

    private func syncStoreToActiveSource() {
        // Switching the active source is a projection swap. Built-in sources
        // keep the legacy per-provider path (which honours the codexRootPath /
        // smoke codexHome overrides); a user-added/auto-detected source uses
        // its own root via the custom path. A missing/disabled active id falls
        // back to the built-in path for the resolved provider.
        let activeId = settings.activeSourceId
        if let active = settings.resolvedSources.source(id: activeId),
           active.enabled, active.origin != .builtin {
            sqliteFirstActivateCustom(source: active)
        } else {
            sqliteFirstActivate(
                provider: settings.activeProvider,
                codexHome: codexHomeURLFromSettings()
            )
        }
    }

    /// Activate a non-built-in source: project its index, creating and starting
    /// the driver on first use. Mirrors `sqliteFirstActivate(provider:)` but
    /// keyed by the source's stable id and rooted at `source.root`.
    private func sqliteFirstActivateCustom(source: SessionSource) {
        guard let store else { return }
        let sourceId = source.id
        for (key, startup) in sqliteFirstStartups where key != sourceId {
            startup.deactivateProjection()
        }
        store.setActiveSourceForProjectionSwap(source)

        if let existing = sqliteFirstStartups[sourceId] {
            existing.activateProjection()
            return
        }
        do {
            let startup = try SQLiteFirstStartup(
                source: ProviderIndexSource(source), appStore: store, sourceId: sourceId
            )
            sqliteFirstStartups[sourceId] = startup
            startup.start()
            LaunchMemoryCheckpoint.record(
                "app.sqliteFirst.startupBegan",
                config: launchDiagnosticsConfig,
                metadata: ["provider": source.kind.rawValue, "source": sourceId]
            )
        } catch {
            LoggerService.shared.error(
                "SQLite-first startup failed (source \(sourceId)): \(error)",
                context: "App"
            )
            store.isLoading = false
        }
    }

    private func codexHomeURLFromSettings() -> URL? {
        if let codexHome = smokeTest?.codexHome {
            return codexHome
        }
        guard let rawPath = settings.codexRootPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            dashboardController.showDashboard()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        LoggerService.shared.info("Lupen terminating", context: "App")
        for startup in sqliteFirstStartups.values {
            startup.stop()
        }
        WallClockCoordinator.shared.stop()
        if let token = appNapActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            appNapActivityToken = nil
        }
        // Nothing to flush: every import lands in SQLite transactionally
        // as it happens, so a quit (or crash) never loses indexed state.
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // --- App menu ---------------------------------------------------
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lupen", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // "Check for Updates…" sits in the Apple-HIG-standard slot for
        // app-update affordances: right after About, before Settings.
        // The action target is `UpdateService.shared` so the menu item
        // is enabled regardless of the responder chain's current state
        // (the user can trigger an update check from anywhere). On a
        // local dev build with no SUPublicEDKey embedded, this still
        // works — Sparkle just fails signature verification on the
        // downloaded update, which is the intended dev-loop behaviour.
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdateService.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = UpdateService.shared
        appMenu.addItem(checkForUpdatesItem)
        appMenu.addItem(.separator())
        // Standard macOS Settings… item — ⌘, matches every Apple app
        // (System Settings, Mail, Xcode, Finder). `target = self` because
        // Preferences is a singleton owned by AppDelegate; no need to
        // bounce through the responder chain.
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openPreferences(_:)),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Lupen", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lupen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // --- File menu --------------------------------------------------
        // Hosts the maintenance actions that touch on-disk state — log
        // file reveal and the destructive cache wipe. They previously
        // lived under a separate Debug menu; users surfaced them as
        // first-class operations rather than developer-only tools, so
        // they belong in File alongside other "open / manage on-disk
        // resource" items. The same actions are mirrored in the
        // Settings ▸ Maintenance section so the user can find them
        // without scanning the menu bar.
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        let revealLogItem = NSMenuItem(
            title: "Reveal Log File in Finder",
            action: #selector(revealLogFileInFinder(_:)),
            keyEquivalent: ""
        )
        revealLogItem.target = self
        fileMenu.addItem(revealLogItem)

        fileMenu.addItem(.separator())

        // Destructive-ish — wipes the derived SQLite indexes and
        // re-scans the source logs in the background. Confirm via
        // NSAlert so a mis-click doesn't discard a finished backfill.
        let clearCacheItem = NSMenuItem(
            title: "Rebuild Index…",
            action: #selector(clearCacheAndReparse(_:)),
            keyEquivalent: ""
        )
        clearCacheItem.target = self
        fileMenu.addItem(clearCacheItem)

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu — for now, this only hosts the "Find" shortcut
        // wired to the sidebar's search field. Placed between the App
        // and Window menus per standard macOS menu bar ordering. The
        // menu item uses `nil` target so AppKit dispatches through
        // the responder chain: `SessionListViewController` and
        // `DashboardSplitViewController` both implement
        // `focusSearchField(_:)`, so ⌘F works whether the user has
        // focus in the sidebar, the turn outline, or the detail pane.
        // When the dashboard window isn't open, no responder in the
        // chain implements the selector and AppKit auto-disables the
        // menu item — no manual `validateMenuItem` needed.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let findItem = NSMenuItem(
            title: "Find",
            action: #selector(SessionListViewController.focusSearchField(_:)),
            keyEquivalent: "f"
        )
        findItem.keyEquivalentModifierMask = [.command]
        findItem.target = nil

        let findNextItem = NSMenuItem(
            title: "Find Next",
            action: #selector(TurnOutlineViewController.navigateToNextMatch(_:)),
            keyEquivalent: "g"
        )
        findNextItem.keyEquivalentModifierMask = [.command]
        findNextItem.target = nil

        let findPrevItem = NSMenuItem(
            title: "Find Previous",
            action: #selector(TurnOutlineViewController.navigateToPreviousMatch(_:)),
            keyEquivalent: "g"
        )
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.target = nil

        editMenu.addItem(findItem)
        editMenu.addItem(findNextItem)
        editMenu.addItem(findPrevItem)

        // Standard Edit menu items — Cut/Copy/Paste/Select All.
        //
        // Without these items present in the main menu, AppKit does
        // NOT dispatch ⌘C / ⌘V / ⌘A through the responder chain to
        // focused NSTextView instances. Right-click → Copy still
        // works (NSTextView builds its own contextual menu), but the
        // keyboard shortcut arrives unbound and gets swallowed.
        // Adding them with `target = nil` makes AppKit walk the
        // responder chain — NSTextView (and any other selectable
        // control) implements `copy:` / `selectAll:` / `cut:` /
        // `paste:` out of the box, so the shortcuts start working
        // everywhere that's actually capable of handling them.
        // Non-text-view focus (e.g. outline view) auto-disables the
        // items through `validateUserInterfaceItem` — no manual
        // plumbing required.
        editMenu.addItem(.separator())
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(pasteItem)

        editMenu.addItem(.separator())
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(selectAllItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // --- View menu --------------------------------------------------
        // Sidebar layout toggle (Grouped/Flat) + Detail Pane toggle.
        // Items route through the responder chain (`target = nil`) so
        // DashboardSplitViewController / SessionListViewController
        // implement the selectors and validation. When the dashboard
        // window isn't key, AppKit auto-disables the items through
        // `validateMenuItem` returning false up the chain.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let groupedLayoutItem = NSMenuItem(
            title: "Group Sessions by Project",
            action: #selector(DashboardSplitViewController.setSessionListLayoutGrouped(_:)),
            keyEquivalent: "1"
        )
        groupedLayoutItem.keyEquivalentModifierMask = [.command]
        groupedLayoutItem.target = nil
        viewMenu.addItem(groupedLayoutItem)

        let flatLayoutItem = NSMenuItem(
            title: "Flat Session List",
            action: #selector(DashboardSplitViewController.setSessionListLayoutFlat(_:)),
            keyEquivalent: "2"
        )
        flatLayoutItem.keyEquivalentModifierMask = [.command]
        flatLayoutItem.target = nil
        viewMenu.addItem(flatLayoutItem)

        viewMenu.addItem(.separator())

        // Xcode-style detail pane toggle. ⇧⌘Y matches Xcode's
        // "Show/Hide Debug Area" shortcut so users familiar with
        // Xcode get the same muscle memory. Belongs in View because
        // it changes what's visible, not a window-management action.
        let toggleDetailItem = NSMenuItem(
            title: "Toggle Detail Pane",
            action: #selector(DashboardSplitViewController.toggleDetailPane(_:)),
            keyEquivalent: "y"
        )
        toggleDetailItem.keyEquivalentModifierMask = [.command, .shift]
        toggleDetailItem.target = nil
        viewMenu.addItem(toggleDetailItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Session menu — keyboard shortcuts for the row-level actions
        // that also live on the sidebar context menu. These can't just
        // be set on the context-menu items: a `keyEquivalent` on a
        // context-menu item only fires while that menu is open, so ⌘R
        // with no open menu would otherwise beep. Hosting them here
        // with `target = nil` routes them through the responder chain
        // to DashboardSplitViewController → SessionListViewController,
        // which validates the selection before running.
        let sessionMenuItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")

        // Title is provider-neutral here; `validateMenuItem` rewrites it
        // to "Resume in Claude Code" / "Resume in Codex" from the selected
        // session before the menu is shown.
        let resumeSessionItem = NSMenuItem(
            title: "Resume Session",
            action: #selector(DashboardSplitViewController.resumeSelectedSession(_:)),
            keyEquivalent: "r"
        )
        resumeSessionItem.keyEquivalentModifierMask = [.command]
        resumeSessionItem.target = nil
        sessionMenu.addItem(resumeSessionItem)

        let copyResumeCommandItem = NSMenuItem(
            title: "Copy Resume Command",
            action: #selector(DashboardSplitViewController.copyResumeCommandForSelectedSession(_:)),
            keyEquivalent: "c"
        )
        copyResumeCommandItem.keyEquivalentModifierMask = [.command, .shift]
        copyResumeCommandItem.target = nil
        sessionMenu.addItem(copyResumeCommandItem)

        sessionMenuItem.submenu = sessionMenu
        mainMenu.addItem(sessionMenuItem)

        // --- Window menu ------------------------------------------------
        // Standard window-management (Close / Minimize / Zoom) + the
        // set of secondary windows the app can open, + Bring All to
        // Front. Maintenance actions (log reveal, cache wipe) live in
        // the File menu.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        windowMenu.addItem(.separator())

        // ⌘0 brings the Dashboard window forward (or builds + shows it
        // when still closed). Matches the "bring primary window to
        // front" idiom many menubar apps use.
        let dashboardItem = NSMenuItem(
            title: "Dashboard",
            action: #selector(openDashboard(_:)),
            keyEquivalent: "0"
        )
        dashboardItem.keyEquivalentModifierMask = [.command]
        dashboardItem.target = self
        windowMenu.addItem(dashboardItem)

        let reportsItem = NSMenuItem(
            title: "Reports…",
            action: #selector(openReports(_:)),
            keyEquivalent: "r"
        )
        reportsItem.keyEquivalentModifierMask = [.command, .shift]
        reportsItem.target = self
        windowMenu.addItem(reportsItem)

        let diagItem = NSMenuItem(
            title: "Parse Diagnostics…",
            action: #selector(openParseDiagnostics(_:)),
            keyEquivalent: "d"
        )
        diagItem.keyEquivalentModifierMask = [.command, .shift]
        diagItem.target = self
        windowMenu.addItem(diagItem)

        // Plan 12 / 13 Phase 6 — user-triggered audit against
        // independent ground truth. Manual (not auto on launch) because
        // the audit re-scans every JSONL from scratch.
        let verifyItem = NSMenuItem(
            title: ProviderKind.claudeCode.verificationMenuTitle,
            action: #selector(openVerifyCosts(_:)),
            keyEquivalent: "v"
        )
        verifyItem.keyEquivalentModifierMask = [.command, .shift]
        verifyItem.target = self
        verifyUsageMenuItem = verifyItem
        windowMenu.addItem(verifyItem)

        let manageItem = NSMenuItem(
            title: "Manage Sessions & Storage…",
            action: #selector(openManageSessions(_:)),
            keyEquivalent: "m"
        )
        manageItem.keyEquivalentModifierMask = [.command, .shift]
        manageItem.target = self
        windowMenu.addItem(manageItem)

        // The log window is a maintainer-only diagnostic; its entry points
        // (this menu item and the dashboard toolbar button) ship in DEBUG
        // builds only.
        #if DEBUG
        let logsItem = NSMenuItem(
            title: "Logs…",
            action: #selector(openLogs(_:)),
            keyEquivalent: "l"
        )
        logsItem.keyEquivalentModifierMask = [.command, .shift]
        logsItem.target = self
        windowMenu.addItem(logsItem)
        #endif

        windowMenu.addItem(.separator())

        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Diagnostics window

    @objc func openParseDiagnostics(_ sender: Any?) {
        if diagnosticsWindowController == nil {
            diagnosticsWindowController = DiagnosticsWindowController(diagnostics: store.diagnostics)
        }
        diagnosticsWindowController?.show()
    }

    @objc private func handleOpenParseDiagnosticsNotification(_ notification: Notification) {
        openParseDiagnostics(nil)
    }

    // MARK: - Reports window

    @objc func openReports(_ sender: Any?) {
        if reportsWindowController == nil {
            reportsWindowController = ReportsWindowController(
                store: store,
                sampleStore: rateLimitSampleStore
            )
        }
        let refresher = makeReportsOpenRefreshCoordinator()
        // Refresh state + samples when the user opens Reports so the
        // Hours tab footer reflects the live picture. Launch diagnostics
        // can disable this path for memory-smoke isolation.
        Task { @MainActor in
            await refresher.refreshIfNeeded()
        }
        reportsWindowController?.show()
    }

    private func makeReportsOpenRefreshCoordinator() -> ReportsOpenRefreshCoordinator {
        ReportsOpenRefreshCoordinator(
            launchDiagnosticsConfig: launchDiagnosticsConfig,
            loadIncrementally: { [rateLimitSampleStore] in
                await rateLimitSampleStore?.loadIncrementally()
            },
            refreshState: { [statuslineService] in
                statuslineService?.refreshState()
            },
            syncSamplePrefsFromStore: { [statuslineService] in
                statuslineService?.syncSamplePrefsFromStore()
            },
            recordSkippedCheckpoint: { [launchDiagnosticsConfig, smokeTest] in
                LaunchMemoryCheckpoint.record(
                    "reports.refresh.skipped",
                    config: launchDiagnosticsConfig,
                    metadata: smokeTest?.checkpointMetadata() ?? [:]
                )
            }
        )
    }

    // MARK: - Verify Costs window (Plan 12 / 13 Phase 6)

    @objc func openVerifyCosts(_ sender: Any?) {
        if verifyCostsWindowController == nil {
            verifyCostsWindowController = VerifyCostsWindowController(store: store)
        }
        verifyCostsWindowController?.show()
    }

    // MARK: - Manage Sessions & Storage window

    @objc func openManageSessions(_ sender: Any?) {
        if manageSessionsWindowController == nil {
            manageSessionsWindowController = ManageSessionsWindowController(
                provider: settings.activeProvider,
                isIndexingProvider: { [weak self] in self?.store.isIndexing ?? false },
                storeProvider: { [weak self] provider in self?.manageProviderStore(for: provider) },
                contextProvider: { [weak self] provider in self?.manageContext(for: provider) },
                requestRescan: { [weak self] provider in self?.sqliteFirstStartups[provider.rawValue]?.coordinator.requestRescan() },
                rebuildIndex: { [weak self] provider in self?.sqliteFirstStartups[provider.rawValue]?.rebuildIndex() }
            )
        }
        manageSessionsWindowController?.show()
    }

    /// Provides the indexing store for the active provider, or opens that
    /// provider's index DB directly (for read/delete consistency) when
    /// inactive. Lets the manage window show Claude Code tab sessions even
    /// when started on codex.
    private func manageProviderStore(for provider: ProviderKind) -> ProviderStore? {
        if let startup = sqliteFirstStartups[provider.rawValue] {
            // Prefer the active store, and release any read-only pool opened
            // while inactive (avoids file-handle/WAL leaks — a GRDB pool closes
            // when its ref is released).
            managedReadStores[provider] = nil
            return startup.coordinator.store
        }
        if let cached = managedReadStores[provider] {
            return cached
        }
        let url = LupenPaths.indexDatabaseURL(for: provider)
        guard FileManager.default.fileExists(atPath: url.path),
              let database = try? ProviderDatabase.open(at: url) else { return nil }
        let store = ProviderStore(database: database)
        managedReadStores[provider] = store
        return store
    }

    private func manageContext(for provider: ProviderKind) -> ManageProviderContext? {
        switch provider {
        case .claudeCode:
            return .claude(projectsDirectory: FileDiscovery().projectsDirectory)
        case .codex:
            return .codex(codexHome: CodexSessionDiscovery(codexHome: codexHomeURLFromSettings()).codexHome)
        }
    }

    // MARK: - Preferences window

    /// Open (or bring forward) the Settings window. Lazy-constructed on
    /// first invocation — matches Reports / Diagnostics / Verify Costs so
    /// the SwiftUI hosting controller isn't paid for until the user asks
    /// for it.
    @objc func openPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                settings: settings,
                onRevealLogFile: { [weak self] in self?.revealLogFileInFinder(nil) },
                onClearCacheAndReparse: { [weak self] in self?.clearCacheAndReparse(nil) },
                statuslineService: statuslineService
            )
        }
        // Re-derive state when the window opens so the user sees the
        // current picture even if Lupen.app moved or settings.json
        // was edited externally.
        Task { @MainActor in
            await rateLimitSampleStore.loadIncrementally()
            statuslineService.refreshState()
            statuslineService.syncSamplePrefsFromStore()
        }
        preferencesWindowController?.show()
    }

    // MARK: - Dashboard window (Window ▸ Dashboard)

    /// Main-menu target for ⌘0 / Window ▸ Dashboard. Builds the
    /// dashboard on first invocation (same path as the status-bar click
    /// handler) and subsequently just brings it forward.
    @objc func openDashboard(_ sender: Any?) {
        dashboardController.showDashboard()
    }

    /// `.openDashboard` notification target (dropdown panel and any
    /// future surface that can't reach the controller directly).
    @objc private func handleOpenDashboardNotification(_ note: Notification) {
        dashboardController.showDashboard()
    }

    // MARK: - Logs window (Window ▸ Logs…)

    /// Opens the Logs window. Same controller as the Dashboard toolbar
    /// button so repeated opens bring the existing window forward
    /// rather than constructing a new one.
    @objc func openLogs(_ sender: Any?) {
        logWindowController.showWindow()
    }

    // MARK: - Reveal Log File

    /// Opens Finder on the Lupen log directory with today's log file
    /// pre-selected when it exists. Falls back to opening just the
    /// directory (creating it if file-logging was disabled). Matches the
    /// pattern Apple apps use for "Show Library Folder" type items.
    @objc func revealLogFileInFinder(_ sender: Any?) {
        LoggerService.shared.revealLogDirectoryInFinder()
    }

    // MARK: - Rebuild Index (plan 5.2 — replaces Clear Cache & Reparse)

    /// Wipes the derived SQLite indexes (every live driver) and
    /// re-scans the source logs in the background. Source JSONL files
    /// are never touched. Confirm first — on a large history the
    /// background re-index can take a while to fully repopulate.
    @objc func clearCacheAndReparse(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Rebuild Index?"
        alert.informativeText = """
        Lupen will clear its derived index and re-scan every session log in the background. \
        The sidebar repopulates as sessions are re-indexed; your provider logs on disk are not modified.

        Use this if the numbers look wrong or after a provider format change.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rebuild Index")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for startup in sqliteFirstStartups.values {
            startup.rebuildIndex()
        }
    }
}
