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

    // MARK: - Source-id-keyed paths (multi-source)

    /// Per-source on-disk root, keyed by the source's stable id. Built-in
    /// source ids equal `ProviderKind.rawValue`, so a built-in source resolves
    /// to the same `providers/<rawValue>` folder the app has always used — the
    /// multi-source model adds sibling folders without disturbing existing ones.
    static func providerRoot(
        forSourceId sourceId: String,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        appSupportRoot
            .appendingPathComponent("providers")
            .appendingPathComponent(sourceId)
    }

    static func sessionCacheURL(
        forSourceId sourceId: String,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(forSourceId: sourceId, appSupportRoot: appSupportRoot)
            .appendingPathComponent("session_cache.json")
    }

    static func parseSnapshotURL(
        forSourceId sourceId: String,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(forSourceId: sourceId, appSupportRoot: appSupportRoot)
            .appendingPathComponent("parse_snapshot.json")
    }

    static func offsetsURL(
        forSourceId sourceId: String,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(forSourceId: sourceId, appSupportRoot: appSupportRoot)
            .appendingPathComponent("offsets.json")
    }

    /// Per-source SQLite index database (SQLite-first refactor,
    /// docs/Research/2026-06-10-sqlite-first-refactor). One file per source
    /// keeps lifecycles independent and makes the rebuild-on-version-bump
    /// policy a per-source wipe.
    static func indexDatabaseURL(
        forSourceId sourceId: String,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(forSourceId: sourceId, appSupportRoot: appSupportRoot)
            .appendingPathComponent("index.sqlite3")
    }

    /// Advisory lock file the CLI holds while refreshing this source's index,
    /// so two `lupen` runs don't index in parallel.
    static func refreshLockURL(
        forSourceId sourceId: String,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(forSourceId: sourceId, appSupportRoot: appSupportRoot)
            .appendingPathComponent("refresh.lock")
    }

    // MARK: - ProviderKind convenience (built-in sources)
    //
    // Each delegates to the source-id variant using the kind's rawValue (==
    // the built-in source id), so existing call sites are unchanged and the
    // resulting paths are byte-identical to the pre-multi-source layout.

    static func providerRoot(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(forSourceId: provider.rawValue, appSupportRoot: appSupportRoot)
    }

    static func sessionCacheURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        sessionCacheURL(forSourceId: provider.rawValue, appSupportRoot: appSupportRoot)
    }

    static func parseSnapshotURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        parseSnapshotURL(forSourceId: provider.rawValue, appSupportRoot: appSupportRoot)
    }

    static func offsetsURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        offsetsURL(forSourceId: provider.rawValue, appSupportRoot: appSupportRoot)
    }

    static func codexUsageSnapshotURL(
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        providerRoot(for: .codex, appSupportRoot: appSupportRoot)
            .appendingPathComponent("usage_snapshot.json")
    }

    static func indexDatabaseURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        indexDatabaseURL(forSourceId: provider.rawValue, appSupportRoot: appSupportRoot)
    }

    static func refreshLockURL(
        for provider: ProviderKind,
        appSupportRoot: URL = applicationSupportRoot()
    ) -> URL {
        refreshLockURL(forSourceId: provider.rawValue, appSupportRoot: appSupportRoot)
    }
}
