import Foundation

/// Rendering helpers for CLI output. Two formats: a plain human table
/// (default) and `--json` for scripting/piping. Progress and hints go to
/// stderr (`CLIOutput.note`) so a `lupen … --json | jq` pipeline only
/// ever sees clean JSON on stdout.
enum CLIOutput {
    /// Print a human-facing line to stdout.
    static func line(_ string: String = "") {
        print(string)
    }

    /// Print a hint/progress message to stderr, keeping stdout clean for
    /// piped consumers.
    static func note(_ string: String) {
        FileHandle.standardError.write(Data((string + "\n").utf8))
    }

    /// Serialize a JSON-object/array value to stdout (pretty, stable key
    /// order for diff-friendly output).
    static func printJSON(_ object: Any) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}

/// Value formatting shared across subcommands. Kept dependency-free
/// (no `NumberFormatter`, which is non-`Sendable` and awkward as a static)
/// so it stays trivially correct under Swift 6 strict concurrency.
enum CLIFormat {
    /// `$12.40`. Two decimal places, matching the GUI's cost display.
    static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// Thousands-grouped integer, e.g. `8,231,004`. Uses `.magnitude`
    /// rather than `abs()` so `Int.min` formats instead of trapping.
    static func int(_ value: Int) -> String {
        let negative = value < 0
        var grouped = ""
        var count = 0
        for character in String(value.magnitude).reversed() {
            if count != 0, count % 3 == 0 { grouped.append(",") }
            grouped.append(character)
            count += 1
        }
        return (negative ? "-" : "") + String(grouped.reversed())
    }
}

extension ProviderKind {
    /// Display name for CLI headers.
    var cliLabel: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }
}
