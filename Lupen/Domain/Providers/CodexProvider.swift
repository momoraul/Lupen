import Foundation

final class CodexProvider: ConversationProvider, @unchecked Sendable {
    let kind: ProviderKind = .codex

    private let discovery: CodexSessionDiscovery
    private let fileWatcher: FileWatcher

    init(
        discovery: CodexSessionDiscovery = CodexSessionDiscovery(),
        fileWatcher: FileWatcher = FileWatcher()
    ) {
        self.discovery = discovery
        self.fileWatcher = fileWatcher
    }

    var defaultSourceRoot: URL {
        discovery.sessionsDirectory
    }

    func discoverSources(in root: URL? = nil) -> [ConversationSource] {
        discoverFiles(in: root).compactMap { url in
            guard let metadata = try? CodexSessionMetadataReader.readMetadata(from: url) else {
                return nil
            }
            return ConversationSource(
                provider: kind,
                url: url,
                rawSessionId: metadata.id,
                projectPath: metadata.cwd,
                isAuxiliarySession: false
            )
        }
    }

    func discoverFiles(in root: URL? = nil) -> [URL] {
        discovery.discoverRolloutFiles(in: root ?? defaultSourceRoot)
    }

    func readLines(from source: ConversationSource, offset: UInt64) -> ConversationLineBatch {
        let (lines, newOffset) = JSONLLineReader.readLines(from: source.url, offset: offset)
        return ConversationLineBatch(source: source, lines: lines, newOffset: newOffset)
    }

    func startWatching(
        sourceRoot: URL,
        onFileAppend: @escaping @Sendable (URL) -> Void,
        onDirectoryChange: @escaping @Sendable () -> Void
    ) {
        fileWatcher.setCallbacks(
            onFileAppend: { url, _ in onFileAppend(url) },
            onDirectoryChange: onDirectoryChange
        )
        fileWatcher.startWatching(directory: sourceRoot)
    }

    func stopWatching() {
        fileWatcher.stopAll()
    }
}
