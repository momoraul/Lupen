import Foundation

/// On-disk shape of `AppSettings`. Plain `Codable` so the JSON round-trip is
/// trivial and the file is human-inspectable.
///
/// Fields are populated via `decodeIfPresent` at load time (see the custom
/// `init(from:)`), so adding a new setting later won't break files written by
/// older builds — missing keys fall back to `.default`.
struct AppSettingsData: Codable, Equatable, Sendable {
    var sessionListLayout: SessionListLayoutMode
    /// App-wide appearance override. `.system` follows macOS (default).
    var appearanceMode: AppearanceMode
    var activeProvider: ProviderKind
    /// Stable id of the active session source — the authority for which source
    /// is projected. Built-in source ids equal `ProviderKind.rawValue`, so
    /// `activeProvider` is kept in sync as the active source's parser kind.
    /// Migrated from `activeProvider` when absent in a file written by an
    /// older build.
    var activeSourceId: String
    var pinnedSessionIds: [String]
    var claudeCodeRootPath: String?
    var codexRootPath: String?
    var providerConfigurations: ProviderConfigurationStore
    /// When true, the status bar item draws the compact today's-cost
    /// string next to the icon (e.g. `$3.47`). When false, icon only.
    var showTodayCostInMenuBar: Bool
    /// When true, the menu-bar cost rounds to whole dollars (e.g. `$23`)
    /// instead of showing cents (`$23.47`). Useful for users juggling
    /// many menu-bar apps on narrow displays. Defaults to false so the
    /// behaviour on first launch matches every previous Lupen release.
    var compactCurrencyInMenuBar: Bool
    /// When true, the Dashboard window is opened automatically during
    /// `applicationDidFinishLaunching`. Off by default — first launch
    /// should feel lightweight (menu bar only); power users can flip
    /// this on.
    var openDashboardOnLaunch: Bool
    /// Whether the user asked macOS to launch Lupen at login. The
    /// source of truth is `SMAppService.mainApp.status`; this field
    /// mirrors the last value we successfully applied so the
    /// Preferences toggle can show the intended state even before the
    /// system reports back on first boot.
    var startAtLogin: Bool
    /// When true, the menu-bar icon overlays a yellow exclamation
    /// mark whenever `ParseDiagnostics.warningCount > 0`. Default is
    /// build-conditional: DEBUG=on (the maintainer wants the signal),
    /// RELEASE=off (most warnings — new tool / block / stop_reason
    /// shapes Claude Code added — are only actionable for the Lupen
    /// developer). The Diagnostics window itself is unaffected; the
    /// rejection counts and samples still accumulate so the user can
    /// open the window to inspect when they choose.
    var showParseWarningBadge: Bool
    /// When true, the menu-bar icon overlays a red dot whenever
    /// `ParseDiagnostics.errorCount > 0`. Same default rule as
    /// `showParseWarningBadge` — DEBUG=on, RELEASE=off — but errors
    /// are rarer and usually point at malformed JSONL, which is
    /// genuinely the user's problem if it happens. Off-by-default in
    /// release keeps first-launch quiet; users can opt in.
    var showParseErrorBadge: Bool
    /// Statusline integration prefs. New in Phase 8.8 — the bag of
    /// fields needed to remember a Connect across launches without
    /// re-parsing settings.json from scratch on every read.
    var statuslinePrefs: StatuslinePrefsData
    /// User-defined session sources: added folders plus enable/name overrides
    /// for built-in and auto-detected sources. Empty = defaults only. Stored
    /// in its OWN field (not `providerConfigurations`) to avoid the legacy
    /// `ensureBuiltIn` root-clobber on persist.
    var sessionSources: [SessionSource]

