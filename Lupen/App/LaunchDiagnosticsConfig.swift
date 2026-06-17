//
//  LaunchDiagnosticsConfig.swift
//  Lupen
//
//  Created by jaden on 2026/06/07.
//

import Foundation

struct LaunchDiagnosticsConfig: Equatable, Sendable {
    let memoryCheckpointsEnabled: Bool
    let dashboardAutoSelectDisabled: Bool
    let reportsRefreshDisabled: Bool

    static let disabled = LaunchDiagnosticsConfig(
        memoryCheckpointsEnabled: false,
        dashboardAutoSelectDisabled: false,
        reportsRefreshDisabled: false
    )

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> LaunchDiagnosticsConfig {
        LaunchDiagnosticsConfig(
            memoryCheckpointsEnabled: flag(
                environmentKey: "LUPEN_MEMORY_CHECKPOINTS",
                argument: "--lupen-memory-checkpoints",
                environment: environment,
                arguments: arguments
            ),
            dashboardAutoSelectDisabled: flag(
                environmentKey: "LUPEN_DISABLE_DASHBOARD_AUTO_SELECT",
                argument: "--lupen-disable-dashboard-auto-select",
                environment: environment,
                arguments: arguments
            ),
            reportsRefreshDisabled: flag(
                environmentKey: "LUPEN_DISABLE_REPORTS_REFRESH",
                argument: "--lupen-disable-reports-refresh",
                environment: environment,
                arguments: arguments
            )
        )
    }

    private static func flag(
        environmentKey: String,
        argument: String,
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        if arguments.contains(argument) {
            return true
        }
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }
}
