import Foundation

/// Pure state machine that separates `/rename` (custom-title) values from
/// Claude Code's carry-forward noise.
///
/// Claude Code writes the *previous* session's custom-title at the top of a
/// new JSONL file as `{"type":"custom-title","customTitle":"<prev>", …}`
/// before any user input. Without filtering, the sidebar would show stale
/// names for sessions the user never `/rename`d.
///
/// Distinction:
///   - **baseline**: last custom-title seen *before* the first user entry —
///     treated as carry-forward and hidden from the UI.
///   - **userInitiated**: most recent value seen *after* the first user
///     entry that differs from baseline. The "differs" condition is
///     required because Claude Code periodically rewrites the same value.
///
/// Trade-off: if the user `/rename`s to a value equal to baseline,
/// `userInitiated` stays nil and the sidebar falls back to firstTurnPreview.
/// Acceptable because baseline is already the carry-forward of that same
/// name (effectively a no-op from the user's POV).
///
/// Pure function — cold parse (full file scan) and live path (incremental
/// append) both call the same `apply`. Cold path starts from default state,
/// live path resumes from the existing state.
enum CustomTitleResolver {

    /// Per-session state. Value type of `AppStateStore.customTitleStateBySessionId`.
    ///
    /// `Codable` — serialized per-session into Plan 13 `ParseSnapshot` and
    /// rehydrated on cold launch. Bump `SnapshotSchema.currentVersion`
    /// whenever fields are added/removed.
    struct State: Sendable, Equatable, Codable {
        /// Whether a `type: "user"` entry has *ever* been observed in this
        /// session. Latches to true. Boundary signal that distinguishes
        /// carry-forward from `/rename`.
        var firstUserObserved: Bool = false
        /// Last custom-title observed before the first user entry
        /// (carry-forward). Hidden from UI; used by live path to filter
        /// repeats of the same value.
        var baseline: String? = nil
        /// Final title set by the user via `/rename`. When nil, the sidebar
        /// falls back to other sources (firstTurnPreview / cachedTitle / slug).
        var userInitiated: String? = nil

        init(firstUserObserved: Bool = false, baseline: String? = nil, userInitiated: String? = nil) {
            self.firstUserObserved = firstUserObserved
            self.baseline = baseline
            self.userInitiated = userInitiated
        }

        // Explicit decode init: tolerates old snapshots missing any of the
        // three fields so forward evolution stays backward-compat until the
        // schema version is bumped (then those older snapshots are dropped
        // anyway per Plan 13 fallback rules).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.firstUserObserved = try c.decodeIfPresent(Bool.self, forKey: .firstUserObserved) ?? false
            self.baseline = try c.decodeIfPresent(String.self, forKey: .baseline)
            self.userInitiated = try c.decodeIfPresent(String.self, forKey: .userInitiated)
        }

        private enum CodingKeys: String, CodingKey {
            case firstUserObserved, baseline, userInitiated
        }
    }

    /// Applies custom-title / user-entry signals from `lines` to `state`
    /// in order and returns the new state.
    ///
    /// - `isUserEntry` pins `firstUserObserved` to true.
    /// - When `extractCustomTitle` returns a record:
    ///   - `firstUserObserved == false` → baseline updates last-wins
    ///   - `firstUserObserved == true` + value != baseline → userInitiated updates
    ///   - `firstUserObserved == true` + value == baseline → no-op (carry-forward persistence)
    static func apply(_ state: State, lines: [Data]) -> State {
        var s = state
        for line in lines {
            s = advance(s, header: RichEntryDecoder.scanHeader(line))
        }
        return s
    }

    /// Advances state by one line from an already-scanned `LineHeader`.
    /// Phase A's main loop uses this path so a single `scanHeader` per line
    /// drives parentLink / custom-title / user-entry signals together.
    /// `apply(state:, lines:)` remains a thin loop wrapper to preserve the
    /// existing caller / test interface.
    static func advance(_ state: State, header: RichEntryDecoder.LineHeader) -> State {
        var s = state
        if let record = RichEntryDecoder.customTitleRecord(from: header) {
            if s.firstUserObserved {
                if record.title != s.baseline, record.title != s.userInitiated {
                    s.userInitiated = record.title
                }
            } else {
                if s.baseline != record.title {
                    s.baseline = record.title
                }
            }
        }
        if !s.firstUserObserved, header.type == "user" {
            s.firstUserObserved = true
        }
        return s
    }
}
