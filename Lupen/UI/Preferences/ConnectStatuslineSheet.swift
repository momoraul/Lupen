import SwiftUI

/// Single-sheet Connect modal — collapses the multi-step wizard alternative
/// into one flat form so the user can scan-confirm everything in 5 seconds:
/// "this is what's about to happen, go." Driven by
/// `StatuslineConnectionService` for the actual side-effects.
@MainActor
struct ConnectStatuslineSheet: View {

    @Bindable var service: StatuslineConnectionService

    /// Called when the sheet should dismiss. The string is non-nil
    /// when the dismissal was caused by an error the parent should
    /// surface; nil for normal success / cancel.
    let onDismiss: (String?) -> Void

    /// Defaults to the value the user previously chose (when
    /// reconfiguring), or — for a first connect — to `.off` per plan §1
    /// ("chain default OFF").
    @State private var chainEnabled: Bool = false
    @State private var inFlight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            actionList
            Divider()
            chainSection
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // First-connect default is OFF (research §1). Reconfigure
            // path remembers the user's previous choice so toggling
            // back is one click instead of "remember to re-check".
            // BUT: if the previous chain target no longer exists (user
            // deleted their statusline.sh), force the toggle off so
            // the visual doesn't end up "checked but disabled" with no
            // path shown.
            if service.detectedChainTarget == nil {
                chainEnabled = false
            } else {
                chainEnabled = service.settings.statuslinePrefs.chainEnabled
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect Lupen to Claude Code statusline")
                .font(.system(size: 15, weight: .semibold))
            Text("Lupen will register a wrapper script in ~/.claude/ and update Claude Code's statusline command. Your existing settings will be backed up.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            bulletLine(
                "Wrapper script will be created at ~/.claude/lupen-statusline-tap.sh"
            )
            bulletLine(
                "settings.json will be backed up to settings.json.lupen-backup-{timestamp}"
            )
            bulletLine(
                "Captured samples land in ~/.claude/lupen/ratelimit-samples.jsonl (30-day rolling)"
            )
        }
    }

    private var chainSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Also keep my existing statusline running", isOn: $chainEnabled)
                .toggleStyle(.checkbox)
                // Disable the toggle when there's nothing to chain —
                // turning it on with no detected target would silently
                // fall back to no-chain. Make that impossible.
                .disabled(service.detectedChainTarget == nil)

            if let detected = service.detectedChainTarget {
                Text("Found: \(detected)")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else {
                Text("No existing statusline detected. Lupen will display nothing in the statusline area.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
        }
    }

    private var footer: some View {
        HStack {
            if inFlight {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                onDismiss(nil)
            }
            .keyboardShortcut(.cancelAction)
            Button(action: connect) {
                Text("Connect")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(inFlight)
        }
    }

    // MARK: - Actions

    private func connect() {
        inFlight = true
        let chain = chainEnabled ? service.detectedChainTarget : nil
        do {
            try service.connect(chainCommand: chain)
            onDismiss(nil)
        } catch {
            inFlight = false
            onDismiss("Connect failed: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func bulletLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

