//
//  SessionSourcesSettingsSection.swift
//  Lupen
//
//  Created by jaden on 2026/06/26.
//

import SwiftUI
import AppKit

/// Settings ▸ Session Sources (plan §4): lists the composed sources
/// (built-in + auto-detected + user-added) with an enable toggle each, a
/// kind/origin badge, the path, and an "Add Folder…" action that infers the
/// kind/root from the picked directory. Only enabled sources are indexed and
/// appear in the mode picker.
///
/// All mutations go through the tested `AppSettings` management API
/// (`setSourceEnabled` / `addSource` / `removeSource`); this view is the
/// declarative surface over them.
struct SessionSourcesSettingsSection: View {

    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            ForEach(settings.resolvedSources) { source in
                row(source)
            }
            Button {
                addFolder()
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
        } header: {
            Text("Session Sources")
        } footer: {
            Text("Only enabled sources are indexed and shown in the mode picker. Built-in Claude Code and Codex are always available; add a folder to track sessions stored elsewhere (e.g. an Xcode Coding Assistant or a custom CLAUDE_CONFIG_DIR / CODEX_HOME).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func row(_ source: SessionSource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: enabledBinding(for: source))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name).fontWeight(.medium)
                    kindBadge(source.kind)
                    Text(originLabel(source.origin))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(source.root.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .help(source.root.path)
            }

            Spacer(minLength: 8)

            if source.origin == .userAdded {
                Button {
                    settings.removeSource(id: source.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this source")
            }
        }
        .padding(.vertical, 2)
    }

    private func kindBadge(_ kind: ProviderKind) -> some View {
        let color: Color = kind == .claudeCode ? .indigo : .teal
        return Text(ProviderRegistry.descriptor(for: kind).shortDisplayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func originLabel(_ origin: SessionSource.Origin) -> String {
        switch origin {
        case .builtin: return "Built-in"
        case .autoDetected: return "Detected"
        case .userAdded: return "Added"
        }
    }

    private func enabledBinding(for source: SessionSource) -> Binding<Bool> {
        Binding(
            get: { settings.resolvedSources.source(id: source.id)?.enabled ?? false },
            set: { settings.setSourceEnabled(id: source.id, $0) }
        )
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a Claude Code projects folder or a Codex home."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let kind: ProviderKind
        let root: URL
        if let inferred = SessionSourceInference.infer(fromPickedFolder: url) {
            kind = inferred.kind
            root = inferred.root
        } else if let chosen = askKind(for: url) {
            // Ambiguous layout — the user picks the kind rather than guessing.
            kind = chosen
            root = url
        } else {
            return
        }
        if settings.addSource(root: root, kind: kind) == nil {
            notifyDuplicate(root: root)
        }
    }

    /// Ask which parser an ambiguous folder holds. Returns nil on Cancel.
    private func askKind(for url: URL) -> ProviderKind? {
        let alert = NSAlert()
        alert.messageText = "Which kind of sessions does this folder hold?"
        alert.informativeText = url.path
        alert.addButton(withTitle: "Claude Code")
        alert.addButton(withTitle: "Codex")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .claudeCode
        case .alertSecondButtonReturn: return .codex
        default: return nil
        }
    }

    /// Tell the user the picked folder is already registered (addSource
    /// returned nil on a duplicate normalized root).
    private func notifyDuplicate(root: URL) {
        let alert = NSAlert()
        alert.messageText = "This folder is already a session source."
        if let existing = SessionSourceInference.duplicateRootSource(
            SessionSource.normalizedRoot(root), in: settings.resolvedSources
        ) {
            alert.informativeText = "“\(existing.name)” already points at \(root.path)."
        }
        alert.runModal()
    }
}
