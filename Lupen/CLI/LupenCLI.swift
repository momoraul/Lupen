import ArgumentParser
import Foundation

/// Root of the `lupen` command-line tool. Subcommands read the same
/// on-disk SQLite index the GUI app maintains (see `CLIEngine`) and print
/// usage/cost reports. Lives in the app target so it links the existing
/// Store/Domain engine directly — no duplicate parsing logic.
struct LupenCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lupen",
        abstract: "Itemized cost and usage reports for Claude Code and Codex — computed locally.",
        discussion: """
            Select a period with one of --last (e.g. 30d, 4w, 1m), --month \
            (YYYY-MM), or --since/--until (YYYY-MM-DD). These styles are \
            mutually exclusive; with none, all recorded usage is included.
            """,
        version: CLIVersion.current,
        subcommands: [
            SummaryCommand.self, SkillsCommand.self,
            DailyCommand.self, WeeklyCommand.self, MonthlyCommand.self,
            TopCommand.self, ModelsCommand.self, ProjectsCommand.self,
            SearchCommand.self, ResumeCommand.self,
            BudgetCommand.self, StatuslineCommand.self, VerifyCommand.self,
            RefreshCommand.self, ConfigCommand.self, InstallCLICommand.self,
        ],
        defaultSubcommand: SummaryCommand.self
    )

    /// Subcommand names `CLIDispatch` uses to recognise a CLI invocation
    /// of the shared binary. `CLIDispatchTests` pins this to the registered
    /// `configuration.subcommands` so the two never drift.
    static let knownCommandNames: Set<String> = [
        "summary", "skills", "daily", "weekly", "monthly", "top", "models", "projects",
        "search", "resume", "budget", "statusline", "verify",
        "refresh", "config", "install-cli",
    ]
}

/// The CLI's reported version. When invoked through a PATH symlink (the
/// Homebrew cask / `install-cli` case), `Bundle.main` can fail to locate the
/// enclosing `.app`, so resolve the executable's real path and read
/// `Contents/Info.plist` directly. Falls back to `Bundle.main`, then a dev
/// sentinel for unbundled debug runs.
enum CLIVersion {
    static var current: String {
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            // …/Lupen.app/Contents/MacOS/Lupen → up two → …/Contents/Info.plist
            let infoPlist = executable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Info.plist")
            if let info = NSDictionary(contentsOf: infoPlist),
               let version = info["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0-dev"
    }
}

/// `--provider claude-code|codex`. Conformance lives in the CLI layer so
/// the Domain type stays free of any ArgumentParser dependency. A custom
/// `init?(argument:)` accepts CLI-conventional spellings (kebab-case)
/// while keeping them decoupled from the persisted raw values
/// (`claudeCode`, stored in `app_settings.json` — must stay stable).
extension ProviderKind: ExpressibleByArgument {
    init?(argument: String) {
        switch argument.lowercased() {
        case "claude-code", "claudecode", "claude", "cc": self = .claudeCode
        case "codex": self = .codex
        default: return nil
        }
    }

    static var allValueStrings: [String] { ["claude-code", "codex"] }

    var defaultValueDescription: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex:      return "codex"
        }
    }
}

/// Options shared by every subcommand. Added as an `@OptionGroup` so the
/// flags read identically across the tool (the ccusage-style vocabulary:
/// `--since/--until`, `--last`, `--month`, `--json`).
struct CLIGlobalOptions: ParsableArguments {
    @Option(name: .customLong("provider"), help: "Built-in provider to report on (claudeCode | codex). Ignored when --source is given.")
    var providerArg: ProviderKind = .claudeCode

    @Option(name: .customLong("source"), help: "Session source to report on, by name or id (overrides --provider). Includes user-added and auto-detected sources.")
    var source: String?

    /// The resolved session source: a custom source when --source matches one,
    /// otherwise the built-in for --provider. The built-in path is cheap (no
    /// settings load / detect cost) so the common case stays fast. An unknown
    /// --source is rejected in `validate()`, so this only reaches the fallback
    /// for a blank/absent value.
    var resolvedSource: SessionSource {
        if let source, !source.trimmingCharacters(in: .whitespaces).isEmpty,
           let resolved = CLISourceResolver.resolveLive(source) {
            return resolved
        }
        return SessionSourceRegistry.builtinSource(
            for: providerArg,
            claudeRoot: FileDiscovery().projectsDirectory,
            codexRoot: CodexSessionDiscovery().codexHome
        )
    }

    /// Parser kind of the resolved source — what commands branch on. Skips the
    /// live resolution on the common (no --source) path.
    var provider: ProviderKind {
        if let source, !source.trimmingCharacters(in: .whitespaces).isEmpty {
            return resolvedSource.kind
        }
        return providerArg
    }

    @Option(name: .long, help: "Start date (YYYY-MM-DD), inclusive. Pair with --until.")
    var since: String?

    @Option(name: .long, help: "End date (YYYY-MM-DD), inclusive. Pair with --since.")
    var until: String?

    @Option(name: .long, help: "Relative window ending now, e.g. 30d, 4w, 1m.")
    var last: String?

    @Option(name: .long, help: "Calendar month, YYYY-MM.")
    var month: String?

    @Flag(name: .long, help: "Emit JSON instead of a human table.")
    var json = false

    @Flag(name: .long, help: "Emit CSV instead of a human table.")
    var csv = false

    @Flag(name: .long, help: "Disable ANSI color in table output.")
    var noColor = false

    @Flag(
        inversion: .prefixedNo,
        help: "Refresh the index from the logs before reporting (default). --no-refresh reads the on-disk index as-is."
    )
    var refresh = true

    func validate() throws {
        if json && csv {
            throw ValidationError("Use only one of --json or --csv.")
        }
        // Reject an unknown --source up front instead of silently falling back
        // to the default provider (which would print a *different* source's
        // data). Built-in/absent values resolve trivially.
        if let source, !source.trimmingCharacters(in: .whitespaces).isEmpty,
           CLISourceResolver.resolveLive(source) == nil {
            throw ValidationError(
                "Unknown --source '\(source)'. Pass a session source name or id "
                + "(see Settings ▸ Session Sources), or omit --source."
            )
        }
    }

    /// Resolve the period flags into a `[from, to]` window for the store
    /// queries. `now`/`calendar` are injectable for tests; production uses
    /// the wall clock and the user's current calendar. Resolution errors
    /// are surfaced as `ValidationError` so ArgumentParser prints a clean
    /// usage message (and a `--help` hint) with the usage exit code.
    func resolveRange(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> CLIDateRange.Resolved {
        do {
            return try CLIDateRange.resolve(
                since: since, until: until, last: last, month: month,
                now: now, calendar: calendar
            )
        } catch let error as CLIDateRange.ResolveError {
            throw ValidationError(error.description)
        }
    }

    /// Human label for the selected period.
    var periodLabel: String {
        CLIDateRange.label(since: since, until: until, last: last, month: month)
    }
}

/// Options for row-shaped reports (skills, and the upcoming daily/monthly/
/// top). Kept out of `CLIGlobalOptions` so single-value commands like
/// `summary`/`verify` don't advertise `--limit`/`--sort` they can't honor.
struct CLIRowOptions: ParsableArguments {
    @Option(name: .long, help: "Limit the number of rows shown.")
    var limit: Int?

    @Option(name: .long, help: "Sort order (see the command's help for valid values).")
    var sort: String?

    func validate() throws {
        if let limit, limit < 0 {
            throw ValidationError("--limit must be 0 or greater.")
        }
    }
}
