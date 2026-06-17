import Foundation

/// Single source of truth for every on-disk path the statusline tap
/// touches. `CLAUDE_CONFIG_DIR` honours the same env override that
/// `AppSettingsStorage` does — staying consistent so test setups and
/// users with non-default config dirs see one coherent picture.
enum StatuslinePaths {

    /// Resolved `~/.claude/` (or `$CLAUDE_CONFIG_DIR`). The home base
    /// every other path hangs off.
    static var claudeConfigDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    /// `~/.claude/settings.json` — Claude Code's user settings file. We
    /// patch this to register the wrapper script as `statusLine.command`.
    static var claudeSettingsFile: URL {
        claudeConfigDirectory.appendingPathComponent("settings.json")
    }

    /// `~/.claude/lupen-statusline-tap.sh` — the wrapper shell script Lupen
    /// installs during Connect. settings.json points here, not to Lupen.app
    /// directly, so a Lupen uninstall doesn't break the user's statusline.
    static var wrapperScript: URL {
        claudeConfigDirectory.appendingPathComponent("lupen-statusline-tap.sh")
    }

    /// `~/.claude/lupen/` — Lupen's data directory. Same root as
    /// `app_settings.json` and `parse_snapshot.json`.
    static var lupenDataDirectory: URL {
        claudeConfigDirectory.appendingPathComponent("lupen")
    }

    /// `~/.claude/lupen/ratelimit-samples.jsonl` — append-only log of
    /// statusline pushes the helper has captured.
    static var sampleStoreFile: URL {
        lupenDataDirectory.appendingPathComponent("ratelimit-samples.jsonl")
    }

    /// `~/.claude/lupen/last-pushed.json` — tiny write-time dedup
    /// sidecar. The helper compares each incoming `rate_limits` block
    /// against this file; identical values skip the JSONL append.
    /// Roughly 83% of statusline triggers carry no value change in
    /// practice, so dedup keeps the JSONL ~5× smaller.
    static var lastPushedFile: URL {
        lupenDataDirectory.appendingPathComponent("last-pushed.json")
    }

    // Backup paths are produced by `StatuslinePatchService.makeBackupURL`
    // — they live next to the configured settings file (not the global
    // claude-config dir) so test harnesses with custom settings paths
    // stay isolated. No helper needed here.
}
