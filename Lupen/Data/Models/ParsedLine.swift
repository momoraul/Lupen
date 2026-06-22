import Foundation

/// Classified JSONL line — either an assistant `RawEntry` (billable) or
/// auxiliary user/system metadata. Produced by `JSONLParser` and consumed by
/// `AuxiliaryLinker`; held only in memory.
///
/// The old `Codable` conformance (serialized into the now-removed
/// `ParseSnapshot`) was dropped in the SQLite-first refactor — nothing
/// encodes/decodes this type anymore.
enum ParsedLine: Sendable, Equatable {
    case assistant(RawEntry)
    case user(UserAux)
    case system(SystemAux)

    struct UserAux: Sendable, Equatable {
        let uuid: String
        let parentUuid: String?
        let sessionId: String
        let timestamp: String
        let text: String
    }

    struct SystemAux: Sendable, Equatable {
        let uuid: String
        let sessionId: String
        let timestamp: String
        let systemPrompt: String?
        let toolDefinitionsJSON: Data?
        let rawPayload: Data?
    }
}
