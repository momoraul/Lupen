import Foundation

enum CodexLineReader {
    struct DecodedLine: Equatable, Sendable {
        let entry: CodexEntry
        let rawData: Data
        let rawLocator: RawPayloadLocator?

        init(entry: CodexEntry, rawData: Data, rawLocator: RawPayloadLocator? = nil) {
            self.entry = entry
            self.rawData = rawData
            self.rawLocator = rawLocator
        }
    }

    struct RejectedLine: Equatable, Sendable {
        let rawData: Data
        let errorDescription: String
    }

    struct Result: Equatable, Sendable {
        let entries: [CodexEntry]
        let decodedLines: [DecodedLine]
        let rejectedLines: [RejectedLine]
        let rejectedLineCount: Int
        let newOffset: UInt64
    }

    /// One streamed decode outcome. Rejected lines carry their position
    /// so importers can write diagnostics with byte offsets without
    /// retaining the lines.
    enum StreamedLine: Sendable {
        case decoded(DecodedLine)
        case rejected(RejectedLine, lineOrdinal: Int, byteOffset: UInt64)
    }

    /// Streaming decode (plan 2.3 / memory-audit P1): delivers each
    /// line's outcome to `handler` without building whole-file
    /// `DecodedLine` arrays. Locators match `readEntries` exactly.
    /// Return `false` to stop early (cancellation at batch boundaries);
    /// offset semantics follow `JSONLLineReader.streamLineRecords`.
    @discardableResult
    static func streamEntries(
        from url: URL,
        offset: UInt64 = 0,
        handler: (StreamedLine) throws -> Bool
    ) rethrows -> UInt64 {
        let fingerprint = RawPayloadLocator.fingerprint(for: url)
        let decoder = JSONDecoder()
        return try JSONLLineReader.streamLineRecords(from: url, offset: offset) { record in
            try handler(decodeRecord(
                record, sourceURL: url, fingerprint: fingerprint, decoder: decoder
            ))
        }
    }

    static func readEntries(from url: URL, offset: UInt64 = 0) -> Result {
        var decodedLines: [DecodedLine] = []
        var rejectedLines: [RejectedLine] = []
        let newOffset = streamEntries(from: url, offset: offset) { streamed in
            switch streamed {
            case .decoded(let line): decodedLines.append(line)
            case .rejected(let line, _, _): rejectedLines.append(line)
            }
            return true
        }
        return Result(
            entries: decodedLines.map(\.entry),
            decodedLines: decodedLines,
            rejectedLines: rejectedLines,
            rejectedLineCount: rejectedLines.count,
            newOffset: newOffset
        )
    }

    static func decodeEntries(from lines: [Data]) -> (entries: [CodexEntry], rejectedLineCount: Int) {
        let decoded = decodeLines(from: lines)
        return (decoded.decodedLines.map(\.entry), decoded.rejectedLines.count)
    }

    static func decodeLines(from lines: [Data]) -> (decodedLines: [DecodedLine], rejectedLines: [RejectedLine], rejectedLineCount: Int) {
        let decoder = JSONDecoder()
        var decodedLines: [DecodedLine] = []
        var rejectedLines: [RejectedLine] = []

        for line in lines {
            if let entry = try? decoder.decode(CodexEntry.self, from: line) {
                decodedLines.append(DecodedLine(entry: entry, rawData: line))
            } else if let entry = decodeViaJSONObject(line) {
                decodedLines.append(DecodedLine(entry: entry, rawData: line))
            } else {
                rejectedLines.append(RejectedLine(
                    rawData: line,
                    errorDescription: decodeErrorDescription(for: line, decoder: decoder)
                ))
            }
        }

        return (decodedLines, rejectedLines, rejectedLines.count)
    }

    private static func decodeRecord(
        _ record: JSONLLineReader.LineRecord,
        sourceURL: URL,
        fingerprint: RawPayloadLocator.SourceFingerprint,
        decoder: JSONDecoder
    ) -> StreamedLine {
        let locator = RawPayloadLocator(
            provider: .codex,
            kind: .stepLine,
            sourceURL: sourceURL,
            byteOffset: record.byteOffset,
            lineOrdinal: record.lineOrdinal,
            lineByteCount: record.data.count,
            lineChecksum: RawPayloadLocator.checksum(for: record.data),
            fingerprint: fingerprint
        )
        if let entry = try? decoder.decode(CodexEntry.self, from: record.data) {
            return .decoded(DecodedLine(entry: entry, rawData: record.data, rawLocator: locator))
        }
        if let entry = decodeViaJSONObject(record.data) {
            return .decoded(DecodedLine(entry: entry, rawData: record.data, rawLocator: locator))
        }
        return .rejected(
            RejectedLine(
                rawData: record.data,
                errorDescription: decodeErrorDescription(for: record.data, decoder: decoder)
            ),
            lineOrdinal: record.lineOrdinal,
            byteOffset: record.byteOffset
        )
    }

    private static func decodeErrorDescription(for line: Data, decoder: JSONDecoder) -> String {
        do {
            _ = try decoder.decode(CodexEntry.self, from: line)
        } catch {
            return error.localizedDescription
        }
        return "Unsupported Codex JSONL shape"
    }

    private static func decodeViaJSONObject(_ line: Data) -> CodexEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        let payloadObject = object["payload"] as? [String: Any]
        let infoObject = payloadObject?["info"] as? [String: Any]
        let payload = CodexEntry.Payload(
            type: payloadObject?["type"] as? String,
            timestamp: payloadObject?["timestamp"] as? String,
            turnId: payloadObject?["turn_id"] as? String,
            model: payloadObject?["model"] as? String,
            cwd: payloadObject?["cwd"] as? String,
            info: CodexEntry.Info(
                lastTokenUsage: tokenUsage(from: infoObject?["last_token_usage"]),
                totalTokenUsage: tokenUsage(from: infoObject?["total_token_usage"]),
                modelContextWindow: infoObject?["model_context_window"] as? Int
            )
        )
        return CodexEntry(
            type: object["type"] as? String,
            timestamp: object["timestamp"] as? String,
            payload: payload
        )
    }

    private static func tokenUsage(from value: Any?) -> CodexTokenUsage? {
        guard let object = value as? [String: Any] else { return nil }
        return CodexTokenUsage(
            inputTokens: intValue(object["input_tokens"]),
            cachedInputTokens: intValue(object["cached_input_tokens"]),
            outputTokens: intValue(object["output_tokens"]),
            reasoningOutputTokens: intValue(object["reasoning_output_tokens"]),
            totalTokens: optionalIntValue(object["total_tokens"])
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        optionalIntValue(value) ?? 0
    }

    private static func optionalIntValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
