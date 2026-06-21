//
//  MarkdownNode.swift
//  Lupen
//
//  Created by jaden on 2026/06/21.
//

import Foundation

/// A block-level node produced by markdown-parsing one text block.
///
/// The unit of Level 2 rendering (extensibility-architecture.md): each node
/// kind can plug in a dedicated renderer (table = NSGridView, code = card,
/// etc.), and unsupported nodes fall back to plain text. Inline markdown
/// (bold/links/etc.) is NOT parsed here — the raw string is preserved so the
/// renderer can handle it via `AttributedString(markdown:)`.
enum MarkdownNode: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case orderedList([String])
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case quote([String])
}
