import Foundation

enum CodexConversationAssembler {
    static func assemble(
        metadata: CodexSessionMetadata,
        decodedLines: [CodexLineReader.DecodedLine],
        usageRequests: [ParsedRequest] = [],
        costsByRequestId: [String: CostBreakdown?] = [:]
    ) -> [Turn] {
        var drafts: [TurnDraft] = []
        var draftIndexByKey: [String: Int] = [:]
        var currentTurnKey: String?
        var currentModel = metadata.model
        var generatedTurnOrdinal = 0
        var stepOrdinal = 0
        var externalToolOrdinal = 0
        var pendingExternalToolCallIds: [String] = []
        var seenExternalToolMarkers = Set<String>()
        let entries = decodedLines.map(\.entry)
        let eventUserMessages = eventUserMessageTexts(in: entries)
        let mirroredEventLineIndexes = mirroredEventLineIndexes(in: decodedLines)
        var hasSeenLiveEventUserMessage = false

        func timestamp(for entry: CodexEntry) -> Date {
            CodexTimestampParser.parse(entry.timestamp)
                ?? CodexTimestampParser.parse(entry.payload?.timestamp)
                ?? metadata.createdAt
                ?? Date(timeIntervalSince1970: 0)
        }

        func ensureDraft(for key: String) -> Int {
            if let index = draftIndexByKey[key] { return index }
            let index = drafts.count
            draftIndexByKey[key] = index
            drafts.append(TurnDraft(key: key, sessionId: metadata.scopedId))
            return index
        }

        func nextGeneratedTurnKey() -> String {
            generatedTurnOrdinal += 1
            return "generated-\(generatedTurnOrdinal)"
        }

        func appendStep(
            kind: StepKind,
            text: String? = nil,
            thinkingText: String? = nil,
            toolCalls: [ToolUseInfo] = [],
            toolResult: ToolResultInfo? = nil,
            stopReason: String? = nil,
            model: String? = nil,
            line: CodexLineReader.DecodedLine
        ) {
            let key = currentTurnKey ?? "session"
            let draftIndex = ensureDraft(for: key)
            stepOrdinal += 1
            let parentUuid = drafts[draftIndex].rootStepUuid
            let uuid = "\(metadata.scopedId):step:\(stepOrdinal)"
            let step = Step(
                uuid: uuid,
                parentUuid: kind == .prompt ? nil : parentUuid,
                sessionId: metadata.scopedId,
                timestamp: timestamp(for: line.entry),
                kind: kind,
                text: text,
                thinkingText: thinkingText,
                mentionedFilePaths: kind == .prompt ? FilePathDetector.extract(from: text) : [],
                toolCalls: toolCalls,
                toolResult: toolResult,
                model: model ?? currentModel,
                stopReason: stopReason,
                rawJSON: nil,
                rawJSONLocator: line.rawLocator
            )
            drafts[draftIndex].steps.append(step)
        }

        for (lineIndex, line) in decodedLines.enumerated() {
            let entry = line.entry
            guard let payload = entry.payload else { continue }

            if entry.type == "event_msg", payload.type == "user_message" {
                hasSeenLiveEventUserMessage = true
            }
            if shouldSkipForkReplayConversationEntry(
                metadata: metadata,
                entry: entry,
                payload: payload,
                hasSeenLiveEventUserMessage: hasSeenLiveEventUserMessage
            ) {
                continue
            }

            if isTurnContext(entry, payload) {
                currentModel = payload.model ?? currentModel
                if let turnId = nonEmpty(payload.turnId) {
                    currentTurnKey = turnId
                    _ = ensureDraft(for: turnId)
                }
                continue
            }

            if isUserMessage(entry, payload) {
                let text = payload.messageText
                if entry.type == "response_item",
                   !eventUserMessages.isEmpty,
                   !eventUserMessages.contains(normalized(text)) {
                    continue
                }
                if shouldSkipDuplicatePrompt(entry: entry, payload: payload, text: text, currentTurnKey: currentTurnKey, drafts: drafts, draftIndexByKey: draftIndexByKey) {
                    continue
                }
                let contextKey: String? = {
                    guard let currentTurnKey,
                          let draftIndex = draftIndexByKey[currentTurnKey],
                          !drafts[draftIndex].isComplete else {
                        return nil
                    }
                    return currentTurnKey
                }()
                let key = nonEmpty(payload.turnId) ?? contextKey ?? nextGeneratedTurnKey()
                currentTurnKey = key
                appendStep(kind: .prompt, text: text, line: line)
                continue
            }

            if isReasoning(entry, payload) {
                let text = payload.messageText
                if mirroredEventLineIndexes.contains(lineIndex) {
                    continue
                }
                if shouldSkipDuplicateAssistantText(
                    entry: entry,
                    text: text,
                    currentTurnKey: currentTurnKey,
                    drafts: drafts,
                    draftIndexByKey: draftIndexByKey
                ) {
                    continue
                }
                appendStep(kind: .thought, text: text, line: line)
                continue
            }

            if isAssistantMessage(entry, payload) {
                let text = payload.messageText
                if mirroredEventLineIndexes.contains(lineIndex) {
                    continue
                }
                if let externalTool = externalAgentToolMarker(in: text) {
                    let markerKey = normalized(text)
                    guard seenExternalToolMarkers.insert(markerKey).inserted else {
                        continue
                    }
                    switch externalTool {
                    case .call(let toolName, let inputJSON):
                        externalToolOrdinal += 1
                        let callId = "\(metadata.scopedId):external-tool:\(externalToolOrdinal)"
                        let tool = ToolUseInfo(
                            id: callId,
                            name: displayToolName(toolName),
                            inputJSON: inputJSON
                        )
                        pendingExternalToolCallIds.append(callId)
                        appendStep(kind: .toolCall, toolCalls: [tool], line: line)
                    case .result(let content):
                        let callId: String
                        if pendingExternalToolCallIds.isEmpty {
                            externalToolOrdinal += 1
                            callId = "\(metadata.scopedId):external-tool:\(externalToolOrdinal)"
                        } else {
                            callId = pendingExternalToolCallIds.removeFirst()
                        }
                        let result = ToolResultInfo(
                            toolUseId: callId,
                            content: content,
                            isError: externalTool.isError
                        )
                        appendStep(kind: .toolResult, toolResult: result, line: line)
                    }
                    continue
                }
                if shouldSkipDuplicateAssistantText(
                    entry: entry,
                    text: text,
                    currentTurnKey: currentTurnKey,
                    drafts: drafts,
                    draftIndexByKey: draftIndexByKey
                ) {
                    continue
                }
                appendStep(kind: .reply, text: text, line: line)
                continue
            }

            if isToolSearchCall(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? "\(metadata.scopedId):tool-search:\(stepOrdinal + 1)"
                let tool = ToolUseInfo(
                    id: callId,
                    name: "Tool Search",
                    inputJSON: payload.arguments ?? payload.input ?? "{}"
                )
                appendStep(kind: .toolCall, toolCalls: [tool], line: line)
                continue
            }

            if isToolSearchOutput(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? "\(metadata.scopedId):tool-search-output:\(stepOrdinal + 1)"
                let result = ToolResultInfo(
                    toolUseId: callId,
                    content: payload.output ?? payload.tools?.compactJSONString ?? payload.messageText ?? "",
                    isError: payload.status == "failed"
                )
                appendStep(kind: .toolResult, toolResult: result, line: line)
                continue
            }

            if isWebSearchCall(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? nonEmpty(payload.id) ?? "\(metadata.scopedId):web-search:\(stepOrdinal + 1)"
                let tool = ToolUseInfo(
                    id: callId,
                    name: "Web Search",
                    inputJSON: webSearchInputJSON(payload)
                )
                appendStep(kind: .toolCall, toolCalls: [tool], line: line)
                continue
            }

            if isWebSearchEnd(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? "\(metadata.scopedId):web-search-output:\(stepOrdinal + 1)"
                let result = ToolResultInfo(
                    toolUseId: callId,
                    content: webSearchResultContent(payload),
                    isError: payload.status == "failed"
                )
                appendStep(kind: .toolResult, toolResult: result, line: line)
                continue
            }

            if isImageGenerationCall(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? nonEmpty(payload.id) ?? "\(metadata.scopedId):image-generation:\(stepOrdinal + 1)"
                let tool = ToolUseInfo(
                    id: callId,
                    name: "Image Generation",
                    inputJSON: imageGenerationInputJSON(payload)
                )
                appendStep(kind: .toolCall, toolCalls: [tool], line: line)
                continue
            }

            if isImageGenerationEnd(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? nonEmpty(payload.id) ?? "\(metadata.scopedId):image-generation-output:\(stepOrdinal + 1)"
                let result = ToolResultInfo(
                    toolUseId: callId,
                    content: imageGenerationResultContent(payload),
                    isError: payload.status == "failed"
                )
                appendStep(kind: .toolResult, toolResult: result, line: line)
                continue
            }

            if isMCPToolCallEnd(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? "\(metadata.scopedId):mcp-tool:\(stepOrdinal + 1)"
                let tool = ToolUseInfo(
                    id: callId,
                    name: "MCP Tool",
                    inputJSON: payload.invocation?.compactJSONString ?? payload.arguments ?? "{}"
                )
                let result = ToolResultInfo(
                    toolUseId: callId,
                    content: payload.result?.compactJSONString ?? payload.output ?? payload.messageText ?? "",
                    isError: isMCPToolError(payload)
                )
                appendStep(kind: .toolCall, toolCalls: [tool], line: line)
                appendStep(kind: .toolResult, toolResult: result, line: line)
                continue
            }

            if isFunctionCall(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? "\(metadata.scopedId):tool:\(stepOrdinal + 1)"
                let inputJSON = payload.arguments ?? payload.input ?? "{}"
                let tool = ToolUseInfo(
                    id: callId,
                    name: displayToolName(payload.name),
                    inputJSON: inputJSON
                )
                appendStep(kind: .toolCall, toolCalls: [tool], line: line)
                continue
            }

            if isFunctionOutput(entry, payload) {
                let callId = nonEmpty(payload.callId) ?? "\(metadata.scopedId):tool-output:\(stepOrdinal + 1)"
                let result = ToolResultInfo(
                    toolUseId: callId,
                    content: payload.output ?? payload.messageText ?? "",
                    isError: payload.status == "failed"
                )
                appendStep(kind: .toolResult, toolResult: result, line: line)
                continue
            }

            if entry.type == "event_msg", payload.type == "patch_apply_end" {
                let files = payload.changes?.objectKeys.joined(separator: "\n")
                let result = ToolResultInfo(
                    toolUseId: "\(metadata.scopedId):patch:\(stepOrdinal + 1)",
                    content: files?.isEmpty == false ? files! : "Patch applied"
                )
                appendStep(kind: .toolResult, toolResult: result, line: line)
                continue
            }

            if isTurnTerminator(entry, payload) {
                guard let currentTurnKey,
                      let draftIndex = draftIndexByKey[currentTurnKey],
                      !drafts[draftIndex].steps.isEmpty,
                      drafts[draftIndex].steps.last?.kind.endsTurn != true else {
                    continue
                }
                appendStep(kind: .stop, stopReason: payload.type ?? entry.type, line: line)
            }
        }

        applyUsage(
            usageRequests,
            costsByRequestId: costsByRequestId,
            to: &drafts,
            draftIndexByKey: draftIndexByKey,
            metadata: metadata
        )

        let orderedDrafts = drafts
            .filter { !$0.steps.isEmpty }
            .sorted { lhs, rhs in
                let lhsTime = lhs.steps.first?.timestamp ?? .distantPast
                let rhsTime = rhs.steps.first?.timestamp ?? .distantPast
                if lhsTime != rhsTime { return lhsTime < rhsTime }
                return lhs.key < rhs.key
            }

        return orderedDrafts.enumerated().map { index, draft in
            let interrupted = !draft.isComplete && index < orderedDrafts.count - 1
            return Turn(
                id: draft.rootStepUuid ?? "\(metadata.scopedId):turn:\(draft.key)",
                sessionId: metadata.scopedId,
                steps: resolveAttachments(
                    in: draft.steps.sorted { lhs, rhs in
                        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                        return lhs.uuid < rhs.uuid
                    },
                    cwd: metadata.cwd
                ),
                isInterrupted: interrupted
            )
        }
    }

