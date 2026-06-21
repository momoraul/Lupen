//
//  ManageCacheView.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import SwiftUI

/// Lupen cache inspection tab — reports index/snapshot size (per file), indexing
/// completion rate/failures/last time, and offers rebuild/cleanup/Reveal. UI
/// strings are English (app-wide policy).
struct ManageCacheView: View {
    let store: ManageStore
    let onRebuild: () -> Void
    let onClearSnapshots: () -> Void
    let onReveal: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Lupen Cache").font(.title3).bold()
                Text(store.provider == .claudeCode ? "Claude Code index" : "Codex index")
                    .font(.subheadline).foregroundStyle(.secondary)

                if let info = store.cacheInfo {
                    card("Storage") {
                        row("index.sqlite3", byteString(info.indexBytes))
                        if info.walBytes > 0 { row("WAL", byteString(info.walBytes)) }
                        if info.shmBytes > 0 { row("SHM", byteString(info.shmBytes)) }
                        row("Snapshot cache", byteString(info.snapshotBytes))
                        Divider()
                        row("Total", byteString(info.indexBytes + info.walBytes + info.shmBytes + info.snapshotBytes), bold: true)
                    }
                    if let coverage = info.coverage {
                        card("Indexing") {
                            row("Imported", "\(coverage.importedSources) / \(coverage.totalSources)")
                            if coverage.failedSources > 0 {
                                row("Failed", "⚠️ \(coverage.failedSources)", valueColor: .orange)
                            }
                            if coverage.pendingSources > 0 {
                                row("Pending", "\(coverage.pendingSources)", valueColor: .secondary)
                            }
                            if let last = info.lastIndexed {
                                row("Last indexed", last.formatted(date: .abbreviated, time: .shortened))
                            }
                            row("Status", coverage.isComplete ? "✅ Complete" : "⏳ In progress")
                        }
                    }
                } else {
                    Text("Loading cache info…").foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button { onRebuild() } label: { Label("Rebuild Index", systemImage: "arrow.clockwise") }
                    Button { onClearSnapshots() } label: { Label("Clear Snapshot Cache", systemImage: "trash") }
                    Button { onReveal() } label: { Label("Open Application Support", systemImage: "folder") }
                }
                .controlSize(.regular)

                Text("Rebuild and clear don't touch your original session logs.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ key: String, _ value: String, bold: Bool = false, valueColor: Color? = nil) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(bold ? .semibold : .regular)
                .monospacedDigit()
                .foregroundStyle(valueColor ?? .primary)
        }
        .font(.callout)
    }

    private func byteString(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
