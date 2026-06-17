//
//  ProviderCapabilities.swift
//  Lupen
//
//  Created by jaden on 2026/05/28.
//

import Foundation

struct ProviderCapabilities: Codable, Equatable, Sendable {
    var supportsRealtimeSync: Bool
    var supportsCostEstimates: Bool
    var supportsUsageVerification: Bool
    var supportsRawPayloadLookup: Bool
    var supportsSessionActions: Bool

    static let claudeCode = ProviderCapabilities(
        supportsRealtimeSync: true,
        supportsCostEstimates: true,
        supportsUsageVerification: true,
        supportsRawPayloadLookup: true,
        supportsSessionActions: true
    )

    static let codex = ProviderCapabilities(
        supportsRealtimeSync: true,
        supportsCostEstimates: true,
        supportsUsageVerification: true,
        supportsRawPayloadLookup: true,
        supportsSessionActions: false
    )

    static let generic = ProviderCapabilities(
        supportsRealtimeSync: false,
        supportsCostEstimates: false,
        supportsUsageVerification: false,
        supportsRawPayloadLookup: false,
        supportsSessionActions: false
    )
}
