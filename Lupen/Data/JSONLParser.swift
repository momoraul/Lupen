import Foundation

struct JSONLParser {
    // Logging routed through `LoggerService.shared.logFromAnyThread`
    // (this struct is invoked from background concurrent parse workers).
    private static let decoderThreadKey = "io.lupen.JSONLParser.decoder"
    private static let newlineByte: UInt8 = 0x0A
    private static let chunkSize = 65536

    // Byte patterns for tail-window type detection
    private static let assistantTypePattern = Data("\"type\":\"assistant\"".utf8)
    private static let userTypePattern = Data("\"type\":\"user\"".utf8)
    private static let systemTypePattern = Data("\"type\":\"system\"".utf8)
    private static let typeSearchTailSize = 2048

    private static func decoder() -> JSONDecoder {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[decoderThreadKey] as? JSONDecoder {
            return existing
        }
        let decoder = JSONDecoder()
        dictionary[decoderThreadKey] = decoder
        return decoder
    }

    // MARK: - Full file parse (assistant-only, Phase 1 compat)

    func parseFile(at url: URL) -> [RawEntry] {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fileHandle.close() }

        var results: [RawEntry] = []
        var lineBuffer = Data()

        while true {
            let chunk = fileHandle.readData(ofLength: Self.chunkSize)
            guard !chunk.isEmpty else { break }
            results.append(contentsOf: parseData(chunk, lineBuffer: &lineBuffer, filePath: url.path))
        }

        if !lineBuffer.isEmpty {
            if let entry = parseAssistantLine(lineBuffer, filePath: url.path) {
                results.append(entry)
            }
        }

