import Foundation

enum CodexSessionTitleIndexReader {

    /// Fingerprint-keyed single-entry cache (plan 5.7): the importer
    /// reads the title index once per atomic unit, and on a 28k-unit
    /// backfill the repeated 17k-line JSON decode dominated the
    /// per-unit cost. (size, mtime) invalidation matches the scanner's
    /// own change detection — a rewritten index is re-read immediately.
    private struct CacheEntry {
        let path: String
        let byteSize: UInt64
        let modifiedAt: Date?
        let index: CodexSessionTitleIndex
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: CacheEntry?

    static func read(from url: URL) -> CodexSessionTitleIndex {
        let path = url.standardizedFileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let byteSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attributes?[.modificationDate] as? Date

        cacheLock.lock()
        if let cache, cache.path == path,
           cache.byteSize == byteSize, cache.modifiedAt == modifiedAt {
            let index = cache.index
            cacheLock.unlock()
            return index
        }
        cacheLock.unlock()

        let index = readUncached(from: url)
        cacheLock.lock()
        cache = CacheEntry(
            path: path, byteSize: byteSize, modifiedAt: modifiedAt, index: index
        )
        cacheLock.unlock()
        return index
    }

    private static func readUncached(from url: URL) -> CodexSessionTitleIndex {
        let lines = JSONLLineReader.readLines(from: url, offset: 0).lines
        guard !lines.isEmpty else { return .empty }

        let decoder = JSONDecoder()
        var entries: [String: CodexSessionTitleIndex.Entry] = [:]
        var rejected = 0

        for line in lines {
            guard let record = try? decoder.decode(Record.self, from: line),
                  !record.id.isEmpty else {
                rejected += 1
                continue
            }

            let entry = CodexSessionTitleIndex.Entry(
                id: record.id,
                threadName: record.threadName,
                updatedAt: CodexTimestampParser.parse(record.updatedAt)
            )
            if shouldReplace(existing: entries[record.id], with: entry) {
                entries[record.id] = entry
            }
        }

        return CodexSessionTitleIndex(entriesById: entries, rejectedLineCount: rejected)
    }

    private static func shouldReplace(
        existing: CodexSessionTitleIndex.Entry?,
        with candidate: CodexSessionTitleIndex.Entry
    ) -> Bool {
        guard let existing else { return true }
        switch (existing.updatedAt, candidate.updatedAt) {
        case let (old?, new?):
            return new >= old
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            return true
        }
    }

    private struct Record: Decodable {
        let id: String
        let threadName: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
            case updatedAt = "updated_at"
        }
    }
}
