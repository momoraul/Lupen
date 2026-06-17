import SwiftUI
import Sparkle

/// Settings UI for Sparkle-driven auto-updates. Mirrors the layout of
/// the other `PreferencesForm` sections: two toggles, a "Check Now"
/// action with a last-checked timestamp, and a footer that calls out
/// the Homebrew Cask interaction.
///
/// **Binding strategy** — Sparkle's `SPUUpdater` properties are not
/// SwiftUI-observable (no `@Published`/`@Observable`), so this view
/// can't bind to them directly with `$`. Instead it uses
/// `Binding(get:set:)` for the toggles (writes round-trip through
/// UserDefaults, which Sparkle owns) and a `@State` nonce that gets
/// bumped after user actions so the "Last checked" label re-reads
/// from the updater. The nonce is the smallest possible alternative
/// to wrapping `SPUUpdater` in an `@Observable` shim, which would
/// duplicate state that Sparkle is already authoritative over.
@MainActor
struct UpdatesSettingsSection: View {

    /// Forces the body to re-evaluate after `Check Now` finishes so
    /// the "Last checked" label picks up the new `lastUpdateCheckDate`.
    /// Sparkle doesn't surface a Combine publisher for that property,
    /// so a nudge here is simpler than wiring KVO.
    @State private var refreshNonce = UUID()

    private var updater: SPUUpdater { UpdateService.shared.updater }

    var body: some View {
        Section {
            Toggle("Automatically check for updates", isOn: autoCheckBinding)

            Toggle("Automatically download updates", isOn: autoDownloadBinding)
                .disabled(!updater.automaticallyChecksForUpdates)

            HStack {
                Text("Last checked:")
                Spacer()
                Text(lastCheckedSummary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .id(refreshNonce)
            }

            Button("Check Now") {
                UpdateService.shared.checkForUpdates(nil)
                // The check is asynchronous (Sparkle fetches the
                // appcast, may present a dialog, then writes
                // `lastUpdateCheckDate`). Bump the nonce after a
                // short delay so the "Last checked" cell reflects
                // the new timestamp once Sparkle has stored it.
                // 1.5s covers a successful no-update-available
                // path on a normal connection; the explicit
                // user-initiated check still also shows Sparkle's
                // own alert regardless of this label.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    refreshNonce = UUID()
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Lupen checks momoraul.github.io for new releases and verifies the download with an EdDSA signature before installing. If you installed via Homebrew, you can leave automatic checks off — `brew upgrade --cask lupen` handles updates from there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bindings + formatters

    /// `Binding(get:set:)` instead of `@Bindable` because `SPUUpdater`
    /// isn't `@Observable`. Writes go through Sparkle's own UserDefaults
    /// storage so the value persists across launches without a parallel
    /// `AppSettings` field.
    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private var autoDownloadBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.automaticallyDownloadsUpdates = $0 }
        )
    }

    private var lastCheckedSummary: String {
        guard let date = updater.lastUpdateCheckDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
