//
//  CostConfidence.swift
//  Lupen
//
//  Created by jaden on 2026-05-26.
//

import Foundation

enum CostConfidence: String, Codable, Equatable, Sendable {
    case notBillable
    case exact
    case partial
    case unavailable

    static func evaluate(provider: ProviderKind, steps: [Step]) -> CostConfidence {
        guard provider == .codex else { return .exact }

        let billable = steps.filter { $0.tokens != nil }
        guard !billable.isEmpty else { return .notBillable }

        let unavailableCount = billable.reduce(into: 0) { count, step in
            if isPricingUnavailable(model: step.model, cost: step.cost) {
                count += 1
            }
        }
        if unavailableCount == 0 { return .exact }
        if unavailableCount == billable.count { return .unavailable }
        return .partial
    }

    static func evaluate(
        provider: ProviderKind,
        requests: [ParsedRequest],
        costsByRequestId: [String: CostBreakdown?]
    ) -> CostConfidence {
        guard provider == .codex else { return .exact }
        guard !requests.isEmpty else { return .notBillable }

        let unavailableCount = requests.reduce(into: 0) { count, request in
            let cost: CostBreakdown? = {
                guard let mapped = costsByRequestId[request.id] else { return nil }
                return mapped
            }()
            if isPricingUnavailable(model: request.model, cost: cost) {
                count += 1
            }
        }
        if unavailableCount == 0 { return .exact }
        if unavailableCount == requests.count { return .unavailable }
        return .partial
    }

    /// Session-level confidence from SQL tallies (plan 5.3 sidebar):
    /// same ladder as the request-array evaluation above, computed from
    /// the per-request `cost_confidence` counts the index stores.
    static func evaluate(
        provider: ProviderKind,
        billableRequestCount: Int,
        unavailableRequestCount: Int
    ) -> CostConfidence {
        guard provider == .codex else { return .exact }
        guard billableRequestCount > 0 else { return .notBillable }
        if unavailableRequestCount == 0 { return .exact }
        if unavailableRequestCount >= billableRequestCount { return .unavailable }
        return .partial
    }

    /// Per-request confidence for finalized SQLite rows (plan 2.6).
    /// Same vocabulary as the session-level evaluations above, applied
    /// to a single request's (model, computed cost) pair.
    static func perRequest(model: String?, cost: CostBreakdown?) -> CostConfidence {
        guard let model else { return .unavailable }
        if PricingTable.isSyntheticModel(model) { return .notBillable }
        guard PricingTable.rates(for: model) != nil else { return .unavailable }
        return cost == nil ? .unavailable : .exact
    }

    private static func isPricingUnavailable(model: String?, cost: CostBreakdown?) -> Bool {
        guard let model else { return true }
        if PricingTable.isSyntheticModel(model) { return false }
        guard PricingTable.rates(for: model) != nil else { return true }
        return cost == nil
    }
}
