import Foundation

enum LupenPaths {
    static func applicationSupportRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["LUPEN_APP_SUPPORT_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let fallback = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
        return (base ?? fallback)
            .appendingPathComponent("Lupen")
    }

    static func providerRoot(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        appSupportRoot
            .appendingPathComponent("providers")
            .appendingPathComponent(provider.rawValue)
    }

    static func sessionCacheURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(for: provider, appSupportRoot: appSupportRoot)
            .appendingPathComponent("session_cache.json")
    }

    static func parseSnapshotURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(for: provider, appSupportRoot: appSupportRoot)
            .appendingPathComponent("parse_snapshot.json")
    }

    static func offsetsURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(for: provider, appSupportRoot: appSupportRoot)
            .appendingPathComponent("offsets.json")
    }

    static func codexUsageSnapshotURL(
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(for: .codex, appSupportRoot: appSupportRoot)
            .appendingPathComponent("usage_snapshot.json")
    }

    /// Per-provider SQLite index database (SQLite-first refactor,
    /// docs/Research/2026-06-10-sqlite-first-refactor). One file per
    /// provider keeps lifecycles independent and makes the
    /// rebuild-on-version-bump policy a per-provider wipe.
    static func indexDatabaseURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(for: provider, appSupportRoot: appSupportRoot)
            .appendingPathComponent("index.sqlite3")
    }

    /// Advisory lock file the CLI holds while refreshing this provider's
    /// index, so two `lupen` runs don't index in parallel.
    static func refreshLockURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(for: provider, appSupportRoot: appSupportRoot)
            .appendingPathComponent("refresh.lock")
    }
}
