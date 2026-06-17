import Foundation

/// Classified JSONL line in the legacy pipeline — either an assistant
/// `RawEntry` (billable) or auxiliary user/system metadata.
///
/// Serialized into `ParseSnapshot.allAuxiliaryLines`. Bump
/// `SnapshotSchema.currentVersion` whenever a case is added or removed.
enum ParsedLine: Sendable, Equatable {
    case assistant(RawEntry)
    case user(UserAux)
    case system(SystemAux)

    struct UserAux: Sendable, Equatable, Codable {
        let uuid: String
        let parentUuid: String?
        let sessionId: String
        let timestamp: String
        let text: String
    }

    struct SystemAux: Sendable, Equatable, Codable {
        let uuid: String
        let sessionId: String
        let timestamp: String
        let systemPrompt: String?
        let toolDefinitionsJSON: Data?
        let rawPayload: Data?
    }
}

extension ParsedLine: Codable {

    private enum Kind: String, Codable {
        case assistant, user, system
    }

    private enum CodingKeys: String, CodingKey {
        case kind, assistant, user, system
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .assistant:
            self = .assistant(try c.decode(RawEntry.self, forKey: .assistant))
        case .user:
            self = .user(try c.decode(UserAux.self, forKey: .user))
        case .system:
            self = .system(try c.decode(SystemAux.self, forKey: .system))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .assistant(let entry):
            try c.encode(Kind.assistant, forKey: .kind)
            try c.encode(entry, forKey: .assistant)
        case .user(let ua):
            try c.encode(Kind.user, forKey: .kind)
            try c.encode(ua, forKey: .user)
        case .system(let sa):
            try c.encode(Kind.system, forKey: .kind)
            try c.encode(sa, forKey: .system)
        }
    }
}
