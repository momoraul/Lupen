import Foundation

struct ParsedRequest: Sendable, Codable, Identifiable, Equatable {
    let id: String
    let messageId: String?
    let sessionId: String
    let provider: ProviderKind
    let rawSessionId: String
    let model: String?
    let timestamp: Date
    let parentUuid: String?
    let isSidechain: Bool
    let speed: String?
    let stopReason: String?
    let tokens: TokenBreakdown
    /// git branch at the time this request was recorded. Nil for legacy
    /// cached requests from before parsing picked this up.
    let gitBranch: String?
    /// Claude Code's human-friendly session slug (e.g. `harmonic-nibbling-meerkat`).
    let slug: String?

    // Default values keep existing call-sites (tests, legacy cache rehydration)
    // compiling without explicit churn — both fields are recent additions.
    init(
        id: String,
        messageId: String?,
        sessionId: String,
        provider: ProviderKind = .claudeCode,
        rawSessionId: String? = nil,
        model: String?,
        timestamp: Date,
        parentUuid: String?,
        isSidechain: Bool,
        speed: String?,
        stopReason: String?,
        tokens: TokenBreakdown,
        gitBranch: String? = nil,
        slug: String? = nil
    ) {
        let parsed = ProviderScopedID(value: sessionId)
        self.id = id
        self.messageId = messageId
        self.sessionId = sessionId
        self.provider = parsed?.provider ?? provider
        self.rawSessionId = rawSessionId ?? parsed?.rawSessionId ?? sessionId
        self.model = model
        self.timestamp = timestamp
        self.parentUuid = parentUuid
        self.isSidechain = isSidechain
        self.speed = speed
        self.stopReason = stopReason
        self.tokens = tokens
        self.gitBranch = gitBranch
        self.slug = slug
    }

    // Explicit decode init so that older cached JSON (written before
    // gitBranch/slug existed) still rehydrates without throwing "keyNotFound".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.messageId = try c.decodeIfPresent(String.self, forKey: .messageId)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        let parsed = ProviderScopedID(value: sessionId)
        self.provider = try c.decodeIfPresent(ProviderKind.self, forKey: .provider)
            ?? parsed?.provider
            ?? .claudeCode
        self.rawSessionId = try c.decodeIfPresent(String.self, forKey: .rawSessionId)
            ?? parsed?.rawSessionId
            ?? sessionId
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.parentUuid = try c.decodeIfPresent(String.self, forKey: .parentUuid)
        self.isSidechain = try c.decode(Bool.self, forKey: .isSidechain)
        self.speed = try c.decodeIfPresent(String.self, forKey: .speed)
        self.stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        self.tokens = try c.decode(TokenBreakdown.self, forKey: .tokens)
        self.gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
    }

    // NOTE: only `init(from:)` is custom; `encode(to:)` is still synthesized
    // from these `CodingKeys`. Adding a new stored property without listing
    // it here would silently drop it from the encoded JSON cache. Keep this
    // list in sync with the stored properties above whenever you add fields.
    private enum CodingKeys: String, CodingKey {
        case id, messageId, sessionId, provider, rawSessionId, model, timestamp, parentUuid,
             isSidechain, speed, stopReason, tokens, gitBranch, slug
    }

    func withSessionIdentity(provider: ProviderKind, rawSessionId: String, scopedSessionId: String) -> ParsedRequest {
        ParsedRequest(
            id: id,
            messageId: messageId,
            sessionId: scopedSessionId,
            provider: provider,
            rawSessionId: rawSessionId,
            model: model,
            timestamp: timestamp,
            parentUuid: parentUuid,
            isSidechain: isSidechain,
            speed: speed,
            stopReason: stopReason,
            tokens: tokens,
            gitBranch: gitBranch,
            slug: slug
        )
    }

    func withID(_ id: String) -> ParsedRequest {
        ParsedRequest(
            id: id,
            messageId: messageId,
            sessionId: sessionId,
            provider: provider,
            rawSessionId: rawSessionId,
            model: model,
            timestamp: timestamp,
            parentUuid: parentUuid,
            isSidechain: isSidechain,
            speed: speed,
            stopReason: stopReason,
            tokens: tokens,
            gitBranch: gitBranch,
            slug: slug
        )
    }

    func withSidechain(_ isSidechain: Bool) -> ParsedRequest {
        guard self.isSidechain != isSidechain else { return self }
        return ParsedRequest(
            id: id,
            messageId: messageId,
            sessionId: sessionId,
            provider: provider,
            rawSessionId: rawSessionId,
            model: model,
            timestamp: timestamp,
            parentUuid: parentUuid,
            isSidechain: isSidechain,
            speed: speed,
            stopReason: stopReason,
            tokens: tokens,
            gitBranch: gitBranch,
            slug: slug
        )
    }
}