    static func assemble(
        metadata: CodexSessionMetadata,
        entries: [CodexEntry],
        usageRequests: [ParsedRequest] = [],
        costsByRequestId: [String: CostBreakdown?] = [:]
    ) -> [Turn] {
        let decodedLines = entries.map { entry in
            CodexLineReader.DecodedLine(entry: entry, rawData: Data())
        }
        return assemble(
            metadata: metadata,
            decodedLines: decodedLines,
            usageRequests: usageRequests,
            costsByRequestId: costsByRequestId
        )
    }
}

private extension CodexConversationAssembler {
    struct TurnDraft {
        let key: String
        let sessionId: String
        var steps: [Step] = []

        var rootStepUuid: String? {
            steps.first(where: { $0.kind == .prompt })?.uuid ?? steps.first?.uuid
        }

        var isComplete: Bool {
            steps.last?.kind.endsTurn == true
        }
    }

    struct UsageBundle {
        let requests: [ParsedRequest]
        let costsByRequestId: [String: CostBreakdown?]

        var requestId: String? { requests.first?.id }
        var requestIds: [String] { requests.map(\.id) }
        var model: String? { requests.reversed().compactMap(\.model).first }
        var timestamp: Date {
            requests.map(\.timestamp).max() ?? Date(timeIntervalSince1970: 0)
        }
        var tokens: TokenBreakdown {
            TokenCalculator.aggregateTokens(requests.map(\.tokens))
        }
        var cost: CostBreakdown {
            TokenCalculator.aggregateCosts(requests.map { costsByRequestId[$0.id] ?? nil })
        }
    }

