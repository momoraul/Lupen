import Foundation

/// Converts `RichEntry` into `Step`. Ground truth for StepKind classification rules.
///
/// Classification rules (docs/CONVERSATION-MODEL.md):
///
/// | Kind       | entryType  | stopReason      | blocks                              |
/// |------------|------------|-----------------|-------------------------------------|
/// | .prompt    | user       | —               | text >=1 && no tool_result          |
/// | .toolResult| user       | —               | tool_result >=1                     |
/// | .toolCall  | assistant  | tool_use        | tool_use >=1 && no text             |
/// | .thought   | assistant  | tool_use        | text >=1 && tool_use >=1            |
/// | .reply     | assistant  | end_turn        | text >=1                            |
/// | .stop      | assistant  | other           | —                                   |
enum StepBuilder {

    /// Falls back to `.stop` when classification is ambiguous (warning, not error).
    static func build(from entry: RichEntry) -> Step {
        let kind = classify(entry)
        let text = collectText(entry.blocks)
        let thinkingText = collectThinking(entry.blocks)
        let images = collectImages(entry)
        // Collect attachment candidates from any text-bearing Step, not just prompt:
        // Step is a pure data carrier, so we extract from full text without kind filtering.
        let mentionedFilePaths = FilePathDetector.extract(from: text)
        let toolCalls = collectToolCalls(entry.blocks)
        let toolResult = collectFirstToolResult(entry.blocks)

        let tokens: TokenBreakdown?
        if let usage = entry.usage {
            tokens = TokenBreakdown.from(usage: usage)
        } else {
            tokens = nil
        }

        let cost: CostBreakdown?
        if let tokens, let model = entry.model {
            cost = CostCalculator.calculateCost(
                tokens: tokens,
                model: model,
                speed: entry.usage?.speed
            )
        } else {
            cost = nil
        }

        return Step(
            uuid: entry.uuid,
            parentUuid: entry.parentUuid,
            sessionId: entry.sessionId,
            timestamp: entry.timestamp,
            kind: kind,
            isSystemInjected: entry.isSystemInjected,
            isSidechain: entry.isSidechain,
            agentId: entry.agentId,
            isCompactSummary: entry.isCompactSummary,
            text: text,
            thinkingText: thinkingText,
            images: images,
            imageSourcePaths: [],  // filled by assembler at merge time
            mentionedFilePaths: mentionedFilePaths,
            attachments: [],       // filled by AttachmentResolver in 2-phase
            toolCalls: toolCalls,
            toolResult: toolResult,
            requestId: entry.requestId,
            messageId: entry.messageId,
            model: entry.model,
            speed: entry.usage?.speed,
            stopReason: entry.stopReason,
            stopReasonKind: StopReason(rawString: entry.stopReason),
            tokens: tokens,
            cost: cost,
            rawJSON: entry.rawJSON
        )
    }

    // MARK: - Classification

    static func classify(_ entry: RichEntry) -> StepKind {
        let hasText = entry.blocks.contains(where: {
            if case .text(let s) = $0 { return !s.isEmpty }
            return false
        })
        // Presence-only check: extended thinking often emits
        // `{type:"thinking", thinking:"", signature:"..."}` with empty text
        // but a signature. The fact that thinking happened still counts toward `.thought`.
        let hasThinking = entry.blocks.contains(where: { $0.isThinking })
        let hasToolUse = entry.blocks.contains(where: { $0.isToolUse })
        let hasToolResult = entry.blocks.contains(where: { $0.isToolResult })

        switch entry.entryType {
        case .user:
            if hasToolResult { return .toolResult }
            // Detect Claude Code auto-interruption markers like [Request interrupted by user]
            let combinedText = entry.blocks.compactMap { block -> String? in
                if case .text(let s) = block { return s }
                return nil
            }.joined()
            if RichEntryDecoder.isUserInterruptionMarker(combinedText) {
                return .interruption
            }
            if hasText || entry.blocks.contains(where: { $0.isImage }) {
                return .prompt
            }
            return .prompt

        case .assistant:
            let kind = StopReason(rawString: entry.stopReason)
            // Turn-continuation reasons: tool_use (awaiting tool) and pause_turn
            // (2025 server-tool iteration pause). Treating either as a terminal stop
            // would split a single user utterance across multiple Turns, cascading
            // breakage into cost rollup, skill-group spans, and attachment ownership
            // (see research-turn-model §2.6).
            if kind == .toolUse || kind == .pauseTurn || hasToolUse {
                if hasText || hasThinking { return .thought }
                return .toolCall
            }
            if kind == .endTurn {
                return .reply  // keep empty end_turn as .reply
            }
            // max_tokens / stop_sequence / refusal / unknown — terminated but not a normal reply.
            return .stop
        }
    }

    // MARK: - Content extraction

    static func collectText(_ blocks: [RichContentBlock]) -> String? {
        let parts: [String] = blocks.compactMap { block in
            if case .text(let s) = block, !s.isEmpty { return s }
            return nil
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: "\n")
    }

    static func collectThinking(_ blocks: [RichContentBlock]) -> String? {
        let parts: [String] = blocks.compactMap { block in
            if case .thinking(let s) = block, !s.isEmpty { return s }
            return nil
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: "\n")
    }

    static func collectImages(_ entry: RichEntry) -> [ImageRef] {
        entry.blocks.compactMap { block -> ImageRef? in
            if case .image(let media, let path) = block {
                return ImageRef(path: path, mediaType: media)
            }
            return nil
        }
    }

    static func collectToolCalls(_ blocks: [RichContentBlock]) -> [ToolUseInfo] {
        blocks.compactMap { block -> ToolUseInfo? in
            if case .toolUse(let id, let name, let inputJSON) = block {
                return ToolUseInfo(id: id, name: name, inputJSON: inputJSON)
            }
            return nil
        }
    }

    static func collectFirstToolResult(_ blocks: [RichContentBlock]) -> ToolResultInfo? {
        for block in blocks {
            if case .toolResult(let toolUseId, let content, let isError) = block {
                return ToolResultInfo(toolUseId: toolUseId, content: content, isError: isError)
            }
        }
        return nil
    }
}
