import Foundation

/// Applies and reverts statusline-related changes to
/// `~/.claude/settings.json`, plus the `~/.claude/lupen-statusline-tap.sh`
/// wrapper script Claude Code actually invokes. All operations are
/// best-effort and **preserve unknown JSON fields** so the user's
/// other settings (theme, hooks, mcpServers, …) survive the patch
/// untouched.
///
/// This is the only code path that mutates the user's `settings.json`.
/// Anything that needs to read the same file (e.g. health checks) goes
/// through `inspectSettings(_:)` so the JSON parsing rules stay
/// centralised.
struct StatuslinePatchService: Sendable {

    let claudeSettingsURL: URL
    let wrapperScriptURL: URL
    let lupenBinaryPath: String

    init(
        claudeSettingsURL: URL = StatuslinePaths.claudeSettingsFile,
        wrapperScriptURL: URL = StatuslinePaths.wrapperScript,
        lupenBinaryPath: String = Bundle.main.executablePath ?? ""
    ) {
        self.claudeSettingsURL = claudeSettingsURL
        self.wrapperScriptURL = wrapperScriptURL
        self.lupenBinaryPath = lupenBinaryPath
    }

    // MARK: - Connect / Disconnect

    /// Result of a successful Connect.
    struct ConnectResult: Equatable, Sendable {
        let backupURL: URL
        let chainTargetUsed: String?
    }

    enum ConnectError: Error, Equatable {
        case settingsReadFailed
        case settingsWriteFailed
        case wrapperWriteFailed
        case backupWriteFailed
    }

