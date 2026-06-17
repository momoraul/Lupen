import Foundation

struct CodexEntry: Decodable, Equatable, Sendable {
    let type: String?
    let timestamp: String?
    let payload: Payload?

    init(type: String?, timestamp: String?, payload: Payload?) {
        self.type = type
        self.timestamp = timestamp
        self.payload = payload
    }

    struct Payload: Decodable, Equatable, Sendable {
        let type: String?
        let timestamp: String?
        let turnId: String?
        let model: String?
        let cwd: String?
        let info: Info?
        let role: String?
        let message: String?
        let text: String?
        let content: [ContentBlock]
        let summary: [ContentBlock]
        let name: String?
        let arguments: String?
        let input: String?
        let output: String?
        let callId: String?
        let id: String?
        let status: String?
        let changes: CodexJSONValue?
        let tools: CodexJSONValue?
        let invocation: CodexJSONValue?
        let action: CodexJSONValue?
        let result: CodexJSONValue?
        let duration: CodexJSONValue?
        let execution: String?
        let query: String?
        let revisedPrompt: String?
        let numTurns: Int?

        init(
            type: String?,
            timestamp: String?,
            turnId: String?,
            model: String?,
            cwd: String?,
            info: Info?,
            role: String? = nil,
            message: String? = nil,
            text: String? = nil,
            content: [ContentBlock] = [],
            summary: [ContentBlock] = [],
            name: String? = nil,
            arguments: String? = nil,
            input: String? = nil,
            output: String? = nil,
            callId: String? = nil,
            id: String? = nil,
            status: String? = nil,
            changes: CodexJSONValue? = nil,
            tools: CodexJSONValue? = nil,
            invocation: CodexJSONValue? = nil,
            action: CodexJSONValue? = nil,
            result: CodexJSONValue? = nil,
            duration: CodexJSONValue? = nil,
            execution: String? = nil,
            query: String? = nil,
            revisedPrompt: String? = nil,
            numTurns: Int? = nil
        ) {
            self.type = type
            self.timestamp = timestamp
            self.turnId = turnId
            self.model = model
            self.cwd = cwd
            self.info = info
            self.role = role
            self.message = message
            self.text = text
            self.content = content
            self.summary = summary
            self.name = name
            self.arguments = arguments
            self.input = input
            self.output = output
            self.callId = callId
            self.id = id
            self.status = status
            self.changes = changes
            self.tools = tools
            self.invocation = invocation
            self.action = action
            self.result = result
            self.duration = duration
            self.execution = execution
            self.query = query
            self.revisedPrompt = revisedPrompt
            self.numTurns = numTurns
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try c.decodeIfPresent(String.self, forKey: .type)
            self.timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
            self.turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
            self.model = try c.decodeIfPresent(String.self, forKey: .model)
            self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            self.info = try c.decodeIfPresent(Info.self, forKey: .info)
            self.role = try c.decodeIfPresent(String.self, forKey: .role)
            self.message = try c.decodeStringIfPresent(forKey: .message)
            self.text = try c.decodeStringIfPresent(forKey: .text)
            self.content = try c.decodeIfPresent([ContentBlock].self, forKey: .content) ?? []
            self.summary = try c.decodeIfPresent([ContentBlock].self, forKey: .summary) ?? []
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
            self.arguments = try c.decodeJSONStringIfPresent(forKey: .arguments)
            self.input = try c.decodeJSONStringIfPresent(forKey: .input)
            self.output = try c.decodeStringIfPresent(forKey: .output)
            self.callId = try c.decodeIfPresent(String.self, forKey: .callId)
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.status = try c.decodeIfPresent(String.self, forKey: .status)
            self.changes = try c.decodeIfPresent(CodexJSONValue.self, forKey: .changes)
            self.tools = try c.decodeIfPresent(CodexJSONValue.self, forKey: .tools)
            self.invocation = try c.decodeIfPresent(CodexJSONValue.self, forKey: .invocation)
            self.action = try c.decodeIfPresent(CodexJSONValue.self, forKey: .action)
            self.result = try c.decodeIfPresent(CodexJSONValue.self, forKey: .result)
            self.duration = try c.decodeIfPresent(CodexJSONValue.self, forKey: .duration)
            self.execution = try c.decodeIfPresent(String.self, forKey: .execution)
            self.query = try c.decodeStringIfPresent(forKey: .query)
            self.revisedPrompt = try c.decodeStringIfPresent(forKey: .revisedPrompt)
            self.numTurns = try c.decodeIfPresent(Int.self, forKey: .numTurns)
        }

