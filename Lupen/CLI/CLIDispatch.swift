import Foundation

/// Decides whether the Lupen executable was invoked as the `lupen`
/// command-line tool rather than launched as the GUI app.
///
/// The same binary serves both roles (see `main.swift`): a Homebrew cask
/// — or `lupen install-cli` — symlinks `Lupen.app/Contents/MacOS/Lupen`
/// onto the PATH as `lupen`, so `argv[0]` is `…/lupen` for CLI use and
/// `…/Lupen` for a Finder / LaunchServices launch. The decision is kept
/// as a pure function so the branch is unit-testable without spawning a
/// process.
///
/// A process is treated as CLI when EITHER:
///   * the invoked name (`argv[0]` basename) is exactly `lupen`, or
///   * the first argument is a recognized subcommand or a help/version
///     flag.
///
/// A plain GUI launch has neither (no subcommand; `argv[0]` is `Lupen`,
/// capitalised), so the dashboard still opens. An XCTest host matches
/// neither either: its `argv[0]` is the test runner and its arguments are
/// XCTest's own. The name comparison is case-sensitive on purpose — the
/// bundle executable is `Lupen`, the PATH symlink is `lupen`, so the two
/// never collide.
enum CLIDispatch {
    /// The command name a PATH symlink uses.
    static let commandName = "lupen"

    enum Mode: Equatable {
        /// Run the CLI (`LupenCLI`) and exit.
        case cli
        /// Continue to the normal GUI launch path.
        case passthrough
    }

    /// Help/version flags that should route to the CLI even when the
    /// binary is invoked under its bundle name (e.g. `Lupen --version`).
    private static let cliFlags: Set<String> = ["--help", "-h", "--version"]

    static func mode(
        for arguments: [String],
        knownCommands: Set<String>
    ) -> Mode {
        guard let invokedPath = arguments.first else { return .passthrough }

        let invokedName = (invokedPath as NSString).lastPathComponent
        if invokedName == commandName { return .cli }

        // First token after argv[0]. A GUI launch passes none, or passes
        // LaunchServices noise like `-psn_0_123` / `-NSDocument…` which
        // matches neither set below.
        if let first = arguments.dropFirst().first {
            if cliFlags.contains(first) { return .cli }
            if knownCommands.contains(first) { return .cli }
        }
        return .passthrough
    }
}
