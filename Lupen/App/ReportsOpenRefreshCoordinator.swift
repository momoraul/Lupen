//
//  ReportsOpenRefreshCoordinator.swift
//  Lupen
//
//  Created by jaden on 2026/06/07.
//

import Foundation

@MainActor
struct ReportsOpenRefreshCoordinator {
    let launchDiagnosticsConfig: LaunchDiagnosticsConfig
    let loadIncrementally: () async -> Void
    let refreshState: () -> Void
    let syncSamplePrefsFromStore: () -> Void
    let recordSkippedCheckpoint: () -> Void

    func refreshIfNeeded() async {
        if launchDiagnosticsConfig.reportsRefreshDisabled {
            recordSkippedCheckpoint()
            return
        }

        await loadIncrementally()
        refreshState()
        syncSamplePrefsFromStore()
    }
}
