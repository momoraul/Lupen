import Foundation

/// Summary of a single tool_use block.
///
/// One assistant Step (`.toolCall` / `.thought`) can carry multiple
/// `ToolUseInfo` values when the response invokes several tools in parallel.
///
/// **Snapshot cap**: `encode(to:)` truncates `inputJSON` at
/// `encodedInputCapBytes` (~1 KB) so oversized tool inputs (Agent prompts,
/// Write with long content, etc.) don't dominate the persisted snapshot.
/// The compact `skillName` / `displayInputSummary` fields preserve the
/// user-visible semantics that would otherwise be lost when `inputJSON`
/// stops being parseable. Full input JSON is still available via the Raw
/// tab's lazy-loaded JSONL line.
/// Measured on the 2026-04-20 corpus: cap at 1 KB cuts ~36 MB from the
/// snapshot while affecting only ~7 k of 60 k tool-use entries
/// (p99=15 KB, max=104 KB long-tail). Under-cap entries encode verbatim
/// so round-trip equality holds for all reasonably-sized calls.
struct ToolUseInfo: Sendable, Equatable, Codable {
    /// `id` of the tool_use block. Matches with the corresponding tool_result.
    let id: String
    /// Tool name (e.g. "Read", "Bash", "Grep").
    let name: String
    /// Serialized tool-input JSON; the UI may pretty-print on display.
    let inputJSON: String
    /// Parsed skill name without the leading slash, preserved separately so
    /// skill group labels survive snapshot truncation of long `args`.
    let skillName: String?
    /// Compact, display-ready input summary captured before `inputJSON` is
    /// truncated. nil when the raw JSON is short enough to parse directly.
    let displayInputSummary: String?

