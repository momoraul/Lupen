import AppKit
import Foundation

/// Launches Claude Code in Terminal.app to continue (`--resume`) a given
/// session from Lupen.
///
/// The feature hinges on two things working correctly:
///
/// 1. **Knowing the right cwd**. Claude Code only finds a resumable
///    session if the caller's current directory matches the one the
///    session was originally recorded in. We get that cwd with a
///    two-stage fallback:
///    a. `ProjectPathDecoder.decodeFullPath` on the encoded project
///       directory name (fast path, correct for every path that
///       doesn't have an internal underscore in one of its segments).
///    b. If the decoded path doesn't exist on disk, we crack open the
///       session's JSONL file and pull the first `cwd` field we find.
///       Claude Code writes the original absolute cwd verbatim on
///       almost every entry, so this is authoritative.
///
/// 2. **Actually running `claude --resume` inside a new Terminal window**.
///    The `open -a Terminal --args …` approach from the plan sketch
///    doesn't work — Terminal.app is a Cocoa GUI app and ignores
///    `--args` as shell commands. The canonical macOS pattern is
///    `osascript -e 'tell application "Terminal" to do script "…"'`,
///    which hands a shell command to a new window and activates it.
///
/// Every user-visible string passes through two levels of escaping:
/// once for the POSIX shell `do script` argument (single-quoted), and
/// once for the AppleScript string literal the shell command lives
/// inside (double-quoted). The `buildAppleScript` helper is exposed
/// `static`/internal so tests can verify the escaping without firing
/// a real Process.
@MainActor
final class SessionResumer {

    enum ResumeError: Swift.Error, LocalizedError {
        /// Neither the decoded path nor the JSONL fallback produced a
        /// directory that currently exists — typically because the user
        /// moved or deleted the project after the session was recorded.
        case cannotResolveCwd
        /// `/usr/bin/osascript` itself refused to launch. Almost never
        /// happens in practice (the binary is a core macOS component).
        case launchFailed(underlying: Swift.Error)
        /// osascript ran but Terminal.app rejected the AppleEvent. The
        /// usual cause is the user denying the one-time "Lupen
        /// wants to control Terminal" automation prompt, or later
        /// revoking it in System Settings → Privacy & Security →
        /// Automation. `stderr` carries the raw error for diagnostics.
        case terminalAutomationDenied(stderr: String)
        /// osascript exited non-zero for a reason we don't have a
        /// specific diagnosis for. `stderr` is included verbatim so the
        /// alert can surface something actionable.
        case osascriptFailed(stderr: String)

        var errorDescription: String? {
            switch self {
            case .cannotResolveCwd:
                return "Couldn't find the session's original working directory. The project folder may have been moved, renamed, or deleted."
            case .launchFailed(let err):
                return "Failed to launch Terminal: \(err.localizedDescription)"
            case .terminalAutomationDenied:
                return "macOS blocked Lupen from controlling Terminal. Open System Settings → Privacy & Security → Automation, find Lupen, and enable the Terminal toggle. Then try again."
            case .osascriptFailed(let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "Terminal refused the resume command."
                    : "Terminal refused the resume command:\n\(trimmed)"
            }
        }
    }

    /// Root under which Claude Code stores per-project JSONL bundles.
    /// Injectable so tests can point at a tmp directory.
    private let claudeProjectsDirectory: URL

    init(claudeProjectsDirectory: URL? = nil) {
        if let url = claudeProjectsDirectory {
            self.claudeProjectsDirectory = url
        } else {
            let base: URL
            if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                base = URL(fileURLWithPath: configDir)
            } else {
                base = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude")
            }
            self.claudeProjectsDirectory = base.appendingPathComponent("projects")
        }
    }

    // MARK: - Public entrypoint

