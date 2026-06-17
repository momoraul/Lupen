//
//  CodexLineDiagnostics.swift
//  Lupen
//
//  Created by jaden on 2026-05-26.
//

import Foundation

enum CodexLineDiagnostics {
    static func batch(
        fileURL: URL?,
        decodedLines: [CodexLineReader.DecodedLine],
        rejectedLines: [CodexLineReader.RejectedLine] = [],
        usageRequests: [ParsedRequest] = [],
        skippedDuplicateCumulativeCount _: Int = 0,
        skippedForkReplayCount: Int = 0
    ) -> ParseDiagnosticsBatch {
        var batch = ParseDiagnosticsBatch(fileURL: fileURL)
        for line in rejectedLines {
            batch.append(.malformedJSON(line.errorDescription), raw: line.rawData)
        }
        for line in decodedLines {
            guard let rejection = unknownLineTypeRejection(for: line.entry) else {
                continue
            }
            batch.append(rejection, raw: line.rawData)
        }
        appendUnsupportedModelPricing(to: &batch, usageRequests: usageRequests)
        appendSkippedUsageEvents(
            to: &batch,
            skippedForkReplayCount: skippedForkReplayCount
        )
        return batch
    }

    private static func appendUnsupportedModelPricing(
        to batch: inout ParseDiagnosticsBatch,
        usageRequests: [ParsedRequest]
    ) {
        var seenModels = Set<String>()
        for request in usageRequests {
            guard let model = request.model,
                  !PricingTable.isSyntheticModel(model),
                  PricingTable.rates(for: model) == nil,
                  seenModels.insert(model).inserted else {
                continue
            }
            batch.append(.codexUnsupportedModelPricing(model))
        }
    }

    private static func appendSkippedUsageEvents(
        to batch: inout ParseDiagnosticsBatch,
        skippedForkReplayCount: Int
    ) {
        if skippedForkReplayCount > 0 {
            batch.append(.codexSkippedForkReplay(skippedForkReplayCount))
        }
    }

    private static func unknownLineTypeRejection(for entry: CodexEntry) -> DecodeRejection? {
        let entryType = entry.type ?? "<missing>"
        let payloadType = entry.payload?.type ?? "<missing>"

        switch entryType {
        case "session_meta",
             "turn_context",
             "turn_aborted",
             "task_started",
             "task_complete",
             "compacted":
            return nil
        case "response_item":
            switch payloadType {
            case "message",
                 "reasoning",
                 "function_call",
                 "custom_tool_call",
                 "function_call_output",
                 "custom_tool_call_output",
                 "tool_search_call",
                 "tool_search_output",
                 "web_search_call",
                 "image_generation_call":
                return nil
            default:
                return .codexUnknownLineType("\(entryType)/\(payloadType)")
            }
        case "event_msg":
            switch payloadType {
            case "turn_context",
                 "user_message",
                 "agent_message",
                 "agent_reasoning",
                 "token_count",
                 "task_started",
                 "mcp_tool_call_end",
                 "patch_apply_begin",
                 "patch_apply_end",
                 "turn_aborted",
                 "task_complete",
                 "web_search_end",
                 "image_generation_end",
                 "context_compacted",
                 "thread_rolled_back":
                return nil
            default:
                return .codexUnknownLineType("\(entryType)/\(payloadType)")
            }
        default:
            return .codexUnknownLineType("\(entryType)/\(payloadType)")
        }
    }
}
