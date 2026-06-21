//
//  ManageInspectorView.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import SwiftUI

/// Right inspector — detail of the single selected row, or a multi-selection
/// summary. Shown only on the Sessions tab (controlled by the ViewController).
/// Doesn't show classification; surfaces only the status (abnormal) in a box.
/// UI strings are English (app-wide policy).
struct ManageInspectorView: View {
    let store: ManageStore
    let actions: ManageRowActions

    var body: some View {
        ScrollView {
            content.padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if store.selectedCount > 1 {
            multiSelection
        } else if let row = store.inspectedRow {
            detail(row)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Select an item to see details.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var multiSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(store.selectedCount) selected").font(.headline)
            Text("Reclaims ~\(byteString(store.selectedReclaimBytes))")
                .foregroundStyle(.secondary)
            Button(role: .destructive) { actions.trashSelected() } label: {
                Label("Move Selected to Trash", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ row: ManageRowModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.displayTitle).font(.headline).lineLimit(3)
            Text(row.provider == .claudeCode ? "Claude Code session" : "Codex session")
                .font(.caption).foregroundStyle(.secondary)

            if row.status != .normal { statusBox(row) }

            VStack(alignment: .leading, spacing: 5) {
                metaRow("Path", row.projectPath ?? "—")
                if let branch = row.branch, !branch.isEmpty { metaRow("Branch", "⎇ \(branch)") }
                metaRow("Size", "\(byteString(row.sizeBytes)) · \(row.fileCount) files")
                if let created = row.createdAt { metaRow("Created", dateString(created)) }
                if let updated = row.lastActivity { metaRow("Updated", dateString(updated)) }
            }
            .font(.caption)

            if let prompt = row.firstPrompt, !prompt.isEmpty {
                Text("First prompt").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(prompt).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }

            actionButtons(row)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBox(_ row: ManageRowModel) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(row.status.emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.status.label).font(.caption).fontWeight(.semibold)
                Text(row.status.detailDescription).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key).foregroundStyle(.tertiary).frame(width: 56, alignment: .leading)
            Text(value).foregroundStyle(.primary).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func actionButtons(_ row: ManageRowModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if row.kind == .diskItem {
                Button { actions.reveal(row) } label: { Label("Reveal in Finder", systemImage: "folder") }
            } else {
                if row.kind == .session {
                    Button { actions.resume(row) } label: { Label("Resume", systemImage: "play.fill") }
                    Button { actions.copyCommand(row) } label: { Label("Copy Resume Command", systemImage: "doc.on.doc") }
                }
                Button { actions.reveal(row) } label: { Label("Reveal in Finder", systemImage: "folder") }
                if row.projectPath != nil {
                    Button { actions.openFolder(row) } label: { Label("Open Project Folder", systemImage: "folder.badge.gearshape") }
                    Button { actions.openTerminal(row) } label: { Label("Open in Terminal", systemImage: "terminal") }
                }
                if row.kind == .session {
                    Button { actions.export(row) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                }
                if row.protection == .deletable {
                    Button(role: .destructive) { actions.trashRow(row) } label: { Label("Move to Trash", systemImage: "trash") }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
