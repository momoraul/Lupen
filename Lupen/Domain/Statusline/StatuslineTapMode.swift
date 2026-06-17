import Foundation
import Darwin

/// Headless "statusline tap" mode for the Lupen binary. Activated when the
/// process is invoked with `--statusline-tap` as the first argument
/// (typically by `~/.claude/lupen-statusline-tap.sh`, which Claude Code
/// runs as its `statusLine.command`).
///
/// The mode reads the JSON payload Claude Code pushes on stdin, persists
/// the `rate_limits` slice as a sample line in
/// `~/.claude/lupen/ratelimit-samples.jsonl`, and either forwards the JSON
/// to a chained user statusline (`LUPEN_NEXT_STATUSLINE` env var) or exits
/// with empty stdout.
///
/// Stability principles (research-statusline-tap.md §5):
///   * **Sample loss << statusline broken** — every parse / write failure
///     is silent. The user's statusline must keep working even if our
///     tap fails.
///   * **POSIX `O_APPEND` atomicity** for cross-process line safety
///     (multiple Claude Code instances pushing concurrently).
///   * **Early-exit before AppKit init** so the spawn cost stays below
///     a few hundred milliseconds (linker work only).
enum StatuslineTapMode {

    /// argv flag that triggers tap mode. Public so the launcher in
    /// `main.swift` can refer to the same constant the wrapper script
    /// installs.
    static let argvFlag = "--statusline-tap"

    /// Entry point. Call from `main.swift` *before* any AppKit work if
    /// `CommandLine.arguments[1] == argvFlag`. Never returns — `exit(_:)`
    /// at the end.
    static func runAndExit() -> Never {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()

        // 1) Try to extract a sample. Failures are silent.
        if let sample = SampleExtractor.extract(from: stdinData, now: Date()) {
            SampleAppender.tryAppend(
                sample,
                to: StatuslinePaths.sampleStoreFile,
                lastPushedURL: StatuslinePaths.lastPushedFile
            )
        }

        // 2) Forward to chained statusline if configured.
        if let chain = ProcessInfo.processInfo.environment["LUPEN_NEXT_STATUSLINE"],
           !chain.trimmingCharacters(in: .whitespaces).isEmpty {
            forwardToChain(command: chain, stdin: stdinData)
        }
        // No chain → empty stdout → Claude Code shows nothing.
        exit(0)
    }

    private static func forwardToChain(command: String, stdin: Data) -> Never {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]

        let stdinPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = FileHandle.standardOutput
        task.standardError = FileHandle.standardError

        do {
            try task.run()
            // Forward SIGTERM / SIGINT to the child so a Claude Code
            // cancellation (which SIGTERMs the helper when a new
            // statusline trigger arrives mid-flight) doesn't leave the
            // user's chained statusline as a zombie. Without this, the
            // child becomes parent-init-reparented and may write to a
            // closed stdout. Static reference because `signal(2)` only
            // accepts a C function pointer.
            ChainSignalForwarder.beginForwarding(toPID: task.processIdentifier)

            // stdinPipe.fileHandleForWriting.write(_:) can throw on broken
            // pipes if the child exits before consuming input — defensive
            // try? keeps us from crashing the helper. Chain output, if
            // any, has already been wired to our stdout.
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? stdinPipe.fileHandleForWriting.close()
            task.waitUntilExit()
            exit(task.terminationStatus)
        } catch {
            // Chain command not found / not executable → behave as
            // chain-less: empty stdout, exit clean. The sample we
            // appended above survives regardless.
            exit(0)
        }
    }
}

// MARK: - Chain signal forwarder

/// Bridges Unix signal handlers (which take C function pointers) to
/// the per-invocation chain child PID. The helper is a one-shot
/// process so we only ever track a single child at a time; a global
/// is the simplest workable approach. The C signal handler reads the
/// PID with a single load — async-signal-safe even without atomics
/// (pid_t is one word; the only writer is the main flow before the
/// signal can fire).
private enum ChainSignalForwarder {
    /// PID of the chain child, set once before the helper waits on it.
    /// Stored in a static so the C callback can reach it. The helper
    /// is single-threaded outside `Process.run()`'s waitloop, so a
    /// `nonisolated(unsafe)` Int satisfies Swift 6 strict concurrency
    /// while remaining async-signal-safe at the OS level.
    nonisolated(unsafe) static var trackedPID: pid_t = 0

    static func beginForwarding(toPID pid: pid_t) {
        trackedPID = pid
        let handler: @convention(c) (Int32) -> Void = { sig in
            let p = ChainSignalForwarder.trackedPID
            if p > 0 {
                _ = kill(p, sig)
            }
            // This helper is a one-shot process. Exiting directly avoids
            // relying on Swift/Foundation state from inside a Unix signal
            // callback, and prevents parent tests from hanging in
            // waitUntilExit if re-raising stalls under XCTest injection.
            _exit(128 + sig)
        }
        signal(SIGTERM, handler)
        signal(SIGINT, handler)
    }
}

