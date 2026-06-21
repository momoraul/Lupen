//
//  ManageTitleFormatter.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Builds the primary title for a session row. The first prompt is used as the
/// identifier, but a name the user set themselves (`/rename`) is the most
/// authoritative if present (see Session.swift comments).
///
/// Priority: `customTitle` (user-set) → `firstPrompt` (content) →
/// `cachedTitle` (automatic) → fallback. (Refines plan §2 — identifiability first.)
/// The display string normalizes newlines, code fences, and runs of whitespace
/// into a single line (research §B-4).
enum ManageTitleFormatter {

    static let emptyFallback = "(Untitled session)"

    static func sessionTitle(
        firstPrompt: String?,
        cachedTitle: String?,
        customTitle: String?,
        maxLength: Int = 80
    ) -> String {
        let chosen = nonEmpty(customTitle)
            ?? nonEmpty(firstPrompt)
            ?? nonEmpty(cachedTitle)
        guard let chosen else { return emptyFallback }
        let cleaned = clean(chosen)
        return cleaned.isEmpty ? emptyFallback : truncate(cleaned, maxLength: maxLength)
    }

    /// Folds newlines/tabs/code fences into spaces and collapses runs of whitespace into one.
    static func clean(_ raw: String) -> String {
        let noFence = raw.replacingOccurrences(of: "```", with: " ")
        return noFence
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
    }

    /// Truncates with an ellipsis (…) when it exceeds `maxLength`.
    static func truncate(_ s: String, maxLength: Int = 80) -> String {
        guard maxLength > 1, s.count > maxLength else { return s }
        let head = s.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
