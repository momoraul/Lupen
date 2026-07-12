import ArgumentParser
import Foundation

/// `lupen verify` — recompute every session's cost independently from the
/// raw logs and diff it against the indexed (reported) value, exactly like
/// the GUI's Verify Costs window. Exits non-zero (4) when anything diverges,
/// so it can gate CI / a pre-commit check. Lupen's trust differentiator:
/// ccusage/tokscale report a number; this proves it.
///
/// Audits the whole corpus — period flags don't scope an independent
/// recompute, so `--since`/`--until`/`--last`/`--month` are ignored here.
struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Recompute costs from the logs and fail on drift or an incomplete index.",
        discussion: """
            Audits the whole corpus, so --since/--until/--last/--month are ignored. \
            Exit codes: 0 = clean, 4 = drift or incomplete index, 3 = source/index \
            unavailable. Full session ids are in --json / --csv.
            """
    )

    @OptionGroup var options: CLIGlobalOptions

    func run() throws {
        // Resolve exactly once. A custom source is more specific than its
        // provider kind, so the identical value must drive both the index and
        // the independent truth scan.
        let source = options.resolvedSource
        let verifier: any ProviderUsageVerifier = source.kind == .claudeCode
            ? ClaudeUsageVerifier()
            : CodexUsageVerifier()
        do {
            try verifier.preflight(source: source)
        } catch let error as VerificationSourceError {
            try emit(sourceFailureReport(error, source: source))
            throw ExitCode(3)
        }

        // Validate the corpus before refresh so an unavailable mount cannot
        // prune its existing derived index. The full truth report is computed
        // afterwards, keeping its O(usage-lines) memory out of the importer's
        // transient working set and including files created during refresh.
        let engine: CLIEngine
        do {
            engine = try CLIEngine.open(source: source, refresh: options.refresh)
        } catch {
            try emit(indexFailureReport(source: source))
            throw ExitCode(3)
        }
        if let note = engine.freshnessNote() { CLIOutput.note(note) }
        if options.periodLabel != "all time" {
            CLIOutput.note("verify audits all sessions; period filters are ignored.")
        }

        let scan: ProviderVerificationScan
        do {
            scan = try verifier.scan(source: source)
        } catch let error as VerificationSourceError {
            try emit(sourceFailureReport(error, source: source))
            throw ExitCode(3)
        }
        CLIOutput.note("Recomputed costs from \(scan.filesScanned) file(s).")

        let verification: GroundTruthVerifier.SQLiteVerification
        do {
            verification = try verifier.verify(
                report: scan.report,
                againstSQLite: engine.store
            )
            try verifier.validateSourceUnchanged(scan: scan, source: source)
        } catch let error as VerificationSourceError {
            try emit(sourceFailureReport(
                error,
                source: source,
                filesScanned: scan.filesScanned,
                verifiedSessionCount: scan.report.perSession.count,
                issueCount: scan.report.issues.count
            ))
            throw ExitCode(3)
        } catch {
            let failed = CLIVerifyReport(
                source: scan.source,
                filesScanned: scan.filesScanned,
                verifiedSessionCount: scan.report.perSession.count,
                rows: [],
                pendingCount: 0,
                issueCount: scan.report.issues.count,
                failureDescription: "The source index could not be verified."
            )
            try emit(failed)
            throw ExitCode(3)
        }

        let verifyReport = CLIVerifyReport(
            source: scan.source,
            filesScanned: scan.filesScanned,
            verifiedSessionCount: scan.report.perSession.count,
            rows: CLIVerifyReport.build(divergences: verification.divergences),
            pendingCount: verification.pendingSessionIds.count,
            issueCount: scan.report.issues.count,
            failureDescription: nil
        )

        try emit(verifyReport)

        if verifyReport.shouldFail {
            throw ExitCode(4)
        }
    }

    private func emit(_ report: CLIVerifyReport) throws {
        // Every output mode gets source provenance on stderr. CSV stdout stays
        // byte-for-byte compatible for existing consumers.
        CLIOutput.note(report.provenanceNote)
        if options.json {
            try CLIOutput.printJSON(report.jsonObject)
        } else if options.csv {
            CLIOutput.line(report.csv)
        } else {
            report.printReport(color: CLIStyle.useColor(disabled: options.noColor))
        }
    }

    private func sourceFailureReport(
        _ error: VerificationSourceError,
        source: SessionSource,
        filesScanned: Int = 0,
        verifiedSessionCount: Int = 0,
        issueCount: Int = 0
    ) -> CLIVerifyReport {
        let failure: String?
        if case .noLogs = error {
            failure = nil
        } else {
            failure = error.localizedDescription
        }
        return CLIVerifyReport(
            source: error.source ?? VerificationSourceIdentity(source: source),
            filesScanned: filesScanned,
            verifiedSessionCount: verifiedSessionCount,
            rows: [],
            pendingCount: 0,
            issueCount: issueCount,
            failureDescription: failure
        )
    }

    private func indexFailureReport(source: SessionSource) -> CLIVerifyReport {
        CLIVerifyReport(
            source: VerificationSourceIdentity(source: source),
            filesScanned: 0,
            verifiedSessionCount: 0,
            rows: [],
            pendingCount: 0,
            issueCount: 0,
            failureDescription: "The source index could not be opened."
        )
    }
}

