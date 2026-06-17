import Foundation
import Observation

/// In-memory cache of every `RateLimitSample` Lupen has captured, plus the
/// retention sweep that prunes lines older than 30 days. The store reads
/// the on-disk `~/.claude/lupen/ratelimit-samples.jsonl` once at launch
/// and incrementally appends new samples as the file grows.
///
/// **Tail-read pattern**. The store remembers the last byte offset it
/// processed (`tailOffset`). On each `loadIncrementally(now:)` call it
/// only reads bytes from that offset onward, so tailing a long-lived
/// log file stays O(new bytes) instead of O(file size).
///
/// **Retention.** At launch and on a once-a-day timer the store rewrites
/// the file in-place dropping any line whose `ts` is older than
/// `retentionDays`. The rewrite uses the SnapshotStore-style atomic
/// rename pattern: write to `<file>.tmp`, then `rename(2)` over the
/// original.
///
/// **Thread safety.** All mutation goes through the main actor — sample
/// counts feed the Settings UI directly, and AppKit doesn't tolerate
/// off-thread observation. The actual file I/O is dispatched to a
/// utility queue inside `loadIncrementally(now:)` so the main actor
/// never blocks on disk.
@Observable
@MainActor
final class RateLimitSampleStore {

    /// Days of history kept in the JSONL log. 30-day rolling window per
    /// the plan; longer windows aren't useful (analyses live in 14 days)
    /// and add disk pressure.
    static let retentionDays: Int = 30

    /// Every sample we've successfully decoded since launch, in the
    /// order they appeared on disk. Reads are O(1) for `count` and
    /// O(N) for filtering — the analyser builds its own indices.
    private(set) var samples: [RateLimitSample] = []

    /// Newest sample timestamp, exposed for the Settings UI's
    /// "last sample 2m ago" line.
    var lastSampleAt: Date? { samples.last?.ts }

    /// Lifetime sample append counter. Survives retention sweeps —
    /// `samples.count` only reports the current 30-day window, this
    /// counts every line we've ever ingested across launches when
    /// combined with the persisted prefs counter.
    private(set) var lifetimeAppendCount: Int = 0

    /// Backing JSONL log path. Exposed so callers like
    /// `StatuslineConnectionService.disconnect(deletingSamples:)` can
    /// remove the actual file the store reads from instead of guessing
    /// at a hardcoded path. Tests rely on this for isolation.
    let fileURL: URL
    private var tailOffset: UInt64 = 0
    private var loadInFlight: Bool = false
    private let ioQueue = DispatchQueue(
        label: "com.momoraul.lupen.ratelimit-store",
        qos: .utility
    )

    init(fileURL: URL = StatuslinePaths.sampleStoreFile) {
        self.fileURL = fileURL
    }

    /// Read everything that's been appended since the last call. Safe to
    /// call from the main actor — file work happens on the io queue and
    /// the main actor only mutates `samples` at the end.
    ///
    /// **Reentrancy guard**: if a prior `loadIncrementally()` is still
    /// in flight (e.g. the user opened Reports and Preferences in quick
    /// succession), subsequent calls return immediately rather than
    /// reading the same range twice. Earlier versions could double-
    /// ingest because two `await` callers would each capture the same
    /// `tailOffset` value before either completed.
    func loadIncrementally() async {
        if loadInFlight { return }
        loadInFlight = true
        defer { loadInFlight = false }

        let result: (lines: [Data], newOffset: UInt64) = await withCheckedContinuation { cont in
            ioQueue.async { [fileURL, tailOffset] in
                cont.resume(returning: Self.readNewLines(
                    from: fileURL,
                    startingAt: tailOffset
                ))
            }
        }
        var decoded: [RateLimitSample] = []
        decoded.reserveCapacity(result.lines.count)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in result.lines {
            guard !line.isEmpty,
                  let sample = try? decoder.decode(RateLimitSample.self, from: line)
            else { continue }
            decoded.append(sample)
        }
        samples.append(contentsOf: decoded)
        lifetimeAppendCount += decoded.count
        tailOffset = result.newOffset
    }

    /// Drop the in-memory cache and reset the read offset. Used by tests
    /// and when the user's "Clear collected samples" toggle in
    /// Disconnect runs (the file delete is the caller's responsibility).
    func reset() {
        samples.removeAll(keepingCapacity: false)
        tailOffset = 0
    }