    /// Atomically:
    ///   1. Reads (or creates) `~/.claude/settings.json`.
    ///   2. Writes a timestamped backup next to it.
    ///   3. Writes the wrapper script with `chmod 0755`.
    ///   4. Patches settings.json:
    ///       * `statusLine.command` → wrapper script absolute path.
    ///       * `env.LUPEN_NEXT_STATUSLINE` ← `chainCommand` (if non-nil).
    ///
    /// `chainCommand` is the user's previous statusline command, or any
    /// shell snippet they want Lupen to chain after capturing the
    /// sample. Pass `nil` to skip chain.
    @discardableResult
    func connect(chainCommand: String?, now: Date = Date()) throws -> ConnectResult {
        // Read existing settings file. **If the file exists but doesn't
        // parse as JSON** (comments, trailing commas, JSON5), abort
        // with a recoverable error — proceeding would silently drop
        // every other field the user has set when we re-encode the
        // parsed dictionary. The UI catches this and prompts the user
        // to clean up their JSON first.
        let existing: [String: Any]
        if FileManager.default.fileExists(atPath: claudeSettingsURL.path) {
            guard let parsed = readJSON() else {
                throw ConnectError.settingsReadFailed
            }
            existing = parsed
        } else {
            existing = [:]
        }

        // 1) Backup. Backup lives next to the settings file (not at
        // a hardcoded `~/.claude/...` path) so tests with custom
        // settingsURLs can run in parallel without colliding.
        let backupURL = makeBackupURL(forTimestamp: now)
        do {
            // Ensure parent dir
            try FileManager.default.createDirectory(
                at: claudeSettingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // If the file doesn't exist yet, the backup is empty JSON
            // for symmetry with restore.
            let bytesToBackup: Data
            if let data = try? Data(contentsOf: claudeSettingsURL) {
                bytesToBackup = data
            } else {
                bytesToBackup = Data("{}".utf8)
            }
            try bytesToBackup.write(to: backupURL, options: .atomic)
        } catch {
            throw ConnectError.backupWriteFailed
        }

        // 2) Wrapper script
        let wrapperBody = WrapperScriptTemplate.render(
            lupenBinaryPath: lupenBinaryPath,
            timestamp: now
        )
        do {
            try FileManager.default.createDirectory(
                at: wrapperScriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(wrapperBody.utf8)
                .write(to: wrapperScriptURL, options: .atomic)
            // chmod 0755 — bash interpreter needs +x.
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: wrapperScriptURL.path
            )
        } catch {
            throw ConnectError.wrapperWriteFailed
        }

        // 3) Patch settings.json (preserve unknown fields)
        var patched = existing

        var statusLine = (patched["statusLine"] as? [String: Any]) ?? [:]
        statusLine["command"] = wrapperScriptURL.path
        patched["statusLine"] = statusLine

        if let chain = chainCommand, !chain.isEmpty {
            var env = (patched["env"] as? [String: Any]) ?? [:]
            env["LUPEN_NEXT_STATUSLINE"] = chain
            patched["env"] = env
        } else {
            // Chain disabled — make sure no stale env from a previous
            // connect lingers.
            if var env = patched["env"] as? [String: Any] {
                env.removeValue(forKey: "LUPEN_NEXT_STATUSLINE")
                if env.isEmpty {
                    patched.removeValue(forKey: "env")
                } else {
                    patched["env"] = env
                }
            }
        }

        do {
            try writeJSON(patched, to: claudeSettingsURL)
        } catch {
            throw ConnectError.settingsWriteFailed
        }

        // Prune older backups so we don't accumulate stale copies of
        // the user's settings (each one carries every other field they
        // had — theme, hooks, MCP secrets — so the privacy footprint
        // grows linearly with connect/disconnect cycles). Keep the 5
        // most recent including the one we just wrote.
        pruneOldBackups(keeping: 5)

        return ConnectResult(backupURL: backupURL, chainTargetUsed: chainCommand)
    }

    /// Delete `*lupen-backup-*` files beyond the most-recent N. Best-
    /// effort — failures are silent. Called automatically at the tail
    /// of every successful connect.
    private func pruneOldBackups(keeping keepCount: Int) {
        let parent = claudeSettingsURL.deletingLastPathComponent()
        let prefix = "settings.json.lupen-backup-"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let ours = entries.filter { $0.lastPathComponent.hasPrefix(prefix) }
        guard ours.count > keepCount else { return }
        // Sort newest → oldest, then drop everything after `keepCount`.
        let sorted = ours.sorted { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate) ?? .distantPast
            return da > db
        }
        for url in sorted.dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Reverts a Connect. Restores `settings.json` from the named backup
    /// (if it still exists) and removes the wrapper script. Doesn't touch
    /// `~/.claude/lupen/ratelimit-samples.jsonl` — sample retention is
    /// the caller's choice (Disconnect alert offers it as a separate
    /// checkbox).
    enum DisconnectError: Error, Equatable {
        case backupMissing
        case settingsRestoreFailed
    }

    func disconnect(restoringFrom backupURL: URL? = nil) throws {
        // If a specific backup is named, prefer it; otherwise look for
        // the most-recent backup we wrote.
        let chosen: URL? = backupURL ?? mostRecentBackup()
        guard let backup = chosen,
              FileManager.default.fileExists(atPath: backup.path)
        else {
            // Fall back to a programmatic strip — remove our wrapper
            // path from statusLine.command and LUPEN_NEXT_STATUSLINE
            // from env. Better than telling the user "your backup is
            // gone, you're on your own".
            try removeOurFootprintFromSettings()
            removeWrapperIfPresent()
            return
        }

        do {
            let bytes = try Data(contentsOf: backup)
            try bytes.write(to: claudeSettingsURL, options: .atomic)
        } catch {
            throw DisconnectError.settingsRestoreFailed
        }
        removeWrapperIfPresent()
    }

    private func removeWrapperIfPresent() {
        if FileManager.default.fileExists(atPath: wrapperScriptURL.path) {
            try? FileManager.default.removeItem(at: wrapperScriptURL)
        }
    }

    private func removeOurFootprintFromSettings() throws {
        guard var json = readJSON() else { return }
        if var statusLine = json["statusLine"] as? [String: Any],
           let cmd = statusLine["command"] as? String,
           cmd == wrapperScriptURL.path {
            statusLine.removeValue(forKey: "command")
            if statusLine.isEmpty {
                json.removeValue(forKey: "statusLine")
            } else {
                json["statusLine"] = statusLine
            }
        }
        if var env = json["env"] as? [String: Any] {
            env.removeValue(forKey: "LUPEN_NEXT_STATUSLINE")
            if env.isEmpty {
                json.removeValue(forKey: "env")
            } else {
                json["env"] = env
            }
        }
        try writeJSON(json, to: claudeSettingsURL)
    }

    // MARK: - Inspection (used by health checker)

    struct SettingsInspection: Sendable, Equatable {
        let exists: Bool
        let parses: Bool
        let statusLineCommand: String?
        let chainCommand: String?
    }

    func inspectSettings() -> SettingsInspection {
        guard FileManager.default.fileExists(atPath: claudeSettingsURL.path) else {
            return .init(
                exists: false, parses: false,
                statusLineCommand: nil, chainCommand: nil
            )
        }
        guard let json = readJSON() else {
            return .init(
                exists: true, parses: false,
                statusLineCommand: nil, chainCommand: nil
            )
        }
        let cmd = (json["statusLine"] as? [String: Any])?["command"] as? String
        let env = json["env"] as? [String: Any]
        let chain = env?["LUPEN_NEXT_STATUSLINE"] as? String
        return .init(
            exists: true, parses: true,
            statusLineCommand: cmd, chainCommand: chain
        )
    }

    /// Probe the wrapper script for existence + executability +
    /// LUPEN_BIN drift. Used by the health checker.
    struct WrapperInspection: Sendable, Equatable {
        let exists: Bool
        let executable: Bool
        let lupenBinaryLineMatches: Bool
    }

    func inspectWrapper() -> WrapperInspection {
        let path = wrapperScriptURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            return .init(exists: false, executable: false, lupenBinaryLineMatches: false)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let exec = (perms & 0o111) != 0

        let body = (try? String(contentsOf: wrapperScriptURL, encoding: .utf8)) ?? ""
        let escaped = WrapperScriptTemplate.shellEscape(lupenBinaryPath)
        let matches = body.contains("LUPEN_BIN=\(escaped)")
        return .init(exists: true, executable: exec, lupenBinaryLineMatches: matches)
    }

    // MARK: - Drift auto-heal

    /// Rewrite the wrapper script with a fresh LUPEN_BIN line. Called by
    /// the health checker when it spots `Lupen.app` has moved (or the
    /// user dragged the .app to a new folder). Does **not** touch
    /// settings.json — the wrapper path didn't change, only its
    /// embedded variable.
    func rewriteWrapperForCurrentBinaryPath(now: Date = Date()) throws {
        let body = WrapperScriptTemplate.render(
            lupenBinaryPath: lupenBinaryPath,
            timestamp: now
        )
        try Data(body.utf8).write(to: wrapperScriptURL, options: .atomic)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapperScriptURL.path
        )
    }