    static func isTurnContext(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "turn_context" || payload.type == "turn_context"
    }

    static func isUserMessage(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        (entry.type == "response_item" && payload.type == "message" && payload.role == "user")
            || (entry.type == "event_msg" && payload.type == "user_message")
    }

    static func isAssistantMessage(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        (entry.type == "response_item" && payload.type == "message" && payload.role == "assistant")
            || (entry.type == "event_msg" && payload.type == "agent_message")
    }

    static func isReasoning(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        (entry.type == "response_item" && payload.type == "reasoning")
            || (entry.type == "event_msg" && payload.type == "agent_reasoning")
    }

    static func isFunctionCall(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "response_item"
            && (payload.type == "function_call" || payload.type == "custom_tool_call")
    }

    static func isFunctionOutput(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "response_item"
            && (payload.type == "function_call_output" || payload.type == "custom_tool_call_output")
    }

    static func isToolSearchCall(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "response_item" && payload.type == "tool_search_call"
    }

    static func isToolSearchOutput(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "response_item" && payload.type == "tool_search_output"
    }

    static func isWebSearchCall(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "response_item" && payload.type == "web_search_call"
    }

    static func isWebSearchEnd(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "event_msg" && payload.type == "web_search_end"
    }

    static func isImageGenerationCall(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "response_item" && payload.type == "image_generation_call"
    }