    /// Rewrite the on-disk log dropping every sample older than
    /// `retentionDays`. Returns the count of dropped lines so callers
    /// can log/telemetry it. Safe to call from the main actor; performs
    /// the rewrite on the io queue.
    ///
    /// **Race-free post-state**: returns both the number of dropped
    /// lines AND the new file size as a single tuple from one
    /// continuation, so the main-actor `tailOffset` reassignment
    /// happens synchronously after the await. Earlier versions
    /// scheduled a separate `Task` to set `tailOffset` which raced
    /// with concurrent `loadIncrementally()` callers.
    @discardableResult
    func runRetentionSweep(now: Date = Date()) async -> Int {
        let cutoff = now.addingTimeInterval(
            -TimeInterval(Self.retentionDays * 86_400)
        )
        let result: (dropped: Int, newSize: UInt64) = await withCheckedContinuation { cont in
            ioQueue.async { [fileURL] in
                let dropped = Self.rewriteDroppingOlderThan(
                    cutoff: cutoff, fileURL: fileURL
                )
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = (attrs?[.size] as? UInt64) ?? 0
                cont.resume(returning: (dropped, size))
            }
        }
        if result.dropped > 0 {
            // Trim the in-memory cache locally — cheaper than re-reading
            // the trimmed file from scratch.
            samples.removeAll { $0.ts < cutoff }
            // The kept lines are already in `samples`. Anchor the tail
            // offset to the new file size so the next
            // `loadIncrementally()` starts at end-of-file. Synchronous
            // assignment on the main actor — no Task indirection.
            tailOffset = result.newSize
        }
        return result.dropped
    }

    // MARK: - Private (off-thread)

    /// Read every newline-terminated line from `fileURL` whose offset is
    /// ≥ `startingAt`. Returns the line slices (without trailing `\n`)
    /// and the new tail offset. Tolerates a partial last line by
    /// stopping at the last `\n` — the leftover bytes will be picked up
    /// next call once the writer flushes them.
    nonisolated static func readNewLines(
        from fileURL: URL,
        startingAt offset: UInt64
    ) -> (lines: [Data], newOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return ([], offset)
        }
        defer { try? handle.close() }

        let total: UInt64
        do {
            total = try handle.seekToEnd()
        } catch {
            return ([], offset)
        }
        guard total > offset else { return ([], offset) }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return ([], offset)
        }
        let length = Int(total - offset)
        guard let chunk = try? handle.read(upToCount: length) else {
            return ([], offset)
        }

        // Slice on `\n`. If the buffer doesn't end with a newline, treat
        // the trailing partial line as not yet committed and rewind the
        // offset so the next call sees it again.
        var lines: [Data] = []
        var lastNewlineIdx: Int? = nil
        var lineStart = 0
        for (idx, byte) in chunk.enumerated() {
            if byte == 0x0A {  // LF
                let slice = chunk.subdata(in: lineStart..<idx)
                lines.append(slice)
                lastNewlineIdx = idx
                lineStart = idx + 1
            }
        }
        let newOffset: UInt64
        if let last = lastNewlineIdx {
            newOffset = offset + UInt64(last + 1)
        } else {
            // No newline in this chunk — treat as still-being-written,
            // don't advance. (Will retry next tick.)
            newOffset = offset
        }
        return (lines, newOffset)
    }

    /// Rewrites `fileURL` keeping only lines whose `ts` ≥ `cutoff`.
    /// Returns the count of dropped lines. No-op (returns 0) if the file
    /// doesn't exist or every line is in-window.
    nonisolated static func rewriteDroppingOlderThan(
        cutoff: Date,
        fileURL: URL
    ) -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        guard let bytes = try? Data(contentsOf: fileURL) else { return 0 }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var keep = Data()
        var dropped = 0
        var idx = 0
        let count = bytes.count
        while idx < count {
            // Find next \n
            var end = idx
            while end < count, bytes[end] != 0x0A { end += 1 }
            let lineRange = idx..<end
            if !lineRange.isEmpty {
                let line = bytes.subdata(in: lineRange)
                if let sample = try? decoder.decode(RateLimitSample.self, from: line) {
                    if sample.ts >= cutoff {
                        keep.append(line)
                        keep.append(0x0A)
                    } else {
                        dropped += 1
                    }
                } else {
                    // Malformed line — keep it so we don't silently
                    // delete data we couldn't parse. (The reader skips
                    // it; a future Lupen version may recognise the
                    // shape.)
                    keep.append(line)
                    keep.append(0x0A)
                }
            }
            idx = end + 1
        }

        guard dropped > 0 else { return 0 }

        // Atomic rewrite: write to .tmp, rename over original. SnapshotStore
        // sweeps `.dat.nosync*` leftovers; we mirror that name-prefix so
        // the same sweep covers our temps if a crash leaves them behind.
        let tmpURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("ratelimit-samples.jsonl.dat.nosync.tmp")
        do {
            try keep.write(to: tmpURL, options: .atomic)
            // POSIX rename is atomic on the same volume — destination
            // either is the old file or the new file at any instant.
            _ = try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tmpURL, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return 0
        }
        return dropped
    }
}
