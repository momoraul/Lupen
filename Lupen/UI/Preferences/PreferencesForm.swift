import SwiftUI

/// Grouped-form content inside `PreferencesWindowController`. Written as a
/// `fileprivate`-style struct but kept internal so the hosting controller in
/// the same module can mount it directly.
///
/// Layout mirrors macOS 26 System Settings:
///   * **Sidebar** section — inline picker for Grouped vs Flat, with a
///     short caption clarifying the behavioural difference.
///   * **Pinned Sessions** section — only appears when at least one
///     session is pinned. Shows a count, a reminder about layout
///     interaction, and an Unpin All button.
///
/// Binding semantics: `@Bindable` on `AppSettings` means every control
/// writes through directly, and the VC's `didSet` debouncer handles disk
/// persistence in the background. Consumers (sidebar, menu) observe the
/// same `AppSettings` instance and rebuild synchronously.
struct PreferencesForm: View {

    @Bindable var settings: AppSettings

    /// Opens Finder on the Lupen log directory. Mirrors the
    /// `File ▸ Reveal Log File in Finder` menu item so users who land
    /// in Settings can perform the same action without hunting the
    /// menu bar. AppDelegate owns the actual implementation.
    let onRevealLogFile: () -> Void

    /// Wipes the derived SQLite indexes and re-scans the source logs
    /// in the background. Mirrors `File ▸ Rebuild Index…`. The
    /// AppDelegate-side handler shows the confirmation alert, so this
    /// closure is just a thin trigger.
    let onClearCacheAndReparse: () -> Void

    /// Statusline service — optional so callers that don't need
    /// limit-tracking UI (early test paths, partial bring-up) skip the
    /// section. Production AppDelegate always supplies one.
    var statuslineService: StatuslineConnectionService? = nil

    var body: some View {
        Form {
            Section {
                Toggle("Start at Login", isOn: $settings.startAtLogin)
                Toggle("Show Today's Cost in Menu Bar", isOn: $settings.showTodayCostInMenuBar)
                Toggle("Compact (no cents — $23 instead of $23.47)",
                       isOn: $settings.compactCurrencyInMenuBar)
                    .disabled(!settings.showTodayCostInMenuBar)
                    .padding(.leading, 20)
                Toggle("Open Dashboard on Launch", isOn: $settings.openDashboardOnLaunch)
            } header: {
                Text("General")
            } footer: {
                Text("Start at Login registers Lupen with macOS's Login Items. The menu-bar cost toggle hides the dollar amount shown next to the icon — useful on small displays. Compact rounds to whole dollars, freeing about 24 px on narrow menu bars. Opening the dashboard on launch is off by default so the app starts quietly in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Mode", selection: $settings.activeProvider) {
                    ForEach(ProviderRegistry.all) { provider in
                        Text(provider.displayName).tag(provider.kind)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Mode")
            } footer: {
                Text("Lupen shows sessions, totals, reports, and verification for the selected mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            UpdatesSettingsSection()

            if let svc = statuslineService {
                StatuslineSettingsSection(service: svc)
            }

            Section {
                Toggle("Show Warning Badge", isOn: $settings.showParseWarningBadge)
                Toggle("Show Error Badge", isOn: $settings.showParseErrorBadge)
            } header: {
                Text("Diagnostics Badge")
            } footer: {
                Text("Overlays a small icon on the menu-bar item when Lupen has parse warnings or errors to report. Most warnings are signals about new Claude Code formats that only the Lupen developer can act on — defaults are off in release builds. The Diagnostics window (Window ▸ Diagnostics) still tracks every event regardless of these toggles, so you can inspect on demand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Session List", selection: $settings.sessionListLayout) {
                    ForEach(SessionListLayoutMode.allCases, id: \.self) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Text("Grouped displays sessions under collapsible project headers. Flat shows a single list sorted by most-recent activity, with the project name inline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Sidebar")
            }

            if !settings.pinnedSessionIds.isEmpty {
                Section {
                    Text("Pinned sessions appear at the top of the sidebar in Flat layout. Pins are ignored in Grouped layout but the pin icon is still shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Unpin All") {
                        settings.unpinAll()
                    }
                } header: {
                    Text("Pinned Sessions (\(settings.pinnedSessionIds.count))")
                }
            }

            Section {
                Button {
                    onRevealLogFile()
                } label: {
                    Label("Reveal Log File in Finder", systemImage: "doc.text.magnifyingglass")
                }

                Button(role: .destructive) {
                    onClearCacheAndReparse()
                } label: {
                    Label("Rebuild Index…", systemImage: "trash")
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Reveal opens Finder on the Lupen log directory. Rebuild Index clears the derived index and re-scans every session log in the background — useful if numbers look wrong or after a provider format change. Source logs on disk are never modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Fixed width + loose height band so the window doesn't collapse
        // to a minimum unreadable size when the Pinned section is absent
        // and doesn't overflow when caption text wraps. Height is driven
        // by SwiftUI's fitting size — the hosting controller's
        // `preferredContentSize` sizing option propagates that up.
        .frame(width: 480)
        .frame(minHeight: 320, idealHeight: 420, maxHeight: 600)
    }
}
