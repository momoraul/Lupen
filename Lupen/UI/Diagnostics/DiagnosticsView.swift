import SwiftUI
import AppKit

/// Parse Diagnostics window content. Observes `ParseDiagnostics` directly
/// via the Observation framework (no explicit @ObservedObject needed — it's
/// an `@Observable` class). Shows a summary header, a scrollable list of
/// recent warning/error samples, and Copy/Clear actions.
struct DiagnosticsView: View {

    let diagnostics: ParseDiagnostics
    let onDismiss: () -> Void

    /// Multi-select. Keeps any sample IDs the user picked even after a
    /// `recentSamples` mutation (new entry appended, ring buffer drop) —
    /// stale IDs are filtered out at copy time, not here, so a benign
    /// scroll while picking doesn't lose the selection.
    @State private var selectedSampleIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            if diagnostics.recentSamples.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sampleList
            }

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 380, idealHeight: 460)
    }

    // MARK: - Summary

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Parse Diagnostics")
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 16) {
                countPill(
                    label: "Errors",
                    count: diagnostics.errorCount,
                    color: .red,
                    symbol: "exclamationmark.circle.fill"
                )
                countPill(
                    label: "Warnings",
                    count: diagnostics.warningCount,
                    color: .orange,
                    symbol: "exclamationmark.triangle.fill"
                )
                countPill(
                    label: "Filter drops",
                    count: infoTotal,
                    color: .secondary,
                    symbol: "tray.fill"
                )
                Spacer()
                if let first = diagnostics.firstIssueAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("First issue")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(first, style: .time)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if diagnostics.hasAnyIssues {
                Text("Unexpected local agent log entries or accounting conditions were encountered. The provider may have updated its format, or the parser has a gap. See `docs/PARSE-DIAGNOSTICS.md`.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var infoTotal: Int {
        var total = 0
        for (key, value) in diagnostics.counts {
            switch key {
            case "filteredPreCheck", "emptyUserContent",
                 "claudeCodeSystemMeta", "imageSourceMeta":
                total += value
            default:
                break
            }
        }
        return total
    }

    private func countPill(label: String, count: Int, color: Color, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.system(size: 12, weight: .medium))
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Samples

    private var sampleList: some View {
        List(selection: $selectedSampleIDs) {
            ForEach(diagnostics.recentSamples.reversed(), id: \.id) { sample in
                SampleRow(sample: sample)
                    .tag(sample.id)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green.opacity(0.8))
            Text("No parse issues")
                .font(.system(size: 13, weight: .medium))
            Text("Every local agent log line was decoded cleanly.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(copyButtonTitle) {
                copySelectedSamples()
            }
            .disabled(selectedSampleIDs.isEmpty)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy the selected diagnostic samples to the clipboard")

            // ⌘A — select every sample currently in the list.
            // SwiftUI List on macOS supports cmd-click / shift-click
            // multi-select natively when bound to a `Set<…>` selection,
            // but `Cmd+A` is not bridged to the underlying NSTableView
            // automatically — so wire an explicit shortcut here. Hiding
            // the button via opacity 0 + tiny frame keeps the visible
            // footer uncluttered while the keyboard equivalent stays
            // active in the focused window.
            Button("Select All") {
                selectAllSamples()
            }
            .keyboardShortcut("a", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityLabel("Select all diagnostic samples")

            Button("Clear All") {
                diagnostics.clear()
                selectedSampleIDs.removeAll()
            }
            .disabled(!diagnostics.hasAnyIssues && diagnostics.counts.isEmpty)

            Spacer()

            Button("Close") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    /// Dynamic label so the user can see at a glance how many rows the
    /// click would actually copy. Singular/plural split keeps the
    /// English natural; the count badge in parentheses survives even
    /// when localised because the parenthetical is the marker.
    private var copyButtonTitle: String {
        switch selectedSampleIDs.count {
        case 0: return "Copy"
        case 1: return "Copy (1)"
        case let n: return "Copy (\(n))"
        }
    }

    // MARK: - Actions

    private func selectAllSamples() {
        selectedSampleIDs = Set(diagnostics.recentSamples.map(\.id))
    }

    /// Serializes every currently-selected sample to one pasteboard
    /// string. Multiple samples are separated by a blank line so the
    /// blocks stay readable when pasted into chat / an issue tracker.
    /// Order matches the on-screen reverse-chronological display so
    /// what the user sees and what they paste line up.
    private func copySelectedSamples() {
        guard !selectedSampleIDs.isEmpty else { return }
        // Iterate over the displayed (reversed) order so the paste
        // mirrors the visual list. Filter to the selected IDs.
        let displayed = diagnostics.recentSamples.reversed()
        let blocks = displayed
            .filter { selectedSampleIDs.contains($0.id) }
            .map(Self.formatSample)
        guard !blocks.isEmpty else { return }
        let combined = blocks.joined(separator: "\n\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(combined, forType: .string)
    }

    /// Single-sample text block — pulled out as `static` so tests can
    /// assert the exact format without spinning up a SwiftUI hierarchy.
    /// `nonisolated` because the formatter is pure on its inputs and
    /// shouldn't drag the MainActor through `.map(formatSample)` chains
    /// in tests / future callers.
    nonisolated static func formatSample(_ sample: ParseDiagnostics.Sample) -> String {
        let fileStr = sample.fileURL?.lastPathComponent ?? "<unknown file>"
        let offsetStr = sample.byteOffset.map { "@\($0)" } ?? ""
        let tsStr = sampleTimestampFormatter.string(from: sample.at)
        return """
        [\(tsStr)] \(fileStr)\(offsetStr)
        Reason: \(sample.rejection.humanDescription)
        Preview:
        \(sample.preview)
        """
    }

    /// File-scope ISO-8601 formatter so the diagnostic-row render path
    /// doesn't allocate one per sample. `nonisolated(unsafe)` because
    /// `ISO8601DateFormatter` is documented thread-safe for `.string(from:)`.
    nonisolated(unsafe) private static let sampleTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()
}

// MARK: - Sample row

private struct SampleRow: View {
    let sample: ParseDiagnostics.Sample

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                severityIcon
                Text(sample.rejection.humanDescription)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(sample.at, style: .time)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let file = sample.fileURL?.lastPathComponent {
                    Text(file)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let offset = sample.byteOffset {
                    Text("@\(offset)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if !sample.preview.isEmpty {
                Text(sample.preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var severityIcon: some View {
        switch sample.rejection.severity {
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .info:
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
    }
}