    /// Resolve the session's original cwd, build the AppleScript, and
    /// hand it to `osascript`. Throws `ResumeError` on any failure so
    /// the caller (usually the sidebar context menu) can surface an
    /// NSAlert.
    ///
    /// We wait for `osascript` to exit and inspect stderr so we can tell
    /// Automation-permission failures (the common case on first use)
    /// apart from other AppleScript errors. `do script` returns
    /// immediately once the Terminal window is handed the command, so
    /// the wait is bounded (~100 ms in practice).
    func resume(session: Session) throws {
        let cwd = try resumeCwd(for: session)
        let script = Self.buildAppleScript(
            provider: session.provider, cwd: cwd, sessionId: session.rawSessionId)
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // Discard stdout — `do script` prints a Terminal object
        // reference we don't need.
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw ResumeError.launchFailed(underlying: error)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // Apple Events returns error -1743 when the user has not
            // granted Automation permission for this app → target app.
            // `-1719` shows up when Terminal.app itself is somehow not
            // scriptable (rare, but we treat it the same — either way
            // the fix is in System Settings).
            if stderr.contains("-1743") || stderr.contains("-1719")
                || stderr.localizedCaseInsensitiveContains("not authorized")
                || stderr.localizedCaseInsensitiveContains("not allowed to send") {
                throw ResumeError.terminalAutomationDenied(stderr: stderr)
            }
            throw ResumeError.osascriptFailed(stderr: stderr)
        }
    }

    /// Build the raw shell command (`cd '<cwd>' && claude --resume '<sid>'`)
    /// that the user could paste into any terminal to pick up the session.
    /// Goes through the same cwd resolution as `resume(session:)` so the
    /// pasted command reflects whatever project path the session was
    /// actually recorded in.
    ///
    /// Throws `ResumeError.cannotResolveCwd` if neither decoder nor JSONL
    /// fallback yields a directory that exists — in that case there's no
    /// command worth copying.
    func buildResumeCommand(for session: Session) throws -> String {
        let cwd = try resumeCwd(for: session)
        return Self.buildShellCommand(
            provider: session.provider, cwd: cwd, sessionId: session.rawSessionId)
    }

    /// Copy a one-line shell command for the session onto the general
    /// pasteboard so the user can paste it into any terminal. Returns
    /// the command string so the caller can optionally show it in a
    /// confirmation alert.
    @discardableResult
    func copyResumeCommand(for session: Session) throws -> String {
        let command = try buildResumeCommand(for: session)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        return command
    }

    // MARK: - cwd resolution (internal for tests)

    /// cwd for the resume command, provider-aware.
    ///
    /// Claude Code can only re-find a session when the caller's cwd
    /// matches the one it recorded, so cwd is **required** — `resolveCwd`
    /// throws if it can't produce a real directory. Codex resumes by
    /// session UUID (`codex resume <uuid>`), which takes precedence over
    /// the picker's cwd filter, so cwd is **optional** there: we `cd`
    /// into the recorded project folder when it still exists (keeps the
    /// agent's working context right) and otherwise omit the `cd`
    /// entirely. For Codex the recorded cwd is already the absolute path
    /// stored in `projectPath` (the importer copies `session_meta.cwd`
    /// verbatim), so no decoding is needed.
    func resumeCwd(for session: Session) throws -> String? {
        switch session.provider {
        case .codex:
            if let path = session.projectPath, Self.directoryExists(at: path) {
                return path
            }
            return nil
        case .claudeCode:
            return try resolveCwd(for: session)
        }
    }

    /// Two-stage fallback to find the session's original working directory.
    ///
    /// Returns the cwd as an absolute path string. Throws if neither the
    /// decoder nor the JSONL scan finds a directory that currently exists
    /// on disk — at that point we can't help the user and the context
    /// menu needs to show an alert rather than silently `cd`-ing into
    /// somewhere nonsensical.
    func resolveCwd(for session: Session) throws -> String {
        guard let encoded = session.projectPath, !encoded.isEmpty else {
            // A session without a projectPath can't even attempt a
            // decode; nothing else we can do.
            throw ResumeError.cannotResolveCwd
        }

        // Stage 1: best-effort decoder. Fast, correct for ~every real
        // path we've seen in the wild.
        let decoded = ProjectPathDecoder.decodeFullPath(encoded)
        if Self.directoryExists(at: decoded) {
            return decoded
        }

        // Stage 2: authoritative JSONL lookup. Claude Code records the
        // original cwd verbatim on basically every message entry, so
        // reading the first one gets the un-mangled truth.
        let jsonlURL = claudeProjectsDirectory
            .appendingPathComponent(encoded)
            .appendingPathComponent("\(session.rawSessionId).jsonl")
        if let jsonlCwd = Self.readFirstCwd(from: jsonlURL),
           Self.directoryExists(at: jsonlCwd) {
            return jsonlCwd
        }

        throw ResumeError.cannotResolveCwd
    }

    /// FileManager wrapper that also rejects regular files masquerading
    /// as directories (we only want to `cd` into real folders).
    private static func directoryExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Scan up to the first 50 lines of a JSONL file for a `"cwd"` field
    /// and return its string value. 50 is a generous budget — in every
    /// real file inspected the first `cwd` appears by line 1 or 2 (the
    /// only lines that precede it are non-message entries like
    /// `file-history-snapshot`).
    ///
    /// Returns nil on read failure, missing field, or if the budget
    /// elapses without seeing one.
    private static func readFirstCwd(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var seen = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            seen += 1
            if seen > 50 { break }
            // Cheap pre-filter: skip lines that clearly don't carry a cwd.
            guard line.contains("\"cwd\":") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = obj["cwd"] as? String,
                  !cwd.isEmpty
            else { continue }
            return cwd
        }
        return nil
    }

    // MARK: - Command / AppleScript construction (pure, testable)

    /// Build the raw shell command string — e.g.
    /// `cd '<cwd>' && claude --resume '<sid>'` or `codex resume '<sid>'`.
    /// This is the single place the command is assembled; both the
    /// Terminal.app AppleScript path and the "Copy Resume Command" menu
    /// go through here so they stay in sync.
    ///
    /// The resume verb comes from `provider.resumeCommandPrefix`. `cwd`
    /// is optional: Claude always supplies one (it's required to re-find
    /// the session), Codex may pass `nil` when the recorded project
    /// folder is gone — `codex resume <uuid>` still works without a `cd`.
    ///
    /// Both inputs are single-quoted, so no inner character needs
    /// escaping *except* another single quote, which
    /// `shellEscapeSingleQuoted` handles with the canonical `'\''`
    /// close-literal-reopen trick.
    static func buildShellCommand(provider: ProviderKind, cwd: String?, sessionId: String) -> String {
        let safeSid = shellEscapeSingleQuoted(sessionId)
        let resume = "\(provider.resumeCommandPrefix) '\(safeSid)'"
        guard let cwd, !cwd.isEmpty else { return resume }
        let safeCwd = shellEscapeSingleQuoted(cwd)
        return "cd '\(safeCwd)' && \(resume)"
    }

    /// Build the AppleScript program that drives Terminal.app's
    /// `do script` to open a new window, optionally `cd` into `cwd`, and
    /// run the provider's resume command (`claude --resume <id>` or
    /// `codex resume <id>`).
    ///
    /// On top of `buildShellCommand`'s shell-layer escaping, the entire
    /// shell command is dropped into a double-quoted AppleScript string
    /// literal, so every `\` and `"` in the shell text gets re-escaped
    /// with a backslash via `appleScriptEscape`.
    static func buildAppleScript(provider: ProviderKind, cwd: String?, sessionId: String) -> String {
        let shellCommand = buildShellCommand(provider: provider, cwd: cwd, sessionId: sessionId)
        let asEscaped = appleScriptEscape(shellCommand)
        return """
        tell application "Terminal"
            activate
            do script "\(asEscaped)"
        end tell
        """
    }

    /// Escapes a string for inclusion inside a POSIX shell single-quoted
    /// literal. Within `'…'`, the only character that can't appear is
    /// another `'`, and the idiomatic workaround is to close the quoted
    /// string, emit an escaped literal quote, and reopen it — `'\''`.
    static func shellEscapeSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Escapes a string for inclusion inside an AppleScript double-quoted
    /// literal. AppleScript uses `\` as an escape character, so we
    /// escape `\` first (so the later `"`-escape doesn't double-escape
    /// it) and then `"`.
    static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
