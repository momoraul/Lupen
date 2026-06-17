import Foundation

enum AuxiliaryLinker {
    static func link(
        assistantEntries: [RawEntry],
        auxiliaryLines: [ParsedLine]
    ) -> [String: AuxiliaryRequestData] {
        // Index: assistant uuid → requestId
        var uuidToRequestId: [String: String] = [:]
        for entry in assistantEntries {
            guard let rid = entry.requestId else { continue }
            uuidToRequestId[entry.uuid] = rid
        }

        // Index: sessionId → most recent SystemAux
        var sessionToSystem: [String: ParsedLine.SystemAux] = [:]
        for line in auxiliaryLines {
            if case .system(let sys) = line {
                if let existing = sessionToSystem[sys.sessionId] {
                    if sys.timestamp > existing.timestamp {
                        sessionToSystem[sys.sessionId] = sys
                    }
                } else {
                    sessionToSystem[sys.sessionId] = sys
                }
            }
        }

        // Pass 1: initialize with system data + assistant content extraction
        var result: [String: AuxiliaryRequestData] = [:]
        for entry in assistantEntries {
            guard let rid = entry.requestId else { continue }
            let sys = sessionToSystem[entry.sessionId]
            let assistantText = entry.message.content?.flatText
            result[rid] = AuxiliaryRequestData(
                userContent: nil,
                assistantContent: assistantText,
                systemPrompt: sys?.systemPrompt,
                toolDefinitionsJSON: sys?.toolDefinitionsJSON,
                rawPayload: sys?.rawPayload,
                userParentUuid: entry.parentUuid
            )
        }

        // Pass 2: link user entries via parentUuid
        var parentUuidToRequestIds: [String: [String]] = [:]
        for entry in assistantEntries {
            guard let parent = entry.parentUuid, let rid = entry.requestId else { continue }
            parentUuidToRequestIds[parent, default: []].append(rid)
        }

        for line in auxiliaryLines {
            guard case .user(let user) = line else { continue }
            guard let requestIds = parentUuidToRequestIds[user.uuid] else { continue }
            for rid in requestIds {
                guard let existing = result[rid] else { continue }
                result[rid] = existing.merging(AuxiliaryRequestData(
                    userContent: user.text,
                    assistantContent: nil,
                    systemPrompt: nil,
                    toolDefinitionsJSON: nil,
                    rawPayload: nil,
                    userParentUuid: nil
                ))
            }
        }

        return result
    }
}
