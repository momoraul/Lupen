//
//  DiagnosticsProjection.swift
//  Lupen
//
//  Created by jaden on 2026/06/11.
//

import Foundation

/// Plan 5.3c: maps the index's persisted diagnostics rows onto the
/// `ParseDiagnostics` surface the status-bar badge, dropdown counts,
/// and Diagnostics window already consume. The importers persist only
/// warning/error rows (the 2.4 contract — silent info drops stay
/// silent), so the projected counts are exactly the user-visible ones.
enum DiagnosticsProjection {

    static func snapshot(store: ProviderStore) -> ParseDiagnostics.Snapshot? {
        guard
            let severity = try? store.severityCounts(),
            let counts = try? store.diagnosticCategoryCounts(),
            let rows = try? store.recentDiagnostics(limit: ParseDiagnostics.maxSamples)
        else { return nil }

        // Ring-buffer semantics: newest LAST (the view reverses).
        let samples = rows.reversed().map { row in
            ParseDiagnostics.Sample(
                at: row.createdAt ?? Date(),
                fileURL: nil,
                byteOffset: (row.byteOffset).map(Int.init),
                rejection: rejection(category: row.category),
                preview: row.preview ?? ""
            )
        }
        return ParseDiagnostics.Snapshot(
            counts: counts,
            errorCount: severity.error,
            warningCount: severity.warning,
            recentSamples: Array(samples),
            firstIssueAt: try? store.firstDiagnosticAt()
        )
    }

    /// Rebuilds a displayable `DecodeRejection` from the persisted
    /// category key via the enum's own Codable mapping (kind raw values
    /// == category keys). Unknown/new categories degrade to
    /// `.unknownType(category)` rather than dropping the row.
    static func rejection(category: String) -> DecodeRejection {
        let payload = #"{"kind":"\#(category)","stringValue":"","intValue":0}"#
        if let decoded = try? JSONDecoder().decode(
            DecodeRejection.self, from: Data(payload.utf8)
        ) {
            return decoded
        }
        return .unknownType(category)
    }
}
