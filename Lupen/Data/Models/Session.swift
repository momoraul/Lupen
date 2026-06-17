import Foundation

struct Session: Sendable, Codable, Identifiable, Equatable {
    let id: String
    let provider: ProviderKind
    let rawSessionId: String
    let requests: [ParsedRequest]
    let projectPath: String?
    var isVisibleInSessionList: Bool
    /// Precomputed display title, saved in the session cache so that a
    /// cache-hit cold launch can render the sidebar without waiting for
    /// the background parse to rebuild `turnsBySession`.
    ///
    /// Populated by `AppStateStore` after each full parse from the first
    /// Turn's cleaned prompt preview. Nil for old cache files written
    /// before this field existed (Codable `decodeIfPresent` semantics)
    /// and for sessions whose first Turn has no recoverable prompt text
    /// (orphan / tool-result-first). The live render path in
    /// `SessionListViewController.sessionTitle(for:)` always prefers
    /// `store.firstTurn(in:)` when it's available, so this value is
    /// strictly a cold-launch fallback — streaming updates during a
    /// running session never go stale because the live path wins.
    ///
    /// `var` (not `let`) so `AppStateStore.populateCachedTitles` can
    /// write it back in place without reconstructing the struct.
    var cachedTitle: String? = nil

    /// User-assigned session title from Claude Code's `/rename` command.
    /// Takes priority over every other title source in the sidebar — if
    /// the user bothered to name the session, that's the canonical label
    /// until they rename it again.
    ///
    /// Extracted by `RichEntryDecoder.extractCustomTitle` from
    /// `{"type":"custom-title","customTitle":"...","sessionId":"..."}`
    /// JSONL entries during ingest. Last value wins per session because
    /// `/rename` can be called multiple times. Persisted via Codable so
    /// the sidebar renders correctly on cold launch without re-parsing.
    ///
    /// Nil for cache files written before this field existed
    /// (`decodeIfPresent` semantics via default value) and for any
    /// session the user never renamed.
    var customTitle: String? = nil

    /// Request-derived time range carried by the SQLite-first shell
    /// projection (plan 3.2). The sidebar renders sessions from SQLite
    /// shells without materializing request rows, so `startTime` /
    /// `endTime` fall back to these when `requests` is empty. Legacy
    /// paths never set them.
    var shellStartTime: Date? = nil
    var shellEndTime: Date? = nil

    /// Scanner-extracted slug carried by the SQLite-first shell
    /// projection (plan 4.3) — `slug` falls back to it when `requests`
    /// is empty so sidebar search keeps matching slugs on shells.
    var shellSlug: String? = nil

    /// Importer-extracted `sessions.last_git_branch` carried by the
    /// shell projection (plan 6.1) — `lastGitBranch` falls back to it
    /// when `requests` is empty so the sidebar branch row renders.
    var shellGitBranch: String? = nil

    var scopedId: String {
        ProviderScopedID(provider: provider, rawSessionId: rawSessionId).value
    }

    init(
        id: String,
        provider: ProviderKind = .claudeCode,
        rawSessionId: String? = nil,
        requests: [ParsedRequest],
        projectPath: String?,
        isVisibleInSessionList: Bool = true,
        cachedTitle: String? = nil,
        customTitle: String? = nil,
        shellStartTime: Date? = nil,
        shellEndTime: Date? = nil,
        shellSlug: String? = nil,
        shellGitBranch: String? = nil
    ) {
        let parsed = ProviderScopedID(value: id)
        self.id = id
        self.provider = parsed?.provider ?? provider
        self.rawSessionId = rawSessionId ?? parsed?.rawSessionId ?? id
        self.requests = requests
        self.projectPath = projectPath
        self.isVisibleInSessionList = isVisibleInSessionList
        self.cachedTitle = cachedTitle
        self.customTitle = customTitle
        self.shellStartTime = shellStartTime
        self.shellEndTime = shellEndTime
        self.shellSlug = shellSlug
        self.shellGitBranch = shellGitBranch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let parsed = ProviderScopedID(value: id)
        self.id = id
        self.provider = try c.decodeIfPresent(ProviderKind.self, forKey: .provider)
            ?? parsed?.provider
            ?? .claudeCode
        self.rawSessionId = try c.decodeIfPresent(String.self, forKey: .rawSessionId)
            ?? parsed?.rawSessionId
            ?? id
        self.requests = try c.decode([ParsedRequest].self, forKey: .requests)
        self.projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        self.isVisibleInSessionList = try c.decodeIfPresent(Bool.self, forKey: .isVisibleInSessionList) ?? true
        self.cachedTitle = try c.decodeIfPresent(String.self, forKey: .cachedTitle)
        self.customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        self.shellStartTime = try c.decodeIfPresent(Date.self, forKey: .shellStartTime)
        self.shellEndTime = try c.decodeIfPresent(Date.self, forKey: .shellEndTime)
        self.shellSlug = try c.decodeIfPresent(String.self, forKey: .shellSlug)
        self.shellGitBranch = try c.decodeIfPresent(String.self, forKey: .shellGitBranch)
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, rawSessionId, requests, projectPath, isVisibleInSessionList, cachedTitle, customTitle
        case shellStartTime, shellEndTime, shellSlug, shellGitBranch
    }

    var startTime: Date? { requests.first?.timestamp ?? shellStartTime }
    var endTime: Date? { requests.last?.timestamp ?? shellEndTime }

    /// The `gitBranch` recorded on the most recent request that carried one.
    /// Claude Code stores the branch per-entry, so a session that did a mid-run
    /// `git checkout` will have different values across requests — "last known"
    /// is what the sidebar cares about.
    var lastGitBranch: String? {
        // `last(where:)` walks from the tail and returns the first non-nil
        // value — semantically "the most recent recorded branch".
        requests.last(where: { $0.gitBranch != nil })?.gitBranch ?? shellGitBranch
    }

    /// Claude Code's human-friendly per-session slug (e.g. `harmonic-nibbling-meerkat`).
    /// Returned as soon as any request provides one, since the slug is stable
    /// across a session.
    var slug: String? {
        requests.first(where: { $0.slug != nil })?.slug ?? shellSlug
    }

    func withProviderScopedIdentity() -> Session {
        let provider = ProviderScopedID(value: id)?.provider ?? self.provider
        let rawID = ProviderScopedID.rawID(from: rawSessionId)
        let scopedID = ProviderScopedID.normalize(rawID, defaultProvider: provider)
        let normalizedRequests = requests.map {
            $0.withSessionIdentity(
                provider: provider,
                rawSessionId: rawID,
                scopedSessionId: scopedID
            )
        }
        guard id != scopedID || rawSessionId != rawID || requests != normalizedRequests else {
            return self
        }
        return Session(
            id: scopedID,
            provider: provider,
            rawSessionId: rawID,
            requests: normalizedRequests,
            projectPath: projectPath,
            isVisibleInSessionList: isVisibleInSessionList,
            cachedTitle: cachedTitle,
            customTitle: customTitle,
            shellStartTime: shellStartTime,
            shellEndTime: shellEndTime,
            shellSlug: shellSlug,
            shellGitBranch: shellGitBranch
        )
    }
}