    static func isImageGenerationEnd(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "event_msg" && payload.type == "image_generation_end"
    }

    static func isMCPToolCallEnd(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        entry.type == "event_msg" && payload.type == "mcp_tool_call_end"
    }

    static func webSearchInputJSON(_ payload: CodexEntry.Payload) -> String {
        if let actionJSON = payload.action?.compactJSONString, !actionJSON.isEmpty {
            return actionJSON
        }
        var object: [String: Any] = [:]
        if let query = nonEmpty(payload.query) {
            object["query"] = query
        }
        if let status = nonEmpty(payload.status) {
            object["status"] = status
        }
        return compactJSONObject(object) ?? "{}"
    }

    static func webSearchResultContent(_ payload: CodexEntry.Payload) -> String {
        var lines: [String] = []
        if let query = nonEmpty(payload.query) {
            lines.append("Query: \(query)")
        }
        if let actionJSON = payload.action?.compactJSONString, !actionJSON.isEmpty {
            lines.append(actionJSON)
        }
        if let status = nonEmpty(payload.status) {
            lines.append("Status: \(status)")
        }
        return firstNonEmpty(lines.joined(separator: "\n"), payload.messageText) ?? "Web search completed"
    }

    static func imageGenerationInputJSON(_ payload: CodexEntry.Payload) -> String {
        var object: [String: Any] = [:]
        if let revisedPrompt = nonEmpty(payload.revisedPrompt) {
            object["revised_prompt"] = revisedPrompt
        }
        if let status = nonEmpty(payload.status) {
            object["status"] = status
        }
        return firstNonEmpty(compactJSONObject(object), payload.input, payload.arguments) ?? "{}"
    }

