import ArgumentParser
import Foundation

/// `lupen search <text>` — full-text search across every prompt, grouped by
/// session. Pairs with `lupen resume` to jump back into a found session.
struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find sessions by any prompt text they contain."
    )

    @OptionGroup var options: CLIGlobalOptions
    @Argument(help: "Text to search for (quote multi-word queries).")
    var query: String
    @Option(name: .long, help: "Max sessions to show.")
    var limit = 20

    func validate() throws {
        if limit < 0 { throw ValidationError("--limit must be 0 or greater.") }
    }

    func run() throws {
        let engine = try CLIEngine.open(provider: options.provider, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }

        // Sanitize the query into an FTS5 prefix expression (as the GUI's
        // search does) so metacharacters in user input can't make MATCH
        // throw; an all-whitespace query simply matches nothing.
        let hits: [StoreSearchHit]
        if let match = ProviderStore.ftsPrefixQuery(from: query) {
            hits = try engine.store.search(matching: match, limit: 500)
        } else {
            hits = []
        }
        let report = CLISearchReport(
            provider: options.provider, query: query,
            rows: CLISearchReport.group(hits: hits, limit: limit)
        )

        if options.json {
            try CLIOutput.printJSON(report.jsonArray)
        } else if options.csv {
            CLIOutput.line(report.csv)
        } else {
            report.printTable(color: CLIStyle.useColor(disabled: options.noColor))
        }
    }
}

/// Data + rendering for `lupen search`.
struct CLISearchReport {
    struct Row: Equatable {
        let sessionId: String
        let hits: Int
        let snippet: String
    }

    let provider: ProviderKind
    let query: String
    let rows: [Row]

    /// Group FTS hits by session (preserving FTS rank order), keep the first
    /// snippet per session, and cap to `limit` sessions. Pure.
    static func group(hits: [StoreSearchHit], limit: Int) -> [Row] {
        var order: [String] = []
        var byId: [String: (hits: Int, snippet: String)] = [:]
        for hit in hits {
            if byId[hit.sessionId] == nil {
                order.append(hit.sessionId)
                byId[hit.sessionId] = (0, hit.snippet)
            }
            byId[hit.sessionId]?.hits += 1
        }
        let rows = order.map { Row(sessionId: $0, hits: byId[$0]?.hits ?? 0, snippet: byId[$0]?.snippet ?? "") }
        return (limit >= 0 && rows.count > limit) ? Array(rows.prefix(limit)) : rows
    }

    func printTable(color: Bool) {
        guard !rows.isEmpty else {
            CLIOutput.line("No matches for \"\(query)\".")
            return
        }
        CLIOutput.line("\(provider.cliLabel) · search \"\(query)\"")
        CLIOutput.line()
        let table = CLITable(
            columns: [.init("SESSION"), .init("HITS", align: .right), .init("MATCH")],
            rows: rows.map { [CLITopReport.shortID($0.sessionId), CLIFormat.int($0.hits), CLITopReport.truncate($0.snippet, 70)] }
        )
        CLIOutput.line(table.render(color: color))
        CLIOutput.line()
        CLIOutput.line("\(rows.count) session(s) matched. Resume one with: lupen resume <id>  (full ids in --json)")
    }

    var jsonArray: [[String: Any]] {
        rows.map { ["sessionId": $0.sessionId, "hits": $0.hits, "snippet": $0.snippet] }
    }

    var csv: String {
        CLICSV.render(
            header: ["sessionId", "hits", "snippet"],
            rows: rows.map { [$0.sessionId, String($0.hits), $0.snippet] }
        )
    }
}

/// `lupen resume <id>` — print (or run) the shell command that reopens a
/// session in its CLI (`claude --resume` / `codex resume`).
struct ResumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Print the command to resume a session in its CLI.",
        discussion: "Pass a full session id (from `lupen search` / `top --json`). --run executes it instead of printing."
    )

    @OptionGroup var options: CLIGlobalOptions
    @Argument(help: "Session id to resume.")
    var sessionId: String
    @Flag(name: .customLong("run"), help: "Execute the resume command instead of printing it.")
    var runNow = false

    func run() throws {
        // Resume reads the existing index (no refresh needed to look up a known id).
        let engine = try CLIEngine.open(provider: options.provider, refresh: false)
        guard let row = try engine.store.session(id: sessionId) else {
            throw ValidationError(
                "No session '\(sessionId)' for \(options.provider.cliLabel). Use the full id from `lupen search` or `lupen top --json`."
            )
        }

        let cwd = CLIResume.resolveCwd(provider: options.provider, projectPath: row.projectPath)
        // Claude needs the original cwd to re-find the session, so a cd-less
        // command wouldn't actually resume. Rather than print a broken
        // command, fail with the bare command so the user can cd themselves.
        if cwd == nil, options.provider == .claudeCode {
            throw ValidationError(
                "Couldn't resolve this session's project directory; `claude --resume` needs it. cd to the project, then run: claude --resume '\(row.rawId)'"
            )
        }
        let command = SessionResumer.buildShellCommand(
            provider: options.provider, cwd: cwd, sessionId: row.rawId
        )

        if runNow {
            CLIResume.run(command)
        } else {
            // Strip control chars before printing: the command embeds the
            // session id and decoded project path (log-derived), so an exotic
            // control byte there must not reach the terminal raw as an escape
            // sequence. The --run path is unaffected (its single-quoting holds).
            CLIOutput.line(CLITable.sanitize(command))
        }
    }
}

enum CLIResume {
    /// Best-effort working directory for the resume `cd` (stage-1 decode +
    /// existence check, mirroring SessionResumer). Returns nil when it can't
    /// be resolved — the caller decides whether that's fatal.
    static func resolveCwd(
        provider: ProviderKind,
        projectPath: String?,
        directoryExists: (String) -> Bool = CLIResume.directoryExists
    ) -> String? {
        guard let encoded = projectPath, !encoded.isEmpty else { return nil }
        switch provider {
        case .codex:
            return directoryExists(encoded) ? encoded : nil
        case .claudeCode:
            let decoded = ProjectPathDecoder.decodeFullPath(encoded)
            return directoryExists(decoded) ? decoded : nil
        }
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Run the resume command inheriting the terminal so the resumed CLI is
    /// interactive, then exit with its status.
    static func run(_ command: String) -> Never {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        } catch {
            CLIOutput.note("Failed to run resume command: \(error.localizedDescription)")
            exit(1)
        }
    }
}