    init(
        id: String,
        name: String,
        inputJSON: String,
        skillName: String? = nil,
        displayInputSummary: String? = nil
    ) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
        self.skillName = Self.sanitizedSkillName(skillName)
            ?? Self.extractSkillName(toolName: name, inputJSON: inputJSON)
        self.displayInputSummary = Self.sanitizedDisplayInputSummary(displayInputSummary)
            ?? Self.makeDisplayInputSummary(toolName: name, inputJSON: inputJSON)
    }

    /// Abbreviated input for UI descriptions, capped at `limit` characters.
    func abbreviatedInput(limit: Int = 80) -> String {
        let source = displayInputSummary ?? semanticInputSummary() ?? inputJSON
        let compacted = Self.normalizedDisplaySummary(source)
        if compacted.count <= limit { return compacted }
        let endIndex = compacted.index(compacted.startIndex, offsetBy: limit)
        return String(compacted[..<endIndex]) + "…"
    }

    var resolvedSkillName: String? {
        Self.sanitizedSkillName(skillName) ?? Self.extractSkillName(toolName: name, inputJSON: inputJSON)
    }

    private func semanticInputSummary() -> String? {
        Self.semanticInputSummary(toolName: name, inputJSON: inputJSON)
    }

    private static func semanticInputSummary(toolName: String, inputJSON: String) -> String? {
        guard let object = decodedInputObject(inputJSON) else {
            return bestEffortSemanticInputSummary(toolName: toolName, inputJSON: inputJSON)
        }

        switch normalizedToolName(toolName) {
        case "Read", "Write", "Edit", "MultiEdit", "NotebookRead", "NotebookEdit":
            return pathSummary(in: object)

        case "Bash":
            return bashSummary(in: object)

        case "Glob":
            return globSummary(in: object)

        case "Grep":
            return grepSummary(in: object)

        case "WebSearch", "ToolSearch":
            return stringField(in: object, keys: ["query"])

        case "WebFetch":
            return stringField(in: object, keys: ["url"])

        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return todoSummary(in: object)

        case "Agent", "Workflow":
            let agentType = stringField(
                in: object,
                keys: ["subagent_type", "agent_type", "type", "name", "agent", "label"]
            )
            let description = stringField(
                in: object,
                keys: ["description", "summary", "task", "prompt", "instructions"]
            )
            return joinedSummary(primary: agentType, secondary: description)

        case "AgentWait", "AgentClose":
            let agentId = stringField(in: object, keys: ["agent_id", "agentId", "id", "task_id"])
            let status = stringField(in: object, keys: ["status", "state"])
            return joinedSummary(primary: agentId, secondary: status)

        case "Skill":
            let skill = extractSkillName(toolName: toolName, inputJSON: inputJSON)
            let command = stringField(in: object, keys: ["command"])
            let args = stringField(in: object, keys: ["args", "argument", "prompt"])
                ?? commandRemainder(command)
            return joinedSummary(primary: skill, secondary: args)

        default:
            return nil
        }
    }

    private static func decodedInputObject(_ inputJSON: String) -> [String: Any]? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func stringField(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func stringArrayField(in object: [String: Any], keys: [String]) -> [String]? {
        for key in keys {
            guard let values = object[key] as? [String], !values.isEmpty else { continue }
            return values
        }
        return nil
    }

    private static func joinedSummary(primary: String?, secondary: String?) -> String? {
        switch (primary, secondary) {
        case (let primary?, let secondary?) where primary != secondary:
            return "\(primary): \(secondary)"
        case (let primary?, _):
            return primary
        case (_, let secondary?):
            return secondary
        default:
            return nil
        }
    }

    private static func makeDisplayInputSummary(toolName: String, inputJSON: String) -> String? {
        guard inputJSON.count > encodedInputCapBytes else { return nil }
        guard let summary = semanticInputSummary(toolName: toolName, inputJSON: inputJSON) else {
            return nil
        }
        let trimmed = normalizedDisplaySummary(summary)
        guard !trimmed.isEmpty else { return nil }
        return capped(trimmed, to: encodedSummaryCapBytes)
    }

    private static func bestEffortSemanticInputSummary(toolName: String, inputJSON: String) -> String? {
        switch normalizedToolName(toolName) {
        case "Read", "Write", "Edit", "MultiEdit", "NotebookRead", "NotebookEdit":
            return scannedStringField(inputJSON, keys: ["file_path", "notebook_path", "path", "relative_path"])
        case "Bash":
            return scannedStringField(inputJSON, keys: ["command", "cmd"])
        case "Glob":
            let pattern = scannedStringField(inputJSON, keys: ["pattern"])
            let path = scannedStringField(inputJSON, keys: ["path"])
            if let pattern, let path { return "\(pattern)  in  \(path)" }
            return pattern ?? path
        case "Grep":
            guard let pattern = scannedStringField(inputJSON, keys: ["pattern"]) else { return nil }
            if let path = scannedStringField(inputJSON, keys: ["path"]) {
                return "/\(pattern)/  in  \(path)"
            }
            return "/\(pattern)/"
        case "WebSearch", "ToolSearch":
            return scannedStringField(inputJSON, keys: ["query"])
        case "WebFetch":
            return scannedStringField(inputJSON, keys: ["url"])
        case "Skill":
            guard let skill = extractSkillName(toolName: toolName, inputJSON: inputJSON) else {
                return nil
            }
            let command = scannedStringField(inputJSON, keys: ["command"])
            let args = scannedStringField(inputJSON, keys: ["args", "argument", "prompt"])
                ?? commandRemainder(command)
            return joinedSummary(primary: skill, secondary: args)
        case "Agent", "Workflow":
            let agentType = scannedStringField(
                inputJSON,
                keys: ["subagent_type", "agent_type", "type", "name", "agent", "label"]
            )
            let description = scannedStringField(
                inputJSON,
                keys: ["description", "summary", "task", "prompt", "instructions"]
            )
            return joinedSummary(primary: agentType, secondary: description)
        case "AgentWait", "AgentClose":
            let agentId = scannedStringField(inputJSON, keys: ["agent_id", "agentId", "id", "task_id"])
            let status = scannedStringField(inputJSON, keys: ["status", "state"])
            return joinedSummary(primary: agentId, secondary: status)
        default:
            return nil
        }
    }

    static func extractSkillName(toolName: String, inputJSON: String) -> String? {
        guard normalizedToolName(toolName) == "Skill" else { return nil }
        if let object = decodedInputObject(inputJSON) {
            if let direct = stringField(in: object, keys: ["skill", "name"]),
               let normalized = normalizeSkillName(direct) {
                return normalized
            }
            if let command = stringField(in: object, keys: ["command"]),
               let normalized = normalizeSkillCommand(command) {
                return normalized
            }
            return nil
        }
        if let direct = scannedStringField(inputJSON, keys: ["skill", "name"]),
           let normalized = normalizeSkillName(direct) {
            return normalized
        }
        if let command = scannedStringField(inputJSON, keys: ["command"]),
           let normalized = normalizeSkillCommand(command) {
            return normalized
        }
        return nil
    }

    private static func normalizeSkillCommand(_ value: String) -> String? {
        let first = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        return first.flatMap(normalizeSkillName)
    }

    private static func commandRemainder(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSpace = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let remainder = trimmed[firstSpace...].trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }

    private static func normalizeSkillName(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") || trimmed.hasPrefix("$") {
            trimmed.removeFirst()
        }
        trimmed = trimmed
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func scannedStringField(_ inputJSON: String, keys: [String]) -> String? {
        for key in keys {
            guard let value = scanStringField(inputJSON, key: key) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func scanStringField(_ inputJSON: String, key: String) -> String? {
        let quotedKey = "\"\(key)\""
        guard let keyRange = inputJSON.range(of: quotedKey),
              let colonRange = inputJSON.range(of: ":", range: keyRange.upperBound..<inputJSON.endIndex),
              let valueStart = inputJSON[colonRange.upperBound...]
                .firstIndex(where: { !$0.isWhitespace }),
              inputJSON[valueStart] == "\"" else {
            return nil
        }

        var result = ""
        var index = inputJSON.index(after: valueStart)
        var escaping = false
        while index < inputJSON.endIndex {
            let char = inputJSON[index]
            if escaping {
                result.append(unescapedCharacter(afterBackslash: char))
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else if char == "\"" {
                return result
            } else {
                result.append(char)
            }
            index = inputJSON.index(after: index)
        }
        return result.isEmpty ? nil : result
    }

    private static func unescapedCharacter(afterBackslash char: Character) -> Character {
        switch char {
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "/": return "/"
        case "\"": return "\""
        case "\\": return "\\"
        default: return char
        }
    }

    private static func capped(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        let endIndex = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<endIndex]) + "…"
    }

    private static func normalizedDisplaySummary(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\n"#, with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static func normalizedToolName(_ name: String) -> String {
        switch name {
        case "exec_command", "shell_command":
            return "Bash"
        case "read_file":
            return "Read"
        case "write_file":
            return "Write"
        case "edit_file", "apply_diff", "apply_patch":
            return "Edit"
        case "read_dir", "list_dir":
            return "Glob"
        case "Tool Search":
            return "ToolSearch"
        case "spawn_agent":
            return "Agent"
        case "wait_agent":
            return "AgentWait"
        case "close_agent":
            return "AgentClose"
        case "skill", "use_skill":
            return "Skill"
        default:
            return name
        }
    }

    private static func pathSummary(in object: [String: Any]) -> String? {
        stringField(in: object, keys: ["file_path", "notebook_path", "path", "relative_path"])
    }

    private static func bashSummary(in object: [String: Any]) -> String? {
        if let command = stringField(in: object, keys: ["command", "cmd"]) {
            return command.replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        if let argv = stringArrayField(in: object, keys: ["argv"]) {
            return argv.joined(separator: " ")
        }
        return nil
    }

    private static func globSummary(in object: [String: Any]) -> String? {
        let pattern = stringField(in: object, keys: ["pattern"])
        let path = stringField(in: object, keys: ["path"])
        if let pattern, let path { return "\(pattern)  in  \(path)" }
        return pattern ?? path
    }

    private static func grepSummary(in object: [String: Any]) -> String? {
        guard let pattern = stringField(in: object, keys: ["pattern"]) else { return nil }
        if let path = stringField(in: object, keys: ["path"]) {
            return "/\(pattern)/  in  \(path)"
        }
        return "/\(pattern)/"
    }

    private static func todoSummary(in object: [String: Any]) -> String? {
        guard let todos = object["todos"] as? [[String: Any]] else {
            return stringField(in: object, keys: ["subject", "description"])
        }
        guard let first = todos.first else { return "\(todos.count) todos" }
        guard let firstContent = stringField(in: first, keys: ["content", "subject"]) else {
            return "\(todos.count) todos"
        }
        let suffix = todos.count > 1 ? " +\(todos.count - 1)" : ""
        return firstContent + suffix
    }

    private static func sanitizedDisplayInputSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizedDisplaySummary(value)
        guard !normalized.isEmpty else { return nil }
        return capped(normalized, to: encodedSummaryCapBytes)
    }

    private static func sanitizedSkillName(_ value: String?) -> String? {
        guard let value else { return nil }
        return normalizeSkillName(value)
    }

    // MARK: - Snapshot size cap

    /// Maximum encoded length for `inputJSON` in Character count.
    static let encodedInputCapBytes: Int = 1024

    /// Cap for persisted display summaries. Summaries are limited to semantic
    /// user-visible fields and must not persist raw oversized tool content.
    static let encodedSummaryCapBytes: Int = 1024

    /// Marker appended when `inputJSON` is truncated. Distinguishable
    /// from valid JSON so downstream JSON parsers fail cleanly rather
    /// than producing garbage — callers that need structured parsing
    /// should lazy-load the original line through the Raw tab path.
    static let truncationMarker: String = "\n…[truncated — full input in Raw tab]"

    enum CodingKeys: String, CodingKey {
        case id, name, inputJSON, skillName, displayInputSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let inputJSON = try c.decode(String.self, forKey: .inputJSON)
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
        let decodedSkillName = try c.decodeIfPresent(String.self, forKey: .skillName)
        self.skillName = Self.sanitizedSkillName(decodedSkillName)
            ?? Self.extractSkillName(toolName: name, inputJSON: inputJSON)
        let decodedDisplaySummary = try c.decodeIfPresent(String.self, forKey: .displayInputSummary)
        self.displayInputSummary = Self.sanitizedDisplayInputSummary(decodedDisplaySummary)
            ?? Self.makeDisplayInputSummary(toolName: name, inputJSON: inputJSON)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(skillName, forKey: .skillName)
        try c.encodeIfPresent(displayInputSummary, forKey: .displayInputSummary)
        if inputJSON.count > Self.encodedInputCapBytes {
            let head = String(inputJSON.prefix(Self.encodedInputCapBytes))
            try c.encode(head + Self.truncationMarker, forKey: .inputJSON)
        } else {
            try c.encode(inputJSON, forKey: .inputJSON)
        }
    }
}
