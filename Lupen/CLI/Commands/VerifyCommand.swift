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
        abstract: "Recompute costs from the logs and flag any drift (exit 4 on mismatch).",
        discussion: """
            Audits the whole corpus, so --since/--until/--last/--month are ignored. \
            Exit codes: 0 = clean, 4 = drift, 3 = no logs found. Full session ids \
            are in --json / --csv.
            """
    )

    @OptionGroup var options: CLIGlobalOptions

    func run() throws {
        let engine = try CLIEngine.open(source: options.resolvedSource, refresh: options.refresh)
        if let note = engine.freshnessNote() { CLIOutput.note(note) }
        if options.periodLabel != "all time" {
            CLIOutput.note("verify audits all sessions; period filters are ignored.")
        }

        let verifier: any ProviderUsageVerifier = options.provider == .claudeCode
            ? ClaudeUsageVerifier()
            : CodexUsageVerifier()
        // Discover the truth file set from disk (independent of the index),
        // so an on-disk session the index missed surfaces as a divergence
        // rather than hiding.
        let files: [URL]
        switch options.provider {
        case .claudeCode:
            files = FileDiscovery().discoverJSONLFiles(in: FileDiscovery().projectsDirectory).map(\.url)
        case .codex:
            files = CodexSessionDiscovery().discoverRolloutFiles()
        }
        CLIOutput.note("Recomputing costs from \(files.count) file(s)…")

        let report = verifier.computeReport(files: files)
        let verification = verifier.verify(report: report, againstSQLite: engine.store)

        let verifyReport = CLIVerifyReport(
            provider: options.provider,
            verifiedSessionCount: report.perSession.count,
            rows: CLIVerifyReport.build(divergences: verification.divergences),
            pendingCount: verification.pendingSessionIds.count,
            issueCount: report.issues.count
        )

        if options.json {
            try CLIOutput.printJSON(verifyReport.jsonObject)
        } else if options.csv {
            CLIOutput.line(verifyReport.csv)
        } else {
            verifyReport.printReport(color: CLIStyle.useColor(disabled: options.noColor))
        }

        // No logs found is NOT a clean pass — a misconfigured CI runner
        // (wrong HOME, unmounted volume) would otherwise gate green on an
        // empty audit. Distinct exit 3 lets the gate fail loudly.
        if files.isEmpty {
            throw ExitCode(3)
        }
        if verifyReport.hasDrift {
            throw ExitCode(4)
        }
    }
}

/// Data + rendering for `lupen verify`.
struct CLIVerifyReport {
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

    let provider: ProviderKind
    let verifiedSessionCount: Int
    /// Diverging sessions (error and warning severities both).
    let rows: [Row]
    let pendingCount: Int
    let issueCount: Int

    /// Sessions with real accounting drift — what the table and exit code key on.
    var errorRows: [Row] { rows.filter(\.hasError) }
    /// Sessions whose only findings are warnings (unknown pricing / zero-usage).
    var warningOnlyRows: [Row] { rows.filter { !$0.hasError } }

    /// Exit-4 gate: only error-severity drift fails the build. Warnings
    /// (estimation limits) are reported but do not break CI.
    var hasDrift: Bool { !errorRows.isEmpty }

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
        CLIOutput.line()

        if errorRows.isEmpty {
            if verifiedSessionCount == 0 {
                CLIOutput.line("No sessions found to verify.")
            } else {
                CLIOutput.line("✓ \(verifiedSessionCount) session(s) verified — indexed costs match the recomputed truth.")
            }
        } else {
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
            CLIOutput.line("✗ \(errorRows.count) of \(verifiedSessionCount) session(s) diverge from the recomputed truth.")
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
            "verifiedSessions": verifiedSessionCount,
            "drift": hasDrift,
            "errorSessions": errorRows.count,
            "warningSessions": warningOnlyRows.count,
            "pending": pendingCount,
            "issues": issueCount,
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
}
