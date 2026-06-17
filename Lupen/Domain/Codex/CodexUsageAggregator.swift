import Foundation

struct CodexUsageAggregation: Equatable, Sendable {
    let session: Session
    let requests: [ParsedRequest]
    let rawPayloadByRequestId: [String: Data]
    let rawPayloadLocatorByRequestId: [String: RawPayloadLocator]
    let tokenEventCount: Int
    let skippedDuplicateCumulativeCount: Int
    let skippedForkReplayCount: Int
    let missingUsageCount: Int
    let unknownPricingCount: Int
}

enum CodexUsageAggregator {
    private struct EntryRecord {
        let entry: CodexEntry
        let rawData: Data?
        let rawLocator: RawPayloadLocator?
    }

    static func aggregate(metadata: CodexSessionMetadata, lines: [Data]) -> CodexUsageAggregation {
        let decoded = CodexLineReader.decodeLines(from: lines)
        var aggregation = aggregate(metadata: metadata, decodedLines: decoded.decodedLines)
        if decoded.rejectedLineCount > 0 {
            aggregation = CodexUsageAggregation(
                session: aggregation.session,
                requests: aggregation.requests,
                rawPayloadByRequestId: aggregation.rawPayloadByRequestId,
                rawPayloadLocatorByRequestId: aggregation.rawPayloadLocatorByRequestId,
                tokenEventCount: aggregation.tokenEventCount,
                skippedDuplicateCumulativeCount: aggregation.skippedDuplicateCumulativeCount,
                skippedForkReplayCount: aggregation.skippedForkReplayCount,
                missingUsageCount: aggregation.missingUsageCount + decoded.rejectedLineCount,
                unknownPricingCount: aggregation.unknownPricingCount
            )
        }
        return aggregation
    }

    static func aggregate(
        metadata: CodexSessionMetadata,
        decodedLines: [CodexLineReader.DecodedLine],
        initialPreviousTotal: CodexTokenUsage? = nil
    ) -> CodexUsageAggregation {
        aggregate(
            metadata: metadata,
            records: decodedLines.map {
                EntryRecord(
                    entry: $0.entry,
                    rawData: $0.rawData,
                    rawLocator: $0.rawLocator
                )
            },
            initialPreviousTotal: initialPreviousTotal
        )
    }

    static func aggregate(metadata: CodexSessionMetadata, entries: [CodexEntry]) -> CodexUsageAggregation {
        aggregate(
            metadata: metadata,
            records: entries.map { EntryRecord(entry: $0, rawData: nil, rawLocator: nil) }
        )
    }

    private static func aggregate(
        metadata: CodexSessionMetadata,
        records: [EntryRecord],
        initialPreviousTotal: CodexTokenUsage? = nil
    ) -> CodexUsageAggregation {
        let entries = records.map(\.entry)
        let eventUserMessages = eventUserMessageTexts(in: entries)
        var previousTotal = initialPreviousTotal
        var requests: [ParsedRequest] = []
        let rawPayloadByRequestId: [String: Data] = [:]
        var rawPayloadLocatorByRequestId: [String: RawPayloadLocator] = [:]
        var currentModel = metadata.model
        var currentTurnId: String?
        var generatedTurnOrdinal = 0
        var tokenEventCount = 0
        var skippedDuplicates = 0
        var skippedForkReplay = 0
        var missingUsage = 0
        var unknownPricing = 0
        var hasSeenLiveEventUserMessage = false

        for record in records {
            let entry = record.entry
            guard let payload = entry.payload else { continue }

            if entry.type == "turn_context" || payload.type == "turn_context" {
                currentTurnId = payload.turnId ?? currentTurnId
                currentModel = payload.model ?? currentModel
                continue
            }

            if entry.type == "response_item",
               payload.type == "message",
               payload.role == "user" {
                let text = normalized(payload.messageText)
                if payload.turnId == nil,
                   !eventUserMessages.isEmpty && !eventUserMessages.contains(text) {
                    continue
                }
                if let turnId = nonEmpty(payload.turnId) {
                    currentTurnId = turnId
                } else if currentTurnId == nil {
                    generatedTurnOrdinal += 1
                    currentTurnId = generatedTurnId(generatedTurnOrdinal)
                }
                continue
            }

            if entry.type == "event_msg",
               payload.type == "user_message" {
                hasSeenLiveEventUserMessage = true
                if currentTurnId == nil {
                    generatedTurnOrdinal += 1
                    currentTurnId = generatedTurnId(generatedTurnOrdinal)
                }
                continue
            }

            if isTurnTerminator(entry, payload) {
                currentTurnId = nil
                continue
            }

            guard entry.type == "event_msg", payload.type == "token_count" else { continue }
            tokenEventCount += 1

            let timestamp = CodexTimestampParser.parse(entry.timestamp)
                ?? CodexTimestampParser.parse(payload.timestamp)
                ?? metadata.createdAt
                ?? Date(timeIntervalSince1970: 0)

            let duplicateCountBefore = skippedDuplicates
            guard let usage = resolveUsage(
                payload.info,
                previousTotal: &previousTotal,
                skippedDuplicates: &skippedDuplicates
            ) else {
                if skippedDuplicates == duplicateCountBefore {
                    missingUsage += 1
                }
                continue
            }

            if CodexForkReplayFilter.shouldSkip(
                metadata: metadata,
                eventTimestamp: timestamp,
                hasSeenLiveEventUserMessage: hasSeenLiveEventUserMessage
            ) {
                skippedForkReplay += 1
                continue
            }

            let model = payload.model ?? payload.info?.model ?? payload.info?.modelName ?? currentModel
            let tokens = usage.normalizedTokenBreakdown(
                contextWindow: payload.info?.modelContextWindow
            )
            if let model, !PricingTable.isSyntheticModel(model),
               PricingTable.rates(for: model) == nil {
                unknownPricing += 1
            }

            let request = ParsedRequest(
                id: requestId(metadata: metadata, turnId: payload.turnId ?? currentTurnId, ordinal: requests.count),
                messageId: nil,
                sessionId: metadata.scopedId,
                provider: .codex,
                rawSessionId: metadata.id,
                model: model,
                timestamp: timestamp,
                parentUuid: nil,
                isSidechain: false,
                speed: nil,
                stopReason: nil,
                tokens: tokens
            )
            requests.append(request)
            if let rawLocator = record.rawLocator {
                rawPayloadLocatorByRequestId[request.id] = rawLocator.withKind(.requestTokenCount)
            }
        }

        let session = Session(
            id: metadata.scopedId,
            provider: .codex,
            rawSessionId: metadata.id,
            requests: requests,
            projectPath: metadata.cwd,
            cachedTitle: metadata.titleHint
        )

        return CodexUsageAggregation(
            session: session,
            requests: requests,
            rawPayloadByRequestId: rawPayloadByRequestId,
            rawPayloadLocatorByRequestId: rawPayloadLocatorByRequestId,
            tokenEventCount: tokenEventCount,
            skippedDuplicateCumulativeCount: skippedDuplicates,
            skippedForkReplayCount: skippedForkReplay,
            missingUsageCount: missingUsage,
            unknownPricingCount: unknownPricing
        )
    }

