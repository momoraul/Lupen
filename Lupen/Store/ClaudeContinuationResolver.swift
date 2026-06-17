import Foundation

/// Drives compact/resume lineage resolution against a store: pulls the
/// whole-corpus billable membership, resolves each requestId's canonical
/// owner, and applies the re-home + supersede. Runs after a detail import
/// cycle. Reads only the lightweight `request_membership` table — no JSONL
/// re-reads — so it is cheap enough to run on every idle.
enum ClaudeContinuationResolver {

    @discardableResult
    static func run(store: ProviderStore) throws -> ClaudeContinuationLineage.Resolution {
        let sessions = try store.sessionRequestMemberships()
        // Nothing can be shared with fewer than two sessions.
        guard sessions.count >= 2 else {
            return ClaudeContinuationLineage.Resolution(
                hidden: [], canonicalByRawId: [:], ownerByRequestId: [:], affectedRawIds: []
            )
        }

        let resolution = ClaudeContinuationLineage.resolve(sessions)
        try store.applyContinuationLineage(resolution)
        return resolution
    }
}
