import Foundation

enum CodexSessionMetadataReadError: Error, Equatable, CustomStringConvertible {
    case cannotOpen
    case emptyFile
    case firstLineTooLarge
    case invalidJSON
    case notSessionMeta
    case missingSessionId
    case nonCodexOriginator(String)

    var description: String {
        switch self {
        case .cannotOpen:
            return "cannot open file"
        case .emptyFile:
            return "empty file"
        case .firstLineTooLarge:
            return "first line exceeds maximum size"
        case .invalidJSON:
            return "invalid session_meta JSON"
        case .notSessionMeta:
            return "first line is not session_meta"
        case .missingSessionId:
            return "session_meta is missing id"
        case .nonCodexOriginator(let originator):
            return "originator is not Codex: \(originator)"
        }
    }
}

enum CodexSessionMetadataReader {
    static let defaultMaxFirstLineBytes = 1_048_576

    static func readMetadata(
        from url: URL,
        maxFirstLineBytes: Int = defaultMaxFirstLineBytes
    ) throws -> CodexSessionMetadata {
        let line = try readFirstLine(from: url, maxBytes: maxFirstLineBytes)
        let envelope: SessionMetaEnvelope
        do {
            envelope = try JSONDecoder().decode(SessionMetaEnvelope.self, from: line)
        } catch {
            throw CodexSessionMetadataReadError.invalidJSON
        }

        guard envelope.type == "session_meta" else {
            throw CodexSessionMetadataReadError.notSessionMeta
        }

        let originator = envelope.payload?.originator ?? envelope.originator
        if let originator, !originator.lowercased().hasPrefix("codex") {
            throw CodexSessionMetadataReadError.nonCodexOriginator(originator)
        }

        let idCandidate = envelope.payload?.id
            ?? envelope.payload?.sessionId
            ?? envelope.id
            ?? envelope.sessionId
            ?? fallbackSessionId(from: url)
        guard let id = idCandidate, !id.isEmpty else {
            throw CodexSessionMetadataReadError.missingSessionId
        }

        let timestamp = envelope.payload?.timestamp ?? envelope.timestamp
        let threadSource = envelope.payload?.threadSource ?? envelope.threadSource
        let agentNickname = envelope.payload?.agentNickname ?? envelope.agentNickname
        return CodexSessionMetadata(
            id: id,
            fileURL: url,
            createdAt: CodexTimestampParser.parse(timestamp),
            cwd: envelope.payload?.cwd ?? envelope.cwd,
            originator: originator,
            cliVersion: envelope.payload?.cliVersion ?? envelope.cliVersion,
            model: envelope.payload?.model ?? envelope.model,
            forkedFromId: envelope.payload?.forkedFromId ?? envelope.forkedFromId,
            threadSource: threadSource,
            agentNickname: agentNickname,
            subagentParentThreadId: envelope.payload?.subagentParentThreadId
                ?? envelope.subagentParentThreadId,
            titleHint: nil,
            gitBranch: envelope.payload?.git?.branch ?? envelope.git?.branch
        )
    }

    private static func readFirstLine(from url: URL, maxBytes: Int) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw CodexSessionMetadataReadError.cannotOpen
        }
        defer { try? handle.close() }

        var buffer = Data()
        while buffer.count <= maxBytes {
            let chunk = handle.readData(ofLength: min(65_536, maxBytes - buffer.count + 1))
            if chunk.isEmpty {
                if buffer.isEmpty {
                    throw CodexSessionMetadataReadError.emptyFile
                }
                return stripTrailingCR(buffer)
            }
            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[..<newlineIndex])
                if buffer.isEmpty {
                    throw CodexSessionMetadataReadError.emptyFile
                }
                return stripTrailingCR(buffer)
            }
            buffer.append(chunk)
        }
        throw CodexSessionMetadataReadError.firstLineTooLarge
    }

    private static func stripTrailingCR(_ data: Data) -> Data {
        if data.last == 0x0D {
            return data.dropLast()
        }
        return data
    }

    private static func fallbackSessionId(from url: URL) -> String? {
        let basename = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return basename.isEmpty ? nil : basename
    }

    private struct SessionMetaEnvelope: Decodable {
        let type: String?
        let timestamp: String?
        let id: String?
        let sessionId: String?
        let cwd: String?
        let originator: String?
        let cliVersion: String?
        let model: String?
        let forkedFromId: String?
        let threadSource: String?
        let agentNickname: String?
        let source: SourceEnvelope?
        let git: GitInfo?
        let payload: Payload?

        var subagentParentThreadId: String? {
            source?.subagent?.threadSpawn?.parentThreadId
        }

        enum CodingKeys: String, CodingKey {
            case type, timestamp, id, cwd, originator, model, payload
            case sessionId = "session_id"
            case cliVersion = "cli_version"
            case forkedFromId = "forked_from_id"
            case threadSource = "thread_source"
            case agentNickname = "agent_nickname"
            case source, git
        }
    }

    private struct Payload: Decodable {
        let id: String?
        let sessionId: String?
        let timestamp: String?
        let cwd: String?
        let originator: String?
        let cliVersion: String?
        let model: String?
        let forkedFromId: String?
        let threadSource: String?
        let agentNickname: String?
        let source: SourceEnvelope?
        let git: GitInfo?

        var subagentParentThreadId: String? {
            source?.subagent?.threadSpawn?.parentThreadId
        }

        enum CodingKeys: String, CodingKey {
            case id, timestamp, cwd, originator, model
            case sessionId = "session_id"
            case cliVersion = "cli_version"
            case forkedFromId = "forked_from_id"
            case threadSource = "thread_source"
            case agentNickname = "agent_nickname"
            case source, git
        }
    }

    /// `session_meta` git facts (codex-rs `GitInfo`): only `branch` is
    /// consumed today; commit/repository stay undecoded.
    private struct GitInfo: Decodable {
        let branch: String?
    }

    private struct SourceEnvelope: Decodable {
        let subagent: Subagent?

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                subagent = nil
                return
            }
            subagent = try container.decodeIfPresent(Subagent.self, forKey: .subagent)
        }

        private enum CodingKeys: String, CodingKey {
            case subagent
        }
    }

    private struct Subagent: Decodable {
        let threadSpawn: ThreadSpawn?

        enum CodingKeys: String, CodingKey {
            case threadSpawn = "thread_spawn"
        }
    }

    private struct ThreadSpawn: Decodable {
        let parentThreadId: String?

        enum CodingKeys: String, CodingKey {
            case parentThreadId = "parent_thread_id"
        }
    }
}

enum CodexTimestampParser {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let wholeSecond: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractional.date(from: value) ?? wholeSecond.date(from: value)
    }
}