    /// Default on first launch / corrupt file fallback.
    ///
    /// `sessionListLayout` defaults to **`.flat`** — the recency-sorted
    /// single list reads more naturally for the "check what I did
    /// today" workflow than the project-grouped tree (most users have
    /// 1–2 active projects at a time; the grouping tax outweighs the
    /// benefit until the project list grows). Users who prefer groups
    /// can flip it in Settings… or via ⌘1.
    static let `default`: AppSettingsData = {
        // Diagnostics badges default ON in DEBUG, OFF in RELEASE — the
        // signal is for the maintainer, not the end user. See the
        // field doc comment for rationale.
        #if DEBUG
        let defaultBadgesOn = true
        #else
        let defaultBadgesOn = false
        #endif
        return AppSettingsData(
            sessionListLayout: .flat,
            appearanceMode: .system,
            activeProvider: .claudeCode,
            activeSourceId: ProviderKind.claudeCode.rawValue,
            pinnedSessionIds: [],
            claudeCodeRootPath: nil,
            codexRootPath: nil,
            providerConfigurations: .legacy(),
            showTodayCostInMenuBar: true,
            compactCurrencyInMenuBar: false,
            openDashboardOnLaunch: false,
            startAtLogin: false,
            showParseWarningBadge: defaultBadgesOn,
            showParseErrorBadge: defaultBadgesOn,
            statuslinePrefs: .default,
            sessionSources: []
        )
    }()

    init(
        sessionListLayout: SessionListLayoutMode,
        appearanceMode: AppearanceMode = .system,
        activeProvider: ProviderKind = .claudeCode,
        activeSourceId: String? = nil,
        pinnedSessionIds: [String],
        claudeCodeRootPath: String? = nil,
        codexRootPath: String? = nil,
        providerConfigurations: ProviderConfigurationStore? = nil,
        showTodayCostInMenuBar: Bool,
        compactCurrencyInMenuBar: Bool = false,
        openDashboardOnLaunch: Bool,
        startAtLogin: Bool,
        showParseWarningBadge: Bool,
        showParseErrorBadge: Bool,
        statuslinePrefs: StatuslinePrefsData = .default,
        sessionSources: [SessionSource] = []
    ) {
        self.sessionListLayout = sessionListLayout
        self.appearanceMode = appearanceMode
        self.activeProvider = activeProvider
        // Built-in source id == ProviderKind.rawValue, so deriving from the
        // active provider is the correct migration when no id was persisted.
        self.activeSourceId = activeSourceId ?? activeProvider.rawValue
        self.pinnedSessionIds = Self.normalizePinnedSessionIds(
            pinnedSessionIds,
            defaultProvider: activeProvider
        )
        self.claudeCodeRootPath = claudeCodeRootPath
        self.codexRootPath = codexRootPath
        self.providerConfigurations = (providerConfigurations ?? .legacy(
            claudeCodeRootPath: claudeCodeRootPath,
            codexRootPath: codexRootPath
        )).mergingLegacyRoots(
            claudeCodeRootPath: claudeCodeRootPath,
            codexRootPath: codexRootPath
        )
        self.showTodayCostInMenuBar = showTodayCostInMenuBar
        self.compactCurrencyInMenuBar = compactCurrencyInMenuBar
        self.openDashboardOnLaunch = openDashboardOnLaunch
        self.startAtLogin = startAtLogin
        self.showParseWarningBadge = showParseWarningBadge
        self.showParseErrorBadge = showParseErrorBadge
        self.statuslinePrefs = statuslinePrefs
        self.sessionSources = sessionSources
    }

