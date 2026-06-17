import SwiftUI
import AppKit

/// Launch progress card driven by `AppStateStore.launchProgress`.
///
/// `.scanningFiles` renders an indeterminate bar (no denominator until
/// the metadata scan finishes); `.indexing` renders a determinate
/// unit-counted bar. Hidden by the caller in `.idle` / `.done`.
struct LaunchProgressView: View {

    let store: AppStateStore

    var body: some View {
        let p = store.launchProgress
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                phaseIcon(for: p)
                Text(p.humanSummary.isEmpty ? defaultTitle(for: p) : p.humanSummary)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }

            if p.phase == .indexing, p.pendingUnits > 0 {
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)

                Text("\(p.processedUnits) / \(p.pendingUnits) sessions")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if p.phase == .scanningFiles || p.phase == .indexing {
                // Indeterminate — no unit denominator yet.
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(16)
        // Fixed-width card: previously `.frame(maxWidth: 520)` let the
        // host shrink-to-fit the longest text, so every counter tick
        // re-measured the intrinsic width and re-centered the host view
        // inside its pane — visible side-to-side jitter that read as
        // unfinished. Pinning to a fixed width keeps the card
        // glassy-still while the inner numbers update in place;
        // `monospacedDigit()` on the dynamic Text fields keeps digit
        // columns from shifting even within the fixed card.
        .frame(width: 480)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func phaseIcon(for p: LaunchProgress) -> some View {
        let name: String = {
            switch p.phase {
            case .idle, .done: return "checkmark.circle"
            case .scanningFiles: return "magnifyingglass"
            case .indexing: return "tray.and.arrow.down"
            }
        }()
        return Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.accentColor)
    }

    private func defaultTitle(for p: LaunchProgress) -> String {
        switch p.phase {
        case .idle: return "Idle"
        case .done: return "Ready"
        default: return ""
        }
    }
}

/// Convenience NSHostingView wrapper so AppKit callers
/// (`TurnOutlineViewController` loading overlay) can drop it into an
/// NSStackView without ceremony.
@MainActor
final class LaunchProgressHostingView: NSHostingView<LaunchProgressView> {
    init(store: AppStateStore) {
        super.init(rootView: LaunchProgressView(store: store))
    }

    @MainActor required init(rootView: LaunchProgressView) {
        super.init(rootView: rootView)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) unused — LaunchProgressHostingView is code-only")
    }
}
