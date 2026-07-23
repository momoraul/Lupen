//
//  TurnAnalysisExportPresenter.swift
//  Lupen
//
//  Created by jaden on 2026/07/20.
//

import AppKit
import UniformTypeIdentifiers

/// AppKit half of the turn analysis export: the save panel, the pasteboard, and
/// the error alert.
///
/// Kept apart from the document generation so `Lupen/Domain/Export` stays pure
/// and unit-testable — the split `ReportsCSVExporter` established and this
/// follows verbatim, including the sheet-if-key-window-else-modal fallback and
/// the `MainActor.assumeIsolated` completion idiom.
@MainActor
enum TurnAnalysisExportPresenter {

    /// Shown on the save panel so the user knows what leaves the machine before
    /// they choose a destination. The app never transmits anything itself, but
    /// the whole point of this file is to be handed to an AI, so the contents
    /// deserve a plain statement rather than a surprise.
    static let privacyMessage = """
        This document contains your prompt text, the assistant's replies and \
        reasoning, file paths, and tool output from this turn. Review it before \
        sharing it with an external service.
        """

    static func save(document: String, provider: ProviderKind, in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TurnAnalysisExporter.suggestedFilename(provider: provider)
        // `.markdown` is not available on every SDK Lupen builds against; derive
        // it from the extension and fall back to plain text rather than failing
        // the export over a type identifier.
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Turn Analysis"
        panel.message = privacyMessage

        let completion: @Sendable (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try Data(document.utf8).write(to: url, options: .atomic)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    /// Copy is the likelier path in practice — the document usually goes
    /// straight into a chat window — so it is a first-class action rather than
    /// an afterthought behind the save panel.
    static func copy(document: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(document, forType: .string)
    }
}