    enum CodingKeys: String, CodingKey {
        case sessionListLayout
        case appearanceMode
        case activeProvider
        case activeSourceId
        case pinnedSessionIds
        case claudeCodeRootPath
        case codexRootPath
        case providerConfigurations
        case showTodayCostInMenuBar
        case compactCurrencyInMenuBar
        case openDashboardOnLaunch
        case startAtLogin
        case showParseWarningBadge
        case showParseErrorBadge
        case statuslinePrefs
        case sessionSources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionListLayout = try c.decodeIfPresent(
            SessionListLayoutMode.self,
            forKey: .sessionListLayout
        ) ?? AppSettingsData.default.sessionListLayout
        self.appearanceMode = try c.decodeIfPresent(
            AppearanceMode.self,
            forKey: .appearanceMode
        ) ?? AppSettingsData.default.appearanceMode
        let activeProviderRaw = try c.decodeIfPresent(String.self, forKey: .activeProvider)
        self.activeProvider = activeProviderRaw.flatMap(ProviderKind.init(rawValue:))
            ?? AppSettingsData.default.activeProvider
        // Migration: older files have no `activeSourceId` — derive it from the
        // active provider (built-in id == rawValue).
        self.activeSourceId = try c.decodeIfPresent(String.self, forKey: .activeSourceId)
            ?? self.activeProvider.rawValue
        self.pinnedSessionIds = Self.normalizePinnedSessionIds(try c.decodeIfPresent(
            [String].self,
            forKey: .pinnedSessionIds
        ) ?? AppSettingsData.default.pinnedSessionIds, defaultProvider: activeProvider)
        self.claudeCodeRootPath = try c.decodeIfPresent(
            String.self,
            forKey: .claudeCodeRootPath
        )
        self.codexRootPath = try c.decodeIfPresent(
            String.self,
            forKey: .codexRootPath
        )
        self.providerConfigurations = (try c.decodeIfPresent(
            ProviderConfigurationStore.self,
            forKey: .providerConfigurations
        ) ?? .legacy(
            claudeCodeRootPath: claudeCodeRootPath,
            codexRootPath: codexRootPath
        )).mergingLegacyRoots(
            claudeCodeRootPath: claudeCodeRootPath,
            codexRootPath: codexRootPath
        )
        self.showTodayCostInMenuBar = try c.decodeIfPresent(
            Bool.self,
            forKey: .showTodayCostInMenuBar
        ) ?? AppSettingsData.default.showTodayCostInMenuBar
        self.compactCurrencyInMenuBar = try c.decodeIfPresent(
            Bool.self,
            forKey: .compactCurrencyInMenuBar
        ) ?? AppSettingsData.default.compactCurrencyInMenuBar
        self.openDashboardOnLaunch = try c.decodeIfPresent(
            Bool.self,
            forKey: .openDashboardOnLaunch
        ) ?? AppSettingsData.default.openDashboardOnLaunch
        self.startAtLogin = try c.decodeIfPresent(
            Bool.self,
            forKey: .startAtLogin
        ) ?? AppSettingsData.default.startAtLogin
        self.showParseWarningBadge = try c.decodeIfPresent(
            Bool.self,
            forKey: .showParseWarningBadge
        ) ?? AppSettingsData.default.showParseWarningBadge
        self.showParseErrorBadge = try c.decodeIfPresent(
            Bool.self,
            forKey: .showParseErrorBadge
        ) ?? AppSettingsData.default.showParseErrorBadge
        self.statuslinePrefs = try c.decodeIfPresent(
            StatuslinePrefsData.self,
            forKey: .statuslinePrefs
        ) ?? AppSettingsData.default.statuslinePrefs
        self.sessionSources = try c.decodeIfPresent(
            [SessionSource].self,
            forKey: .sessionSources
        ) ?? AppSettingsData.default.sessionSources
    }

    private static func normalizePinnedSessionIds(_ ids: [String], defaultProvider: ProviderKind) -> [String] {
        ids.map { ProviderScopedID.normalize($0, defaultProvider: defaultProvider) }
    }
}

/// Phase 8.8 — persisted statusline integration state. Lives inside
/// `app_settings.json` rather than its own file so a single fsync per
/// preference change covers every Lupen setting. Field-level
/// `decodeIfPresent` keeps existing settings files compatible.
struct StatuslinePrefsData: Codable, Equatable, Sendable {

    /// First time the user successfully connected. Nil for users who
    /// never connected.
    var connectedAt: Date?

    /// Whether the user opted into chaining their existing statusline.
    var chainEnabled: Bool

    /// The chain target the user chose (typically
    /// `~/.claude/statusline.sh`). Nil when chain is disabled, or the
    /// path no longer exists.
    var chainTargetPath: String?

    /// Path of the most recent backup we wrote during Connect. Used by
    /// Disconnect to restore the user's settings file.
    var lastBackupPath: String?

    /// Wall-clock time of the most recently captured sample. Drives
    /// the Settings UI's "last sample 2m ago" line.
    var lastSampleAt: Date?

    /// Lifetime sample count (informational — shown in Settings).
    var totalSamplesCollected: Int

    /// User dismissed the Dashboard banner at this date. We re-show
    /// the banner after 7 days so an "I'll deal with this later" user
    /// is gently re-engaged.
    var lastBannerDismissedAt: Date?

    static let `default` = StatuslinePrefsData(
        connectedAt: nil,
        chainEnabled: false,
        chainTargetPath: nil,
        lastBackupPath: nil,
        lastSampleAt: nil,
        totalSamplesCollected: 0,
        lastBannerDismissedAt: nil
    )

