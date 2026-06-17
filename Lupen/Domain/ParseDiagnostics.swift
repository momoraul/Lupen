import Foundation
import Observation

/// Aggregates JSONL parse rejections so the app can surface format
/// breakage (Claude Code updates, unknown entry types, malformed lines)
/// instead of silently dropping data.
///
/// - Counters track every rejection category (including silent drops)
///   for future analytics; hot-path counter bumps are cheap.
/// - Recent samples are kept only for `.warning` and `.error` severity.
///   Ring-buffer capped at `maxSamples` to bound memory.
/// - `hasErrors` / `hasWarnings` drive status-bar badge visibility.
///
/// Thread model: follows the `AppStateStore` convention — all mutations
/// must happen on the main thread. Worker threads accumulate rejections
/// into per-file `ParseDiagnosticsBatch` structs (Sendable value type)
/// and hand them off via `apply(_:)` during Phase B of the parse
/// pipeline, which runs on the calling (main) thread after
/// `DispatchQueue.concurrentPerform` returns.
///
/// Declared `@unchecked Sendable` to match the store's compromise: the
/// compiler doesn't statically verify isolation, but the runtime
/// convention is single-threaded access.
@Observable
final class ParseDiagnostics: @unchecked Sendable {

    struct Snapshot: Sendable {
        let counts: [String: Int]
        let errorCount: Int
        let warningCount: Int
        let recentSamples: [Sample]
        let firstIssueAt: Date?

        static let empty = Snapshot(
            counts: [:],
            errorCount: 0,
            warningCount: 0,
            recentSamples: [],
            firstIssueAt: nil
        )
    }

    // MARK: - Sample

    /// A captured rejection with enough context to reproduce.
    struct Sample: Identifiable, Sendable {
        let id: UUID
        let at: Date
        let fileURL: URL?
        let byteOffset: Int?
        let rejection: DecodeRejection
        /// First 200 chars of the raw JSONL line (UTF-8 best-effort decode).
        /// Intentionally small — diagnostics surface, not forensic archive.
        let preview: String

        init(
            id: UUID = UUID(),
            at: Date = Date(),
            fileURL: URL?,
            byteOffset: Int?,
            rejection: DecodeRejection,
            preview: String
        ) {
            self.id = id
            self.at = at
            self.fileURL = fileURL
            self.byteOffset = byteOffset
            self.rejection = rejection
            self.preview = preview
        }
    }

    // MARK: - Configuration

    /// Max samples retained in the ring buffer. Older samples drop off.
    static let maxSamples = 20

    /// Max preview length (characters). Keeps memory and UI bounded.
    static let previewCharLimit = 200

    // MARK: - Observable state

    /// Rejection counts keyed by `DecodeRejection.categoryKey`. Includes
    /// silent-info drops — useful for "last session: 12,340 filter drops,
    /// 0 errors" health reporting.
    private(set) var counts: [String: Int] = [:]

    /// Total `.error` severity rejections seen this session.
    private(set) var errorCount: Int = 0

    /// Total `.warning` severity rejections seen this session.
    private(set) var warningCount: Int = 0

    /// Ring buffer of recent error/warning samples (newest last).
    private(set) var recentSamples: [Sample] = []

    /// Timestamp of the first error/warning this session, nil if clean.
    private(set) var firstIssueAt: Date?

    // MARK: - Derived

    var hasErrors: Bool { errorCount > 0 }
    var hasWarnings: Bool { warningCount > 0 }
    var hasAnyIssues: Bool { hasErrors || hasWarnings }

    // MARK: - Init

    init() {}

    // MARK: - Recording