    static func imageGenerationResultContent(_ payload: CodexEntry.Payload) -> String {
        var lines: [String] = []
        if let status = nonEmpty(payload.status) {
            lines.append("Status: \(status)")
        }
        if let revisedPrompt = nonEmpty(payload.revisedPrompt) {
            lines.append("Prompt: \(revisedPrompt)")
        }
        if let result = payload.result {
            lines.append("Result: \(imageResultSummary(result))")
        }
        return firstNonEmpty(lines.joined(separator: "\n"), payload.messageText) ?? "Image generation completed"
    }

    static func imageResultSummary(_ value: CodexJSONValue) -> String {
        switch value {
        case .string(let string):
            return "base64 image data (\(string.count) characters)"
        case .array(let values):
            return "array result (\(values.count) items)"
        case .object(let object):
            return "object result (\(object.keys.count) fields)"
        case .number, .bool, .null:
            return value.compactJSONString
        }
    }

    static func compactJSONObject(_ object: [String: Any]) -> String? {
        guard !object.isEmpty,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func shouldSkipForkReplayConversationEntry(
        metadata: CodexSessionMetadata,
        entry: CodexEntry,
        payload: CodexEntry.Payload,
        hasSeenLiveEventUserMessage: Bool = false
    ) -> Bool {
        guard entry.type == "response_item" || entry.type == "event_msg" else { return false }
        if entry.type == "event_msg", payload.type == "user_message" {
            return false
        }
        let eventTimestamp = CodexTimestampParser.parse(entry.timestamp)
            ?? CodexTimestampParser.parse(payload.timestamp)
            ?? metadata.createdAt
            ?? Date(timeIntervalSince1970: 0)
        return CodexForkReplayFilter.shouldSkip(
            metadata: metadata,
            eventTimestamp: eventTimestamp,
            hasSeenLiveEventUserMessage: hasSeenLiveEventUserMessage
        )
    }

    static func isMCPToolError(_ payload: CodexEntry.Payload) -> Bool {
        if payload.status == "failed" {
            return true
        }
        let resultKeys = Set(payload.result?.objectKeys.map { $0.lowercased() } ?? [])
        return resultKeys.contains("err") || resultKeys.contains("error")
    }

    static func isTurnTerminator(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        if entry.type == "turn_aborted" || entry.type == "task_complete" {
            return true
        }
        return entry.type == "event_msg"
            && (payload.type == "turn_aborted" || payload.type == "task_complete")
    }

    static func shouldSkipDuplicatePrompt(
        entry: CodexEntry,
        payload: CodexEntry.Payload,
        text: String?,
        currentTurnKey: String?,
        drafts: [TurnDraft],
        draftIndexByKey: [String: Int]
    ) -> Bool {
        guard entry.type == "event_msg",
              payload.type == "user_message",
              let currentTurnKey,
              let draftIndex = draftIndexByKey[currentTurnKey],
              let lastPrompt = drafts[draftIndex].steps.last(where: { $0.kind == .prompt }) else {
            return false
        }
        let hasAssistantStep = drafts[draftIndex].steps.contains { !$0.kind.isUserRole }
        guard !hasAssistantStep else { return false }
        return normalized(lastPrompt.text) == normalized(text) || normalized(text).isEmpty
    }

    static func shouldSkipDuplicateAssistantText(
        entry: CodexEntry,
        text: String?,
        currentTurnKey: String?,
        drafts: [TurnDraft],
        draftIndexByKey: [String: Int]
    ) -> Bool {
        guard entry.type == "event_msg",
              let currentTurnKey,
              let draftIndex = draftIndexByKey[currentTurnKey] else {
            return false
        }
        let normalizedText = normalized(text)
        guard !normalizedText.isEmpty else { return false }
        return drafts[draftIndex].steps.contains { step in
            step.kind.isAssistantRole && normalized(step.text) == normalizedText
        }
    }

    static func applyUsage(
        _ requests: [ParsedRequest],
        costsByRequestId: [String: CostBreakdown?],
        to drafts: inout [TurnDraft],
        draftIndexByKey: [String: Int],
        metadata: CodexSessionMetadata
    ) {
        let grouped = Dictionary(grouping: requests) { request in
            turnComponent(from: request.id)
        }

        for (turnKey, requests) in grouped {
            let draftIndex: Int
            if let existingIndex = draftIndexByKey[turnKey]
                ?? fallbackDraftIndex(for: turnKey, drafts: drafts) {
                draftIndex = existingIndex
            } else {
                draftIndex = drafts.count
                drafts.append(TurnDraft(key: turnKey, sessionId: metadata.scopedId))
            }
            let bundle = UsageBundle(requests: requests, costsByRequestId: costsByRequestId)
            if let stepIndex = usageCarrierIndex(in: drafts[draftIndex].steps) {
                drafts[draftIndex].steps[stepIndex] = applyingUsage(bundle, to: drafts[draftIndex].steps[stepIndex])
            } else if let requestId = bundle.requestId {
                let uuid = "\(metadata.scopedId):usage:\(turnKey)"
                drafts[draftIndex].steps.append(
                    Step(
                        uuid: uuid,
                        parentUuid: drafts[draftIndex].rootStepUuid,
                        sessionId: metadata.scopedId,
                        timestamp: bundle.timestamp,
                        kind: .reply,
                        requestId: requestId,
                        requestIds: bundle.requestIds,
                        model: bundle.model,
                        tokens: bundle.tokens,
                        cost: bundle.cost
                    )
                )
            }
        }
    }

    static func usageCarrierIndex(in steps: [Step]) -> Int? {
        steps.indices.reversed().first { index in
            switch steps[index].kind {
            case .reply, .thought, .toolCall, .stop:
                return true
            case .prompt, .toolResult, .interruption:
                return false
            }
        }
    }

    static func applyingUsage(_ bundle: UsageBundle, to step: Step) -> Step {
        Step(
            uuid: step.uuid,
            parentUuid: step.parentUuid,
            sessionId: step.sessionId,
            timestamp: step.timestamp,
            kind: step.kind,
            isSystemInjected: step.isSystemInjected,
            isSidechain: step.isSidechain,
            agentId: step.agentId,
            isCompactSummary: step.isCompactSummary,
            text: step.text,
            thinkingText: step.thinkingText,
            images: step.images,
            imageSourcePaths: step.imageSourcePaths,
            mentionedFilePaths: step.mentionedFilePaths,
            attachments: step.attachments,
            toolCalls: step.toolCalls,
            toolResult: step.toolResult,
            requestId: bundle.requestId ?? step.requestId,
            requestIds: bundle.requestIds.isEmpty ? step.requestIds : bundle.requestIds,
            messageId: step.messageId,
            model: bundle.model ?? step.model,
            speed: step.speed,
            stopReason: step.stopReason,
            stopReasonKind: step.stopReasonKind,
            tokens: bundle.tokens,
            cost: bundle.cost,
            rawJSON: step.rawJSON,
            rawJSONLocator: step.rawJSONLocator
        )
    }

    static func fallbackDraftIndex(for turnKey: String, drafts: [TurnDraft]) -> Int? {
        guard turnKey == "session" else { return nil }
        return drafts.indices.last
    }

    static func turnComponent(from requestId: String) -> String {
        guard let markerRange = requestId.range(of: ":token_count:") else {
            return "session"
        }
        let suffix = requestId[markerRange.upperBound...]
        guard let lastColon = suffix.lastIndex(of: ":") else {
            return String(suffix)
        }
        return String(suffix[..<lastColon])
    }

    static func displayToolName(_ name: String?) -> String {
        switch name {
        case "exec_command", "shell_command":
            return "Bash"
        case "read_file":
            return "Read"
        case "write_file":
            return "Write"
        case "edit_file", "apply_diff", "apply_patch":
            return "Edit"
        case "spawn_agent":
            return "Agent"
        case "wait_agent":
            return "AgentWait"
        case "close_agent":
            return "AgentClose"
        case "skill", "use_skill":
            return "Skill"
        case "read_dir", "list_dir":
            return "Glob"
        case let name? where !name.isEmpty:
            return name
        default:
            return "Tool"
        }
    }

    enum ExternalAgentToolMarker {
        case call(toolName: String, inputJSON: String)
        case result(content: String)

        var isError: Bool {
            guard case .result(let content) = self else { return false }
            return content.localizedCaseInsensitiveContains("failed")
                || content.localizedCaseInsensitiveContains("error")
        }
    }

    static func externalAgentToolMarker(in text: String?) -> ExternalAgentToolMarker? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let call = externalToolCallMarker(in: trimmed) {
            return call
        }
        if let result = externalToolResultMarker(in: trimmed) {
            return result
        }
        return nil
    }

