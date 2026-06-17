import SwiftUI
import AppKit

/// Settings UI for the statusline integration. Lives inside the
/// `PreferencesForm` `Form` and renders one of three layouts depending
/// on the current connection state:
///
///   * **Not connected** → big [Connect…] button + 1-line pitch.
///   * **Connected (any sub-state)** → status line, paths, chain
///     toggle, [Disconnect…] button.
///   * **Broken** → red status + [Fix…] button (which just opens the
///     Connect sheet again with current detection).
///
/// All side-effects route through the injected
/// `StatuslineConnectionService` so this view stays UI-only.
@MainActor
struct StatuslineSettingsSection: View {

    @Bindable var service: StatuslineConnectionService

    /// Single source of truth for which modal is currently presented.
    /// Earlier versions stacked two `.alert` modifiers + a `.sheet` on
    /// the same view; SwiftUI on macOS only honours one at a time and
    /// silently dropped the disconnect-confirm alert when the error
    /// alert was attached afterwards. A routing enum collapses all
    /// presentations to one `.alert` + one `.sheet`.
    private enum Modal: Identifiable {
        case confirmDisconnect
        case error(String)
        var id: String {
            switch self {
            case .confirmDisconnect: return "disconnect"
            case .error: return "error"
            }
        }
    }

    @State private var showingConnectSheet = false
    @State private var modal: Modal? = nil

    var body: some View {
        Section {
            statusLine

            switch service.state {
            case .neverConnected:
                pitchAndConnect

            case .connectedActive, .connectedAwaitingFirst, .connectedStale, .drifted:
                connectedDetails

            case .broken(let reason):
                brokenDetails(reason: reason)
            }
        } header: {
            Text("Statusline (Limit Tracking)")
        } footer: {
            Text("Lupen watches Claude Code's statusline to capture 5-hour limit usage. Without this connection, the Hours tab in Reports falls back to estimated data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingConnectSheet) {
            ConnectStatuslineSheet(service: service) { error in
                showingConnectSheet = false
                if let error { modal = .error(error) }
            }
        }
        .alert(item: $modal) { current in
            switch current {
            case .confirmDisconnect:
                return Alert(
                    title: Text("Disconnect statusline?"),
                    message: Text("Lupen will stop collecting 5-hour limit data and your Claude Code settings will be restored from backup. Collected samples are kept (delete them with Reset…)."),
                    primaryButton: .destructive(Text("Disconnect")) {
                        do {
                            try service.disconnect(deletingSamples: false)
                        } catch {
                            modal = .error("Disconnect failed: \(error.localizedDescription)")
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .error(let message):
                return Alert(
                    title: Text("Statusline error"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    // MARK: - Status line at top of section

    private var statusLine: some View {
        HStack(spacing: 6) {
            stateIndicator
            Text(service.state.shortLabel)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            // The "last sample" subtitle reads directly from the live
            // sample store, so it stays accurate even between prefs
            // persist cycles.
            if let last = service.state.lastSampleSubtitle(
                prefs: service.sampleStore.lastSampleAt
            ) {
                Text(last)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stateIndicator: some View {
        let color: Color
        switch service.state {
        case .connectedActive:        color = .green
        case .connectedAwaitingFirst: color = .yellow
        case .connectedStale:         color = .orange
        case .drifted:                color = .blue
        case .broken:                 color = .red
        case .neverConnected:         color = .secondary
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: - Layouts

    private var pitchAndConnect: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Track precise 5-hour limit usage by hour of day. Requires a one-time settings.json update.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Connect…") {
                showingConnectSheet = true
            }
            .controlSize(.regular)
        }
    }

    private var connectedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Wrapper script path — gives the user something concrete
            // to grep for when audit-paranoid.
            HStack(spacing: 4) {
                Text("Wrapper:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(StatuslinePaths.wrapperScript.path)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
            // Chain target — visible regardless of toggle so the user
            // can confirm what's being kept alive after Lupen.
            if let chain = service.detectedChainTarget {
                HStack(spacing: 4) {
                    Text("Chain:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(chain)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                Button("Disconnect…") {
                    modal = .confirmDisconnect
                }
                if case .drifted = service.state {
                    Button("Heal Drift") {
                        service.healDrift()
                    }
                }
                Button("Reconfigure…") {
                    showingConnectSheet = true
                }
            }
        }
    }

    private func brokenDetails(reason: StatuslineConnectionState.BrokenReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(brokenLabel(reason))
                .font(.system(size: 11))
                .foregroundStyle(.red)
            HStack(spacing: 8) {
                Button("Fix…") {
                    showingConnectSheet = true
                }
                Button("Disconnect Anyway", role: .destructive) {
                    modal = .confirmDisconnect
                }
            }
        }
    }

    private func brokenLabel(_ reason: StatuslineConnectionState.BrokenReason) -> String {
        switch reason {
        case .wrapperMissing:
            return "Wrapper script missing — reconnect to recreate it."
        case .wrapperUnexecutable:
            return "Wrapper script lost its executable bit — reconnect to fix."
        case .settingsNotPointingToWrapper:
            return "settings.json statusLine.command no longer points at our wrapper. If you edited it on purpose, click Disconnect Anyway."
        case .settingsFileMissing:
            return "~/.claude/settings.json is missing — reconnect to recreate it."
        case .settingsMalformed:
            return "~/.claude/settings.json is malformed — please fix the JSON manually before reconnecting."
        }
    }
}

// MARK: - State helper

extension StatuslineConnectionState {
    /// Optional caption rendered next to the short label. Returns nil
    /// for states where no time stamp is meaningful.
    func lastSampleSubtitle(prefs lastSampleAt: Date?) -> String? {
        guard let last = lastSampleAt else { return nil }
        let interval = Date().timeIntervalSince(last)
        switch self {
        case .connectedActive, .connectedStale:
            if interval < 60 { return "just now" }
            if interval < 3600 { return "\(Int(interval / 60))m ago" }
            if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
            return "\(Int(interval / 86_400))d ago"
        default:
            return nil
        }
    }
}
