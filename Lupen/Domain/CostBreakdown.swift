import Foundation

struct CostBreakdown: Sendable, Codable, Equatable {
    let inputCostUSD: Double
    let outputCostUSD: Double
    let cacheCreate1hCostUSD: Double
    let cacheCreate5mCostUSD: Double
    let cacheReadCostUSD: Double

    var totalCostUSD: Double {
        inputCostUSD + outputCostUSD + cacheCreate1hCostUSD + cacheCreate5mCostUSD + cacheReadCostUSD
    }
}