/// Data + rendering for `lupen verify`.
struct CLIVerifyReport {
    enum Status: String, Sendable {
        case clean
        case drift
        case incomplete
        case noLogs = "no-logs"
        case verificationFailed = "verification-failed"
    }

    struct Row: Equatable {
        let sessionId: String
        let viewCostUSD: Double?
        let truthCostUSD: Double?
        let kinds: [String]
        /// True when the session has at least one error-severity finding
        /// (cost / token / coverage drift). Warning-only rows do not gate CI.
        let hasError: Bool

        var delta: Double? {
            guard let view = viewCostUSD, let truth = truthCostUSD else { return nil }
            return view - truth
        }
    }

    let source: VerificationSourceIdentity
    let filesScanned: Int
    let verifiedSessionCount: Int
    /// Diverging sessions (error and warning severities both).
    let rows: [Row]
    let pendingCount: Int
    let issueCount: Int
    let failureDescription: String?

    var provider: ProviderKind { source.provider }

    /// Sessions with real accounting drift — what the table and exit code key on.
    var errorRows: [Row] { rows.filter(\.hasError) }
    /// Sessions whose only findings are warnings (unknown pricing / zero-usage).
    var warningOnlyRows: [Row] { rows.filter { !$0.hasError } }

    /// Sessions considered across both directions of the audit. Truth-backed
    /// sessions retain the existing verified count; index-only sessions are
    /// additive so existing JSON and CSV consumers keep their semantics.
    var auditedSessionCount: Int {
        verifiedSessionCount + rows.filter { $0.kinds.contains("missingInTruth") }.count
    }

    /// Accounting-drift flag: warnings and pending imports are represented
    /// separately and do not get mislabeled as numerical drift.
    var hasDrift: Bool { !errorRows.isEmpty }

    /// A pending import cannot prove the index is clean. It fails the command
    /// without being mislabeled as accounting drift in JSON.
    var shouldFail: Bool { hasDrift || pendingCount > 0 }

    var status: Status {
        if failureDescription != nil { return .verificationFailed }
        if filesScanned == 0 { return .noLogs }
        if hasDrift { return .drift }
        return pendingCount > 0 ? .incomplete : .clean
    }

    /// Privacy-safe one-line provenance for stderr. The raw source root is
    /// intentionally excluded; its normalized path SHA-256 is sufficient to
    /// distinguish roots without disclosing them in logs.
    var provenanceNote: String {
        "Source: \(Self.singleLine(source.name)) [\(Self.singleLine(source.id))] · "
        + "root sha256 \(source.rootHash) · \(filesScanned) file(s) · status \(status.rawValue)"
    }

    /// Group divergences by session into mismatch rows (pure: no store).
    static func build(divergences: [GroundTruthVerifier.Divergence]) -> [Row] {
        var bySession: [String: (view: Double?, truth: Double?, kinds: Set<String>, hasError: Bool)] = [:]
        for divergence in divergences {
            var entry = bySession[divergence.sessionId] ?? (nil, nil, [], false)
            entry.kinds.insert(kindLabel(divergence.kind))
            if divergence.severity == .error { entry.hasError = true }
            if case .costMismatch(let view, let truth) = divergence.kind {
                entry.view = view
                entry.truth = truth
            }
            bySession[divergence.sessionId] = entry
        }
        var rows = bySession.map { sessionId, entry in
            Row(sessionId: sessionId, viewCostUSD: entry.view, truthCostUSD: entry.truth, kinds: entry.kinds.sorted(), hasError: entry.hasError)
        }
        rows.sort { lhs, rhs in
            let lhsDelta = abs(lhs.delta ?? 0), rhsDelta = abs(rhs.delta ?? 0)
            return lhsDelta != rhsDelta ? lhsDelta > rhsDelta : lhs.sessionId < rhs.sessionId
        }
        return rows
    }

    /// Short token for a divergence kind.
    static func kindLabel(_ kind: GroundTruthVerifier.Divergence.Kind) -> String {
        switch kind {
        case .costMismatch: return "cost"
        case .inputTokenMismatch: return "input"
        case .outputTokenMismatch: return "output"
        case .reasoningOutputTokenMismatch: return "reasoning"
        case .cacheCreationInputMismatch: return "cacheCreate"
        case .cacheReadMismatch: return "cacheRead"
        case .cacheCreation1hMismatch: return "cache1h"
        case .cacheCreation5mMismatch: return "cache5m"
        case .requestCountMismatch: return "requestCount"
        case .missingPickedRequestId: return "missingRequestId"
        case .sessionMissingInView: return "missingInView"
        case .sessionMissingInTruth: return "missingInTruth"
        case .missingUsageEvent: return "missingUsage"
        case .unknownPricing: return "unknownPricing"
        case .sourceRejected: return "sourceRejected"
        case .parserRejectedLine: return "parserRejected"
        }
    }

