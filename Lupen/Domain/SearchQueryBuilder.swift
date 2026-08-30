import Foundation

/// Which side of the conversation a text search looks at.
///
/// Backed by the `kind` column of `search_fts`, which carries
/// `prompt | reply | thinking | title` per indexed row.
enum SearchTextScope: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// Everything indexed — what the user asked, what the model replied,
    /// its thinking, and session titles.
    case everything
    /// Only what the user typed.
    case prompts
    /// Only what the model said back.
    case replies

    var id: Self { self }

    var displayName: String {
        switch self {
        case .everything: "All Text"
        case .prompts: "My Prompts"
        case .replies: "Claude's Replies"
        }
    }

    /// `kind` values this scope admits. Empty means "no restriction".
    var kinds: [String] {
        switch self {
        case .everything: []
        case .prompts: ["prompt"]
        case .replies: ["reply"]
        }
    }
}

/// Turns what the user typed into an FTS5 MATCH expression.
///
/// The previous rule was "escape everything": every whitespace token became
/// a quoted prefix term, so no input could be mistaken for FTS syntax. That
/// is safe but total — it also removed the three things people actually
/// reach for. This builder keeps the escaping default and carves out
/// exactly those three, then adds column scoping on top.
///
/// | Input | Meaning |
/// |---|---|
/// | `cache refactor` | both terms, prefix-matched (unchanged) |
/// | `"cache refactor"` | that phrase, in order |
/// | `-warmed` | exclude rows containing the term |
/// | `a OR b` | either term |
///
/// Anything else — stray quotes, `NEAR`, `column:` — is escaped and matched
/// literally, exactly as before.
enum SearchQueryBuilder {

    /// Build the MATCH expression, or nil when there is nothing to search
    /// for. A scope with no text still returns nil: "every reply" is not a
    /// search, and running it would drag the whole corpus back.
    static func ftsQuery(from raw: String, scope: SearchTextScope = .everything) -> String? {
        let terms = parse(raw)
        guard !terms.isEmpty else { return nil }

        let content = expression(for: terms)
        guard let content else { return nil }

        let kinds = scope.kinds
        guard !kinds.isEmpty else { return content }
        // `(kind:a OR kind:b) AND (<content>)` — verified against FTS5:
        // the column filter only works because `kind` is an indexed
        // column, so this must stay in step with the schema.
        let kindClause = kinds.map { "kind:\($0)" }.joined(separator: " OR ")
        return "(\(kindClause)) AND (\(content))"
    }

    // MARK: - Parsing

    /// One parsed unit of the user's input.
    enum Term: Equatable {
        /// A bare word — matched as a prefix, as it always has been.
        case prefix(String)
        /// A quoted run of words — matched in order.
        case phrase(String)
        /// A term the row must NOT contain.
        case excluded(String)
        /// An explicit `OR` between the terms on either side.
        case or
    }

    /// Split raw input into terms. Pure and total: any input produces a
    /// term list, and unbalanced quotes close at end-of-input rather than
    /// failing.
    static func parse(_ raw: String) -> [Term] {
        var terms: [Term] = []
        var current = ""
        var inQuotes = false
        var negateNext = false

        func flush() {
            defer { current = ""; negateNext = false }
            guard !current.isEmpty else { return }
            if negateNext {
                terms.append(.excluded(current))
            } else if current == "OR" || current == "|" {
                // Only meaningful between two terms; a leading or trailing
                // OR is dropped below.
                terms.append(.or)
            } else {
                terms.append(.prefix(current))
            }
        }

        for character in raw {
            if character == "\"" {
                if inQuotes {
                    if !current.isEmpty {
                        terms.append(negateNext ? .excluded(current) : .phrase(current))
                    }
                    current = ""
                    negateNext = false
                    inQuotes = false
                } else {
                    flush()
                    inQuotes = true
                }
                continue
            }
            if inQuotes {
                current.append(character)
                continue
            }
            if character.isWhitespace {
                flush()
                continue
            }
            // A leading `-` negates, but only at the start of a term, so
            // hyphenated words and negative numbers survive intact.
            if character == "-", current.isEmpty, !negateNext {
                negateNext = true
                continue
            }
            current.append(character)
        }
        if inQuotes, !current.isEmpty {
            terms.append(negateNext ? .excluded(current) : .phrase(current))
        } else {
            flush()
        }

        return trimmingDanglingOperators(terms)
    }

    /// Drop `OR`s that have nothing on one side, and collapse runs of them.
    /// FTS5 would reject the expression outright, and the user meant the
    /// terms either way.
    private static func trimmingDanglingOperators(_ terms: [Term]) -> [Term] {
        var result: [Term] = []
        for term in terms {
            if term == .or {
                guard let last = result.last, last != .or else { continue }
                result.append(term)
            } else {
                result.append(term)
            }
        }
        if result.last == .or { result.removeLast() }
        return result
    }

    // MARK: - Expression

    /// Render terms as an FTS5 expression. Positive terms join with AND (or
    /// OR where the user asked); exclusions are appended as `NOT` — FTS5
    /// spells exclusion that way, not with a leading `-`.
    private static func expression(for terms: [Term]) -> String? {
        var positives: [String] = []
        var exclusions: [String] = []
        var pendingOr = false

        for term in terms {
            switch term {
            case .or:
                pendingOr = true
            case .prefix(let word):
                append(quoted(word) + "*", to: &positives, or: &pendingOr)
            case .phrase(let text):
                append(quoted(text), to: &positives, or: &pendingOr)
            case .excluded(let word):
                exclusions.append(quoted(word) + "*")
            }
        }

        guard !positives.isEmpty else {
            // Exclusions alone have nothing to subtract from.
            return nil
        }
        var expression = positives.joined(separator: " ")
        for exclusion in exclusions {
            expression += " NOT \(exclusion)"
        }
        return expression
    }

    /// Join `piece` onto `list`, honouring a pending `OR` by folding it
    /// into the previous element so precedence stays explicit.
    private static func append(_ piece: String, to list: inout [String], or pendingOr: inout Bool) {
        if pendingOr, let previous = list.popLast() {
            list.append("(\(previous) OR \(piece))")
        } else {
            list.append(piece)
        }
        pendingOr = false
    }

    /// FTS5 string literal: wrap in quotes and double any inside. Every
    /// user term goes through this, so nothing typed can escape into
    /// syntax position.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
