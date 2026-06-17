import Foundation

struct ConversationSource: Equatable, Sendable {
    let provider: ProviderKind
    let url: URL
    let rawSessionId: String
    let projectPath: String?
    let isAuxiliarySession: Bool
}

struct ConversationLineBatch: Sendable {
    let source: ConversationSource
    let lines: [Data]
    let newOffset: UInt64
}

protocol ConversationProvider: AnyObject {
    var kind: ProviderKind { get }
    var defaultSourceRoot: URL { get }

    func discoverSources(in root: URL?) -> [ConversationSource]
    func readLines(from source: ConversationSource, offset: UInt64) -> ConversationLineBatch
    func startWatching(
        sourceRoot: URL,
        onFileAppend: @escaping @Sendable (URL) -> Void,
        onDirectoryChange: @escaping @Sendable () -> Void
    )
    func stopWatching()
}