    /// Record a single rejection. Callers should prefer `apply(_:)` when
    /// draining a per-file batch to avoid many small main-actor hops.
    func record(
        _ rejection: DecodeRejection,
        fileURL: URL? = nil,
        byteOffset: Int? = nil,
        raw: Data? = nil
    ) {
        counts[rejection.categoryKey, default: 0] += 1

        switch rejection.severity {
        case .info:
            return  // silent — count only
        case .warning:
            warningCount += 1
        case .error:
            errorCount += 1
        }

        if firstIssueAt == nil {
            firstIssueAt = Date()
        }

        // Routed through LoggerService so the in-app Logs window picks
        // up parse rejections alongside Console.app's
        // `subsystem:com.momoraul.lupen category:ParseDiagnostics` filter.
        // `record(...)` is contractually called from main thread (see
        // class header), so `LoggerService.shared.{warning,error}`
        // works directly — no thread-bridge required.
        let fileName = fileURL?.lastPathComponent ?? "<unknown>"
        let offsetStr = byteOffset.map { "@\($0)" } ?? ""
        // ParseDiagnostics is `@unchecked Sendable` and `record(...)`
        // is callable from worker threads in principle even though
        // the runtime convention is main-thread only. Use the
        // thread-bridge entry point so we don't pin a MainActor
        // requirement here.
        switch rejection.severity {
        case .error:
            LoggerService.shared.logFromAnyThread(
                .error,
                "\(fileName)\(offsetStr): \(rejection.humanDescription)",
                context: "ParseDiagnostics"
            )
        case .warning:
            LoggerService.shared.logFromAnyThread(
                .warning,
                "\(fileName)\(offsetStr): \(rejection.humanDescription)",
                context: "ParseDiagnostics"
            )
        case .info:
            break
        }

        // Keep a sample (only for surfaced severities).
        let preview = Self.buildPreview(from: raw)
        let sample = Sample(
            fileURL: fileURL,
            byteOffset: byteOffset,
            rejection: rejection,
            preview: preview
        )
        recentSamples.append(sample)
        let overflow = recentSamples.count - Self.maxSamples
        if overflow > 0 {
            recentSamples.removeFirst(overflow)
        }
    }

    /// Drain a per-file batch accumulated on a worker thread. Preserves
    /// order within the batch; counts added atomically on main actor.
    func apply(_ batch: ParseDiagnosticsBatch) {
        for item in batch.items {
            record(
                item.rejection,
                fileURL: batch.fileURL,
                byteOffset: item.byteOffset,
                raw: item.rawPreview
            )
        }
    }

    /// Clear all state. User-initiated from Diagnostics window.
    func clear() {
        counts.removeAll()
        recentSamples.removeAll()
        errorCount = 0
        warningCount = 0
        firstIssueAt = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            counts: counts,
            errorCount: errorCount,
            warningCount: warningCount,
            recentSamples: recentSamples,
            firstIssueAt: firstIssueAt
        )
    }

    func restore(_ snapshot: Snapshot) {
        counts = snapshot.counts
        errorCount = snapshot.errorCount
        warningCount = snapshot.warningCount
        recentSamples = snapshot.recentSamples
        firstIssueAt = snapshot.firstIssueAt
    }

    // MARK: - Helpers

    /// Trims raw bytes to the preview char limit and returns a
    /// UTF-8 best-effort decoded String.
    static func buildPreview(from raw: Data?) -> String {
        guard let raw else { return "" }
        let prefixData = raw.prefix(previewCharLimit * 4)  // UTF-8 up to 4 bytes/char
        let s = String(decoding: prefixData, as: UTF8.self)
        if s.count <= previewCharLimit { return s }
        return String(s.prefix(previewCharLimit)) + "…"
    }
}

// MARK: - Batch collector (Sendable, no main-actor requirement)

/// Thread-safe container populated by decoder workers and drained by
/// `ParseDiagnostics.apply(_:)` on the main actor. One batch per file
/// per parse pass.
struct ParseDiagnosticsBatch: Sendable, Equatable, Codable {

    /// A single rejection accumulated on a worker thread.
    struct Item: Sendable, Equatable, Codable {
        let rejection: DecodeRejection
        let byteOffset: Int?
        /// Small (≤ 800 bytes) preview of the original JSONL line so the
        /// main actor can re-decode the text without the full `Data`.
        let rawPreview: Data?
    }

    /// File the batch belongs to. nil for non-file contexts (tests, streams).
    let fileURL: URL?

    /// Accumulated rejections in ingestion order.
    var items: [Item]

    init(fileURL: URL?, items: [Item] = []) {
        self.fileURL = fileURL
        self.items = items
    }

    /// Append a rejection. Free to call from any thread — `self` is a
    /// value type and the caller owns its copy.
    mutating func append(
        _ rejection: DecodeRejection,
        byteOffset: Int? = nil,
        raw: Data? = nil
    ) {
        let previewBytes = raw.map { $0.prefix(800) }.map { Data($0) }
        items.append(Item(
            rejection: rejection,
            byteOffset: byteOffset,
            rawPreview: previewBytes
        ))
    }
}