        return results
    }

    // MARK: - Incremental parse (assistant-only)

    func parseFileFrom(url: URL, offset: UInt64) -> (entries: [RawEntry], newOffset: UInt64) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? fileHandle.close() }

        fileHandle.seek(toFileOffset: offset)
        var results: [RawEntry] = []
        var lineBuffer = Data()

        while true {
            let chunk = fileHandle.readData(ofLength: Self.chunkSize)
            guard !chunk.isEmpty else { break }
            results.append(contentsOf: parseData(chunk, lineBuffer: &lineBuffer, filePath: url.path))
        }

        if !lineBuffer.isEmpty {
            if let entry = parseAssistantLine(lineBuffer, filePath: url.path) {
                results.append(entry)
            }
        }

        return (results, fileHandle.offsetInFile)
    }

    // MARK: - Full parse with auxiliary (assistant + user + system)

    func parseFileWithAuxiliary(
        url: URL,
        offset: UInt64
    ) -> (assistant: [RawEntry], auxiliary: [ParsedLine], newOffset: UInt64) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            LoggerService.shared.logFromAnyThread(.error, "Cannot open file for parsing: \(url.lastPathComponent)", context: "Parser")
            return ([], [], offset)
        }
        defer { try? fileHandle.close() }

        fileHandle.seek(toFileOffset: offset)
        var assistantResults: [RawEntry] = []
        var auxResults: [ParsedLine] = []
        var lineBuffer = Data()

        while true {
            let chunk = fileHandle.readData(ofLength: Self.chunkSize)
            guard !chunk.isEmpty else { break }
            processChunkWithAuxiliary(
                chunk, lineBuffer: &lineBuffer, filePath: url.path,
                assistantOut: &assistantResults, auxOut: &auxResults
            )
        }

        if !lineBuffer.isEmpty {
            classifyLine(lineBuffer, filePath: url.path, assistantOut: &assistantResults, auxOut: &auxResults)
        }

        return (assistantResults, auxResults, fileHandle.offsetInFile)
    }

    // MARK: - Private: chunk processing

    func parseData(_ data: Data, lineBuffer: inout Data, filePath: String) -> [RawEntry] {
        var results: [RawEntry] = []
        var start = data.startIndex
        while let newlineIndex = data[start...].firstIndex(of: Self.newlineByte) {
            var lineData = lineBuffer
            lineData.append(contentsOf: data[start..<newlineIndex])
            lineBuffer = Data()
            if !lineData.isEmpty {
                if let entry = parseAssistantLine(lineData, filePath: filePath) {
                    results.append(entry)
                }
            }
            start = data.index(after: newlineIndex)
        }
        if start < data.endIndex {
            lineBuffer.append(contentsOf: data[start...])
        }
        return results
    }

    private func processChunkWithAuxiliary(
        _ data: Data,
        lineBuffer: inout Data,
        filePath: String,
        assistantOut: inout [RawEntry],
        auxOut: inout [ParsedLine]
    ) {
        var start = data.startIndex
        while let newlineIndex = data[start...].firstIndex(of: Self.newlineByte) {
            var lineData = lineBuffer
            lineData.append(contentsOf: data[start..<newlineIndex])
            lineBuffer = Data()
            if !lineData.isEmpty {
                classifyLine(lineData, filePath: filePath, assistantOut: &assistantOut, auxOut: &auxOut)
            }
            start = data.index(after: newlineIndex)
        }
        if start < data.endIndex {
            lineBuffer.append(contentsOf: data[start...])
        }
    }

    // MARK: - Parse from pre-read lines (Phase 2 single-read fan-out)

    /// Classify pre-split lines so `AppStateStore` can read each file once
    /// via `JSONLLineReader` and fan the bytes out to legacy / v2 pipelines.
    func classifyPreReadLines(
        _ lines: [Data],
        filePath: String
    ) -> (assistant: [RawEntry], auxiliary: [ParsedLine]) {
        var assistantOut: [RawEntry] = []
        var auxOut: [ParsedLine] = []
        for line in lines {
            classifyLine(line, filePath: filePath, assistantOut: &assistantOut, auxOut: &auxOut)
        }
        return (assistantOut, auxOut)
    }

    // MARK: - Line classification

    private func classifyLine(
        _ lineData: Data,
        filePath: String,
        assistantOut: inout [RawEntry],
        auxOut: inout [ParsedLine]
    ) {
        guard !EntryFilter.shouldReject(lineData) else { return }

        let tailStart = lineData.count > Self.typeSearchTailSize
            ? lineData.count - Self.typeSearchTailSize : 0
        let tail = lineData[tailStart..<lineData.count]

        // For user/system entries, "type":"user" is at the line start.
        // Large entries (e.g. with base64 image data) may exceed the tail window,
        // so also check the first 128 bytes.
        let headEnd = min(lineData.count, 256)
        let head = lineData[0..<headEnd]

        // Check both head and tail for `"type":"assistant"` — matches the
        // symmetry user/system already use below. Real JSONL fixtures
        // (`<synthetic>` stop entries, interrupted-turn markers) put the
        // `type` field at the head with a long Korean/English content
        // block trailing, pushing the token well out of the tail window.
        // Tail-only caused a silent drop that surfaced as
        // "missing billable requestId" in Verify Costs.
        // The byte pattern `"type":"assistant"` can appear inside a user
        // line's serialised content (e.g., the user pasted a JSON
        // example). Decode + re-gate on `entry.type == "assistant"`
        // eliminates false positives — but if decoding succeeds with
        // `type != "assistant"` or decoding fails outright, fall
        // through to the user/system classifiers instead of returning,
        // so those branches still get a chance to classify the line.
        if tail.range(of: Self.assistantTypePattern) != nil ||
           head.range(of: Self.assistantTypePattern) != nil {
            if let entry = try? Self.decoder().decode(RawEntry.self, from: lineData),
               entry.type == "assistant", entry.message.usage != nil {
                assistantOut.append(entry)
                return
            }
            // fall through — let user/system checks try to classify.
        }

        if tail.range(of: Self.userTypePattern) != nil ||
           head.range(of: Self.userTypePattern) != nil {
            if let loose = try? Self.decoder().decode(LooseEntry.self, from: lineData) {
                let text = loose.message?.content?.flatText ?? ""
                auxOut.append(.user(ParsedLine.UserAux(
                    uuid: loose.uuid ?? "",
                    parentUuid: loose.parentUuid,
                    sessionId: loose.sessionId ?? "",
                    timestamp: loose.timestamp ?? "",
                    text: text
                )))
            }
            return
        }

        if tail.range(of: Self.systemTypePattern) != nil ||
           head.range(of: Self.systemTypePattern) != nil {
            if let loose = try? Self.decoder().decode(LooseEntry.self, from: lineData) {
                let sp: String? = loose.message?.system ?? loose.message?.content?.flatText
                var toolsData: Data? = nil
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let msg = obj["message"] as? [String: Any],
                   let tools = msg["tools"] {
                    toolsData = try? JSONSerialization.data(withJSONObject: tools, options: [])
                }
                auxOut.append(.system(ParsedLine.SystemAux(
                    uuid: loose.uuid ?? "",
                    sessionId: loose.sessionId ?? "",
                    timestamp: loose.timestamp ?? "",
                    systemPrompt: sp,
                    toolDefinitionsJSON: toolsData,
                    rawPayload: lineData
                )))
            }
            return
        }
    }

    private func parseAssistantLine(_ lineData: Data, filePath: String) -> RawEntry? {
        guard !EntryFilter.shouldReject(lineData) else { return nil }
        do {
            let entry = try Self.decoder().decode(RawEntry.self, from: lineData)
            guard entry.type == "assistant", entry.message.usage != nil else { return nil }
            return entry
        } catch {
            LoggerService.shared.logFromAnyThread(
                .warning,
                "Malformed JSONL line in \(filePath): \(error.localizedDescription)",
                context: "JSONLParser"
            )
            return nil
        }
    }

    // MARK: - Permissive decoder for user/system lines

    private struct LooseEntry: Decodable {
        let type: String
        let uuid: String?
        let parentUuid: String?
        let sessionId: String?
        let timestamp: String?
        let message: MessageBox?

        struct MessageBox: Decodable {
            let content: ContentField?
            let system: String?
            let tools: [ToolDef]?

            struct ToolDef: Decodable, Sendable {}
        }
    }
}