// MARK: - Sample extraction

/// Pulls the `rate_limits` / `session_id` / `ts` slice out of a Claude
/// Code statusline JSON payload. Lenient: every step uses
/// `decodeIfPresent`-equivalent guards and returns `nil` rather than
/// throwing on shape changes.
enum SampleExtractor {

    /// Hard cap on the persisted `sessionId` length. Bounds the worst-
    /// case JSONL line size so a hostile / unusual payload can't push a
    /// single append past macOS `PIPE_BUF` (512 bytes), which would
    /// break `O_APPEND` atomicity for concurrent helper invocations.
    /// Claude Code's actual session_id is a UUID (~36 chars); 128 keeps
    /// plenty of headroom while staying well under the limit.
    static let sessionIdCap = 128

    static func extract(from data: Data, now: Date) -> RateLimitSample? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rateLimits = json["rate_limits"] as? [String: Any]
        let rawSessionId = (json["session_id"] as? String) ?? ""
        let sessionId: String
        if rawSessionId.count <= sessionIdCap {
            sessionId = rawSessionId
        } else {
            sessionId = String(rawSessionId.prefix(sessionIdCap))
        }

        let fiveHour = rateLimits.flatMap { parseWindow($0["five_hour"]) }
        let sevenDay = rateLimits.flatMap { parseWindow($0["seven_day"]) }

