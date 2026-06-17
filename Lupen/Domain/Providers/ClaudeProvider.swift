import Foundation

struct ClaudeLineParseResult: Sendable {
    let assistantEntries: [RawEntry]
    let auxiliaryLines: [ParsedLine]
}

final class ClaudeProvider: ConversationProvider, @unchecked Sendable {
    let kind: ProviderKind = .claudeCode

    private let fileDiscovery: FileDiscovery
    private let parser: JSONLParser
    private let fileWatcher: FileWatcher

    init(
        fileDiscovery: FileDiscovery = FileDiscovery(),
        parser: JSONLParser = JSONLParser(),
        fileWatcher: FileWatcher = FileWatcher()
    ) {
        self.fileDiscovery = fileDiscovery
        self.parser = parser
        self.fileWatcher = fileWatcher
    }

    var defaultSourceRoot: URL {
        fileDiscovery.projectsDirectory
    }

    func discoverSources(in root: URL? = nil) -> [ConversationSource] {
        discoverFiles(in: root).map { file in
            ConversationSource(
                provider: kind,
                url: file.url,
                rawSessionId: file.sessionId,
                projectPath: file.projectPath,
                isAuxiliarySession: file.isSubagent
            )
        }
    }

    func discoverFiles(in root: URL? = nil) -> [FileDiscovery.DiscoveredFile] {
        fileDiscovery.discoverJSONLFiles(in: root ?? defaultSourceRoot)
    }

    func readLines(from source: ConversationSource, offset: UInt64) -> ConversationLineBatch {
        let (lines, newOffset) = JSONLLineReader.readLines(from: source.url, offset: offset)
        return ConversationLineBatch(source: source, lines: lines, newOffset: newOffset)
    }

    func readLines(from url: URL, offset: UInt64) -> (lines: [Data], newOffset: UInt64) {
        JSONLLineReader.readLines(from: url, offset: offset)
    }

    func parseLines(_ lines: [Data], filePath: String) -> ClaudeLineParseResult {
        let parsed = parser.classifyPreReadLines(lines, filePath: filePath)
        return ClaudeLineParseResult(
            assistantEntries: parsed.assistant,
            auxiliaryLines: parsed.auxiliary
        )
    }

    func aggregateUsage(
        _ entries: [RawEntry],
        projectPathMap: [String: String] = [:]
    ) -> SessionAggregator.Result {
        Self.aggregateUsage(entries, projectPathMap: projectPathMap)
    }

    static func aggregateUsage(
        _ entries: [RawEntry],
        projectPathMap: [String: String] = [:]
    ) -> SessionAggregator.Result {
        SessionAggregator.aggregate(entries, projectPathMap: projectPathMap)
    }

    func computeGroundTruth(files: [URL]) -> GroundTruth.Report {
        GroundTruthCalculator.compute(files: files)
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
