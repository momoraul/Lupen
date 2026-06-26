import ArgumentParser
import Foundation

/// `lupen config` — where Lupen reads and writes for the current provider.
/// Read-only; handy for support and "is it looking at the right place?".
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show the paths and versions Lupen uses for the current provider."
    )

    @OptionGroup var options: CLIGlobalOptions

    /// The (ordered) key/value rows config prints. Pure + hoisted so the
    /// JSON/CSV key contract is unit-testable.
    static func fields(
        provider: ProviderKind,
        appSupport: URL = LupenPaths.applicationSupportRoot()
    ) -> [(String, String)] {
        let index = LupenPaths.indexDatabaseURL(for: provider, appSupportRoot: appSupport)
        let sourceDir = provider == .claudeCode
            ? FileDiscovery().projectsDirectory
            : CodexSessionDiscovery().sessionsDirectory
        return [
            ("version", CLIVersion.current),
            ("schema", String(ProviderDatabase.schemaVersion)),
            ("provider", provider.rawValue),
            ("sourceDir", sourceDir.path),
            ("indexDb", index.path),
            ("appSupport", appSupport.path),
        ]
    }

    func run() throws {
        let fields = ConfigCommand.fields(provider: options.provider)

        if options.json {
            try CLIOutput.printJSON(Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1) }))
        } else if options.csv {
            CLIOutput.line(CLICSV.render(header: ["key", "value"], rows: fields.map { [$0.0, $0.1] }))
        } else {
            let width = fields.map(\.0.count).max() ?? 0
            for (key, value) in fields {
                CLIOutput.line("  \(key.padding(toLength: width, withPad: " ", startingAt: 0))  \(value)")
            }
        }
    }
}

/// `lupen refresh` — update the index from the logs now, without a report.
/// Useful to pre-warm the index (e.g. in a cron job before `statusline`).
struct RefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Index new/changed logs now (no report)."
    )

    @OptionGroup var options: CLIGlobalOptions

    func run() throws {
        let engine = try CLIEngine.open(source: options.resolvedSource, refresh: true)
        CLIOutput.line(CLIRefreshMessage.text(for: engine.refreshOutcome))
    }
}

/// Pure summary of a refresh outcome for `lupen refresh` — surfaces both
/// imported and failed counts so a partial failure isn't reported as
/// "up to date".
enum CLIRefreshMessage {
    static func text(for outcome: CLIRefresher.Outcome?) -> String {
        guard let outcome else { return "Index already up to date." }
        if outcome.skipped { return "Another Lupen process is indexing; skipped." }
        var parts: [String] = []
        if outcome.imported > 0 { parts.append("Indexed \(outcome.imported) updated session(s).") }
        if outcome.failed > 0 { parts.append("\(outcome.failed) session(s) failed (retried next run).") }
        return parts.isEmpty ? "Index already up to date." : parts.joined(separator: " ")
    }
}

/// `lupen install-cli` — symlink the `lupen` command onto your PATH. For DMG
/// installs; the Homebrew cask does this automatically via its `binary`
/// stanza, so brew users don't need it.
struct InstallCLICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cli",
        abstract: "Symlink `lupen` onto your PATH (DMG installs; brew does it for you)."
    )

    @Option(name: .long, help: "Directory to link into (must be on your PATH).")
    var binDir: String?

    func run() throws {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw ValidationError("Couldn't locate the Lupen executable.")
        }

        guard let dir = CLIInstall.chooseDir(
            override: binDir,
            candidates: CLIInstall.candidateDirs,
            isWritableDir: CLIInstall.isWritableDir,
            ensureDir: CLIInstall.ensureUserDir
        ) else {
            CLIOutput.note("No writable PATH directory found. Symlink it yourself:")
            let suggestedDir = CLIInstall.candidateDirs.first ?? "/usr/local/bin"
            CLIOutput.line("ln -s '\(executable.path)' \(suggestedDir)/lupen")
            throw ExitCode(3)
        }

        let link = URL(fileURLWithPath: dir).appendingPathComponent("lupen")
        switch CLIInstall.decide(at: link.path) {
        case .refuseExistingFile:
            throw ValidationError("\(link.path) already exists and isn't a Lupen symlink; remove it first.")
        case .replaceSymlink:
            try? FileManager.default.removeItem(at: link)
            fallthrough
        case .create:
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        }

        CLIOutput.line("Installed: \(link.path) → \(executable.path)")
        if !CLIInstall.dirOnPath(dir) {
            CLIOutput.note("\(dir) isn't on your PATH yet — add it to use `lupen` directly.")
        }
    }
}

enum CLIInstall {
    static let candidateDirs = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]

    enum LinkDecision: Equatable {
        case create            // nothing there
        case replaceSymlink    // an existing symlink we can update
        case refuseExistingFile // a real file/dir — don't clobber
    }

    /// First usable target directory: an explicit override, else the first
    /// candidate that exists-and-is-writable (creating `~/.local/bin` if
    /// that's the fallback). Returns an expanded absolute path, or nil.
    static func chooseDir(
        override: String?,
        candidates: [String],
        isWritableDir: (String) -> Bool,
        ensureDir: (String) -> Bool
    ) -> String? {
        if let override {
            let path = (override as NSString).expandingTildeInPath
            return isWritableDir(path) ? path : nil
        }
        for candidate in candidates {
            let path = (candidate as NSString).expandingTildeInPath
            if isWritableDir(path) { return path }
            // Allow creating a user-owned fallback dir (~/.local/bin).
            if candidate.hasPrefix("~"), ensureDir(path), isWritableDir(path) { return path }
        }
        return nil
    }

    static func decide(at path: String) -> LinkDecision {
        // `attributesOfItem` does NOT follow symlinks, so it detects an
        // existing link (even a dangling one) as `.typeSymbolicLink`; it
        // throws (→ nil) only when nothing exists at the path.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .create
        }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink ? .replaceSymlink : .refuseExistingFile
    }

    // MARK: - FS probes (overridable for tests)

    static func isWritableDir(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue && fm.isWritableFile(atPath: path)
    }

    static func ensureUserDir(_ path: String) -> Bool {
        (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil
    }

    static func dirOnPath(_ dir: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map(String.init).contains(dir)
    }
}
