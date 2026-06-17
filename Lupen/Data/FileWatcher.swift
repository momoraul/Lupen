import Foundation
import CoreServices

/// Watches the `~/.claude/projects/` tree.
///
/// A single `FSEventStream` covers the whole tree to keep FD usage at **O(1)**.
/// Per-file `FileHandle`/`DispatchSource` was abandoned because large projects
/// occupied 2000+ FDs and triggered **EMFILE** (`NSPOSIXErrorDomain 24`),
/// breaking unrelated file IO such as snapshot save. Append detection only
/// needs the changed path — actual data is read by
/// `AppStateStore.handleNewData` via bookmark offsets, so per-file handles
/// were unnecessary.
///
/// The callback signature is kept for source compatibility — `onFileAppend`
/// passes an empty `Data()` (callers already discarded it with `_`).
final class FileWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.momoraul.lupen.filewatcher", qos: .utility)

    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private nonisolated(unsafe) var onFileAppend: ((URL, Data) -> Void)?
    private nonisolated(unsafe) var onDirectoryChange: (() -> Void)?

    init() {}

    deinit { stopAll() }

    /// `onFileAppend` receives an empty `Data()` — FSEvents is path-only and
    /// callers don't read the bytes here.
    nonisolated func setCallbacks(
        onFileAppend: @escaping @Sendable (URL, Data) -> Void,
        onDirectoryChange: @escaping @Sendable () -> Void
    ) {
        queue.sync { [weak self] in
            guard let self else { return }
            self.onFileAppend = onFileAppend
            self.onDirectoryChange = onDirectoryChange
        }
    }

    /// Watches the full subtree of `directory`. Tears down any existing stream
    /// first. Event latency is 250ms — live appends still arrive ahead of the
    /// debounced rebuild (300ms+), so the user perceives no delay.
    nonisolated func startWatching(directory: URL) {
        queue.sync { [weak self] in
            guard let self else { return }
            self.tearDownStreamLocked()

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let paths = [directory.path] as CFArray
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                fileWatcherEventCallback,
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.25,
                flags
            ) else {
                // Stream creation failure is fatal — log loudly. Previously
                // this was a silent fail, forcing us to backtrack from user
                // symptoms to discover that FileWatcher was dead.
                LoggerService.shared.logFromAnyThread(
                    .error,
                    "FSEventStreamCreate returned nil — file watching disabled for \(directory.path)",
                    context: "FileWatcher"
                )
                return
            }
            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)
            self.stream = stream
            LoggerService.shared.logFromAnyThread(
                .info,
                "FSEvents stream started — path=\(directory.path) latency=0.25s",
                context: "FileWatcher"
            )
        }
    }

    /// Stops watching and releases resources.
    nonisolated func stopAll() {
        queue.sync { [weak self] in
            self?.tearDownStreamLocked()
        }
    }

    // MARK: - Private

    /// Caller must already be on `queue`.
    private func tearDownStreamLocked() {
        guard let stream = self.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        LoggerService.shared.logFromAnyThread(
            .debug,
            "FSEvents stream torn down",
            context: "FileWatcher"
        )
    }

    /// Routing entry point invoked from the FSEvents callback. Filters to
    /// Claude JSONL files and workflow metadata JSON files, then classifies
    /// each event as append vs. new file based on its flags.
    fileprivate func dispatchEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard let onFileAppend, let onDirectoryChange else { return }

        var sawDirectoryMutation = false
        var jsonlCount = 0
        var workflowMetadataCount = 0
        var modifiedCount = 0
        var createdCount = 0
        var renamedCount = 0
        var removedCount = 0
        for (index, path) in paths.enumerated() {
            let isJSONL = path.hasSuffix(".jsonl")
            let isWorkflowMetadata = Self.isWorkflowMetadataPath(path)
            guard isJSONL || isWorkflowMetadata else { continue }
            if isJSONL { jsonlCount += 1 }
            if isWorkflowMetadata { workflowMetadataCount += 1 }
            let flag = flags[index]

            let isCreated = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0
            let isRenamed = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
            let isRemoved = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) != 0
            let isModified = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0

            if isRemoved {
                removedCount += 1
                onFileAppend(URL(fileURLWithPath: path), Data())
                if isWorkflowMetadata {
                    continue
                }
                // A removed file changes the set of discoverable sessions.
                // Route it through the directory path so provider-specific
                // state can prune stale sessions, bookmarks, diagnostics,
                // and persisted snapshot fingerprints.
                sawDirectoryMutation = true
                continue
            }

            // FSEvents may attach `itemCreated` to any inode it sees for the
            // first time after the stream starts, so a single batch can carry
            // `itemCreated | itemModified` together. We must therefore judge
            // `isModified` **independently** rather than branching on
            // `isCreated` alone:
            //   - Modified → route as append (write to an existing file).
            //   - Created / Renamed → directory-mutation signal (new session
            //     file). When both flags arrive together, fire both.
            if isModified {
                modifiedCount += 1
                onFileAppend(URL(fileURLWithPath: path), Data())
            }
            if isCreated { createdCount += 1 }
            if isRenamed { renamedCount += 1 }
            if isCreated || isRenamed {
                if isJSONL {
                    sawDirectoryMutation = true
                }
                if !isModified {
                    onFileAppend(URL(fileURLWithPath: path), Data())
                }
            }
        }

        if sawDirectoryMutation {
            onDirectoryChange()
        }

        // Batch-level diagnostic — always emitted at debug level so that
        // long-running sessions can confirm which flags arrived for which
        // paths. This log is the only reliable signal that FSEvents is still
        // alive (events count > 0). To avoid log flooding, only one line per
        // batch is emitted and paths are truncated to the first 10.
        if !paths.isEmpty {
            let sample = paths.prefix(10).joined(separator: " | ")
            let more = paths.count > 10 ? " (+\(paths.count - 10) more)" : ""
            LoggerService.shared.logFromAnyThread(
                .debug,
                "events total=\(paths.count) jsonl=\(jsonlCount) workflowMetadata=\(workflowMetadataCount) modified=\(modifiedCount) created=\(createdCount) renamed=\(renamedCount) removed=\(removedCount) | \(sample)\(more)",
                context: "FileWatcher"
            )
        }
    }

    private static func isWorkflowMetadataPath(_ path: String) -> Bool {
        guard path.hasSuffix(".json") else { return false }
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().lastPathComponent == "workflows"
    }
}

/// C-callable callback handed to `FSEventStreamCreate`. Restores the
/// `Unmanaged.passUnretained(FileWatcher)` pointer stashed in `context.info`
/// and dispatches into the Swift instance. `takeUnretainedValue` is safe
/// because the owner (`AppStateStore`) keeps a strong reference to the
/// FileWatcher for its full lifetime.
private func fileWatcherEventCallback(
    stream: ConstFSEventStreamRef,
    clientInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo else { return }
    let watcher = Unmanaged<FileWatcher>.fromOpaque(clientInfo).takeUnretainedValue()

    // `kFSEventStreamCreateFlagUseCFTypes` → eventPaths is a CFArray<CFString>.
    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let count = CFArrayGetCount(cfPaths)
    var paths: [String] = []
    paths.reserveCapacity(count)
    for index in 0..<count {
        guard let raw = CFArrayGetValueAtIndex(cfPaths, index) else { continue }
        let cfString = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        paths.append(cfString as String)
    }

    var flagsCopy: [FSEventStreamEventFlags] = []
    flagsCopy.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        flagsCopy.append(eventFlags[index])
    }

    watcher.dispatchEvents(paths: paths, flags: flagsCopy)
}
