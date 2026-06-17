import Foundation

enum CodexSessionIndexBuilder {
    static func build(
        from files: [URL],
        titleIndex: CodexSessionTitleIndex = .empty
    ) -> CodexSessionIndex {
        var sessions: [CodexSessionMetadata] = []
        var rejected: [CodexSessionIndex.RejectedFile] = []

        for file in files {
            do {
                let metadata = try CodexSessionMetadataReader.readMetadata(from: file)
                sessions.append(metadata.withTitleHint(titleIndex.title(for: metadata.id)))
            } catch let error as CodexSessionMetadataReadError {
                rejected.append(.init(url: file, reason: error.description))
            } catch {
                rejected.append(.init(url: file, reason: error.localizedDescription))
            }
        }

        sessions.sort { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?) where l != r:
                return l > r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.fileURL.path < rhs.fileURL.path
            }
        }
        return CodexSessionIndex(sessions: sessions, rejectedFiles: rejected)
    }
}
