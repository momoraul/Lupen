import Foundation

/// Builds a one-line summary by extracting the most meaningful input
/// field per tool, since raw escaped tool_use JSON renders unreadably.
enum ToolInputFormatter {

    static func format(call: ToolUseInfo, limit: Int = 80) -> String {
        if let summary = call.displayInputSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return truncate(homeElidedDisplaySummary(summary), to: limit)
        }
        return format(toolName: call.name, inputJSON: call.inputJSON, limit: limit)
    }

    static func format(toolName: String, inputJSON: String, limit: Int = 80) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return truncate(unescape(inputJSON), to: limit)
        }

        let summary = summary(toolName: StepKindStyle.displayName(forToolName: toolName), input: obj)
        return truncate(summary, to: limit)
    }

    // MARK: - Per-tool extraction

    private static func summary(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Read", "Write", "Edit", "MultiEdit", "NotebookRead", "NotebookEdit":
            if let path = input["file_path"] as? String { return prettyPath(path) }
            if let path = input["notebook_path"] as? String { return prettyPath(path) }
            if let path = input["path"] as? String { return prettyPath(path) }
            if let path = input["relative_path"] as? String { return prettyPath(path) }
            return firstStringValue(input) ?? "(no input)"

        case "Bash":
            if let cmd = input["command"] as? String {
                return cmd.replacingOccurrences(of: "\n", with: " ⏎ ")
            }
            if let cmd = input["cmd"] as? String {
                return cmd.replacingOccurrences(of: "\n", with: " ⏎ ")
            }
            if let argv = input["argv"] as? [String], !argv.isEmpty {
                return argv.joined(separator: " ")
            }
            return firstStringValue(input) ?? "(no input)"

        case "Glob":
            if let pattern = input["pattern"] as? String {
                if let path = input["path"] as? String, !path.isEmpty {
                    return "\(pattern)  in  \(prettyPath(path))"
                }
                return pattern
            }
            if let path = input["path"] as? String { return prettyPath(path) }
            return firstStringValue(input) ?? "(no input)"

        case "Grep":
            if let pattern = input["pattern"] as? String {
                if let path = input["path"] as? String, !path.isEmpty {
                    return "/\(pattern)/  in  \(prettyPath(path))"
                }
                return "/\(pattern)/"
            }
            return firstStringValue(input) ?? "(no input)"

        case "WebSearch":
            if let q = input["query"] as? String { return q }
            return firstStringValue(input) ?? "(no input)"

        case "WebFetch":
            if let url = input["url"] as? String { return url }
            return firstStringValue(input) ?? "(no input)"

        case "TodoWrite", "TaskCreate", "TaskUpdate":
            if let todos = input["todos"] as? [[String: Any]] {
                if let first = todos.first?["content"] as? String ?? todos.first?["subject"] as? String {
                    let suffix = todos.count > 1 ? " +\(todos.count - 1)" : ""
                    return first + suffix
                }
                return "\(todos.count) todos"
            }
            if let subject = input["subject"] as? String { return subject }
            if let desc = input["description"] as? String { return desc }
            return firstStringValue(input) ?? "(no input)"

        case "Task", "Agent", "Workflow":
            let agentType = input["subagent_type"] as? String
                ?? input["agent_type"] as? String
                ?? input["agentType"] as? String
                ?? input["type"] as? String
                ?? input["name"] as? String
                ?? input["agent"] as? String
                ?? input["label"] as? String
            let desc = input["description"] as? String
                ?? input["summary"] as? String
                ?? input["task"] as? String
                ?? input["prompt"] as? String
                ?? input["instructions"] as? String
            if let agentType, let desc, !agentType.isEmpty, !desc.isEmpty {
                return "\(agentType): \(desc)"
            }
            if let desc, !desc.isEmpty { return desc }
            if let agentType, !agentType.isEmpty { return agentType }
            if let name = input["name"] as? String { return name }
            if let task = input["task"] as? String { return task }
            if let prompt = input["prompt"] as? String { return prompt }
            return firstStringValue(input) ?? "(no input)"

        case "AgentWait", "AgentClose":
            let agentId = input["agent_id"] as? String
                ?? input["agentId"] as? String
                ?? input["id"] as? String
                ?? input["task_id"] as? String
            let status = input["status"] as? String
                ?? input["state"] as? String
            switch (agentId, status) {
            case (let agentId?, let status?) where !agentId.isEmpty && !status.isEmpty:
                return "\(agentId)  \(status)"
            case (let agentId?, _) where !agentId.isEmpty:
                return agentId
            case (_, let status?) where !status.isEmpty:
                return status
            default:
                return firstStringValue(input) ?? "(no input)"
            }

        case "ToolSearch", "Tool Search":
            if let q = input["query"] as? String { return q }
            return firstStringValue(input) ?? "(no input)"

        case "Skill":
            let skill = normalizedSkillName(input["skill"] as? String)
                ?? normalizedSkillName(input["name"] as? String)
                ?? normalizedSkillCommand(input["command"] as? String)
            let args = input["args"] as? String
                ?? input["argument"] as? String
                ?? input["prompt"] as? String
                ?? commandRemainder(input["command"] as? String)
            if let skill, !skill.isEmpty {
                if let args, !args.isEmpty {
                    return "\(skill)  \(args)"
                }
                return skill
            }
            return firstStringValue(input) ?? "(no input)"

        default:
            return firstStringValue(input) ?? compactJSONSummary(input)
        }
    }

    // MARK: - Helpers

    /// Collapse the user's home directory to `~`.
    static func prettyPath(_ path: String) -> String {
        elideHomeDirectory(in: path)
    }

    private static func elideHomeDirectory(in value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if value == home {
            return "~"
        }
        return value.replacingOccurrences(of: home + "/", with: "~/")
    }

    private static func firstStringValue(_ dict: [String: Any]) -> String? {
        for (_, value) in dict {
            if let s = value as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    private static func compactJSONSummary(_ dict: [String: Any]) -> String {
        let parts = dict.compactMap { (key, value) -> String? in
            if let s = value as? String { return "\(key): \(s)" }
            if let n = value as? NSNumber { return "\(key): \(n)" }
            return nil
        }
        return parts.joined(separator: ", ")
    }

    /// Backslash unescape, used only as a fallback when JSON parsing fails.
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\n"#, with: " ⏎ ")
    }

    static func truncate(_ s: String, to limit: Int) -> String {
        if s.count <= limit { return s }
        let endIndex = s.index(s.startIndex, offsetBy: limit)
        return String(s[..<endIndex]) + "…"
    }

    private static func normalizedDisplaySummary(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\n"#, with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static func homeElidedDisplaySummary(_ value: String) -> String {
        elideHomeDirectory(in: normalizedDisplaySummary(value))
    }

    private static func normalizedSkillCommand(_ value: String?) -> String? {
        guard let value else { return nil }
        let first = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        return normalizedSkillName(first)
    }

    private static func commandRemainder(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSpace = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let remainder = trimmed[firstSpace...].trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }

    private static func normalizedSkillName(_ value: String?) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        while trimmed.hasPrefix("/") || trimmed.hasPrefix("$") {
            trimmed.removeFirst()
        }
        trimmed = trimmed
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? trimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}
