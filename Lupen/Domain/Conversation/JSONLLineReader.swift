import Foundation

/// Splits a JSONL file into newline-delimited `Data` lines, in order.
///
/// Chunk-buffered so large files stay memory-safe; supports offset-based
/// incremental reads. Feeds the `ConversationAssembler` pipeline.
enum JSONLLineReader {
    struct LineRecord: Equatable, Sendable {
        let data: Data
        let byteOffset: UInt64
        let lineOrdinal: Int
    }

    private static let chunkSize = 65_536
    private static let newlineByte: UInt8 = 0x0A

    /// Reads from `offset` to EOF, returning newline-split lines (empty lines
    /// dropped) and the new file offset.
    static func readLines(from url: URL, offset: UInt64) -> (lines: [Data], newOffset: UInt64) {
        let read = readLineRecords(from: url, offset: offset)
        return (read.records.map(\.data), read.newOffset)
    }

    /// Reads from `offset` to EOF, returning newline-split records with the
    /// source byte offset of each line. This keeps provider-specific raw lookup
    /// possible without storing raw line bytes in long-lived state.
    static func readLineRecords(from url: URL, offset: UInt64) -> (records: [LineRecord], newOffset: UInt64) {
        var records: [LineRecord] = []
        let newOffset = streamLineRecords(from: url, offset: offset) { record in
            records.append(record)
            return true
        }
        return (records, newOffset)
    }

    /// Streaming core (plan 2.3): delivers each record to `handler`
    /// without materializing a whole-file array — scoped importers feed
    /// bounded write batches from this. Return `false` to stop early
    /// (cancellation at batch boundaries); the returned offset is then
    /// the byte after the last delivered line, EOF otherwise (identical
    /// to `readLineRecords` bookkeeping — the batch API delegates here).
    @discardableResult
    static func streamLineRecords(
        from url: URL,
        offset: UInt64 = 0,
        handler: (LineRecord) throws -> Bool
    ) rethrows -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            LoggerService.shared.logFromAnyThread(
                .warning,
                "JSONLLineReader: cannot open \(url.lastPathComponent)",
                context: "Parser"
            )
            return offset
        }
        defer { try? handle.close() }

        handle.seek(toFileOffset: offset)

        var lineBuffer = Data()
        var lineStartOffset = offset
        var currentOffset = offset
        var lineOrdinal = 0

        while true {
            let chunk = handle.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty { break }

            var start = chunk.startIndex
            while let newlineIndex = chunk[start...].firstIndex(of: Self.newlineByte) {
                var lineData = lineBuffer
                lineData.append(contentsOf: chunk[start..<newlineIndex])
                lineBuffer = Data()

                let recordStart = lineStartOffset
                let bytesThroughNewline = chunk.distance(from: start, to: newlineIndex) + 1
                currentOffset += UInt64(bytesThroughNewline)
                lineStartOffset = currentOffset
                start = chunk.index(after: newlineIndex)

                if !lineData.isEmpty {
                    let record = LineRecord(
                        data: stripTrailingCR(lineData),
                        byteOffset: recordStart,
                        lineOrdinal: lineOrdinal
                    )
                    lineOrdinal += 1
                    if try !handler(record) {
                        return currentOffset
                    }
                }
            }
            if start < chunk.endIndex {
                lineBuffer.append(contentsOf: chunk[start...])
                currentOffset += UInt64(chunk.distance(from: start, to: chunk.endIndex))
            }
        }

        // Trailing line without a final newline.
        if !lineBuffer.isEmpty {
            let record = LineRecord(
                data: stripTrailingCR(lineBuffer),
                byteOffset: lineStartOffset,
                lineOrdinal: lineOrdinal
            )
            if try !handler(record) {
                return currentOffset
            }
        }

        return handle.offsetInFile
    }

    /// Single-read fan-out: AppStateStore reads the file once and shares the
    /// `Data` between the legacy and v2 pipelines via this entry point.
    static func splitAllLines(from data: Data) -> [Data] {
        splitLines(data)
    }

    static func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var lineBuffer = Data()
        processChunk(data, lineBuffer: &lineBuffer, output: &lines)
        if !lineBuffer.isEmpty {
            lines.append(lineBuffer)
        }
        return lines
    }

    static func readLine(at locator: RawPayloadLocator) -> Data? {
        guard let byteOffset = locator.byteOffset else {
            return nil
        }
        guard fingerprintMatches(locator) else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: locator.sourceURL) else {
            return nil
        }
        defer { try? handle.close() }

        handle.seek(toFileOffset: byteOffset)
        var line = Data()
        let maxLineBytes = locator.lineByteCount.map { $0 + 1 }
        while true {
            let readLength: Int
            if let maxLineBytes {
                let remaining = maxLineBytes - line.count + 1
                guard remaining > 0 else { return nil }
                readLength = min(chunkSize, remaining)
            } else {
                readLength = chunkSize
            }
            let chunk = handle.readData(ofLength: readLength)
            if chunk.isEmpty { break }
            if let newlineIndex = chunk.firstIndex(of: newlineByte) {
                line.append(contentsOf: chunk[..<newlineIndex])
                break
            }
            line.append(chunk)
            if let maxLineBytes, line.count > maxLineBytes {
                return nil
            }
        }
        let stripped = stripTrailingCR(line)
        guard !stripped.isEmpty, lineMatchesLocator(stripped, locator: locator) else {
            return nil
        }
        return stripped
    }

    // MARK: - Internal

    private static func processChunk(_ chunk: Data, lineBuffer: inout Data, output: inout [Data]) {
        var start = chunk.startIndex
        while let newlineIndex = chunk[start...].firstIndex(of: Self.newlineByte) {
            var lineData = lineBuffer
            lineData.append(contentsOf: chunk[start..<newlineIndex])
            lineBuffer = Data()
            if !lineData.isEmpty {
                output.append(stripTrailingCR(lineData))
            }
            start = chunk.index(after: newlineIndex)
        }
        if start < chunk.endIndex {
            lineBuffer.append(contentsOf: chunk[start...])
        }
    }

    /// CRLF support: drop a trailing 0x0D so the JSON decoder doesn't choke.
    private static func stripTrailingCR(_ data: Data) -> Data {
        if let last = data.last, last == 0x0D {
            return data.dropLast()
        }
        return data
    }

    private static func fingerprintMatches(_ locator: RawPayloadLocator) -> Bool {
        guard let expected = locator.fingerprint else { return true }
        let actual = RawPayloadLocator.fingerprint(for: locator.sourceURL)
        guard actual.fileSize >= expected.fileSize else { return false }
        if let byteOffset = locator.byteOffset, actual.fileSize <= byteOffset {
            return false
        }
        if locator.lineChecksum == nil,
           let expectedModificationTime = expected.modificationTime,
           let actualModificationTime = actual.modificationTime,
           actualModificationTime != expectedModificationTime {
            return false
        }
        return true
    }

    private static func lineMatchesLocator(_ line: Data, locator: RawPayloadLocator) -> Bool {
        if let expectedByteCount = locator.lineByteCount,
           line.count != expectedByteCount {
            return false
        }
        if let expectedChecksum = locator.lineChecksum,
           RawPayloadLocator.checksum(for: line) != expectedChecksum {
            return false
        }
        return true
    }
}
