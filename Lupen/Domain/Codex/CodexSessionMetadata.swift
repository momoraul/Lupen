import Foundation

struct CodexSessionMetadata: Equatable, Sendable {
    let id: String
    let fileURL: URL
    let createdAt: Date?
    let cwd: String?
    let originator: String?
    let cliVersion: String?
    let model: String?
    let forkedFromId: String?
    let threadSource: String?
    let agentNickname: String?
    let subagentParentThreadId: String?
    let titleHint: String?
    /// `session_meta.payload.git.branch` — the checked-out branch when the
    /// rollout started. Absent when the cwd is not a git repository.
    let gitBranch: String?

    init(
        id: String,
        fileURL: URL,
        createdAt: Date?,
        cwd: String?,
        originator: String?,
        cliVersion: String?,
        model: String?,
        forkedFromId: String?,
        threadSource: String? = nil,
        agentNickname: String? = nil,
        subagentParentThreadId: String? = nil,
        titleHint: String?,
        gitBranch: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.cwd = cwd
        self.originator = originator
        self.cliVersion = cliVersion
        self.model = model
        self.forkedFromId = forkedFromId
        self.threadSource = threadSource
        self.agentNickname = agentNickname
        self.subagentParentThreadId = subagentParentThreadId
        self.titleHint = titleHint
        self.gitBranch = gitBranch
    }

    var scopedId: String {
        ProviderScopedID(provider: .codex, rawSessionId: id).value
    }

    var subagentParentRawSessionId: String? {
        guard isSubagentThread else { return nil }
        return nonEmpty(subagentParentThreadId) ?? nonEmpty(forkedFromId)
    }

    var visibleRawSessionId: String {
        subagentParentRawSessionId ?? id
    }

    var visibleScopedId: String {
        ProviderScopedID(provider: .codex, rawSessionId: visibleRawSessionId).value
    }

    var isSubagentThread: Bool {
        normalized(threadSource) == "subagent" || nonEmpty(subagentParentThreadId) != nil
    }

    func withTitleHint(_ titleHint: String?) -> CodexSessionMetadata {
        CodexSessionMetadata(
            id: id,
            fileURL: fileURL,
            createdAt: createdAt,
            cwd: cwd,
            originator: originator,
            cliVersion: cliVersion,
            model: model,
            forkedFromId: forkedFromId,
            threadSource: threadSource,
            agentNickname: agentNickname,
            subagentParentThreadId: subagentParentThreadId,
            titleHint: titleHint,
            gitBranch: gitBranch
        )
    }

    private func normalized(_ value: String?) -> String? {
        nonEmpty(value)?.lowercased()
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct CodexSessionIndex: Equatable, Sendable {
    struct RejectedFile: Equatable, Sendable {
        let url: URL
        let reason: String
    }

    let sessions: [CodexSessionMetadata]
    let rejectedFiles: [RejectedFile]
}

struct CodexSessionTitleIndex: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let id: String
        let threadName: String?
        let updatedAt: Date?
    }

    static let empty = CodexSessionTitleIndex(entriesById: [:], rejectedLineCount: 0)

    let entriesById: [String: Entry]
    let rejectedLineCount: Int

    func title(for sessionId: String) -> String? {
        guard let title = entriesById[sessionId]?.threadName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }
}
