import Foundation

/// One observation of Claude Code's per-account 5-hour / 7-day rate-limit
/// usage, captured the moment Claude Code pushed a JSON payload to the
/// configured statusline command. Persisted to
/// `~/.claude/lupen/ratelimit-samples.jsonl` as one line per sample so the
/// main app can tail-read the file with the same FSEvents pattern that
/// drives JSONL parsing.
///
/// The payload Claude Code sends contains the full session/transcript
/// context, but we deliberately extract only `rate_limits`, `session_id`,
/// and the capture time — keeping transcript text out of Lupen's persisted
/// state. Plan §8 / privacy.
///
/// Fields decode through `decodeIfPresent` so a future Claude Code version
/// that drops or renames a sub-field doesn't poison the entire history;
/// the unknown field surfaces as `nil` and the rest of the sample is
/// usable.
struct RateLimitSample: Codable, Sendable, Equatable {

    /// Wall-clock instant the helper observed the push. ISO-8601
    /// fractional seconds in the on-disk JSONL.
    let ts: Date

    /// Claude Code session id from the payload. Used to correlate samples
    /// with conversation entries during aggregation; not strictly required
    /// for time-series math.
    let sessionId: String

    /// 5-hour rolling-window state. `nil` for API-key users (the field
    /// only appears for Pro/Max subscribers after the first API response
    /// in the session — see Claude Code statusline docs).
    let fiveHour: WindowState?

    /// 7-day rolling-window state. Captured but not yet surfaced in v1
    /// UI; collected so we can light it up later without a snapshot bump.
    let sevenDay: WindowState?

    struct WindowState: Codable, Sendable, Equatable {
        /// 0…100 (Anthropic docs say "0-100"; treated as Double to defend
        /// against future fractional values).
        let usedPercentage: Double
        /// When this window resets. Used to detect resets so the
        /// aggregator skips Δlimit pairs that straddle the boundary.
        let resetsAt: Date
    }
}