    // MARK: - JSON helpers

    private func readJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeSettingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: []))
            as? [String: Any]
    }

    private func writeJSON(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    /// Build a unique backup URL next to `claudeSettingsURL`. The
    /// "next-to" requirement keeps tests with custom settingsURLs
    /// isolated; production behaviour is unchanged because the default
    /// `claudeSettingsURL` lives in `~/.claude/`. Adds a process-unique
    /// suffix so two tests landing inside the same wall-clock second
    /// don't fight over the same path.
    private func makeBackupURL(forTimestamp ts: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: ts)
            .replacingOccurrences(of: ":", with: "-")
        let suffix = String(format: "%08x", arc4random_uniform(UInt32.max))
        return claudeSettingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.lupen-backup-\(stamp)-\(suffix)")
    }

    private func mostRecentBackup() -> URL? {
        let parent = claudeSettingsURL.deletingLastPathComponent()
        let prefix = "settings.json.lupen-backup-"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        // Filter out backups that already contain *our* footprint —
        // i.e. an old backup whose `statusLine.command` is the wrapper.
        // Restoring from one of those would leave the user pointed at
        // a wrapper script we're about to delete (broken statusline).
        // Prefer pre-Lupen backups; fall back to any backup if none
        // qualify (the user can Reconnect to recover, which is still
        // less destructive than no restore at all).
        let prefiltered = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
        let preLupen = prefiltered.filter { url in
            !backupContainsOurWrapper(url)
        }
        let pool = preLupen.isEmpty ? prefiltered : preLupen
        return pool.max(by: { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate) ?? .distantPast
            return da < db
        })
    }

    /// Returns true if the backup's JSON has `statusLine.command`
    /// pointing at our wrapper script — meaning the backup was taken
    /// *after* a previous Connect, not before. Restoring from such a
    /// backup leaves the user statusline pointing at a wrapper we're
    /// about to delete.
    private func backupContainsOurWrapper(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let cmd = statusLine["command"] as? String
        else { return false }
        return cmd == wrapperScriptURL.path
    }
}
