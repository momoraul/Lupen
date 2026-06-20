//
//  CodexEntryProjection.swift
//  Lupen
//
//  Created by jaden on 2026/06/19.
//

import Foundation

extension CodexEntry {
    /// Memory-bounded projection for an oversized rollout piece (see
    /// `CodexDetailImporter.importPiece`). Clips the non-user
    /// conversation BODY (assistant replies, tool output/args) to
    /// `textCap` characters and drops the large display-only structured
    /// JSON, so the per-piece working set tracks line count × cap instead
    /// of file bytes.
    ///
    /// **User-prompt text is preserved VERBATIM.** It is the matching
    /// basis for everything load-bearing: the subagent replay trim and
    /// the same-raw dedup match prompt text; skill detection, prompt
    /// preview, search content, and first-prompt all derive from it.
    /// Leaving it untouched is what makes the projection usage-/turn-/
    /// skill-/link-equivalent to the full path for any non-duplicated
    /// piece — including a parent whose prompts seed its children's trim.
    /// `info` (token usage), `type`/`role`/`turnId`/`model`/`cwd`, and the
    /// `name`/`call_id` link fields are likewise preserved; `output`
    /// (spawn `agent_id` JSON) is small and survives the clip.
    ///
    /// The importer still excludes DUPLICATED chains, whose same-raw
    /// dedup keys on assistant text — that is the only cross-piece
    /// matcher that reads non-user body. Pinned by the equivalence tests.
    ///
    /// Known display-only limitation: clipping non-user body can make the
    /// assembler's intra-piece mirror dedup (`isMatchingResponseMirror`,
    /// which compares normalized assistant text) miss a match when the
    /// SAME reply is a single string on the `event_msg` mirror side but
    /// multi-block `content` on the `response_item` side and exceeds the
    /// cap — leaving a duplicate assistant step (`StoreTurnRow.stepCount`
    /// +1). No usage/cost/turn/skill/link/search number is affected, and
    /// it only arises in a >=threshold (degraded) session.
    func lightweightProjection(textCap: Int) -> CodexEntry {
        guard let payload else { return self }

        // Reuse the ONE canonical user-message predicate (shared with the
        // aggregator, subagent trimmer, and assembler) so the preserved
        // set can never drift from what the matchers read.
        let isUserMessage = CodexConversationAssembler.isUserMessage(self, payload)

        func clip(_ value: String?) -> String? {
            // `utf8.count` is O(1) (String is UTF-8 backed) and a necessary
            // precondition for `count > textCap`, so an already-short field
            // skips the O(n) grapheme walk entirely; only a genuine over-cap
            // candidate pays for the grapheme count + prefix.
            guard let value, value.utf8.count > textCap else { return value }
            return value.count > textCap ? String(value.prefix(textCap)) : value
        }
        func clip(_ blocks: [ContentBlock]) -> [ContentBlock] {
            blocks.map { ContentBlock(type: $0.type, text: clip($0.text)) }
        }

        let projected = Payload(
            type: payload.type,
            timestamp: payload.timestamp,
            turnId: payload.turnId,
            model: payload.model,
            cwd: payload.cwd,
            info: payload.info,
            role: payload.role,
            // Preserve user-prompt text; clip only non-user body.
            message: isUserMessage ? payload.message : clip(payload.message),
            text: isUserMessage ? payload.text : clip(payload.text),
            content: isUserMessage ? payload.content : clip(payload.content),
            summary: isUserMessage ? payload.summary : clip(payload.summary),
            name: payload.name,
            arguments: clip(payload.arguments),
            input: clip(payload.input),
            output: clip(payload.output),
            callId: payload.callId,
            id: payload.id,
            status: payload.status,
            changes: nil,
            tools: nil,
            invocation: nil,
            action: nil,
            result: nil,
            duration: nil,
            execution: clip(payload.execution),
            query: clip(payload.query),
            revisedPrompt: clip(payload.revisedPrompt),
            numTurns: payload.numTurns
        )
        return CodexEntry(type: type, timestamp: timestamp, payload: projected)
    }
}