        // We persist even when both windows are absent so the analyser
        // can later quantify "how often does Claude Code push without
        // rate-limit data" (helps debug Pro/Max gating).
        return RateLimitSample(
            ts: now,
            sessionId: sessionId,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    private static func parseWindow(_ raw: Any?) -> RateLimitSample.WindowState? {
        guard let dict = raw as? [String: Any] else { return nil }
        // Anthropic doc says 0-100 integer but we accept Double so a
        // future precision bump doesn't break ingestion.
        let used: Double?
        if let d = dict["used_percentage"] as? Double {
            used = d
        } else if let i = dict["used_percentage"] as? Int {
            used = Double(i)
        } else {
            used = nil
        }
        let reset: Date?
        if let t = dict["resets_at"] as? Double {
            reset = Date(timeIntervalSince1970: t)
        } else if let t = dict["resets_at"] as? Int {
            reset = Date(timeIntervalSince1970: TimeInterval(t))
        } else {
            reset = nil
        }
        guard let used, let reset else { return nil }
        // Snap to 4 decimal places to kill IEEE-754 jitter that
        // upstream emits (e.g., `7.000000000000001` instead of `7.0`,
        // `28.999999999999996` instead of `29.0`). Without this,
        // strict-equality dedup/collapse misses near-duplicates and
        // the aggregator builds pairs with Δlimit ≈ 1e-15 → R → 0 →
        // displayed `1/R` blows up to infinity, polluting percentiles
        // and the Bayesian-shrinkage anchor. 4 decimal places preserve
        // any sub-percent precision Anthropic might add later (0.01%
        // resolution = 1 part in 10⁶ of the 5h window).
        return RateLimitSample.WindowState(
            usedPercentage: snappedPercent(used),
            resetsAt: reset
        )
    }

    /// Round to 4 decimal places. Pure helper exposed for testability.
    static func snappedPercent(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}

// MARK: - Sample append (POSIX atomic + write-time dedup)

/// Appends a sample as a single JSON line to the store file. Uses POSIX
/// `O_APPEND` so concurrent helper instances (multiple Claude Code
/// sessions) don't interleave bytes within a line — guaranteed atomic
/// for writes ≤ `PIPE_BUF` (≥ 512 bytes per POSIX, 4 KB+ on macOS), and
/// our lines are ~200 bytes.
///
/// **Dedup**: ~83% of statusline pushes carry no rate_limits change
/// (Claude Code triggers on every assistant message + permission-mode
/// change, but the cap accounting only ticks when work is actually
/// done). The appender reads a tiny `last-pushed.json` sidecar before
/// writing and skips the append when the incoming sample's rate_limits
/// block matches what's already on file. Every error path falls back
/// to always-append — sample loss is strictly worse than file bloat.
enum SampleAppender {

    /// Convenience wrapper used by tests + non-helper code paths that
    /// don't care about dedup. Defaults the sidecar URL to nil → no
    /// dedup, every call appends.
    static func tryAppend(_ sample: RateLimitSample, to fileURL: URL) {
        tryAppend(sample, to: fileURL, lastPushedURL: nil)
    }

    /// Primary entry. When `lastPushedURL` is non-nil, the appender
    /// reads the sidecar, compares its `rate_limits` snapshot to the
    /// incoming sample, and skips the JSONL append when they match.
    /// On any sidecar I/O failure we fall back to always-append so
    /// dedup is best-effort, never a correctness liability.
    static func tryAppend(
        _ sample: RateLimitSample,
        to fileURL: URL,
        lastPushedURL: URL?
    ) {
        // Ensure parent dir exists. Failures here defeat append, so we
        // silently skip — same policy as every other failure mode.
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        // Dedup + regression check. The sidecar represents the most
        // recent rate_limits state we've recorded; we skip the JSONL
        // append in two cases:
        //   (a) exact match — the new sample carries no information
        //   (b) regression within the same 5h/7d window — the new
        //       sample is from a stale-cached session view, not real
        //       consumption (real usage is monotonic until reset).
        // In both cases we leave the sidecar untouched so subsequent
        // pushes still compare against the canonical maximum.
        if let sidecar = lastPushedURL,
           let prior = LastPushedSidecar.read(from: sidecar),
           (prior.matches(sample) || prior.isRegression(sample)) {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let lineData = try? encoder.encode(sample) else { return }
        var payload = lineData
        payload.append(0x0A)  // LF

        let path = fileURL.path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // write(2) with O_APPEND guarantees the offset bump and the
        // bytes-write are atomic w.r.t. other O_APPEND writers.
        _ = payload.withUnsafeBytes { ptr -> ssize_t in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.write(fd, base, payload.count)
        }

        // After a successful append, refresh the sidecar so the next
        // helper invocation can dedup against the values we just
        // wrote. If the sidecar update fails (perms, disk full), we
        // accept that the next push will write a redundant duplicate
        // — recoverable, not a correctness break.
        if let sidecar = lastPushedURL {
            LastPushedSidecar.write(LastPushedSidecar.snapshot(of: sample), to: sidecar)
        }
    }
}

// MARK: - Last-pushed sidecar (write-time dedup)

/// Tiny on-disk marker that records the most-recently-appended sample's
/// `rate_limits` shape. Compared against incoming samples to decide
/// whether the new line carries new information. Stored as a single
/// JSON object — Codable round-trip, ~80 bytes.
struct LastPushedSidecar: Codable, Equatable, Sendable {
    let fiveHourPercentage: Double?
    let fiveHourResetsAt: Date?
    let sevenDayPercentage: Double?
    let sevenDayResetsAt: Date?

    /// Does this sidecar's snapshot match an incoming sample's
    /// rate_limits state? A match means the helper can skip the
    /// JSONL append. `sessionId` and `ts` are intentionally NOT
    /// compared — they change every push but carry no rate-limit
    /// information.
    func matches(_ sample: RateLimitSample) -> Bool {
        return fiveHourPercentage == sample.fiveHour?.usedPercentage
            && fiveHourResetsAt    == sample.fiveHour?.resetsAt
            && sevenDayPercentage  == sample.sevenDay?.usedPercentage
            && sevenDayResetsAt    == sample.sevenDay?.resetsAt
    }

    /// Should the helper skip this sample as a same-window regression?
    /// Returns true when the incoming sample's `resetsAt` is identical
    /// to what we already recorded but the `usedPercentage` is
    /// strictly lower. Real consumption is monotonic within a window,
    /// so a regression means a stale-cached view from a concurrent
    /// Claude Code session — exactly the noise the read-time
    /// `canonicalize` step was added to suppress. Filtering here
    /// keeps the JSONL itself clean and prevents the cost-attribution
    /// gap that arises when canonicalize has to mask intermediate
    /// stale samples (cost between a stale push and the next real
    /// increase would otherwise land in the wrong pair window).
    ///
    /// Either window in regression is enough — both come from the
    /// same session, so a stale view in one implies the whole sample
    /// is from a stale source.
    func isRegression(_ sample: RateLimitSample) -> Bool {
        if let inFive = sample.fiveHour,
           let cachedPct = fiveHourPercentage,
           let cachedReset = fiveHourResetsAt,
           cachedReset == inFive.resetsAt,
           inFive.usedPercentage < cachedPct {
            return true
        }
        if let inSeven = sample.sevenDay,
           let cachedPct = sevenDayPercentage,
           let cachedReset = sevenDayResetsAt,
           cachedReset == inSeven.resetsAt,
           inSeven.usedPercentage < cachedPct {
            return true
        }
        return false
    }

    static func snapshot(of sample: RateLimitSample) -> LastPushedSidecar {
        .init(
            fiveHourPercentage: sample.fiveHour?.usedPercentage,
            fiveHourResetsAt:   sample.fiveHour?.resetsAt,
            sevenDayPercentage: sample.sevenDay?.usedPercentage,
            sevenDayResetsAt:   sample.sevenDay?.resetsAt
        )
    }

    /// Read + parse the sidecar. Returns nil for any failure (missing
    /// file, malformed JSON, version skew) — the appender falls back
    /// to always-append in that case, which self-heals on the next
    /// successful write.
    static func read(from url: URL) -> LastPushedSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LastPushedSidecar.self, from: data)
    }

    /// Atomic write — `.atomic` rename pattern guards against torn
    /// reads from a concurrent helper. Failures are silent (best-
    /// effort dedup).
    static func write(_ snapshot: LastPushedSidecar, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