    /// Compact MISMATCH cell: the full kind list can be 8+ tokens (a session
    /// that diverges on everything), which would blow the table past 80
    /// columns. Show the first few; the complete list stays in --json/--csv.
    static func mismatchSummary(_ kinds: [String]) -> String {
        guard kinds.count > 3 else { return kinds.joined(separator: ", ") }
        return kinds.prefix(3).joined(separator: ", ") + " +\(kinds.count - 3) more"
    }

    // MARK: - Rendering

    func printReport(color: Bool) {
        CLIOutput.line("\(provider.cliLabel) · cost verification")
        CLIOutput.line("Source: \(Self.singleLine(source.name)) [\(Self.singleLine(source.id))]")
        CLIOutput.line("Root identity: sha256:\(source.rootHash)")
        CLIOutput.line("Files scanned: \(filesScanned)")
        CLIOutput.line("Status: \(status.rawValue)")
        CLIOutput.line()

        if let failureDescription {
            CLIOutput.line("Verification failed: \(Self.singleLine(failureDescription))")
        } else if errorRows.isEmpty, pendingCount == 0 {
            if verifiedSessionCount == 0 {
                CLIOutput.line("No sessions found to verify.")
            } else {
                CLIOutput.line("✓ \(verifiedSessionCount) session(s) verified — indexed costs match the recomputed truth.")
            }
        } else if !errorRows.isEmpty {
            let table = CLITable(
                columns: [
                    .init("SESSION"),
                    .init("VIEW", align: .right),
                    .init("TRUTH", align: .right),
                    .init("Δ", align: .right),
                    .init("MISMATCH"),
                ],
                rows: errorRows.map { row in
                    [
                        CLITopReport.shortID(row.sessionId),
                        row.viewCostUSD.map(CLIFormat.money) ?? "—",
                        row.truthCostUSD.map(CLIFormat.money) ?? "—",
                        row.delta.map(CLIFormat.money) ?? "—",
                        Self.mismatchSummary(row.kinds),
                    ]
                }
            )
            CLIOutput.line(table.render(color: color))
            CLIOutput.line()
            CLIOutput.line("✗ \(errorRows.count) of \(auditedSessionCount) session(s) diverge from the recomputed truth.")
        } else {
            CLIOutput.line("Index import is incomplete; no clean verdict is available yet.")
        }

        if !warningOnlyRows.isEmpty {
            CLIOutput.note("\(warningOnlyRows.count) session(s) with warnings only (unknown pricing / zero-usage) — not counted as drift; open Verify Costs for detail.")
        }
        if pendingCount > 0 {
            CLIOutput.note("\(pendingCount) session(s) still importing — rerun after indexing settles.")
        }
        if issueCount > 0 {
            CLIOutput.note("\(issueCount) data issue(s) (unknown pricing / rejected lines) — open Verify Costs for detail.")
        }
    }

    var jsonObject: [String: Any] {
        [
            "provider": provider.rawValue,
            "status": status.rawValue,
            "source": [
                "id": source.id,
                "name": source.name,
                "rootHash": source.rootHash,
                "filesScanned": filesScanned,
            ],
            "verifiedSessions": verifiedSessionCount,
            "auditedSessions": auditedSessionCount,
            "drift": hasDrift,
            "errorSessions": errorRows.count,
            "warningSessions": warningOnlyRows.count,
            "pending": pendingCount,
            "issues": issueCount,
            "failure": failureDescription as Any? ?? NSNull(),
            "mismatches": rows.map { row in
                [
                    "sessionId": row.sessionId,
                    "severity": row.hasError ? "error" : "warning",
                    "viewCostUsd": row.viewCostUSD as Any? ?? NSNull(),
                    "truthCostUsd": row.truthCostUSD as Any? ?? NSNull(),
                    "costDelta": row.delta as Any? ?? NSNull(),
                    "kinds": row.kinds,
                ]
            },
        ]
    }

    var csv: String {
        CLICSV.render(
            header: ["sessionId", "severity", "viewCostUsd", "truthCostUsd", "costDelta", "kinds"],
            rows: rows.map { row in
                [
                    row.sessionId,
                    row.hasError ? "error" : "warning",
                    row.viewCostUSD.map { String(format: "%.6f", $0) } ?? "",
                    row.truthCostUSD.map { String(format: "%.6f", $0) } ?? "",
                    row.delta.map { String(format: "%.6f", $0) } ?? "",
                    row.kinds.joined(separator: ";"),
                ]
            }
        )
    }

    private static func singleLine(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
    }
}
