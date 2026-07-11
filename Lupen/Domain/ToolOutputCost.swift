//
//  ToolOutputCost.swift
//  Lupen
//
//  Created by jaden on 2026/07/06.
//

import Foundation

/// One tool output ranked by how much it drove cost (C-25 "Top cost drivers").
/// A tool result sits in the context window and is re-read from cache every
/// subsequent turn, so its lifetime cost scales with `size × turns carried`.
struct ToolOutputCost: Sendable, Equatable, Identifiable {
    let toolName: String
    /// Short target label ("Read build.log", "Bash npm test"), if captured.
    let summary: String?
    let estTokens: Int
    /// Turns this output was carried in context (its own turn + subsequent),
    /// i.e. how many times it was re-read.
    let turnsCarried: Int
    /// Estimated lifetime carry cost — `estTokens × turnsCarried × cache-read
    /// rate`. Approximate; the *ranking* is the robust signal.
    let estCostUSD: Double
    let id: String

    /// Rate-independent ranking key (token-turns).
    var carryWeight: Int { estTokens * turnsCarried }
}

/// Pure ranker: turns raw per-output rows + per-session context into the
/// top cost-driving tool outputs. No I/O — unit-testable off `Input`.
enum ToolOutputRanker {

    struct Candidate: Sendable, Equatable {
        let sessionId: String
        let toolName: String
        let summary: String?
        let outputChars: Int
        /// Ordinal of the turn that produced this output (when it entered
        /// context).
        let turnOrdinal: Int
    }

    struct Input: Sendable, Equatable {
        let candidates: [Candidate]
        /// Last turn ordinal per session (how far the output is carried).
        let maxOrdinalBySession: [String: Int]
        /// Effective cache-read $/token per session (Σ read cost / Σ read
        /// tokens); falls back to `fallbackCacheReadRate` when a session has
        /// no cache-read tokens.
        let cacheReadRateBySession: [String: Double]
        let fallbackCacheReadRate: Double
    }

    static func rank(
        _ input: Input,
        charsPerToken: Double = ContextComposition.defaultCharsPerToken,
        limit: Int = 8
    ) -> [ToolOutputCost] {
        let cpt = charsPerToken > 0 ? charsPerToken : ContextComposition.defaultCharsPerToken
        var rows: [ToolOutputCost] = []
        for (index, candidate) in input.candidates.enumerated() {
            let estTokens = Int((Double(candidate.outputChars) / cpt).rounded())
            guard estTokens > 0 else { continue }
            let maxOrdinal = input.maxOrdinalBySession[candidate.sessionId] ?? candidate.turnOrdinal
            let turnsCarried = max(1, maxOrdinal - candidate.turnOrdinal + 1)
            let rate = input.cacheReadRateBySession[candidate.sessionId]
                .flatMap { $0 > 0 ? $0 : nil } ?? input.fallbackCacheReadRate
            let estCost = Double(estTokens) * Double(turnsCarried) * rate
            rows.append(ToolOutputCost(
                toolName: candidate.toolName,
                summary: candidate.summary,
                estTokens: estTokens,
                turnsCarried: turnsCarried,
                estCostUSD: estCost,
                id: "\(candidate.sessionId)#\(index)"
            ))
        }
        // Rank by token-turns (rate-independent so a 0-rate session still
        // sorts sensibly), tie-break on est tokens.
        return Array(
            rows.sorted {
                $0.carryWeight != $1.carryWeight
                    ? $0.carryWeight > $1.carryWeight
                    : $0.estTokens > $1.estTokens
            }.prefix(max(0, limit))
        )
    }
}
