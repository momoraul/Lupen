import Foundation
import Darwin

/// Minimal fixed-width table renderer shared by the report subcommands.
/// Numeric columns right-align; the header bolds when color is enabled.
/// Display width is grapheme count — fine for the ASCII/number cells the
/// reports emit. Cells are sanitized of control characters before
/// measuring/printing, so an attacker-influenced value (skill names come
/// from prompt text) can't inject ANSI escapes or break column alignment.
struct CLITable {
    enum Align { case left, right }

    struct Column {
        let header: String
        let align: Align
        init(_ header: String, align: Align = .left) {
            self.header = header
            self.align = align
        }
    }

    let columns: [Column]
    let rows: [[String]]

    func render(color: Bool) -> String {
        let headers = columns.map { Self.sanitize($0.header) }
        let safeRows = rows.map { $0.map(Self.sanitize) }

        var widths = headers.map { $0.count }
        for row in safeRows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }

        func pad(_ value: String, width: Int, align: Align) -> String {
            let gap = max(0, width - value.count)
            let spaces = String(repeating: " ", count: gap)
            return align == .left ? value + spaces : spaces + value
        }

        func line(_ cells: [String]) -> String {
            columns.enumerated().map { index, column in
                pad(index < cells.count ? cells[index] : "", width: widths[index], align: column.align)
            }
            .joined(separator: "  ")
        }

        var lines: [String] = []
        let headerLine = line(headers)
        lines.append(color ? CLIStyle.bold(headerLine) : headerLine)
        lines.append(contentsOf: safeRows.map(line))
        // Trim trailing padding so right-most left-aligned cells don't carry
        // a ragged tail of spaces.
        return lines
            .map { $0.replacingOccurrences(of: "[ ]+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    /// Strip C0 control characters (incl. ESC, TAB, NUL) and DEL. ESC would
    /// otherwise reach the terminal as a live escape sequence (even under
    /// --no-color) and inflate the grapheme count used for alignment.
    static func sanitize(_ value: String) -> String {
        String(String.UnicodeScalarView(
            value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        ))
    }
}

/// CSV serialization with RFC-4180 quoting plus spreadsheet formula-injection
/// guarding. Fields are produced by `render`; `escape` is the RFC step alone.
enum CLICSV {
    static func render(header: [String], rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(field).joined(separator: ",") }
            .joined(separator: "\n")
    }

    /// A fully-prepared CSV field: control-sanitized, formula-guarded, then
    /// RFC-4180 quoted.
    static func field(_ raw: String) -> String {
        escape(guardingFormula(sanitize(raw)))
    }

    /// Strip control characters that would inject ANSI when a `.csv` is later
    /// viewed in a terminal — but keep newlines, which are legitimate
    /// multi-line field content that RFC-4180 quoting handles. (Skill/session
    /// names and titles come from prompt text, so they're untrusted.)
    static func sanitize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.value == 0x0A || ($0.value >= 0x20 && $0.value != 0x7F)
        }))
    }

    /// Neutralize spreadsheet formula injection: a field whose first
    /// character is `= + - @` (or a leading tab/CR that some apps treat as
    /// a formula lead-in) is prefixed with a single quote so Excel / Sheets
    /// / LibreOffice render it as text. Skill names flow from prompt input,
    /// so `/=cmd(...)` would otherwise become a live cell formula.
    static func guardingFormula(_ field: String) -> String {
        guard let first = field.first, "=+-@\t\r".contains(first) else { return field }
        return "'" + field
    }

    /// RFC-4180 quoting: quote fields containing a comma, quote, or newline;
    /// double embedded quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Terminal styling helpers. Color is on only for an interactive stdout
/// with color not disabled by `--no-color` or the `NO_COLOR` convention.
enum CLIStyle {
    static func useColor(disabled: Bool) -> Bool {
        if disabled { return false }
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(fileno(stdout)) != 0
    }

    static func bold(_ text: String) -> String {
        "\u{001B}[1m\(text)\u{001B}[0m"
    }
}