    static func externalToolCallMarker(in text: String) -> ExternalAgentToolMarker? {
        let prefix = "[external_agent_tool_call:"
        let suffix = "[/external_agent_tool_call]"
        guard text.hasPrefix(prefix),
              let headerEnd = text.firstIndex(of: "]"),
              text.hasSuffix(suffix) else {
            return nil
        }

        let rawName = text[text.index(text.startIndex, offsetBy: prefix.count)..<headerEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyStart = text.index(after: headerEnd)
        let bodyEnd = text.index(text.endIndex, offsetBy: -suffix.count)
        let body = String(text[bodyStart..<bodyEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return .call(
            toolName: rawName.isEmpty ? "Tool" : rawName,
            inputJSON: externalToolInputJSON(fromBody: body)
        )
    }

    static func externalToolResultMarker(in text: String) -> ExternalAgentToolMarker? {
        let prefix = "[external_agent_tool_result]"
        let suffix = "[/external_agent_tool_result]"
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else {
            return nil
        }
        let bodyStart = text.index(text.startIndex, offsetBy: prefix.count)
        let bodyEnd = text.index(text.endIndex, offsetBy: -suffix.count)
        let body = String(text[bodyStart..<bodyEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .result(content: body)
    }

    static func externalToolInputJSON(fromBody body: String) -> String {
        let lines = body
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.count == 1,
           let input = lines.first,
           input.hasPrefix("input:") {
            let rawInput = input.dropFirst("input:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rawInput.hasPrefix("{") || rawInput.hasPrefix("[") {
                return rawInput
            }
        }

        var object: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                object[key] = value
            }
        }

        guard !object.isEmpty,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return body.isEmpty ? "{}" : body
        }
        return json
    }

    static func resolveAttachments(in steps: [Step], cwd: String?) -> [Step] {
        var toolNameByUseId: [String: String] = [:]
        for step in steps {
            for call in step.toolCalls {
                toolNameByUseId[call.id] = call.name
            }
        }

        var diagnostics: [String] = []
        return steps.map { step in
            let resolved = AttachmentResolver.resolve(
                step: step,
                toolNameByUseId: toolNameByUseId,
                diagnostics: &diagnostics
            )
            let codexRefs = codexSpecificAttachments(for: step, cwd: cwd)
            return AttachmentResolver.withAttachments(
                step,
                deduplicatedAttachments(resolved + codexRefs)
            )
        }
    }

    static func codexSpecificAttachments(for step: Step, cwd: String?) -> [AttachmentRef] {
        var refs: [AttachmentRef] = []

        for call in step.toolCalls {
            refs.append(contentsOf: structuredCodexFilePaths(for: call, cwd: cwd).map {
                AttachmentRef(kind: .file, origin: .toolInput, locator: $0, toolName: call.name)
            })

            if call.name == "Edit" {
                refs.append(contentsOf: patchFilePaths(in: call.inputJSON, cwd: cwd).map {
                    AttachmentRef(kind: .file, origin: .toolInput, locator: $0, toolName: call.name)
                })
            }
        }

        if let result = step.toolResult,
           !result.isError,
           result.toolUseId.contains(":patch:") {
            refs.append(contentsOf: result.content
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .compactMap { absoluteCodexPath($0, cwd: cwd) }
                .map {
                    AttachmentRef(kind: .file, origin: .toolOutput, locator: $0, toolName: "Edit")
                })
        }

        return refs
    }

    static func structuredCodexFilePaths(for call: ToolUseInfo, cwd: String?) -> [String] {
        let keys: [String]
        switch call.name {
        case "Read", "Write", "Edit", "MultiEdit":
            keys = ["file_path", "path"]
        case "NotebookRead", "NotebookEdit":
            keys = ["notebook_path", "path"]
        default:
            return []
        }

        guard let data = call.inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [String] = []
        var seen = Set<String>()
        for key in keys {
            guard let rawPath = object[key] as? String,
                  let path = absoluteCodexPath(rawPath, cwd: cwd),
                  seen.insert(path).inserted else {
                continue
            }
            results.append(path)
        }
        return results
    }

    static func patchFilePaths(in input: String, cwd: String?) -> [String] {
        let patterns = [
            #"(?m)^\*\*\* (?:Add File|Update File|Delete File|Move to):\s+(.+?)\s*$"#,
            #"(?m)^(?:---|\+\+\+) [ab]/(.+?)\s*$"#,
        ]
        var results: [String] = []
        var seen = Set<String>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = input as NSString
            let matches = regex.matches(
                in: input,
                range: NSRange(location: 0, length: ns.length)
            )
            for match in matches where match.numberOfRanges >= 2 {
                let range = match.range(at: 1)
                guard range.location != NSNotFound else { continue }
                let rawPath = ns.substring(with: range)
                guard let path = absoluteCodexPath(rawPath, cwd: cwd),
                      seen.insert(path).inserted else {
                    continue
                }
                results.append(path)
            }
        }
        return results
    }

    static func absoluteCodexPath(_ rawPath: String, cwd: String?) -> String? {
        let trimmed = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty, trimmed != "/dev/null" else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        guard let cwd = nonEmpty(cwd) else { return nil }
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
    }

    static func deduplicatedAttachments(_ refs: [AttachmentRef]) -> [AttachmentRef] {
        var result: [AttachmentRef] = []
        var indexByLocator: [String: Int] = [:]
        for ref in refs {
            if let index = indexByLocator[ref.locator] {
                if ref.origin.dedupPriority > result[index].origin.dedupPriority {
                    result[index] = ref
                }
                continue
            }
            indexByLocator[ref.locator] = result.count
            result.append(ref)
        }
        return result
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value = nonEmpty(value) {
                return value
            }
        }
        return nil
    }

    static func normalized(_ value: String?) -> String {
        value?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }

    static func eventUserMessageTexts(in entries: [CodexEntry]) -> Set<String> {
        Set(entries.compactMap { entry in
            guard entry.type == "event_msg",
                  entry.payload?.type == "user_message" else {
                return nil
            }
            let text = normalized(entry.payload?.messageText)
            return text.isEmpty ? nil : text
        })
    }

    static func mirroredEventLineIndexes(in decodedLines: [CodexLineReader.DecodedLine]) -> Set<Int> {
        var indexes = Set<Int>()
        for index in decodedLines.indices {
            let entry = decodedLines[index].entry
            guard entry.type == "event_msg",
                  let payload = entry.payload,
                  payload.type == "agent_message" || payload.type == "agent_reasoning" else {
                continue
            }
            let text = normalized(payload.messageText)
            guard !text.isEmpty else { continue }
            var neighbors: [Int] = []
            if index > decodedLines.startIndex {
                neighbors.append(decodedLines.index(before: index))
            }
            let next = decodedLines.index(after: index)
            if decodedLines.indices.contains(next) {
                neighbors.append(next)
            }
            if neighbors.contains(where: {
                isMatchingResponseMirror(
                    eventPayloadType: payload.type,
                    eventText: text,
                    responseEntry: decodedLines[$0].entry
                )
            }) {
                indexes.insert(index)
            }
        }
        return indexes
    }

    static func isMatchingResponseMirror(
        eventPayloadType: String?,
        eventText: String,
        responseEntry: CodexEntry
    ) -> Bool {
        guard responseEntry.type == "response_item",
              let payload = responseEntry.payload else {
            return false
        }
        switch eventPayloadType {
        case "agent_message":
            guard payload.type == "message", payload.role == "assistant" else { return false }
        case "agent_reasoning":
            guard payload.type == "reasoning" else { return false }
        default:
            return false
        }
        return normalized(payload.messageText) == eventText
    }
}
