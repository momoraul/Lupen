import Foundation

struct AuxiliaryRequestData: Sendable, Equatable {
    let userContent: String?
    let assistantContent: String?
    let systemPrompt: String?
    let toolDefinitionsJSON: Data?
    let rawPayload: Data?
    let userParentUuid: String?

    static let empty = AuxiliaryRequestData(
        userContent: nil, assistantContent: nil, systemPrompt: nil,
        toolDefinitionsJSON: nil, rawPayload: nil, userParentUuid: nil
    )

    func merging(_ other: AuxiliaryRequestData) -> AuxiliaryRequestData {
        AuxiliaryRequestData(
            userContent: other.userContent ?? userContent,
            assistantContent: other.assistantContent ?? assistantContent,
            systemPrompt: other.systemPrompt ?? systemPrompt,
            toolDefinitionsJSON: other.toolDefinitionsJSON ?? toolDefinitionsJSON,
            rawPayload: other.rawPayload ?? rawPayload,
            userParentUuid: other.userParentUuid ?? userParentUuid
        )
    }
}