    enum CodingKeys: String, CodingKey {
        case connectedAt
        case chainEnabled
        case chainTargetPath
        case lastBackupPath
        case lastSampleAt
        case totalSamplesCollected
        case lastBannerDismissedAt
    }

    init(
        connectedAt: Date?,
        chainEnabled: Bool,
        chainTargetPath: String?,
        lastBackupPath: String?,
        lastSampleAt: Date?,
        totalSamplesCollected: Int,
        lastBannerDismissedAt: Date?
    ) {
        self.connectedAt = connectedAt
        self.chainEnabled = chainEnabled
        self.chainTargetPath = chainTargetPath
        self.lastBackupPath = lastBackupPath
        self.lastSampleAt = lastSampleAt
        self.totalSamplesCollected = totalSamplesCollected
        self.lastBannerDismissedAt = lastBannerDismissedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.connectedAt = try c.decodeIfPresent(Date.self, forKey: .connectedAt)
        self.chainEnabled = try c.decodeIfPresent(Bool.self, forKey: .chainEnabled)
            ?? StatuslinePrefsData.default.chainEnabled
        self.chainTargetPath = try c.decodeIfPresent(String.self, forKey: .chainTargetPath)
        self.lastBackupPath = try c.decodeIfPresent(String.self, forKey: .lastBackupPath)
        self.lastSampleAt = try c.decodeIfPresent(Date.self, forKey: .lastSampleAt)
        self.totalSamplesCollected = try c.decodeIfPresent(Int.self, forKey: .totalSamplesCollected)
            ?? StatuslinePrefsData.default.totalSamplesCollected
        self.lastBannerDismissedAt = try c.decodeIfPresent(Date.self, forKey: .lastBannerDismissedAt)
    }
}

/// JSON persistence for `AppSettings`, modelled after `ExpandedGroupsStorage`.
///
/// Stored at `~/.claude/lupen/app_settings.json` next to the other
/// lupen state files. Failures are logged, never thrown — UI preference
/// persistence is best-effort and should never crash the app.
///
/// `load()` / `save(_:)` are synchronous and free-standing; the caller
/// (`AppSettings`) owns the debounce so this type stays trivially testable.
struct AppSettingsStorage: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let base: URL
            if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                base = URL(fileURLWithPath: configDir)
            } else {
                base = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude")
            }
            self.fileURL = base
                .appendingPathComponent("lupen")
                .appendingPathComponent("app_settings.json")
        }
    }

    /// Reads and decodes the persisted settings. Returns `.default` on any
    /// failure path (missing file, unreadable bytes, corrupt JSON, unknown
    /// enum value) so a torn file never locks the user out of the app.
    func load() -> AppSettingsData {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(AppSettingsData.self, from: data)
        } catch {
            LoggerService.shared.logFromAnyThread(
                .warning,
                "Failed to decode app_settings.json — using defaults (\(error.localizedDescription))",
                context: "Cache"
            )
            return .default
        }
    }

    /// Atomic JSON write. Sorts the pinned id array for deterministic file
    /// contents (same input → same bytes, which makes diffs easy to eyeball).
    func save(_ data: AppSettingsData) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let normalized = AppSettingsData(
                sessionListLayout: data.sessionListLayout,
                appearanceMode: data.appearanceMode,
                activeProvider: data.activeProvider,
                activeSourceId: data.activeSourceId,
                pinnedSessionIds: data.pinnedSessionIds.sorted(),
                claudeCodeRootPath: data.claudeCodeRootPath,
                codexRootPath: data.codexRootPath,
                providerConfigurations: data.providerConfigurations,
                showTodayCostInMenuBar: data.showTodayCostInMenuBar,
                compactCurrencyInMenuBar: data.compactCurrencyInMenuBar,
                openDashboardOnLaunch: data.openDashboardOnLaunch,
                startAtLogin: data.startAtLogin,
                showParseWarningBadge: data.showParseWarningBadge,
                showParseErrorBadge: data.showParseErrorBadge,
                statuslinePrefs: data.statuslinePrefs,
                sessionSources: data.sessionSources
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(normalized)
            try bytes.write(to: fileURL, options: .atomic)
        } catch {
            LoggerService.shared.logFromAnyThread(
                .error,
                "Failed to save app_settings.json: \(error.localizedDescription)",
                context: "Cache"
            )
        }
    }
}