        enum CodingKeys: String, CodingKey {
            case type, timestamp, model, cwd, info, role, message, text, content, summary
            case name, arguments, input, output, id, status, changes
            case tools, invocation, action, result, duration, execution, query
            case turnId = "turn_id"
            case callId = "call_id"
            case revisedPrompt = "revised_prompt"
            case numTurns = "num_turns"
        }

        var contentText: String? {
            Self.joinedText(content)
        }

        var summaryText: String? {
            Self.joinedText(summary)
        }

        var messageText: String? {
            firstNonEmpty(message, text, contentText, summaryText)
        }

        private static func joinedText(_ blocks: [ContentBlock]) -> String? {
            let text = blocks.compactMap(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        }

        private func firstNonEmpty(_ values: String?...) -> String? {
            for value in values {
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty { return trimmed }
            }
            return nil
        }
    }

    struct Info: Decodable, Equatable, Sendable {
        let model: String?
        let modelName: String?
        let lastTokenUsage: CodexTokenUsage?
        let totalTokenUsage: CodexTokenUsage?
        let modelContextWindow: Int?

        init(
            model: String? = nil,
            modelName: String? = nil,
            lastTokenUsage: CodexTokenUsage?,
            totalTokenUsage: CodexTokenUsage?,
            modelContextWindow: Int?
        ) {
            self.model = model
            self.modelName = modelName
            self.lastTokenUsage = lastTokenUsage
            self.totalTokenUsage = totalTokenUsage
            self.modelContextWindow = modelContextWindow
        }

        enum CodingKeys: String, CodingKey {
            case model
            case modelName = "model_name"
            case lastTokenUsage = "last_token_usage"
            case totalTokenUsage = "total_token_usage"
            case modelContextWindow = "model_context_window"
        }
    }

    struct ContentBlock: Decodable, Equatable, Sendable {
        let type: String?
        let text: String?

        init(type: String?, text: String?) {
            self.type = type
            self.text = text
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try c.decodeIfPresent(String.self, forKey: .type)
            self.text = try c.decodeStringIfPresent(forKey: .text)
                ?? c.decodeStringIfPresent(forKey: .content)
        }

        private enum CodingKeys: String, CodingKey {
            case type, text, content
        }
    }
}

enum CodexJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: CodexJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Codex JSON value"
            )
        }
    }

    var compactJSONString: String {
        guard JSONSerialization.isValidJSONObject(foundationValue),
              let data = try? JSONSerialization.data(
                withJSONObject: foundationValue,
                options: [.sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8) else {
            switch self {
            case .string(let value): return value
            case .number(let value): return String(value)
            case .bool(let value): return value ? "true" : "false"
            case .null: return "null"
            case .object, .array: return ""
            }
        }
        return text
    }

    var objectKeys: [String] {
        guard case .object(let object) = self else { return [] }
        return object.keys.sorted()
    }

    private var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let object):
            return object.mapValues(\.foundationValue)
        case .array(let array):
            return array.map(\.foundationValue)
        case .null:
            return NSNull()
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeStringIfPresent(forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(CodexJSONValue.self, forKey: key) {
            return value.compactJSONString
        }
        return nil
    }

    func decodeJSONStringIfPresent(forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(CodexJSONValue.self, forKey: key) {
            return value.compactJSONString
        }
        return nil
    }
}

struct CodexTokenUsage: Decodable, Equatable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int?

    init(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int?
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        self.outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.reasoningOutputTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
        self.totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
    }

    var isZero: Bool {
        inputTokens == 0 &&
        cachedInputTokens == 0 &&
        outputTokens == 0 &&
        reasoningOutputTokens == 0
    }

    func delta(from previous: CodexTokenUsage) -> CodexTokenUsage {
        CodexTokenUsage(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens),
            totalTokens: totalTokens.flatMap { current in
                previous.totalTokens.map { max(0, current - $0) }
            }
        )
    }

    func adding(_ delta: CodexTokenUsage) -> CodexTokenUsage {
        let combinedTotalTokens: Int?
        if let totalTokens, let deltaTotalTokens = delta.totalTokens {
            combinedTotalTokens = totalTokens + deltaTotalTokens
        } else {
            combinedTotalTokens = nil
        }

        return CodexTokenUsage(
            inputTokens: inputTokens + delta.inputTokens,
            cachedInputTokens: cachedInputTokens + delta.cachedInputTokens,
            outputTokens: outputTokens + delta.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens + delta.reasoningOutputTokens,
            totalTokens: combinedTotalTokens
        )
    }

    func normalizedTokenBreakdown(contextWindow: Int? = nil) -> TokenBreakdown {
        let cached = max(0, cachedInputTokens)
        return TokenBreakdown(
            inputTokens: max(0, inputTokens - cached),
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: cached,
            cacheCreationEphemeral1h: 0,
            cacheCreationEphemeral5m: 0,
            contextWindow: contextWindow
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}
