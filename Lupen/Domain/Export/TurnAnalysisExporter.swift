//
//  TurnAnalysisExporter.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import Foundation

/// One call from the UI to a finished document.
///
/// The pieces underneath stay separately testable — `TurnRawSource` does I/O,
/// `TurnRawEnricher` and `TurnAnalysisBundleBuilder` and
/// `TurnAnalysisMarkdownRenderer` are pure — and this is the seam that joins
/// them so no view controller has to know the order.
///
/// The UI keeps ownership of the save panel and the pasteboard, matching
/// `ReportsCSVExporter`.
enum TurnAnalysisExporter {

    struct Request: Sendable {
        let turn: Turn
        let provider: ProviderKind
        /// Must be the same numbers the outline row shows, so the export can
        /// never contradict the row the user acted on.
        let displayCost: CostBreakdown
        let displayTokens: TokenBreakdown
        var projectLabel: String?
        var sessionTitle: String?
        /// Wall clock for this turn, measured the same way the session baseline
        /// samples are (aggregate-preferred), so the "vs. median" ratio compares
        /// like with like. `nil` falls back to the step-timestamp span.
        var turnDurationSeconds: TimeInterval?
        var sessionSamples: [TurnAnalysisBundleBuilder.MetricSample] = []
        var skillGroups: [SkillGroupBuilder.SkillGroup] = []
        var subAgentLinks: [SubAgentLinker.Link] = []
        var subAgentCostByAgentId: [String: CostBreakdown] = [:]
        var composition: ContextComposition.Result?
        var budget: TurnExportBudget = .default

        init(
            turn: Turn,
            provider: ProviderKind,
            displayCost: CostBreakdown,
            displayTokens: TokenBreakdown
        ) {
            self.turn = turn
            self.provider = provider
            self.displayCost = displayCost
            self.displayTokens = displayTokens
        }
    }

    /// Builds the document. Performs bounded file reads (the turn's own lines
    /// plus, on Codex, a capped backward scan for `turn_context`), so callers
    /// should treat it as potentially blocking and keep it off the main thread
    /// for large turns.
    static func makeDocument(
        _ request: Request,
        options: TurnAnalysisMarkdownRenderer.Options = .init()
    ) -> String {
        let loaded = TurnRawSource.load(steps: request.turn.steps, provider: request.provider)
        // Order the lines by the turn's steps (chronological) so the enricher's
        // "last wins" fields are deterministic — `loaded.lines` is a dictionary.
        let orderedLines = request.turn.steps.compactMap { step in
            loaded.lines[step.uuid].map { (uuid: step.uuid, line: $0) }
        }
        let facts = TurnRawEnricher.enrich(
            provider: request.provider,
            rawLines: orderedLines,
            turnContextLine: loaded.turnContext,
            missingLineCount: loaded.missingCount
        )
        let bundle = TurnAnalysisBundleBuilder.build(
            TurnAnalysisBundleBuilder.Inputs(
                turn: request.turn,
                provider: request.provider,
                displayCost: request.displayCost,
                displayTokens: request.displayTokens,
                projectLabel: request.projectLabel,
                sessionTitle: request.sessionTitle,
                turnDurationSeconds: request.turnDurationSeconds,
                sessionSamples: request.sessionSamples,
                skillGroups: request.skillGroups,
                subAgentLinks: request.subAgentLinks,
                subAgentCostByAgentId: request.subAgentCostByAgentId,
                composition: request.composition,
                rawFacts: facts,
                budget: request.budget
            )
        )
        return TurnAnalysisMarkdownRenderer.render(bundle, options: options)
    }

    /// `lupen-turn-claude-code-2026-07-20-1432.md`. Fixed POSIX format so the
    /// filename sorts chronologically in Finder regardless of Region settings —
    /// the same convention `ReportsCSVExporter.suggestedFilename` uses.
    static func suggestedFilename(provider: ProviderKind, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = provider == .codex ? "codex" : "claude-code"
        return "lupen-turn-\(slug)-\(formatter.string(from: now)).md"
    }
}