    private static func resolveUsage(
        _ info: CodexEntry.Info?,
        previousTotal: inout CodexTokenUsage?,
        skippedDuplicates: inout Int
    ) -> CodexTokenUsage? {
        guard let info else { return nil }

        if let total = info.totalTokenUsage,
           let previousTotal,
           total == previousTotal {
            skippedDuplicates += 1
            return nil
        }

        let usage: CodexTokenUsage?
        if let last = info.lastTokenUsage {
            usage = last
            if info.totalTokenUsage == nil {
                if let totalBeforeLast = previousTotal {
                    previousTotal = totalBeforeLast.adding(last)
                } else {
                    previousTotal = last
                }
            }
        } else if let total = info.totalTokenUsage {
            if let previousTotal {
                usage = total.delta(from: previousTotal)
            } else {
                usage = total
            }
        } else {
            usage = nil
        }

        if let total = info.totalTokenUsage {
            previousTotal = total
        }
        guard let usage, !usage.isZero else { return nil }
        return usage
    }

    private static func requestId(metadata: CodexSessionMetadata, turnId: String?, ordinal: Int) -> String {
        let turnComponent = turnId?.isEmpty == false ? turnId! : "session"
        return "\(metadata.scopedId):token_count:\(turnComponent):\(ordinal)"
    }

    private static func generatedTurnId(_ ordinal: Int) -> String {
        "generated-\(ordinal)"
    }

    private static func isTurnTerminator(_ entry: CodexEntry, _ payload: CodexEntry.Payload) -> Bool {
        if entry.type == "turn_aborted" || entry.type == "task_complete" {
            return true
        }
        return entry.type == "event_msg"
            && (payload.type == "turn_aborted" || payload.type == "task_complete")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func eventUserMessageTexts(in entries: [CodexEntry]) -> Set<String> {
        Set(entries.compactMap { entry in
            guard entry.type == "event_msg",
                  entry.payload?.type == "user_message" else {
                return nil
            }
            let text = normalized(entry.payload?.messageText)
            return text.isEmpty ? nil : text
        })
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }
}

enum CodexForkReplayFilter {
    private static let replayWindow: TimeInterval = 5

    static func shouldSkip(
        metadata: CodexSessionMetadata,
        eventTimestamp: Date,
        hasSeenLiveEventUserMessage: Bool = false
    ) -> Bool {
        guard !hasSeenLiveEventUserMessage else { return false }
        guard !metadata.isSubagentThread else { return false }
        guard metadata.forkedFromId != nil,
              let createdAt = metadata.createdAt else {
            return false
        }
        let delta = eventTimestamp.timeIntervalSince(createdAt)
        return delta >= 0 && delta <= replayWindow
    }
}
