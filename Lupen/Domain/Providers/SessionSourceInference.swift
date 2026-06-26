//
//  SessionSourceInference.swift
//  Lupen
//
//  Created by jaden on 2026/06/26.
//

import Foundation

/// Pure helpers behind the "add a folder" flow in Settings ▸ Session Sources
/// (plan §4.4): infer the parser kind and the source root from a folder the
/// user picked, suggest a display name, and validate name/path uniqueness.
/// Kept free of AppKit so the inference rules are unit-testable.
enum SessionSourceInference {

    struct Inference: Equatable {
        let kind: ProviderKind
        /// The normalized base directory the pipeline will index — for Codex
        /// the codexHome (parent of `sessions/`), for Claude the `projects`
        /// directory it scans directly.
        let root: URL
    }

    /// Infer `(kind, root)` from a picked folder using directory structure.
    /// Returns nil when the layout is ambiguous so the caller can ask the user
    /// to choose the kind explicitly.
    ///
    /// Codex's root is the codexHome, so picking either the codexHome (which
    /// contains `sessions/`) or the `sessions/` directory itself resolves to
    /// the codexHome. Claude's root is the `projects` directory, so picking a
    /// config directory that contains `projects/` resolves into it.
    static func infer(
        fromPickedFolder picked: URL,
        fileManager: FileManager = .default
    ) -> Inference? {
        let dir = picked.standardizedFileURL
        let name = dir.lastPathComponent.lowercased()

        func hasSubdirectory(_ component: String) -> Bool {
            isReadableDirectory(dir.appendingPathComponent(component), fileManager: fileManager)
        }

        // Codex: a codexHome holds `sessions/` (and session_index.jsonl).
        if hasSubdirectory("sessions") {
            return Inference(kind: .codex, root: normalized(dir))
        }
        if name == "sessions" {
            return Inference(kind: .codex, root: normalized(dir.deletingLastPathComponent()))
        }
        // Claude: the pipeline scans the `projects` directory directly.
        if name == "projects" {
            return Inference(kind: .claudeCode, root: normalized(dir))
        }
        if hasSubdirectory("projects") {
            return Inference(kind: .claudeCode, root: normalized(dir.appendingPathComponent("projects")))
        }
        return nil
    }

    /// Suggest an editable display name from the source root. Prefers the most
    /// distinctive ancestor directory (skipping generic tokens like `projects`,
    /// `.claude`, the user's home) combined with the kind's short label, e.g.
    /// `…/Xcode/CodingAssistant/ClaudeAgentConfig/projects` → "ClaudeAgentConfig
    /// Claude". Falls back to the kind's display name.
    static func suggestName(forRoot root: URL, kind: ProviderKind) -> String {
        let label = ProviderRegistry.descriptor(for: kind).shortDisplayName
        let generic: Set<String> = [
            "/", "projects", "sessions", ".claude", ".codex", "users", "library",
        ]
        let distinctive = root.standardizedFileURL.pathComponents
            .reversed()
            .first { component in
                let lower = component.lowercased()
                return !generic.contains(lower)
                    && !component.hasPrefix(".")
                    && component.count > 1
            }
        guard let distinctive else { return label }
        return "\(distinctive) \(label)"
    }

    /// Make `base` unique against `existingNames` by appending " 2", " 3", ….
    /// Case-sensitive (names are user-facing labels). Returns `base` unchanged
    /// when it's already unique.
    static func uniqueName(_ base: String, existingNames: [String]) -> String {
        let taken = Set(existingNames)
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// The existing source whose normalized root equals `root`, if any —
    /// used to warn "already registered" before adding a duplicate path.
    static func duplicateRootSource(_ root: URL, in sources: [SessionSource]) -> SessionSource? {
        let normalizedPath = SessionSource.normalizedRoot(root).path
        return sources.first { $0.root.path == normalizedPath }
    }

    // MARK: - Helpers

    private static func normalized(_ url: URL) -> URL {
        SessionSource.normalizedRoot(url)
    }

    private static func isReadableDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
